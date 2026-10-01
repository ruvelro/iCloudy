import XCTest
@testable import iCloudy

/// Tabs, the second pane and the history each of them keeps.
@MainActor
final class TabsAndPanesTests: XCTestCase {
    private func folder(_ id: String) -> CloudFile {
        CloudFile(id: id, name: "Carpeta \(id)", mime: "folder", size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    private func place(_ account: String, _ folders: String...) -> BrowserLocation {
        BrowserLocation(accountID: account, collection: .files, path: folders.map(folder))
    }

    // MARK: - History

    func testBackAndForwardRetraceTheTab() {
        var tab = BrowserState(accountID: "a")
        tab.open(place("a", "1"))
        tab.open(place("a", "1", "2"))
        tab.open(place("b"))
        XCTAssertEqual(tab.back.count, 3)
        XCTAssertTrue(tab.goBack())
        XCTAssertEqual(tab.location, place("a", "1", "2"))
        XCTAssertTrue(tab.goBack())
        XCTAssertEqual(tab.location, place("a", "1"))
        XCTAssertTrue(tab.goForward())
        XCTAssertEqual(tab.location, place("a", "1", "2"))
        XCTAssertEqual(tab.forward, [place("b")])
        tab.open(place("a", "9"))
        XCTAssertTrue(tab.forward.isEmpty, "Ir a un sitio nuevo descarta lo que quedaba por delante")
        XCTAssertEqual(tab.back.last, place("a", "1", "2"))
    }

    func testOpeningTheSamePlaceAgainIsNotAStep() {
        var tab = BrowserState(accountID: "a")
        tab.open(place("a"))
        XCTAssertTrue(tab.back.isEmpty)
        var empty = BrowserState()
        empty.open(place("a"))
        XCTAssertTrue(empty.back.isEmpty, "Una pestaña sin cuenta no deja un sitio al que volver")
    }

    func testHistoryIsBoundedAndSkipsAccountsThatLeft() {
        var tab = BrowserState(accountID: "a")
        for index in 0..<(BrowserState.historyLimit + 10) { tab.open(place(index.isMultiple(of: 2) ? "a" : "b", "\(index)")) }
        XCTAssertEqual(tab.back.count, BrowserState.historyLimit)
        let current = tab.location
        // The last place was "b"/59; the one before it, "a"/58, belongs to an account that is gone.
        XCTAssertTrue(tab.goBack(where: { $0.accountID == "b" }))
        XCTAssertEqual(tab.location, place("b", "57"), "Se salta lo que era de una cuenta desconectada")
        XCTAssertEqual(tab.forward, [current])
        tab.forgetHistory(of: ["a"])
        XCTAssertTrue(tab.back.allSatisfy { $0.accountID == "b" })
        var fresh = BrowserState(accountID: "a")
        XCTAssertFalse(fresh.goBack(), "Sin historial no hay a dónde volver")
        XCTAssertEqual(fresh.location, BrowserLocation(accountID: "a"))
    }

    func testARenameFollowsThePlaceAndItsHistory() {
        var tab = BrowserState(accountID: "a")
        tab.open(place("a", "1"))
        tab.open(place("a", "1", "2"))
        tab.files = [folder("1")]
        let change = RemoteIdentityChange(oldID: "1", newID: "uno", name: "Uno", descendants: false)
        tab.remap(change, accountID: "a")
        XCTAssertEqual(tab.path.map(\.id), ["uno", "2"])
        XCTAssertEqual(tab.back.last?.path.map(\.id), ["uno"])
        XCTAssertEqual(tab.files.first?.name, "Uno")
        tab.remap(RemoteIdentityChange(oldID: "2", newID: "dos", name: "Dos", descendants: false), accountID: "otra")
        XCTAssertEqual(tab.path.map(\.id), ["uno", "2"], "Lo de otra cuenta no se toca")
    }
}
