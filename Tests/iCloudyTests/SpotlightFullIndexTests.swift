import XCTest
import CoreSpotlight
@testable import iCloudy

/// The optional full index: a bounded walk, its own domain and identifiers, and a result Spotlight can open.
@MainActor
final class SpotlightFullIndexTests: XCTestCase {
    func testTheWalkGoesFolderByFolderAndStopsAtTheCap() async throws {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        let walked = await model.walkForFullIndex(.demo, limit: 10_000, pacer: ListingPacer(interval: .zero))
        let whole = try XCTUnwrap(walked)
        XCTAssertFalse(whole.truncated)
        let notes = try XCTUnwrap(whole.entries.first { $0.file.name == "Notas.txt" })
        XCTAssertEqual(notes.path, ["Proyectos"], "Each item carries the folders above it")
        let short = await model.walkForFullIndex(.demo, limit: 2, pacer: ListingPacer(interval: .zero))
        let capped = try XCTUnwrap(short)
        XCTAssertEqual(capped.entries.count, 2)
        XCTAssertTrue(capped.truncated)
    }

    func testAFullIndexLivesInItsOwnDomainAndIsFoundAgain() async throws {
        let root = try temporaryRoot()
        let mock = MockSearchableIndex()
        let index = SpotlightIndex(index: mock, storeURL: root.appendingPathComponent("spotlight.json"))
        let file = CloudFile(id: "f1", name: "informe.pdf", mime: "application/pdf", size: 1, modified: nil, webURL: nil, isFolder: false)
        index.note(file, accountID: "acc", path: [], accountLabel: "Trabajo")
        index.replaceFull("acc", with: FullIndexState(entries: [IndexedItem(accountID: "acc", file: file, path: ["Docs"], seen: Date())], indexed: Date()), label: "Trabajo")
        await index.settle()
        let identifier = SpotlightFullIndex.identifier(accountID: "acc", fileID: "f1")
        XCTAssertEqual(mock.stored[identifier], SpotlightFullIndex.domain("acc"))
        XCTAssertNotNil(mock.stored[SpotlightIndex.identifier(accountID: "acc", fileID: "f1")], "The recent entry is a separate one")
        let decoded = try XCTUnwrap(SpotlightIndex.decode(identifier: identifier))
        XCTAssertEqual(decoded.fileID, "f1")
        XCTAssertEqual(index.entry(accountID: "acc", fileID: "f1")?.file.name, "informe.pdf")

        index.dropFull("acc")
        await index.settle()
        XCTAssertNil(mock.stored[identifier], "Switching it off takes the full index out")
        XCTAssertNotNil(mock.stored[SpotlightIndex.identifier(accountID: "acc", fileID: "f1")], "and leaves the recent item")
        XCTAssertNil(index.fullState("acc"))

        index.replaceFull("acc", with: FullIndexState(entries: [], indexed: Date()), label: "Trabajo")
        StoreWriter.shared.flush()
        XCTAssertNotNil(SpotlightIndex(index: mock, storeURL: index.storeURL).fullState("acc"), "The full index survives a relaunch")
        index.removeAccount("acc")
        await index.settle()
        XCTAssertTrue(mock.deletedDomains.contains(SpotlightFullIndex.domain("acc")))
    }

    func testTheSettingsAreBounded() {
        SpotlightFullIndex.limit = 10
        XCTAssertEqual(SpotlightFullIndex.limit, 100)
        SpotlightFullIndex.limit = 10_000_000
        XCTAssertEqual(SpotlightFullIndex.limit, 100_000)
        SpotlightFullIndex.enabled = ["b", "a"]
        XCTAssertEqual(SpotlightFullIndex.enabled, ["a", "b"])
    }
}
