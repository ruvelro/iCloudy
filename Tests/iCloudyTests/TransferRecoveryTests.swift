import XCTest
@testable import iCloudy

/// After a transfer that failed or stopped halfway, the report offers two ways forward: retry only what is left, and
/// look at the destination again to confirm what is already there.
@MainActor
final class TransferRecoveryTests: XCTestCase {
    private var root: URL!
    private var demo: DemoStore!
    private var queue: TransferQueue!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        let demo = demo!
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func settle() async throws {
        for _ in 0..<500 {
            if !queue.isWorking, !queue.items.contains(where: { [.queued, .running].contains($0.state) }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
    }
    private func upload(_ url: URL, batch: UUID) -> Transfer {
        Transfer(batchID: batch, name: url.lastPathComponent, destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: url)
    }
    private func write(_ text: String, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testRetryingOnlyThePendingPartRequeuesExactlyWhatDidNotFinish() async throws {
        let batch = UUID()
        // The destination refuses one name, the way OneDrive refuses "?": the job stops there, after the rest.
        let strict = Account(id: Account.demo.id, cloud: .microsoft, name: "Demo", email: "demo", clientID: "", clientSecret: nil)
        let demo = demo!
        queue.client = { _ in CloudAPI(account: strict, demo: demo) }
        let single = try write("uno", "uno.txt")
        let folder = root.appendingPathComponent("carpeta", isDirectory: true)
        _ = try write("a", "carpeta/a.txt"); _ = try write("b", "carpeta/sub/b.txt"); _ = try write("z", "carpeta/z?.txt")
        let late = try write("tarde", "tarde.txt")
        let a = upload(single, batch: batch), b = upload(folder, batch: batch), c = upload(late, batch: batch)
        try queue.add([a, b, c])
        queue.cancel(c.id, pause: true)
        try await settle()
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed, .paused])

        let before = TransferReport(jobs: queue.items)
        XCTAssertEqual(before.outstandingKeys, [b.id: ["./z?.txt"], c.id: ["."]], "What is left, and nothing else")
        let reportOfB = try XCTUnwrap(queue.items.first { $0.id == b.id }).report
        XCTAssertTrue(reportOfB["./z?.txt"]?.reason?.contains("OneDrive no admite") == true)

        // The person fixes the cause (here, a destination that accepts the name) and retries only what is left.
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        XCTAssertEqual(queue.retryPending(batch), 2)
        XCTAssertEqual(queue.items.first { $0.id == a.id }?.state, .completed, "A finished job is not touched")
        try await settle()
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .completed }, queue.items.map(\.detail).joined(separator: " | "))

