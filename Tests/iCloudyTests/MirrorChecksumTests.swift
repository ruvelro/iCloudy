import XCTest
@testable import iCloudy

/// Comparing mirrored files by checksum, and the verification pass that looks at every one of them.
@MainActor
final class MirrorChecksumTests: XCTestCase {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func touch(_ url: URL, _ date: Date) throws { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }

    func testTheTwoWayPlannerTrustsAMatchingChecksumOverTheDates() throws {
        let local = ["a.txt": FileStamp(size: 3, modified: Date(timeIntervalSince1970: 500))]
        let remote = ["a.txt": CloudFile(id: "a", name: "a.txt", mime: "x", size: 3, modified: Date(timeIntervalSince1970: 100), webURL: nil, isFolder: false)]
        let baseline = ["a.txt": SyncEntry(local: FileStamp(size: 3, modified: Date(timeIntervalSince1970: 100)), remoteID: "a", remoteSize: 3,
                                           remoteModified: Date(timeIntervalSince1970: 100), isFolder: false)]
        XCTAssertEqual(try TwoWayPlanner.plan(local: local, remote: remote, baseline: baseline), [.upload("a.txt", replacing: "a")], "By date, it changed")
        var same = ContentComparison.Result(); same.identical = ["a.txt"]
        XCTAssertEqual(try TwoWayPlanner.plan(local: local, remote: remote, baseline: baseline, contents: same), [.adopt("a.txt", remote["a.txt"]!)])
        var different = ContentComparison.Result(); different.different = ["a.txt"]
        XCTAssertEqual(try TwoWayPlanner.plan(local: local, remote: remote, baseline: [:], contents: different), [.conflict("a.txt", remote["a.txt"]!)],
                       "The same size is no longer taken as the same file when the checksum says otherwise")
    }

    private struct Fixture {
        let demo: DemoStore
        let queue: TransferQueue
        let manager: MirrorManager
        let local: URL
        let remote: String
        @MainActor var id: UUID { manager.mirrors[0].id }
    }
    private func fixture(mode: FolderMirror.Mode, options: MirrorOptions) async throws -> Fixture {
        let root = try temporaryRoot()
        let local = root.appendingPathComponent("Carpeta")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        demo.listsChecksums = true
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        if mode == .upload { try write("uno", to: local.appendingPathComponent("a.txt")) }
        else { _ = try demo.add(name: "a.txt", parent: remoteID, content: Data("uno".utf8)) }
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [], mode: mode)
        manager.setOptions(options, for: manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != nil && manager.mirrors.first?.activeTransferID == nil }
        return Fixture(demo: demo, queue: queue, manager: manager, local: local, remote: remoteID)
    }

    func testAnUploadMirrorDoesNotResendAFileThatOnlyChangedDate() async throws {
        let f = try await fixture(mode: .upload, options: MirrorOptions(compareChecksums: true))
        let count = f.queue.items.count
        try touch(f.local.appendingPathComponent("a.txt"), Date(timeIntervalSinceNow: -3600))
        f.manager.syncNow(f.id)
        try await wait { f.manager.mirrors[0].stamps["a.txt"]?.modified.timeIntervalSinceNow ?? 0 < -3000 }
        try await assertStays({ f.queue.items.count == count }, for: .milliseconds(100))
    }

    func testTheVerificationPassFindsADamagedCloudCopyAndTheNextRunSendsItAgain() async throws {
        let f = try await fixture(mode: .upload, options: MirrorOptions())
        let a = try XCTUnwrap(f.demo.list(f.remote).first)
        try Data("dos".utf8).write(to: f.demo.directory.appendingPathComponent(a.id))
        let summary = try await f.manager.verify(f.id)
        XCTAssertEqual(summary.checked, 1)
        XCTAssertEqual(summary.missing, 1, summary.text)
        XCTAssertNotNil(f.manager.mirrors[0].lastVerified)
        XCTAssertEqual(f.manager.mirrors[0].lastVerification, summary.text)
        // The bytes reach the cloud a moment before the mirror closes the job that sent them, and only then does it
        // know the file as synced again; verifying in between would find nothing it vouches for.
        try await wait {
            (try? Data(contentsOf: f.demo.directory.appendingPathComponent(a.id))) == Data("uno".utf8)
                && f.manager.mirrors[0].activeTransferID == nil && f.manager.mirrors[0].stamps["a.txt"] != nil
        }
        let clean = try await f.manager.verify(f.id)
        XCTAssertEqual(clean.verified, 1, clean.text)
        XCTAssertEqual(clean.missing, 0)
    }

    func testADownloadMirrorRepairsALocalCopyThatChangedUnderTheSameDate() async throws {
        let f = try await fixture(mode: .download, options: MirrorOptions(compareChecksums: true))
        let file = f.local.appendingPathComponent("a.txt")
        let date = try XCTUnwrap(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data("UNO".utf8).write(to: file)
        try touch(file, date)
        // Dates do not round-trip to the nanosecond everywhere: the baseline takes the stamp as it reads back now, which
        // is what a copy silently damaged in place looks like.
        f.manager.mirrors[0].baseline["a.txt"]?.local = try MirrorPlanner.stamps(of: f.local)["a.txt"]
        let summary = try await f.manager.verify(f.id)
        XCTAssertEqual(summary.missing, 1, summary.text)
        try await wait { (try? String(contentsOf: file, encoding: .utf8)) == "uno" }
        XCTAssertNil(f.queue.conflict, "Its own copy is replaced without asking")
    }

    func testOlderOptionsCompareByDate() throws {
        let options = try JSONDecoder().decode(MirrorOptions.self, from: Data("{}".utf8))
        XCTAssertFalse(options.compareChecksums)
        XCTAssertNil(options.verifyEvery)
        let mirror = try JSONDecoder().decode(FolderMirror.self, from: Data(#"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/"}"#.utf8))
        XCTAssertNil(mirror.lastVerified)
    }
}
