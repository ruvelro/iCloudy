import XCTest
import AppKit
@testable import iCloudy

@MainActor
final class SearchAppearanceTests: XCTestCase {
    private let other = Account(id: "other", cloud: .microsoft, name: "Other", email: "other@example.com", clientID: "test", clientSecret: nil)
    private func hit(_ account: String = Account.demo.id, id: String = "same", name: String = "report.pdf", size: Int64? = 10_000_000, date: Date? = Date(), folder: Bool = false) -> SearchHit {
        SearchHit(accountID: account, file: CloudFile(id: id, name: name, mime: "application/octet-stream", size: size, modified: date, webURL: nil, isFolder: folder), parentID: "root")
    }
    private func settle(_ model: GlobalSearch) async throws {
        for _ in 0..<200 {
            if model.loadingIDs.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not settle")
    }
    private func client(_ cloud: Cloud) -> CloudAPI {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: Account(id: "api", cloud: cloud, name: "Test", email: "test@example.com", clientID: "test", clientSecret: nil), session: URLSession(configuration: configuration), tokenProvider: { "test-token" })
    }
    func testFiltersHandleBoundariesAndUnknownMetadata() {
        XCTAssertNotEqual(hit().id, hit(other.id).id)
        XCTAssertTrue(SearchFilters(type: .documents, age: .week, size: .medium).matches(hit()))
        XCTAssertFalse(SearchFilters(size: .small).matches(hit()))
        XCTAssertTrue(SearchFilters(size: .large).matches(hit(size: 100_000_000)))
        XCTAssertFalse(SearchFilters(size: .medium).matches(hit(size: 100_000_000)))
        XCTAssertFalse(SearchFilters(size: .small).matches(hit(size: nil)))
        XCTAssertFalse(SearchFilters(size: .small).matches(hit(size: 0, folder: true)))
        XCTAssertFalse(SearchFilters(age: .week).matches(hit(date: nil)))
        XCTAssertFalse(SearchFilters(age: .week).matches(hit(date: Date().addingTimeInterval(-86400 * 8))))
        XCTAssertFalse(SearchFilters(accountID: other.id).matches(hit()))
        XCTAssertTrue(SearchFilters(type: .images).matches(hit(name: "Photo.PNG")))
        XCTAssertTrue(SearchFilters(type: .folders).matches(hit(folder: true)))
    }
    func testParallelAccountsPreserveSuccessWhenOneFailsAndRetryDeduplicates() async throws {
        let model = GlobalSearch(); model.query = "report"
        var failOther = true
        model.start(accounts: [.demo, other]) { account, _, _ in
            if account.id == self.other.id && failOther { throw URLError(.notConnectedToInternet) }
            return SearchPage(hits: [self.hit(account.id), self.hit(account.id)])
        }
        try await settle(model)
        XCTAssertEqual(model.hits.count, 1); XCTAssertNotNil(model.errors[other.id])
        failOther = false; model.loadMore(other.id); try await settle(model)
        XCTAssertEqual(model.hits.count, 2); XCTAssertNil(model.errors[other.id])
        model.removeAccount(other.id)
        XCTAssertEqual(model.hits.count, 1)
    }
    func testBatchesExposeMorePagesAndDetectRepeatedCursor() async throws {
        let model = GlobalSearch(); model.query = "report"
        model.start(accounts: [.demo]) { account, _, cursor in
            let offset = Int(cursor ?? "0")!
            return SearchPage(hits: [self.hit(account.id, id: String(offset))], next: offset < 4 ? String(offset + 1) : nil)
        }
        try await settle(model)
        XCTAssertEqual(model.hits.count, 3); XCTAssertEqual(model.cursors[Account.demo.id], "3")
        model.loadMore(Account.demo.id); try await settle(model)
        XCTAssertEqual(model.hits.count, 5); XCTAssertNil(model.cursors[Account.demo.id])
        model.start(accounts: [.demo]) { account, _, _ in SearchPage(hits: [self.hit(account.id)], next: "repeat") }
        try await settle(model)
        XCTAssertEqual(model.hits.count, 1); XCTAssertNotNil(model.errors[Account.demo.id]); XCTAssertNil(model.cursors[Account.demo.id])
    }
    func testCancelledOlderSearchCannotRestoreResults() async throws {
        let model = GlobalSearch(); model.query = "old"
        model.start(accounts: [.demo]) { account, _, _ in
            try? await Task.sleep(for: .milliseconds(40))
            return SearchPage(hits: [self.hit(account.id, name: "old.txt")])
        }
        await Task.yield()
        model.query = "new"
        model.start(accounts: [.demo]) { account, _, _ in SearchPage(hits: [self.hit(account.id, name: "new.txt")]) }
        try await settle(model)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.hits.map(\.file.name), ["new.txt"])
        XCTAssertEqual(model.submittedQuery, "new")
    }
    func testGoogleSearchEscapesQueryAndKeepsParentsAndPagination() async throws {
        defer { StubProtocol.handler = nil }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let q = query.first { $0.name == "q" }!.value!
            XCTAssertTrue(q.contains("trashed = false"))
            XCTAssertTrue(q.contains("name contains 'O\\'Brien'"))
            XCTAssertTrue(q.contains("fullText contains 'O\\'Brien'"))
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "second")
            return (200, [:], Data(#"{"incompleteSearch":true,"nextPageToken":"third","files":[{"id":"one","name":"Report","mimeType":"text/plain","parents":["folder"]},{"id":"shared","name":"Shared drive","driveId":"outside"}]}"#.utf8))
        }
        let page = try await client(.google).searchPage(term: "O'Brien", cursor: "second")
        XCTAssertEqual(page.hits.count, 1); XCTAssertEqual(page.hits.first?.parentID, "folder")
        XCTAssertTrue(page.incomplete); XCTAssertEqual(page.next, "third")
    }
    func testMicrosoftSearchEncodesQuotesAndRejectsForeignPageBeforeSendingToken() async throws {
        defer { StubProtocol.handler = nil }
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            let path = request.url!.absoluteString.removingPercentEncoding!
            XCTAssertTrue(path.contains("search(q='O''Brien & plan')"))
            return (200, [:], Data(#"{"value":[{"id":"one","name":"Plan","size":42,"parentReference":{"id":"folder"}}],"@odata.nextLink":"https://attacker.invalid/next"}"#.utf8))
        }
        let api = client(.microsoft)
        let page = try await api.searchPage(term: "O'Brien & plan")
        XCTAssertEqual(page.hits.first?.parentID, "folder")
        do { _ = try await api.searchPage(term: "anything", cursor: page.next); XCTFail("Expected pagination rejection") } catch {}
        XCTAssertEqual(requests, 1)
    }
    func testDemoSearchFindsNestedItemsAndReturnsRealBreadcrumbs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = try DemoStore(directory: root)
        let parent = try demo.add(name: "Projects", parent: "root", folder: true)
        let nested = try demo.add(name: "Reports", parent: parent, folder: true)
        let id = try demo.add(name: "report.pdf", parent: nested)
        let api = CloudAPI(account: .demo, demo: demo)
        let page = try await api.searchPage(term: "report.pdf")
        XCTAssertEqual(page.hits.map(\.file.id), [id]); XCTAssertEqual(page.hits.first?.parentID, nested)
        let trail = try await api.folderTrail(id: nested)
        XCTAssertEqual(trail.map(\.name), ["Projects", "Reports"])
    }
    func testAppearancePersistenceIsScopedByAccountAndValidatesManualSymbols() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("appearance.json")
        let store = try AppearanceStore(url: url)
        try store.save(AccountAppearance(alias: "  Trabajo  ", tint: .purple, icon: "briefcase.fill"), for: "work")
        try store.save(AccountAppearance(alias: "Personal", tint: .orange, icon: "drive"), for: "home")
        let restored = try AppearanceStore(url: url)
        XCTAssertEqual(restored.values["work"]?.alias, "Trabajo"); XCTAssertEqual(restored.values["home"]?.tint, .orange)
        XCTAssertThrowsError(try store.save(AccountAppearance(icon: "not.a.real.symbol.icloudy"), for: "work"))
        XCTAssertEqual(store.values["work"]?.icon, "briefcase.fill")
        XCTAssertThrowsError(try AccountAppearance(alias: String(repeating: "a", count: 61)).validated())
        XCTAssertThrowsError(try AccountAppearance(alias: "a\nb").validated())
        XCTAssertEqual(AccountAppearance().title(for: .demo), "Demo local")
        XCTAssertNotNil(NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil))
        _ = try AccountAppearance(icon: "gamecontroller.fill").validated()
    }
    func testImportedImageSurvivesOriginalRemovalAndIsDownsampled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = root.appendingPathComponent("icon.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let data = try AccountAppearance.importIcon(from: image)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(rep.pixelsWide, 256); XCTAssertLessThanOrEqual(rep.pixelsHigh, 256)
        let url = root.appendingPathComponent("preferences.json")
        let store = try AppearanceStore(url: url)
        try store.save(AccountAppearance(icon: "custom", customPNG: data), for: "account")
        try FileManager.default.removeItem(at: image)
        XCTAssertEqual(try AppearanceStore(url: url).values["account"]?.customPNG, data)
        try store.save(AccountAppearance(icon: "drive", customPNG: data), for: "account")
        XCTAssertNil(store.values["account"]?.customPNG)
    }
    func testInvalidImageAndCorruptPreferencesAreNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try AccountAppearance.importIcon(from: invalid))
        XCTAssertThrowsError(try AppearanceStore(url: invalid))
        XCTAssertEqual(try String(contentsOf: invalid), "not an image")
    }
}