        let after = try XCTUnwrap(queue.items.first { $0.id == b.id }).report
        let changed = Set(after.keys.filter { after[$0] != reportOfB[$0] })
        XCTAssertEqual(changed, ["./z?.txt"], "Only the failed file was transferred again")
        XCTAssertEqual(after["./z?.txt"]?.outcome, .verified)
        let remote = try XCTUnwrap(demo.list("root").first { $0.name == "carpeta" })
        XCTAssertEqual(try demo.list(remote.id).map(\.name).sorted(), ["a.txt", "sub", "z?.txt"], "Nothing copied twice")
        XCTAssertEqual(try demo.list("root").filter { $0.name == "uno.txt" }.count, 1)
        XCTAssertTrue(TransferReport(jobs: queue.items).outstandingKeys.isEmpty)
    }

    func testVerifyingFindsAMissingCopyAndRetryingBringsOnlyThatBack() async throws {
        let batch = UUID()
        _ = try write("a", "carpeta/a.txt"); _ = try write("bb", "carpeta/sub/b.txt"); _ = try write("ccc", "carpeta/c.txt")
        try queue.add([upload(root.appendingPathComponent("carpeta"), batch: batch)])
        try await settle()
        let remote = try XCTUnwrap(demo.list("root").first { $0.name == "carpeta" })
        let sub = try XCTUnwrap(demo.list(remote.id).first { $0.name == "sub" })
        // Someone deletes one copy at the destination after the transfer.
        try demo.deletePermanently(try XCTUnwrap(demo.list(sub.id).first).id)

        var ticks: [Int] = []
        let summary = try await queue.verifyCopied(batch) { done, _ in ticks.append(done) }
        XCTAssertEqual(summary, VerificationSummary(checked: 3, verified: 0, sizeOnly: 2, missing: 1, skipped: 0))
        XCTAssertEqual(ticks, [1, 2, 3])
        XCTAssertTrue(summary.text.contains("1 no están en el destino"), summary.text)
        let job = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(job.report["./sub/b.txt"]?.outcome, .pending)
        XCTAssertEqual(job.report["./sub/b.txt"]?.reason, "No está en el destino.")
        XCTAssertEqual(job.report["./a.txt"]?.outcome, .verified, "A size-only listing does not undo the check made when it was sent")
        XCTAssertFalse(job.completedPaths.contains("./sub/b.txt")); XCTAssertFalse(job.completedPaths.contains("./sub"))
        XCTAssertFalse(job.completedPaths.contains("."), "The walk has to get down to it again")
        XCTAssertTrue(job.completedPaths.contains("./a.txt"))

        XCTAssertEqual(queue.retryPending(batch), 1, "A completed job with a line pending again is recoverable")
        try await settle()
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        XCTAssertEqual(try demo.list(sub.id).map(\.name), ["b.txt"])
        XCTAssertEqual(try demo.list(remote.id).map(\.name).sorted(), ["a.txt", "c.txt", "sub"], "Nothing else copied again")
        XCTAssertEqual(try demo.list("root").filter { $0.name == "carpeta" }.count, 1)
    }

    func testVerifyingADownloadNoticesALocalCopyThatIsGone() async throws {
        let batch = UUID()
        let top = try demo.add(name: "Docs", parent: "root", folder: true)
        _ = try demo.add(name: "uno.txt", parent: top, content: Data("1".utf8))
        _ = try demo.add(name: "dos.txt", parent: top, content: Data("22".utf8))
        let source = try XCTUnwrap(demo.list("root").first { $0.id == top })
        let output = root.appendingPathComponent("salida", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try queue.add([Transfer(batchID: batch, name: "Docs", destination: output.path, accountID: Account.demo.id, direction: .download, localURL: output, file: source)])
        try await settle()
        try FileManager.default.removeItem(at: output.appendingPathComponent("Docs/dos.txt"))
        try Data("XX".utf8).write(to: output.appendingPathComponent("Docs/uno.txt"))

        let summary = try await queue.verifyCopied(batch)
        XCTAssertEqual(summary.checked, 2); XCTAssertEqual(summary.missing, 2, "One is gone and the other no longer matches")
        let job = try XCTUnwrap(queue.items.first)
        XCTAssertTrue(job.report.values.allSatisfy { $0.outcome == .pending })
        XCTAssertTrue(job.report.values.contains { $0.reason?.contains("tamaño") == true })
    }

    func testTheJudgementOfOneFile() {
        let listed = CloudFile(id: "1", name: "a", mime: "text/plain", size: 5, modified: nil, webURL: nil, isFolder: false,
                               checksum: ContentHash(algorithm: .md5, value: "ABC"))
        XCTAssertEqual(TransferRecovery.judge(listed: listed, size: 5, digest: "abc").0, .verified, "Hex compares without case")
        XCTAssertEqual(TransferRecovery.judge(listed: listed, size: 5, digest: "abd").0, .failed)
        XCTAssertEqual(TransferRecovery.judge(listed: listed, size: 4, digest: "abc").0, .failed, "The size is looked at first")
        XCTAssertEqual(TransferRecovery.judge(listed: listed, size: 5, digest: nil).0, .unverified)
        let bare = CloudFile(id: "1", name: "a", mime: "text/plain", size: nil, modified: nil, webURL: nil, isFolder: false)
        XCTAssertEqual(TransferRecovery.judge(listed: bare, size: 5, digest: nil).0, .unverified)
    }

    func testACrossCloudCopyIsCheckedAgainstItsOriginal() async throws {
        let batch = UUID()
        let other = try DemoStore(directory: root.appendingPathComponent("cloudB")); other.latency = .milliseconds(1)
        let account = Account(id: "demo:other", cloud: .dropbox, name: "B", email: "b@example.com", clientID: "", clientSecret: nil)
        let demo = demo!
        queue.client = { id in id == Account.demo.id ? CloudAPI(account: .demo, demo: demo) : CloudAPI(account: account, demo: other) }
        queue.scratchRoot = root.appendingPathComponent("scratch")
        let folder = try demo.add(name: "Viaje", parent: "root", folder: true)
        _ = try demo.add(name: "foto.bin", parent: folder, content: Data(repeating: 3, count: 1000))
        _ = try demo.add(name: "nota.txt", parent: folder, content: Data("hola".utf8))
        var job = Transfer(batchID: batch, name: "Viaje", destination: "B", accountID: Account.demo.id, direction: .transfer, localURL: URL(fileURLWithPath: "/"), parent: "root",
                           file: try XCTUnwrap(demo.list("root").first { $0.id == folder }))
        job.localURL = queue.scratchDirectory(for: job.id); job.targetAccountID = account.id
        try queue.add([job])
        try await settle()
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        let copied = try XCTUnwrap(other.list("root").first { $0.name == "Viaje" })
        try other.deletePermanently(try XCTUnwrap(other.list(copied.id).first { $0.name == "nota.txt" }).id)
        let summary = try await queue.verifyCopied(batch)
        XCTAssertEqual(summary.checked, 2)
        XCTAssertEqual(summary.missing, 1)
        XCTAssertEqual(queue.items.first?.report.values.filter { $0.outcome == .pending }.map(\.path), ["Viaje/nota.txt"])
    }
}
