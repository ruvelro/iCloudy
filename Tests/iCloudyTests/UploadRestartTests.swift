import XCTest
@testable import iCloudy

/// An upload that failed because its file could not be read used to stay failed for good: fixing the permissions
/// changes the file's change time, the saved fingerprint no longer matched, and every retry said "El archivo cambió
/// durante la subida". Nothing had been sent, so nothing could be mixed. When bytes were sent, the protection against
/// mixing two versions (A03) stays, and the person gets a way out: starting that upload from zero.
@MainActor
final class UploadRestartTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots {
            // Undo any chmod 000 first, or the folder cannot be removed.
            if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                for name in names { chmod(root.appendingPathComponent(name).path, 0o644) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        super.tearDown()
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
    private func fixture() throws -> (URL, DemoStore, TransferQueue) {
        let root = try root()
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        return (root, demo, queue)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
        throw CloudError.message("Test timeout")
    }
    private func upload(_ url: URL) -> Transfer {
        Transfer(name: url.lastPathComponent, destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: url)
    }
    private func modified(_ url: URL) throws -> Date? { try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    private func content(of name: String, in demo: DemoStore, root: URL) async throws -> Data {
        let file = try XCTUnwrap(demo.list("root").first { $0.name == name })
        let target = root.appendingPathComponent("descarga-" + UUID().uuidString)
        try await demo.download(file, to: target) { _, _ in }
        return try Data(contentsOf: target)
    }

    // MARK: - The checkpoint

    func testAChangeBeforeAnyByteWasSentStartsAFreshCheckpointAndSession() throws {
        let local = try root().appendingPathComponent("a.txt"); try Data("abc".utf8).write(to: local)
        var saved = UploadCheckpoint(total: 3, modified: try modified(local))
        saved.sourceStamp = try UploadSourceStamp(local)
        saved.url = URL(string: "https://upload.example/session")
        XCTAssertEqual(chmod(local.path, 0o600), 0, "Only the change time moves")
        XCTAssertNotEqual(saved.sourceStamp, try UploadSourceStamp(local))

        let resumed = try UploadCheckpoint.resuming(saved, for: local, total: 3, modified: try modified(local))
        XCTAssertNil(resumed.url, "A session that may have received unsaved bytes is not continued")
        XCTAssertEqual(resumed.offset, 0)
        XCTAssertEqual(resumed.sourceStamp, try UploadSourceStamp(local))
    }

    func testAnUnchangedSourceKeepsItsSession() throws {
        let local = try root().appendingPathComponent("a.txt"); try Data("abc".utf8).write(to: local)
        var saved = UploadCheckpoint(total: 3, modified: try modified(local))
        saved.sourceStamp = try UploadSourceStamp(local); saved.url = URL(string: "https://upload.example/session"); saved.offset = 2
        let resumed = try UploadCheckpoint.resuming(saved, for: local, total: 3, modified: try modified(local))
        XCTAssertEqual(resumed.url, saved.url); XCTAssertEqual(resumed.offset, 2)
    }

    func testOnceBytesWereSentAnyDifferenceIsRefusedEvenAPermissionChange() throws {
        let local = try root().appendingPathComponent("a.txt"); try Data("abc".utf8).write(to: local)
        let date = try modified(local)
        var saved = UploadCheckpoint(total: 3, modified: date)
        saved.sourceStamp = try UploadSourceStamp(local); saved.offset = 1; saved.url = URL(string: "https://upload.example/session")
        XCTAssertEqual(chmod(local.path, 0o600), 0)
        XCTAssertThrowsError(try UploadCheckpoint.resuming(saved, for: local, total: 3, modified: date)) { XCTAssertTrue($0 is UploadSourceChanged) }

        // A03: same size, content changed, modification time put back. Still refused.
        try Data("xyz".utf8).write(to: local)
        try FileManager.default.setAttributes([.modificationDate: date!], ofItemAtPath: local.path)
        XCTAssertThrowsError(try UploadCheckpoint.resuming(saved, for: local, total: 3, modified: date)) { XCTAssertTrue($0 is UploadSourceChanged) }
    }

    // MARK: - The queue

    func testFixingAnUnreadableFileAndRetryingUploadsIt() async throws {
        let (root, demo, queue) = try fixture()
        let source = root.appendingPathComponent("informe.txt")
        try Data("contenido del informe".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, 0o000), 0)
        let job = upload(source)
        try queue.add([job])
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .failed)
        XCTAssertEqual(queue.items.first?.needsRestart, false, "Nothing was sent: there is nothing to restart, only to retry")

        XCTAssertEqual(chmod(source.path, 0o644), 0)
        queue.retry(job.id)
        try await wait { !queue.isWorking && queue.items.first?.state != .queued }
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        let uploaded = try await content(of: "informe.txt", in: demo, root: root)
        XCTAssertEqual(uploaded, Data("contenido del informe".utf8))
    }

    func testASourceThatChangedMidwayOffersARestartThatUploadsTheNewVersionWhole() async throws {
        let (root, demo, queue) = try fixture()
        demo.latency = .milliseconds(20)
        let source = root.appendingPathComponent("grande.dat")
        try Data(repeating: 1, count: 4 * 1024 * 1024).write(to: source)
        let date = try XCTUnwrap(try modified(source))
        let job = upload(source)
        try queue.add([job])
        try await wait { (queue.items.first?.uploads["."]?.offset ?? 0) > 0 }
        queue.cancel(job.id, pause: true)
        try await wait { !queue.isWorking }

        // Same size and the same modification time: only the content and the change time say it is another file.
        let replacement = Data(repeating: 2, count: 4 * 1024 * 1024)
        try replacement.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        demo.latency = .milliseconds(1)
        queue.retry(job.id)
        try await wait { !queue.isWorking && queue.items.first?.state != .queued }
        let failed = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.needsRestart)
        XCTAssertTrue(failed.detail.contains("Empezar de cero"), failed.detail)
        XCTAssertTrue(try demo.list("root").filter { $0.name == "grande.dat" }.isEmpty, "Nothing mixed was published")

        queue.restartFromZero(job.id)
        try await wait { !queue.isWorking && queue.items.first?.state != .queued }
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        XCTAssertEqual(queue.items.first?.needsRestart, false)
        let uploaded = try await content(of: "grande.dat", in: demo, root: root)
        XCTAssertEqual(uploaded, replacement)
    }

    func testTheRestartFlagSurvivesARelaunch() throws {
        var transfer = Transfer(name: "a", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: URL(fileURLWithPath: "/tmp/a"))
        transfer.needsRestart = true
        let restored = try JSONDecoder().decode(Transfer.self, from: JSONEncoder().encode(transfer))
        XCTAssertTrue(restored.needsRestart)
        let legacy = try JSONDecoder().decode(Transfer.self, from: Data(#"{"accountID":"demo","direction":"upload","localURL":"file:///tmp/a"}"#.utf8))
        XCTAssertFalse(legacy.needsRestart)
    }
}
