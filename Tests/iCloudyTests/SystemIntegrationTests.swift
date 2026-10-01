import XCTest
import CoreSpotlight
import UniformTypeIdentifiers
@testable import iCloudy

/// Records what would reach Spotlight instead of touching the user's real index, and keeps what the system would
/// hold after each request, so a test can see an entry that was left behind and not only the calls that were made.
@MainActor
final class MockSearchableIndex: SearchableIndexing {
    var indexed: [CSSearchableItem] = []
    var deletedDomains: [String] = []
    var deletedItems: [String] = []
    var deletedAll = 0
    /// Identifier to domain of every entry the fake system index holds.
    var stored: [String: String] = [:]
    /// How long a publication takes. The real index answers on its own queue, so a slow publication followed by a
    /// fast deletion is how an unordered pair of requests left a hit behind.
    var indexDelay: Duration = .zero
    func index(_ items: [CSSearchableItem]) async throws {
        if indexDelay > .zero { try await Task.sleep(for: indexDelay) }
        indexed += items
        for item in items { stored[item.uniqueIdentifier] = item.domainIdentifier ?? "" }
    }
    func deleteItems(withDomainIdentifiers identifiers: [String]) async throws {
        deletedDomains += identifiers
        stored = stored.filter { !identifiers.contains($0.value) }
    }
    func deleteItems(withIdentifiers identifiers: [String]) async throws {
        deletedItems += identifiers
        for identifier in identifiers { stored[identifier] = nil }
    }
    func deleteAllItems() async throws { deletedAll += 1; stored = [:] }
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

    func testBinningAnItemAndRenamingOneReachSpotlight() async throws {
        // A hit left behind after the item went to the bin opens on a file that is not there, and the app can only
        // answer that the result is no longer available. A rename left Spotlight offering the old name.
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        index.note(file("Informe.pdf", id: "f1"), accountID: "google:1", path: [], accountLabel: "Drive")
        await index.settle()
        XCTAssertEqual(mock.indexed.count, 1)

        index.rename(file("Informe final.pdf", id: "f1"), accountID: "google:1", accountLabel: "Drive")
        await index.settle()
        XCTAssertEqual(index.items.first?.file.name, "Informe final.pdf")
        XCTAssertEqual(mock.indexed.last?.attributeSet.title, "Informe final.pdf", "Y se vuelve a publicar")

        index.forget(accountID: "google:1", fileID: "f1")
        await index.settle()
        XCTAssertTrue(index.items.isEmpty)
        XCTAssertEqual(mock.deletedItems, [SpotlightIndex.identifier(accountID: "google:1", fileID: "f1")])

        // Something that was never indexed asks the system for nothing at all.
        index.forget(accountID: "google:1", fileID: "jamás")
        index.rename(file("x", id: "jamás"), accountID: "google:1", accountLabel: "Drive")
        await index.settle()
        XCTAssertEqual(mock.deletedItems.count, 1)
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
        await index.settle()
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
        await index.settle()
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
        await index.settle()
        XCTAssertEqual(mock.indexed.last?.attributeSet.contentDescription, "Drive / Legal")
    }

    func testTheLimitEvictsFromTheSystemIndexTooButNeverAFavorite() async throws {
        // Dropping the oldest entry from the local list used to leave it in Spotlight for good: nothing remembered
        // it any more, so nothing would ever retire it.
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        index.limit = 2
        let favorite = Favorite(accountID: "google:1", file: file("Contrato.pdf", id: "fav"), path: [])
        index.refreshFavorites([favorite]) { _ in "Drive" }
        for name in ["a", "b", "c"] { index.note(file(name, id: name), accountID: "google:1", path: [], accountLabel: "Drive") }
        await index.settle()
        XCTAssertEqual(index.items.map(\.file.id), ["c", "fav"], "The favorite stays even though it is the oldest")
        XCTAssertEqual(mock.deletedItems, ["a", "b"].map { SpotlightIndex.identifier(accountID: "google:1", fileID: $0) })
        XCTAssertEqual(Set(mock.stored.keys), Set(index.items.map { SpotlightIndex.identifier(accountID: $0.accountID, fileID: $0.file.id) }),
                       "The system index holds exactly what the list holds")
    }

    func testRequestsReachTheSystemIndexInTheOrderTheyWereMade() async throws {
        // Each request used to run in a task of its own. A slow publication followed by a quick deletion finished
        // in the opposite order and left in Spotlight a file that had just gone to the bin.
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        mock.indexDelay = .milliseconds(40)
        index.note(file("Informe.pdf", id: "f1"), accountID: "google:1", path: [], accountLabel: "Drive")
        index.forget(accountID: "google:1", fileID: "f1")
        index.note(file("Otro.pdf", id: "f2"), accountID: "google:1", path: [], accountLabel: "Drive")
        index.clear()
        index.note(file("Nuevo.pdf", id: "f3"), accountID: "microsoft:2", path: [], accountLabel: "OneDrive")
        await index.settle()
        XCTAssertEqual(Array(mock.stored.keys), [SpotlightIndex.identifier(accountID: "microsoft:2", fileID: "f3")],
                       "Only what was published after «Vaciar» survives, and the binned file is gone")
        XCTAssertEqual(mock.indexed.map(\.uniqueIdentifier).last, SpotlightIndex.identifier(accountID: "microsoft:2", fileID: "f3"))
    }

    func testClearingReachesEntriesTheListNoLongerRemembers() async throws {
        // «Vaciar» deleted the accounts of the entries still in the list. An entry evicted by an older version, or
        // of an account whose entries had all been dropped, stayed in the system's search.
        let (index, mock, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        mock.stored = ["dropbox:viejo\u{1F}x": "dropbox:viejo"]
        index.note(file("uno", id: "1"), accountID: "google:1", path: [], accountLabel: "Drive")
        index.clear()
        await index.settle()
        XCTAssertTrue(index.items.isEmpty)
        XCTAssertEqual(mock.deletedAll, 1)
        XCTAssertTrue(mock.stored.isEmpty, "Nothing iCloudy ever published is left")
        // Clearing an empty list still reaches the system: that is exactly the case of entries nobody remembers.
        mock.stored = ["dropbox:viejo\u{1F}y": "dropbox:viejo"]
        index.clear()
        await index.settle()
        XCTAssertTrue(mock.stored.isEmpty)
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
