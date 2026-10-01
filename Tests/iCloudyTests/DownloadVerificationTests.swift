import XCTest
import CryptoKit
@testable import iCloudy

/// Downloads used to trust whatever arrived: only Mega checked its own MAC, and only cross-cloud copies compared the
/// size. Every download is now held against the listed size and the provider's checksum before it is put in place.
@MainActor
final class DownloadVerificationTests: XCTestCase {
    private func client(_ cloud: Cloud, driveID: String? = nil) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let base = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil)
        let account = driveID.map { Account.scoped(to: $0, named: "Biblioteca", from: base) } ?? base
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func destination() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func md5(_ text: String) -> String { UploadHasher.hex(Insecure.MD5.hash(data: Data(text.utf8))) }
    private func driveFile(_ content: String, md5 hash: String? = nil, size: Int64? = nil, modified: String = "2026-09-01T10:00:00.000Z") -> CloudFile {
        CloudFile(id: "f1", name: "nota.txt", mime: "text/plain", size: size ?? Int64(content.utf8.count),
                  modified: CloudSession.date(modified), webURL: nil, isFolder: false,
                  checksum: ContentHash(algorithm: .md5, value: hash ?? md5(content)))
    }
    /// Drive serves the bytes and the description from the same path; `alt=media` tells them apart.
    private final class Counter { var value = 0 }
    private func stubDrive(content: @escaping () -> String, metadata: @escaping () -> (Int, String), metadataCalls: Counter? = nil) {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/files/f1")
            if request.url?.query?.contains("alt=media") == true { return (200, [:], Data(content().utf8)) }
            metadataCalls?.value += 1
            XCTAssertTrue(request.url?.query?.contains("md5Checksum") == true, "The new description carries the checksum too")
            let (status, body) = metadata()
            return (status, [:], Data(body.utf8))
        }
    }

    func testOldQueuesDecodeWithoutDownloadState() throws {
        let legacy = #"{"accountID":"a","direction":"download","localURL":"file:///tmp/"}"#
        let transfer = try JSONDecoder().decode(Transfer.self, from: Data(legacy.utf8))
        XCTAssertTrue(transfer.downloads.isEmpty); XCTAssertEqual(transfer.exportedFiles, 0)
    }

    // MARK: - Single downloads

    func testACorrectChecksumVerifiesTheDownload() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        stubDrive(content: { "hola!" }, metadata: { XCTFail("No mismatch, no second request"); return (500, "") })
        let result = try await client(.google).download(file: driveFile("hola!"), to: target)
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(try Data(contentsOf: target), Data("hola!".utf8))
    }

    func testAWrongChecksumFailsAndLeavesNothingBehind() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        let calls = Counter()
        let listed = driveFile("hola!")
        // Same description as listed: the provider still says it holds "hola!", so these bytes are damaged.
        stubDrive(content: { "HOLA!" }, metadata: {
            (200, #"{"id":"f1","name":"nota.txt","mimeType":"text/plain","size":"5","modifiedTime":"2026-09-01T10:00:00.000Z","md5Checksum":"\#(listed.checksum!.value)"}"#)
        }, metadataCalls: calls)
        do {
            try await client(.google).download(file: listed, to: target)
            XCTFail("A checksum mismatch must fail")
        } catch let error as DownloadIntegrityError {
            XCTAssertEqual(error, .checksumMismatch(name: "nota.txt"))
            XCTAssertFalse(error.retryable, "Downloading the same damaged bytes again would not help")
        }
        XCTAssertEqual(calls.value, 1, "The item is asked for once before calling it corruption")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "The bad copy is deleted")
    }

    func testASizeMismatchFailsBeforeAnyHashing() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        StubProtocol.handler = { request in
            if request.url?.path == "/2/files/get_metadata" {
                return (200, [:], Data(#"{".tag":"file","name":"corto.txt","path_lower":"/corto.txt","size":10,"server_modified":"2026-09-01T10:00:00Z"}"#.utf8))
            }
            return (200, [:], Data("12345".utf8))
        }
        let file = CloudFile(id: "/corto.txt", name: "corto.txt", mime: "text/plain", size: 10, modified: CloudSession.date("2026-09-01T10:00:00Z"),
                             webURL: nil, isFolder: false, checksum: ContentHash(algorithm: .dropbox, value: "irrelevant"))
        do {
            try await client(.dropbox).download(file: file, to: target)
            XCTFail("Five bytes of a ten-byte file is not a download")
        } catch let error as DownloadIntegrityError {
            XCTAssertEqual(error, .sizeMismatch(name: "corto.txt", expected: 10, actual: 5))
            XCTAssertTrue(error.localizedDescription.contains("5 bytes"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testAFileChangedWhileDownloadingIsReportedAsSuchAndIsRetryable() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        let payload = Data("versión nueva".utf8)
        var quick = QuickXorHash(); quick.update(Data("versión vieja".utf8))
        let listed = CloudFile(id: "m1", name: "doc.txt", mime: "text/plain", size: Int64(payload.count), modified: CloudSession.date("2026-09-01T10:00:00Z"),
                               webURL: nil, isFolder: false, checksum: ContentHash(algorithm: .quickXor, value: quick.finalize().base64EncodedString()))
        var fresh = QuickXorHash(); fresh.update(payload)
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/content") { return (200, [:], payload) }
            XCTAssertEqual(request.url?.path, "/v1.0/me/drive/items/m1")
            let body: [String: Any] = ["id": "m1", "name": "doc.txt", "size": payload.count, "lastModifiedDateTime": "2026-09-01T10:05:00Z",
                                       "file": ["mimeType": "text/plain", "hashes": ["quickXorHash": fresh.finalize().base64EncodedString()]]]
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }
        do {
            try await client(.microsoft).download(file: listed, to: target)
            XCTFail("The bytes do not match what was listed")
        } catch let error as DownloadIntegrityError {
            guard case .changedRemotely(let name, let current?) = error else { return XCTFail("Expected a remote change, got \(error)") }
            XCTAssertEqual(name, "doc.txt")
            XCTAssertEqual(current.modified, CloudSession.date("2026-09-01T10:05:00Z"))
            XCTAssertTrue(error.retryable)
            XCTAssertEqual(TransferQueue.outcome(for: error, attempts: 0, online: true), .retry, "The queue tries again with the new version")
            XCTAssertTrue(error.localizedDescription.contains("cambió"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        // And with the new description, the same bytes pass.
        let verified = try await client(.microsoft).download(file: CloudFile(id: "m1", name: "doc.txt", mime: "text/plain", size: Int64(payload.count), modified: nil, webURL: nil, isFolder: false,
                                                                            checksum: ContentHash(algorithm: .quickXor, value: fresh.finalize().base64EncodedString())), to: target)
        XCTAssertEqual(verified, .verified)
    }

    func testAFileDeletedWhileDownloadingIsNotCalledCorrupt() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        stubDrive(content: { "otra cosa" }, metadata: { (404, #"{"error":{"code":404,"message":"File not found: f1."}}"#) })
        do {
            try await client(.google).download(file: driveFile("hola!"), to: target)
            XCTFail("Expected a failure")
        } catch let error as DownloadIntegrityError {
            XCTAssertEqual(error, .changedRemotely(name: "nota.txt", current: nil))
            XCTAssertFalse(error.retryable, "Nothing left to download again")
        }
    }

    func testBoxSha1IsCheckedToo() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        let payload = Data("caja".utf8)
        StubProtocol.handler = { _ in (200, [:], payload) }
        let file = CloudFile(id: "9", name: "caja.txt", mime: "text/plain", size: 4, modified: nil, webURL: nil, isFolder: false,
                             checksum: ContentHash(algorithm: .sha1, value: UploadHasher.hex(Insecure.SHA1.hash(data: payload)).uppercased()))
        let result = try await client(.box).download(file: file, to: target)
        XCTAssertEqual(result, .verified)
    }

    func testExportedGoogleDocumentsAreRecordedAsUnverifiable() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/export"), "Only the export is requested, no metadata")
            return (200, [:], Data("%PDF-1.7 generado".utf8))
        }
        let document = CloudFile(id: "f1", name: "Informe", mime: "application/vnd.google-apps.document", size: 1, modified: nil, webURL: nil, isFolder: false)
        let result = try await client(.google).download(file: document, to: target, exportMime: "application/pdf")
        XCTAssertEqual(result, .exported, "Drive lists no size or checksum for what it generates; the stray size is not compared")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testSharePointOfficeFilesAreNotHeldToTheirStaleListing() async throws {
        let target = destination(); defer { try? FileManager.default.removeItem(at: target) }
        StubProtocol.handler = { _ in (200, [:], Data("docx con metadatos de SharePoint".utf8)) }
        let file = CloudFile(id: "s1", name: "Acta.docx", mime: "application/octet-stream", size: 3, modified: nil, webURL: nil, isFolder: false,
                             checksum: ContentHash(algorithm: .quickXor, value: "AAAAAAAAAAAAAAAAAAAAAAAAAAA="))
        let result = try await client(.microsoft, driveID: "b!library").download(file: file, to: target)
        XCTAssertEqual(result, .unavailable)
    }

    // MARK: - Transfer queue

    private func queue() -> (TransferQueue, URL) {
        let root = destination()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        let api = client(.google)
        queue.client = { _ in api }
        let output = root.appendingPathComponent("salida", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return (queue, output)
    }
    private func wait(_ queue: TransferQueue) async throws {
        for _ in 0..<500 {
            if !queue.isWorking, queue.items.allSatisfy(\.finished) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
    }
    private func job(_ file: CloudFile, into output: URL, export: String? = nil) -> Transfer {
        var job = Transfer(name: file.name, destination: output.path, accountID: "test", direction: .download, localURL: output, file: file)
        job.exportMime = export; job.exportExtension = export == nil ? nil : "pdf"
        return job
    }

    func testTheQueueShowsVerifiedDownloadsTheWayItShowsUploads() async throws {
        let (queue, output) = queue(); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        stubDrive(content: { "hola!" }, metadata: { (500, "") })
        try queue.add([job(driveFile("hola!"), into: output)])
        try await wait(queue)
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(done.verifiedFiles, 1)
        XCTAssertEqual(done.detail, "Completada · 1 archivo verificado con la suma del proveedor")
        XCTAssertTrue(done.downloads.isEmpty, "Per-file state is dropped once the counters carry it")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("nota.txt")), Data("hola!".utf8))
    }

    func testAFailedCheckFailsTheJobAndNeverPutsTheCopyInPlace() async throws {
        let (queue, output) = queue(); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let listed = driveFile("hola!")
        stubDrive(content: { "HOLA!" }, metadata: {
            (200, #"{"id":"f1","name":"nota.txt","mimeType":"text/plain","size":"5","modifiedTime":"2026-09-01T10:00:00.000Z","md5Checksum":"\#(listed.checksum!.value)"}"#)
        })
        try queue.add([job(listed, into: output)])
        try await wait(queue)
        let failed = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attempts, 0, "Corruption is not retried on its own")
        XCTAssertTrue(failed.detail.contains("suma de verificación"), failed.detail)
        XCTAssertEqual(failed.downloads["."], .failed, "The failed check is kept on the job")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [], "Neither the file nor a .part is left")
        let saved = try XCTUnwrap(LocalStore.read([Transfer].self, from: queue.storeURL)?.first)
        XCTAssertEqual(saved.downloads["."], .failed, "And it is on disk, not only in memory")
    }

    func testAFileChangedDuringTheJobIsDownloadedAgainInItsNewVersion() async throws {
        let (queue, output) = queue(); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let listed = driveFile("hola!"), newHash = md5("adiós!")
        stubDrive(content: { "adiós!" }, metadata: {
            (200, #"{"id":"f1","name":"nota.txt","mimeType":"text/plain","size":"7","modifiedTime":"2026-09-01T11:00:00.000Z","md5Checksum":"\#(newHash)"}"#)
        })
        try queue.add([job(listed, into: output)])
        try await wait(queue)
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(done.attempts, 1, "One automatic retry, with the description that was fetched")
        XCTAssertEqual(done.file?.size, 7)
        XCTAssertEqual(done.verifiedFiles, 1)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("nota.txt")), Data("adiós!".utf8))
    }

    func testTheQueueRecordsExportsAsSkipped() async throws {
        let (queue, output) = queue(); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        StubProtocol.handler = { _ in (200, [:], Data("%PDF-1.7".utf8)) }
        let document = CloudFile(id: "f1", name: "Informe", mime: "application/vnd.google-apps.document", size: nil, modified: nil, webURL: nil, isFolder: false)
        try queue.add([job(document, into: output, export: "application/pdf")])
        try await wait(queue)
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(done.exportedFiles, 1)
        XCTAssertEqual(done.verifiedFiles + done.unverifiedFiles, 0)
        XCTAssertEqual(done.detail, "Completada · 1 exportados de Google, sin suma que comparar")
    }

    func testACrossCloudCopyNeverUploadsASourceThatFailedItsCheck() async throws {
        let (queue, output) = queue(); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let target = try DemoStore(directory: output.deletingLastPathComponent().appendingPathComponent("destino")); target.latency = .milliseconds(1)
        let other = Account(id: "demo:other", cloud: .dropbox, name: "B", email: "b@example.com", clientID: "", clientSecret: nil)
        let source = client(.google)
        queue.client = { id in id == "test" ? source : CloudAPI(account: other, demo: target) }
        queue.scratchRoot = output.deletingLastPathComponent().appendingPathComponent("scratch")
        let listed = driveFile("hola!")
        stubDrive(content: { "HOLA!" }, metadata: {
            (200, #"{"id":"f1","name":"nota.txt","mimeType":"text/plain","size":"5","modifiedTime":"2026-09-01T10:00:00.000Z","md5Checksum":"\#(listed.checksum!.value)"}"#)
        })
        var job = Transfer(name: listed.name, destination: "B", accountID: "test", direction: .transfer, localURL: URL(fileURLWithPath: "/"), parent: "root", file: listed)
        job.localURL = queue.scratchDirectory(for: job.id); job.targetAccountID = other.id
        try queue.add([job])
        try await wait(queue)
        let failed = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.downloads["."], .failed)
        XCTAssertFalse(try target.list("root").contains { $0.name == "nota.txt" }, "The damaged bytes never reach the other cloud")
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: job.localURL.path)) ?? []
        XCTAssertTrue(staged.isEmpty, "Nothing staged is left to be uploaded by a retry: \(staged)")
    }
}
