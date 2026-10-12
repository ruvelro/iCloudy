import XCTest
import AppKit
@testable import iCloudy

/// Thumbnails, dragging out, notifications, undo, batch renaming, sorting by kind, the grid's keyboard, saved
/// searches and search by walking the tree.
@MainActor
final class DailyUseTests: XCTestCase {
    private func client(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: cloud == .pcloud ? ["apiHost": "eapi.pcloud.com"] : [:])
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func file(_ name: String, id: String? = nil, folder: Bool = false, mime: String = "application/octet-stream", modified: Date? = nil) -> CloudFile {
        CloudFile(id: id ?? name, name: name, mime: folder ? "application/vnd.google-apps.folder" : mime, size: folder ? nil : 10,
                  modified: modified, webURL: nil, isFolder: folder)
    }
    private var png: Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Thumbnails

    func testOnlyPicturesVideosAndPDFsAskForAThumbnail() {
        XCTAssertTrue(ThumbnailRequest.isCandidate(file("playa.jpg")))
        XCTAssertTrue(ThumbnailRequest.isCandidate(file("clip.mov")))
        XCTAssertTrue(ThumbnailRequest.isCandidate(file("informe.pdf")))
        XCTAssertFalse(ThumbnailRequest.isCandidate(file("notas.txt")))
        XCTAssertFalse(ThumbnailRequest.isCandidate(file("Fotos", folder: true)))
        XCTAssertFalse(ThumbnailRequest.isCandidate(file("Doc", mime: "application/vnd.google-apps.document")))
        XCTAssertTrue(ThumbnailRequest.accepts(png))
        XCTAssertFalse(ThumbnailRequest.accepts(Data(#"{"error":"x"}"#.utf8)), "A JSON error answered with a 200 is not an image")
    }

    func testAThumbnailKeyChangesWhenTheFileChanges() {
        let account = Account(id: "a", cloud: .google, name: "A", email: "a", clientID: "", clientSecret: nil)
        let old = file("a.jpg", modified: Date(timeIntervalSince1970: 100)), new = file("a.jpg", modified: Date(timeIntervalSince1970: 200))
        XCTAssertNotEqual(ThumbnailStore.key(old, account: account), ThumbnailStore.key(new, account: account))
        XCTAssertEqual(ThumbnailStore.key(old, account: account), ThumbnailStore.key(old, account: account))
    }

    func testThumbnailCapabilityFollowsTheProviders() {
        for cloud in [Cloud.google, .microsoft, .dropbox, .box, .pcloud, .volume] { XCTAssertTrue(cloud.capabilities.thumbnails, cloud.rawValue) }
        for cloud in [Cloud.webdav, .ftp, .sftp, .mega, .o2, .s3] { XCTAssertFalse(cloud.capabilities.thumbnails, cloud.rawValue) }
    }

    func testOneDriveAsksGraphForACroppedThumbnail() async throws {
        let image = png
        var asked: URL?
        StubProtocol.handler = { request in asked = request.url; return (200, ["Content-Type": "image/png"], image) }
        let data = try await client(.microsoft).thumbnail(of: file("a.jpg", id: "ITEM1"), side: 128)
        XCTAssertEqual(data, image)
        XCTAssertEqual(asked?.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/items/ITEM1/thumbnails/0/c128x128/content")
    }

    func testDropboxNamesTheFileAndSizeInItsArgumentHeader() async throws {
        let image = png
        var argument: [String: Any] = [:]
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://content.dropboxapi.com/2/files/get_thumbnail_v2")
            argument = (try? JSONSerialization.jsonObject(with: Data((request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "").utf8))) as? [String: Any] ?? [:]
            return (200, [:], image)
        }
        _ = try await client(.dropbox).thumbnail(of: file("a.jpg", id: "/fotos/a.jpg"), side: 128)
        XCTAssertEqual((argument["resource"] as? [String: Any])?["path"] as? String, "/fotos/a.jpg")
        XCTAssertEqual(argument["size"] as? String, "w128h128")
    }

    func testBoxStillDrawingAThumbnailIsNotAnImage() async throws {
        StubProtocol.handler = { _ in (202, ["Retry-After": "5"], Data()) }
        let data = try await client(.box).thumbnail(of: file("a.jpg", id: "77"), side: 128)
        XCTAssertNil(data)
    }

    func testGoogleSizesTheLinkAndSendsTheTokenOnlyToGoogle() async throws {
        let image = png
        var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if request.url?.host == "www.googleapis.com" {
                return (200, [:], Data(#"{"thumbnailLink":"https://lh3.googleusercontent.com/abc=s220"}"#.utf8))
            }
            return (200, [:], image)
        }
        _ = try await client(.google).thumbnail(of: file("a.jpg", id: "F1"), side: 128)
        XCTAssertEqual(requests.last?.url?.absoluteString, "https://lh3.googleusercontent.com/abc=s128")

        StubProtocol.handler = { request in
            if request.url?.host == "www.googleapis.com" { return (200, [:], Data(#"{"thumbnailLink":"https://evil.example.com/abc=s220"}"#.utf8)) }
            XCTFail("The token must not leave Google"); return (200, [:], image)
        }
        let refused = try await client(.google).thumbnail(of: file("a.jpg", id: "F1"), side: 128)
        XCTAssertNil(refused)
    }

    func testTheLimiterNeverRunsMoreThanItsWidth() async {
        let limiter = AsyncLimiter(width: 2)
        var running = 0, peak = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    await limiter.run {
                        running += 1; peak = max(peak, running)
                        try? await Task.sleep(for: .milliseconds(10))
                        running -= 1
                    }
                }
            }
        }
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(running, 0)
    }

    // MARK: - Dragging out

    func testAGoogleDocumentIsDraggedOutAsAnOfficeFile() {
        XCTAssertEqual(AppModel.dragName(file("Acta", mime: "application/vnd.google-apps.document")), "Acta.docx")
        XCTAssertEqual(AppModel.dragName(file("Cuentas", mime: "application/vnd.google-apps.spreadsheet")), "Cuentas.xlsx")
        XCTAssertEqual(AppModel.dragName(file("foto.jpg")), "foto.jpg")
    }

    // MARK: - Notifications

    private func transfer(_ state: TransferState, mirror: Bool = false, bytes: Int64 = 1_000) -> Transfer {
        var job = Transfer(name: "x", destination: "", accountID: "a", direction: .upload, localURL: URL(fileURLWithPath: "/"))
        job.state = state; job.total = bytes
        if mirror { job.mirrorEntries = [:] }
        return job
    }

    func testOneNotificationSumsUpARunAndSkipsMirrors() {
        UserDefaults.standard.removeObject(forKey: Prefs.notifyTransfers)
        let notifier = TransferNotifier()
        var posted: [(String, String)] = []
        notifier.post = { posted.append(($0, $1)) }
        notifier.isAppActive = { false }
        notifier.queueChanged(active: true)
        notifier.finished(transfer(.completed))
        notifier.finished(transfer(.completed))
        notifier.finished(transfer(.failed))
        notifier.finished(transfer(.completed, mirror: true))
        notifier.queueChanged(active: true)
        XCTAssertTrue(posted.isEmpty, "Nothing while the run goes on")
        notifier.queueChanged(active: false)
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted[0].1.contains("2"), posted[0].1)
        XCTAssertTrue(posted[0].0.contains("errores"))
        notifier.queueChanged(active: false)
        XCTAssertEqual(posted.count, 1, "An idle queue does not repeat the last summary")
    }

    func testNoNotificationWhileICloudyIsInFront() {
        let notifier = TransferNotifier()
        var posted = 0
        notifier.post = { _, _ in posted += 1 }
        notifier.isAppActive = { true }
        notifier.queueChanged(active: true)
        notifier.finished(transfer(.completed))
        notifier.queueChanged(active: false)
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(notifier.summary, TransferNotifier.Summary(), "The next run starts from zero")
    }

    // MARK: - Undo

    func testTrashIsUndoneOnlyWhereTheBinGivesItemsBackByID() {
        func account(_ cloud: Cloud) -> Account { Account(id: cloud.rawValue, cloud: cloud, name: "", email: "", clientID: "", clientSecret: nil) }
        XCTAssertTrue(AppModel.undoesTrash(account(.google)))
        XCTAssertTrue(AppModel.undoesTrash(account(.box)))
        XCTAssertTrue(AppModel.undoesTrash(account(.pcloud)))
        XCTAssertFalse(AppModel.undoesTrash(account(.dropbox)), "Dropbox restores by revision")
        XCTAssertFalse(AppModel.undoesTrash(account(.volume)), "The Finder's Trash is out of reach")
        XCTAssertFalse(AppModel.undoesTrash(account(.webdav)), "Deleting there is final")
    }

    // MARK: - Batch rename

    func testBatchRenameKeepsExtensionsAndNumbersInOrder() {
        let files = (1...12).map { file("IMG_\($0).JPG") } + [file("Viaje 2024.03", folder: true)]
        var rule = BatchRename(mode: .format, base: "Playa", start: 1)
        let names = rule.names(for: files)
        XCTAssertEqual(names.first, "Playa 01.JPG")
        XCTAssertEqual(names[11], "Playa 12.JPG")
        XCTAssertEqual(names.last, "Playa 13", "A folder has no extension to keep")

        rule = BatchRename(mode: .replace, find: "img_", replacement: "foto-", ignoresCase: true)
        XCTAssertEqual(rule.names(for: [file("IMG_7.jpg")]), ["foto-7.jpg"])
        rule = BatchRename(mode: .replace, find: "img_", replacement: "foto-", ignoresCase: false)
        XCTAssertEqual(rule.names(for: [file("IMG_7.jpg")]), ["IMG_7.jpg"])
        rule = BatchRename(mode: .add, text: " (copia)", position: .after)
        XCTAssertEqual(rule.names(for: [file("acta.pdf")]), ["acta (copia).pdf"])
        rule = BatchRename(mode: .add, text: "2024 ", position: .before)
        XCTAssertEqual(rule.names(for: [file("acta.pdf")]), ["2024 acta.pdf"])
        XCTAssertEqual(BatchRename.split(file(".bashrc")).stem, ".bashrc", "A dot file is all name")
    }

    func testBatchRenameRefusesClashesBeforeSendingAnything() {
        let a = file("a.txt"), b = file("b.txt"), other = file("c.txt")
        XCTAssertNotNil(BatchRename.problem(files: [a, b], names: ["x.txt", "X.txt"], siblings: [], cloud: .google), "Two of them would end up equal")
        XCTAssertNotNil(BatchRename.problem(files: [a, b], names: ["c.txt", "d.txt"], siblings: [a, b, other], cloud: .google), "Something else is called that")
        XCTAssertNil(BatchRename.problem(files: [a, b], names: ["b.txt", "a.txt"], siblings: [a, b, other], cloud: .google), "Swapping within the batch is fine")
        XCTAssertNotNil(BatchRename.problem(files: [a], names: ["a/b.txt"], siblings: [], cloud: .google))
        XCTAssertTrue(BatchRename.needsTwoSteps(files: [a, b], names: ["b.txt", "a.txt"]))
        XCTAssertFalse(BatchRename.needsTwoSteps(files: [a, b], names: ["x.txt", "y.txt"]))
    }

    // MARK: - Sorting and the grid's keyboard

    func testSortingByKindGroupsFoldersThenKinds() {
        let files = [file("z.mp4"), file("b.pdf"), file("a.jpg"), file("Carpeta", folder: true), file("c.pdf"), file("a.docx")]
        let sorted = BrowserState.visible(files, search: "", sortMode: "kind").map(\.name)
        XCTAssertEqual(sorted.first, "Carpeta")
        XCTAssertEqual(Array(sorted[1...2]), ["b.pdf", "c.pdf"], "Same kind, by name")
        XCTAssertLessThan(sorted.firstIndex(of: "a.docx")!, sorted.firstIndex(of: "a.jpg")!)
        XCTAssertLessThan(sorted.firstIndex(of: "a.jpg")!, sorted.firstIndex(of: "z.mp4")!)
    }

    func testArrowKeysMoveAcrossTheGridAndStopAtItsEdges() {
        XCTAssertEqual(ExplorerView.gridStep(from: nil, dx: 1, dy: 0, columns: 4, count: 10), 0, "Nothing selected starts at the first")
        XCTAssertEqual(ExplorerView.gridStep(from: 0, dx: 1, dy: 0, columns: 4, count: 10), 1)
        XCTAssertEqual(ExplorerView.gridStep(from: 1, dx: 0, dy: 1, columns: 4, count: 10), 5)
        XCTAssertEqual(ExplorerView.gridStep(from: 3, dx: 1, dy: 0, columns: 4, count: 10), 3, "No wrapping to the next row")
        XCTAssertEqual(ExplorerView.gridStep(from: 4, dx: -1, dy: 0, columns: 4, count: 10), 4)
        XCTAssertEqual(ExplorerView.gridStep(from: 7, dx: 0, dy: 1, columns: 4, count: 10), 7, "Nothing below")
        XCTAssertEqual(ExplorerView.gridStep(from: 1, dx: 0, dy: -1, columns: 4, count: 10), 1)
        XCTAssertNil(ExplorerView.gridStep(from: nil, dx: 1, dy: 0, columns: 4, count: 0))
        XCTAssertEqual(ExplorerView.gridColumns(width: 0), 1)
        XCTAssertEqual(ExplorerView.gridColumns(width: 2 * Layout.margin + 156 * 3 - 16), 3)
    }

    // MARK: - Saved searches

    func testSavedSearchesKeepTextAndFiltersAndReplaceByName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SavedSearches(url: url)
        var filters = SearchFilters(); filters.type = .images; filters.age = .month; filters.accountID = "acc"
        store.save(name: "Fotos recientes", query: "playa", filters: filters)
        store.save(name: "  ", query: "x", filters: SearchFilters())
        store.save(name: "fotos RECIENTES", query: "mar", filters: filters)
        XCTAssertEqual(store.items.count, 1, "Same name, case aside, replaces")
        let reloaded = SavedSearches(url: url)
        XCTAssertEqual(reloaded.items.first?.query, "mar")
        XCTAssertEqual(reloaded.items.first?.filters.type, .images)
        XCTAssertEqual(reloaded.items.first?.filters.age, .month)
        XCTAssertEqual(reloaded.items.first?.filters.accountID, "acc")
        reloaded.remove(reloaded.items[0].id)
        XCTAssertTrue(SavedSearches(url: url).items.isEmpty)
    }

    // MARK: - Search by walking the tree

    func testWalkingTheTreeFindsNamesAndCarriesOnPageByPage() async throws {
        let storage = MemoryProvider()
        var folders: [String] = []
        for index in 0..<45 {
            let folder = try await storage.createFolder(name: "Carpeta \(index)", parent: "root")
            folders.append(folder)
            storage.items[UUID().uuidString] = .init(name: "Nota \(index).txt", parent: folder, folder: false, data: Data(), checksum: nil)
        }
        _ = try await storage.createFolder(name: "nota vieja", parent: folders[0])
        var hits: [SearchHit] = []
        var page = try await storage.walkSearch(term: "NOTA", cursor: nil)
        hits += page.hits
        XCTAssertNotNil(page.next, "Forty folders per page; there are more")
        var pages = 1
        while let next = page.next {
            page = try await storage.walkSearch(term: "NOTA", cursor: next); hits += page.hits; pages += 1
        }
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(hits.count, 46)
        XCTAssertTrue(hits.allSatisfy { $0.accountID == "memory" && $0.parentID != nil })
        do { _ = try await storage.walkSearch(term: "NOTA", cursor: "caducado"); XCTFail("An unknown cursor is refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("caducado"), error.localizedDescription) }
    }
}
