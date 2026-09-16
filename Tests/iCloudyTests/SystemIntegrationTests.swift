import XCTest
import CoreSpotlight
import UniformTypeIdentifiers
@testable import iCloudy

/// Records what would reach Spotlight instead of touching the user's real index.
@MainActor
final class MockSearchableIndex: SearchableIndexing {
    var indexed: [CSSearchableItem] = []
    var deletedDomains: [String] = []
    func index(_ items: [CSSearchableItem]) async throws { indexed += items }
    func deleteItems(withDomainIdentifiers identifiers: [String]) async throws { deletedDomains += identifiers }
}

@MainActor
final class SystemIntegrationTests: XCTestCase {
    private func file(_ name: String, id: String = UUID().uuidString, folder: Bool = false, mime: String = "application/pdf") -> CloudFile {
        CloudFile(id: id, name: name, mime: mime, size: 1234, modified: Date(timeIntervalSince1970: 1_700_000_000), webURL: URL(string: "https://example.com/\(id)"), isFolder: folder)
    }
    private func makeIndex() throws -> (SpotlightIndex, MockSearchableIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mock = MockSearchableIndex()
        return (SpotlightIndex(index: mock, storeURL: root.appendingPathComponent("spotlight.json")), mock, root)
    }
    /// The index publishes through detached tasks; let them run before asserting.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    func testIdentifierRoundTripsAndRejectsMalformedValues() {
        let id = SpotlightIndex.identifier(accountID: "google:1", fileID: "abc")
        let decoded = SpotlightIndex.decode(identifier: id)
        XCTAssertEqual(decoded?.accountID, "google:1")
        XCTAssertEqual(decoded?.fileID, "abc")
        XCTAssertNil(SpotlightIndex.decode(identifier: "sin-separador"))
        XCTAssertNil(SpotlightIndex.decode(identifier: SpotlightIndex.identifier(accountID: "", fileID: "abc")))
    }

    func testSearchableItemCarriesNameAndLocationButNoContents() {
        let entry = IndexedItem(accountID: "google:1", file: file("Informe.pdf", id: "f1"), path: ["Trabajo", "2026"], seen: Date())
        let item = SpotlightIndex.searchableItem(for: entry, accountLabel: "Drive personal")
        XCTAssertEqual(item.uniqueIdentifier, "google:1\u{1F}f1")
        XCTAssertEqual(item.domainIdentifier, "google:1", "Deleting by domain must wipe exactly one account")
        XCTAssertEqual(item.attributeSet.title, "Informe.pdf")
        XCTAssertEqual(item.attributeSet.contentDescription, "Drive personal / Trabajo / 2026")
        XCTAssertEqual(item.attributeSet.fileSize, 1234)
        XCTAssertNil(item.attributeSet.textContent, "Contents are never indexed")
        let folder = SpotlightIndex.searchableItem(for: IndexedItem(accountID: "a", file: file("Fotos", id: "d1", folder: true, mime: "application/vnd.google-apps.folder"), path: [], seen: Date()), accountLabel: "A")
        XCTAssertEqual(folder.attributeSet.contentType, UTType.folder.identifier)
    }

    func testNoteDeduplicatesKeepsTheNewestAndHonoursTheLimit() async throws {
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        index.limit = 3
        for name in ["a", "b", "c", "d"] { index.note(file(name, id: name), accountID: "google:1", path: [], accountLabel: "Drive") }
        XCTAssertEqual(index.items.map(\.file.id), ["d", "c", "b"], "Newest first, oldest dropped")
        index.note(file("c", id: "c"), accountID: "google:1", path: [], accountLabel: "Drive")
        XCTAssertEqual(index.items.map(\.file.id), ["c", "d", "b"], "A repeat moves up instead of duplicating")
        XCTAssertEqual(index.items.count, 3)
        try await settle()
        XCTAssertEqual(mock.indexed.count, 5)
        let restored = SpotlightIndex(index: mock, storeURL: index.storeURL)
        XCTAssertEqual(restored.items.map(\.file.id), ["c", "d", "b"], "Survives a restart")
    }

    func testDisconnectingAnAccountWipesOnlyItsItems() async throws {
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        index.note(file("uno", id: "1"), accountID: "google:1", path: [], accountLabel: "Drive")
        index.note(file("dos", id: "2"), accountID: "microsoft:2", path: [], accountLabel: "OneDrive")
        index.removeAccount("google:1")
        try await settle()
        XCTAssertEqual(index.items.map(\.accountID), ["microsoft:2"])
        XCTAssertEqual(mock.deletedDomains, ["google:1"])
    }

    func testFavoritesAreIndexedWithTheirBreadcrumbs() async throws {
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let favorite = Favorite(accountID: "google:1", file: file("Contrato.pdf", id: "f9"), path: [file("Legal", id: "d1", folder: true)])
        index.refreshFavorites([favorite]) { _ in "Drive" }
        index.refreshFavorites([favorite]) { _ in "Drive" }
        XCTAssertEqual(index.items.count, 1, "Re-publishing a favorite must not duplicate it")
        try await settle()
        XCTAssertEqual(mock.indexed.last?.attributeSet.contentDescription, "Drive / Legal")
    }

    func testResumeAllRevivesPausedAndFailedButNotCompleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        var items: [Transfer] = []
        for (name, state) in [("a", TransferState.paused), ("b", .failed), ("c", .completed), ("d", .cancelled)] {
            var job = Transfer(name: name, destination: "d", accountID: "acc", direction: .upload, localURL: root.appendingPathComponent(name))
            job.state = state; items.append(job)
        }
        try LocalStore.save(items, to: queue.storeURL)
        let restored = TransferQueue(storeURL: queue.storeURL)
        restored.client = { _ in throw CloudError.message("sin red") }
        XCTAssertEqual(restored.resumeAll(), 2, "Paused and failed only")
        XCTAssertEqual(restored.items.first { $0.name == "c" }?.state, .completed)
        XCTAssertEqual(restored.items.first { $0.name == "d" }?.state, .cancelled)
    }
}
