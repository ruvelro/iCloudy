import XCTest
@testable import iCloudy

/// A transfer used to end with a sentence: how many files were verified. The report keeps a line per file, so a long
/// job that stopped halfway can say what is already at the destination and what is not.
@MainActor
final class TransferReportTests: XCTestCase {
    private func fixture() throws -> (URL, DemoStore, TransferQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        return (root, demo, queue)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
        throw CloudError.message("Test timeout")
    }
    private func upload(_ url: URL, batch: UUID = UUID()) -> Transfer {
        Transfer(batchID: batch, name: url.lastPathComponent, destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: url)
    }
    /// carpeta/a.txt, carpeta/sub/b.txt, carpeta/c.txt
    private func folder(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("carpeta", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("bb".utf8).write(to: folder.appendingPathComponent("sub/b.txt"))
        try Data("ccc".utf8).write(to: folder.appendingPathComponent("c.txt"))
        return folder
    }

    // MARK: - Storage

    func testQueuesSavedBeforeReportsStillDecode() throws {
        let legacy = #"[{"accountID":"a","direction":"upload","localURL":"file:///tmp/x","state":"completed","verifiedFiles":3}]"#
        let jobs = try JSONDecoder().decode([Transfer].self, from: Data(legacy.utf8))
        XCTAssertEqual(jobs.count, 1)
        XCTAssertTrue(jobs[0].report.isEmpty)
        XCTAssertFalse(jobs[0].planned)
        // And a report written by a newer version, with an outcome this one does not know, does not cost the queue.
        let newer = #"{"accountID":"a","direction":"upload","localURL":"file:///tmp/x","report":{".":{"p":"x","o":"teleported"}}}"#
        let job = try JSONDecoder().decode(Transfer.self, from: Data(newer.utf8))
        XCTAssertEqual(job.report["."]?.outcome, .pending)
    }

    func testRecordsAreStoredCompactly() throws {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta"))
        job.record("./a.txt", .verified, bytes: 12)
        job.record("./b.txt", .failed, reason: "sin red")
        let text = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        XCTAssertTrue(text.contains(#""p":"carpeta\/a.txt""#) || text.contains(#""p":"carpeta/a.txt""#), text)
        XCTAssertFalse(text.contains(#""c":"#), "The default is not written")
        XCTAssertFalse(text.contains("outcome"), "Short keys only")
        let decoded = try JSONDecoder().decode(Transfer.self, from: Data(text.utf8))
        XCTAssertEqual(decoded.report, job.report)
        XCTAssertEqual(decoded.verifiedFiles, 1)
    }

    func testRecordingAFileAgainMovesItBetweenCountersInsteadOfCountingItTwice() {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta"))
        job.record("./a.txt", .unverified)
        job.record("./a.txt", .verified)
        XCTAssertEqual(job.verifiedFiles, 1); XCTAssertEqual(job.unverifiedFiles, 0)
        job.record("./b.txt", .exported, counted: false)
        XCTAssertEqual(job.exportedFiles, 0, "A link is reported, never counted as an export")
        job.record("./b.txt", .failed)
        XCTAssertEqual(job.exportedFiles, 0, "Nor taken back out")
    }

    func testADownloadCheckedBeforeReportsExistedIsNotCountedTwice() {
        // A download job saved mid-way by the previous version: the check is in `downloads` and in the counter.
        var job = Transfer(name: "Fotos", destination: "/tmp", accountID: "a", direction: .download, localURL: URL(fileURLWithPath: "/tmp"))
        job.downloads["./f1"] = .verified; job.verifiedFiles = 1; job.names["."] = "Fotos"; job.names["./f1"] = "playa.jpg"
        job.recordDownload("./f1", .verified)
        XCTAssertEqual(job.verifiedFiles, 1)
        XCTAssertEqual(job.report["./f1"], FileRecord(path: "Fotos/playa.jpg", outcome: .verified))
    }

    func testOnlyAFailedCheckOfACrossCloudCopyReachesTheReport() {
        var job = Transfer(name: "x", destination: "B", accountID: "a", direction: .transfer, localURL: URL(fileURLWithPath: "/"))
        job.recordDownload(".", .verified)
        XCTAssertNil(job.report["."], "The download is half the work; the upload records what stays")
        XCTAssertEqual(job.verifiedFiles, 0)
        job.recordDownload(".", .failed)
        XCTAssertEqual(job.report["."]?.outcome, .failed)
    }

    // MARK: - The queue fills it in

    func testAFolderUploadReportsEveryFile() async throws {
        let (root, _, queue) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try queue.add([upload(try folder(in: root))])
        try await wait { !queue.isWorking }
        let job = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(job.state, .completed, job.detail)
        XCTAssertEqual(Set(job.report.values.map(\.path)), ["carpeta/a.txt", "carpeta/sub/b.txt", "carpeta/c.txt"])
        XCTAssertTrue(job.report.values.allSatisfy { $0.outcome == .verified })
        XCTAssertEqual(job.report["./sub/b.txt"]?.bytes, 2)
        XCTAssertEqual(job.verifiedFiles, 3, "The counters follow the records")
        let saved = try XCTUnwrap(LocalStore.read([Transfer].self, from: queue.storeURL)?.first)
        XCTAssertEqual(saved.report.count, 3, "Unlike the checkpoints, the report survives completion on disk")
    }

    func testASkippedFolderIsReportedAsSkippedWithWhatItHeld() async throws {
        let (root, demo, queue) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try demo.add(name: "carpeta", parent: "root", folder: true)
        var job = upload(try folder(in: root))
        job.batchChoice = .skip
        job.planned = true
        job.report = ["./a.txt": FileRecord(path: "carpeta/a.txt", outcome: .pending)]
        try queue.add([job])
        try await wait { !queue.isWorking }
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.report["."]?.outcome, .skipped)
        XCTAssertEqual(done.report["."]?.path, "carpeta/")
        XCTAssertEqual(done.report["./a.txt"]?.outcome, .skipped, "Its planned contents are not left pending")
    }

    func testAFailureLandsOnTheFileThatCausedItAndTheRestIsKept() async throws {
        let (root, _, queue) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try folder(in: root)
        // Sorted after the others, so they are uploaded before the walk reaches a file nobody can read.
        let locked = source.appendingPathComponent("z-bloqueado.txt")
        try Data("zzz".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        try queue.add([upload(source)])
        try await wait { !queue.isWorking }
        let job = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.report["./z-bloqueado.txt"]?.outcome, .failed)
        XCTAssertEqual(job.report["./z-bloqueado.txt"]?.path, "carpeta/z-bloqueado.txt")
        XCTAssertFalse(job.report["./z-bloqueado.txt"]?.reason?.isEmpty ?? true, "The reason travels with the line")
        XCTAssertEqual(job.report["./a.txt"]?.outcome, .verified, "What was copied before stays on record")
        XCTAssertEqual(job.report["./sub/b.txt"]?.outcome, .verified)
    }

    func testAPlannedFileThatVanishedIsNotLeftPendingOnACompletedJob() {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta"))
        job.report = ["./a.txt": FileRecord(path: "carpeta/a.txt", outcome: .pending), "./b.txt": FileRecord(path: "carpeta/b.txt", outcome: .verified)]
        job.settleReport()
        XCTAssertEqual(job.report["./a.txt"]?.outcome, .failed)
        XCTAssertEqual(job.report["./b.txt"]?.outcome, .verified)
    }

    func testAFolderWhoseCreationWasNeverConfirmedIsUncertainNotFailed() {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta"))
        job.uncertainFolders = ["./sub"]
        job.recordFailure(at: ReportCursor(key: "./sub", leaf: "sub", folder: true), CloudError.message("timeout"))
        XCTAssertEqual(job.report["./sub"], FileRecord(path: "carpeta/sub/", outcome: .uncertain, reason: "timeout"))
    }

    // MARK: - Batch report and export

    func testAJobThatNeverStartedStillHasALine() {
        var waiting = upload(URL(fileURLWithPath: "/tmp/uno.txt")); waiting.state = .cancelled
        var failed = upload(URL(fileURLWithPath: "/tmp/dos.txt")); failed.state = .failed; failed.detail = "Sin permiso"
        let report = TransferReport(jobs: [waiting, failed])
        XCTAssertEqual(report.lines.map(\.record.path), ["dos.txt", "uno.txt"])
        XCTAssertEqual(report.lines.map(\.record.outcome), [.failed, .pending])
        XCTAssertEqual(report.lines[0].record.reason, "Sin permiso")
        XCTAssertEqual(report.outstanding, 2)
    }

    func testTheExplanationSaysWhatIsAlreadyAtTheDestination() {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta")); job.state = .failed; job.planned = true
        job.record("./a", .verified, bytes: 1000); job.record("./b", .unverified, bytes: 24); job.record("./c", .pending); job.record("./d", .skipped)
        let text = TransferReportView.explanation(TransferReport(jobs: [job]))
        XCTAssertTrue(text.hasPrefix("2 archivos ya están en el destino"), text)
        XCTAssertTrue(text.contains("1 de ellos se comprobaron"), text)
        XCTAssertTrue(text.contains("1 se dejaron fuera"), text)
        XCTAssertTrue(text.contains("Quedan 1 por transferir"), text)
        XCTAssertFalse(TransferReport(jobs: [job]).incomplete, "A planned job lists every file")
    }

    func testCSVQuotesCommasQuotesAndLineBreaks() {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta")); job.state = .failed
        job.record("./a", .verified, path: "carpeta/uno, dos.txt", bytes: 5)
        job.record("./b", .failed, path: "carpeta/\"citado\".txt", reason: "línea 1\nlínea 2")
        let lines = TransferReport(jobs: [job]).csv()
        XCTAssertEqual(lines, """
        Ruta,Estado,Código,Bytes,Motivo
        "carpeta/""citado"".txt",Fallido,failed,,"línea 1
        línea 2"
        "carpeta/uno, dos.txt",Copiado y verificado,verified,5,

        """)
        XCTAssertEqual(TransferReport.csvField("simple"), "simple")
    }

    func testJSONUsesStableCodesBesideTheLabels() throws {
        var job = upload(URL(fileURLWithPath: "/tmp/carpeta")); job.state = .completed
        job.record("./a", .verified, bytes: 5)
        job.record("./b", .skipped, reason: "Ya existía")
        let data = try TransferReport(jobs: [job]).json(generated: Date(timeIntervalSince1970: 0))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(TransferReport.Export.self, from: data)
        XCTAssertEqual(export.generated, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(export.jobs.map(\.state), ["completed"])
        XCTAssertEqual(export.files.map(\.status), ["verified", "skipped"])
        XCTAssertEqual(export.files.map(\.label), ["Copiado y verificado", "Omitido"])
        XCTAssertEqual(export.files[0].bytes, 5)
        XCTAssertEqual(export.files[1].reason, "Ya existía")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""path" : "carpeta/a""#), "Slashes are not escaped")
    }
}
