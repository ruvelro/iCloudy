import XCTest
import PDFKit
@testable import iCloudy

@MainActor
final class PreviewTests: XCTestCase {
    private func fixture() throws -> (URL, DemoStore, PreviewModel, CloudAPI) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-tests-" + UUID().uuidString)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud"))
        demo.latency = .milliseconds(1)
        let model = PreviewModel(store: try PreviewStore(root: root.appendingPathComponent("cache")))
        model.availableCapacity = { 2_000_000_000 }
        return (root, demo, model, CloudAPI(account: .demo, demo: demo))
    }
    private func file(_ name: String, size: Int64? = 1, id: String = "test", folder: Bool = false, mime: String = "application/octet-stream") -> CloudFile {
        CloudFile(id: id, name: name, mime: mime, size: size, modified: nil, webURL: nil, isFolder: folder)
    }
    private func settle(_ model: PreviewModel) async throws {
        for _ in 0..<300 {
            if model.phase != .loading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Preview failed to settle")
    }
    func testAllowlistDoesNotEnableExecutableOrWebContent() {
        for name in ["a.pdf", "a.PNG", "a.heic", "a.txt", "a.py", "a.js"] { XCTAssertNotNil(PreviewKind.forFile(file(name))) }
        for name in ["a.html", "a.svg", "a.app", "a.zip", "a.pdf.exe", "a", "a.pkg", "a.dmg", "a.webarchive"] { XCTAssertNil(PreviewKind.forFile(file(name))) }
        XCTAssertNil(PreviewKind.forFile(file("folder.txt", folder: true)))
        XCTAssertEqual(PreviewKind.forFile(file("a.mp4")), .media("mp4"))
        XCTAssertEqual(PreviewKind.forFile(file("a.M4A")), .media("m4a"))
        XCTAssertEqual(PreviewKind.forFile(file("a.docx")), .office("docx"))
        XCTAssertEqual(PreviewKind.forFile(file("a.key")), .office("key"))
        XCTAssertEqual(PreviewKind.forFile(file("Google", mime: "application/vnd.google-apps.document")), .exportedPDF)
        XCTAssertEqual(PreviewKind.forFile(file("Hoja", mime: "application/vnd.google-apps.spreadsheet")), .exportedPDF)
        XCTAssertNil(PreviewKind.forFile(file("Form", mime: "application/vnd.google-apps.form")), "Forms have no PDF export")
        XCTAssertNil(PreviewKind.forFile(file("Shortcut", mime: "application/vnd.google-apps.shortcut")))
        XCTAssertTrue(PreviewKind.exportedPDF.usesQuickLook && PreviewKind.office("docx").usesQuickLook)
        XCTAssertFalse(PreviewKind.media("mp4").usesQuickLook || PreviewKind.text.usesQuickLook)
        XCTAssertEqual(PreviewKind.exportedPDF.exportMime, "application/pdf")
    }
    func testOfficeStructureCheckRejectsMislabelledContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let docx = root.appendingPathComponent("a.docx"); try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]).write(to: docx)
        let fake = root.appendingPathComponent("b.docx"); try Data("<html>".utf8).write(to: fake)
        let doc = root.appendingPathComponent("c.doc"); try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(to: doc)
        let rtf = root.appendingPathComponent("d.rtf"); try Data("{\\rtf1\\ansi}".utf8).write(to: rtf)
        XCTAssertTrue(PreviewKind.looksValid(.office("docx"), at: docx))
        XCTAssertFalse(PreviewKind.looksValid(.office("docx"), at: fake))
        XCTAssertTrue(PreviewKind.looksValid(.office("doc"), at: doc))
        XCTAssertTrue(PreviewKind.looksValid(.office("rtf"), at: rtf))
        XCTAssertTrue(PreviewKind.looksValid(.pdf, at: fake), "Only Office kinds are structurally checked here")
    }
    func testGoogleDocumentPreviewExportsToPDFWithoutSizeConfirmation() async throws {
        let (root, _, model, _) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = CloudAPI(account: Account(id: "google:t", cloud: .google, name: "T", email: "t@example.com", clientID: "c", clientSecret: nil), session: URLSession(configuration: config), tokenProvider: { "token" })
        var exportURL: URL?
        let pdf = PDFDocument(); pdf.insert(PDFPage(), at: 0)
        StubProtocol.handler = { request in exportURL = request.url; return (200, [:], pdf.dataRepresentation() ?? Data()) }
        model.open(file: file("Informe", size: nil, mime: "application/vnd.google-apps.document"), account: .demo, client: api)
        XCTAssertEqual(model.phase, .loading, "Exports skip the unknown-size confirmation")
        try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(exportURL?.path, "/drive/v3/files/test/export")
        XCTAssertEqual(URLComponents(url: exportURL!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mimeType" }?.value, "application/pdf")
        XCTAssertEqual(model.localURL?.pathExtension, "pdf")
    }
    func testTextPreviewSaveAndCleanupNeverChangesSourceOrSavedCopy() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        let data = Data("print('solo texto, nunca ejecutar')".utf8)
        let id = try demo.add(name: "code.py", parent: "root", content: data)
        model.open(file: file("code.py", size: Int64(data.count), id: id), account: .demo, client: api)
        try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.text, String(data: data, encoding: .utf8))
        let temporary = try XCTUnwrap(model.localURL)
        let saved = root.appendingPathComponent("saved.py")
        try model.saveCopy(to: saved)
        XCTAssertThrowsError(try model.saveCopy(to: saved))
        var detachedBeforeDeletion = false
        model.willDiscard = { detachedBeforeDeletion = FileManager.default.fileExists(atPath: temporary.path) }
        model.close()
        XCTAssertTrue(detachedBeforeDeletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(id)), data)
    }
    func testUnknownAndLargeSizesRequireConsentBeforeDownloading() throws {
        let (root, _, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        for size: Int64? in [nil, -1, 100_000_001] {
            model.open(file: file("large.txt", size: size), account: .demo, client: api)
            XCTAssertEqual(model.phase, .confirmation)
            XCTAssertNil(model.localURL)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path), [])
        }
    }
    func testConfirmedUnknownSizeCanPreviewAnEmptyFile() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        let id = try demo.add(name: "empty.txt", parent: "root")
        model.open(file: file("empty.txt", size: nil, id: id), account: .demo, client: api)
        XCTAssertEqual(model.phase, .confirmation)
        model.start(); try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.text, "")
    }
    func testLowDiskAndUnsupportedFilesNeverDownload() throws {
        let (root, _, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        model.availableCapacity = { 100 }
        model.open(file: file("text.txt"), account: .demo, client: api)
        guard case .failed(let message) = model.phase else { return XCTFail("Expected disk failure") }
        XCTAssertTrue(message.contains("espacio"))
        model.open(file: file("archive.zip"), account: .demo, client: api)
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).isEmpty)
    }
    func testCancellationAndRapidAccountSwitchDoNotLeakOrMixContents() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(20)
        let first = try demo.add(name: "same.txt", parent: "root", content: Data(repeating: 65, count: 2_000_000))
        let second = try demo.add(name: "same.txt", parent: "root", content: Data("other account".utf8))
        model.open(file: file("same.txt", size: 2_000_000, id: first), account: .demo, client: api)
        try await Task.sleep(for: .milliseconds(35))
        let other = Account(id: "demo:other", cloud: .microsoft, name: "Other", email: "other@example.com", clientID: "", clientSecret: nil)
        model.open(file: file("same.txt", size: 13, id: second), account: other, client: CloudAPI(account: other, demo: demo))
        try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.text, "other account")
        XCTAssertEqual(model.account?.id, other.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).count, 1)
        model.close()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }
    func testStartupCleanupOnlyRemovesOwnedDirectories() throws {
        let (root, _, model, _) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let store = try PreviewStore(root: cache)
        let orphan = try store.create()
        let sentinel = cache.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sentinel)
        _ = try PreviewStore(root: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertThrowsError(try store.remove(root))
        XCTAssertThrowsError(try store.remove(sentinel))
    }
    func testLongTextIsTruncatedForDisplayButSavedInFull() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 65, count: PreviewModel.textLimit + 100)
        let id = try demo.add(name: "long.txt", parent: "root", content: data)
        model.open(file: file("long.txt", size: Int64(data.count), id: id), account: .demo, client: api)
        try await settle(model)
        XCTAssertTrue(model.textTruncated)
        XCTAssertEqual(model.text?.count, PreviewModel.textLimit)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.localURL)).count, data.count)
    }
    func testInvalidImageAndBinaryTextFailAndCleanUp() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        for name in ["fake.png", "binary.txt", "fake.pdf"] {
            let id = try demo.add(name: name, parent: "root", content: Data([0, 1, 2, 3]))
            model.open(file: file(name, size: 4, id: id), account: .demo, client: api)
            try await settle(model)
            guard case .failed = model.phase else { return XCTFail("Invalid content must fail") }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).isEmpty)
        }
    }
    func testRealByteLimitDoesNotTrustMetadata() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        let id = try demo.add(name: "text.txt", parent: "root", content: Data(repeating: 65, count: 1000))
        let destination = root.appendingPathComponent("bounded.txt")
        do {
            try await api.download(file: file("text.txt", size: 1, id: id), to: destination, maxBytes: 100)
            XCTFail("Expected download limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("límite")) }
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThanOrEqual(size, 100)
    }
    func testNetworkFailureLeavesNoPreviewContent() async throws {
        let (root, demo, model, api) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: root) }
        demo.offline = true
        model.open(file: file("text.txt"), account: .demo, client: api)
        try await settle(model)
        guard case .failed = model.phase else { return XCTFail("Expected offline failure") }
        XCTAssertNil(model.localURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).isEmpty)
    }
    func testNativeDownloadDelegateCancelsOversizedResponses() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let download = session.downloadTask(with: URL(string: "https://example.invalid/test")!)
        var reported = false
        let delegate = DownloadProgress(maxBytes: 100) { _, _ in reported = true }
        delegate.urlSession(session, downloadTask: download, didWriteData: 1, totalBytesWritten: 1, totalBytesExpectedToWrite: 101)
        XCTAssertTrue(delegate.exceededLimit)
        XCTAssertFalse(reported)
    }
}
