import XCTest
@testable import iCloudy

/// The explorer's place used to be a dozen loose properties on the model. It is a value now, one per tab, and these
/// pin down that moving it there changed nothing about what the list shows.
@MainActor
final class BrowserStateTests: XCTestCase {
    private func file(_ id: String, _ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil) -> CloudFile {
        CloudFile(id: id, name: name, mime: folder ? "folder" : "text/plain", size: size, modified: modified, webURL: nil, isFolder: folder)
    }

    func testTheListIsFilteredAndSortedAsBefore() {
        var state = BrowserState(accountID: "a")
        state.files = [file("1", "b.txt", size: 5, modified: Date(timeIntervalSince1970: 10)),
                       file("2", "Carpeta", folder: true),
                       file("3", "a.txt", size: 9, modified: Date(timeIntervalSince1970: 20))]
        XCTAssertEqual(state.visibleFiles.map(\.id), ["2", "3", "1"], "Las carpetas primero y luego por nombre")
        state.sortMode = "size"
        XCTAssertEqual(state.visibleFiles.map(\.id), ["2", "3", "1"])
        state.sortMode = "date"
        XCTAssertEqual(state.visibleFiles.map(\.id), ["2", "3", "1"])
        state.sortMode = "name"; state.search = "B."
        XCTAssertEqual(state.visibleFiles.map(\.id), ["1"], "El filtro no distingue mayúsculas")
    }

    func testOpeningAnotherPlaceDropsWhatBelongedToTheOldOne() {
        var state = BrowserState(accountID: "a", sortMode: "date", viewMode: "grid")
        state.files = [file("1", "x")]; state.search = "x"; state.selection = ["1"]
        let folder = file("f", "Fotos", folder: true)
        state.open(BrowserLocation(accountID: "b", collection: .files, path: [folder]))
        XCTAssertEqual(state.accountID, "b")
        XCTAssertEqual(state.folderID, "f")
        XCTAssertTrue(state.files.isEmpty && state.search.isEmpty && state.selection.isEmpty)
        XCTAssertEqual(state.sortMode, "date", "Cómo se ordena y se dibuja es de la pestaña, no del sitio")
        XCTAssertEqual(state.viewMode, "grid")
        state.open(BrowserLocation(accountID: "b", collection: .recent))
        XCTAssertEqual(state.folderID, Collection.recent.rootID)
        XCTAssertFalse(state.isWritableLocation, "Recientes no es una carpeta")
    }

    func testTheModelForwardsToTheFocusedTab() {
        let model = AppModel()
        model.workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: "a")])])
        model.files = [file("1", "uno")]
        model.search = "uno"
        XCTAssertEqual(model.workspace.current.files.map(\.id), ["1"])
        XCTAssertEqual(model.visibleFiles.map(\.id), ["1"])
        model.selectedIDs = ["1"]
        XCTAssertEqual(model.workspace.current.selection, ["1"])
        XCTAssertEqual(model.folderID, "root")
    }

    func testAnAnswerForATabThatIsGoneIsDropped() {
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: "a")])])
        let before = workspace.current
        workspace.update(UUID()) { $0.files = [self.file("1", "uno")] }
        XCTAssertEqual(workspace.current.files.count, before.files.count)
        XCTAssertNil(workspace.tab(UUID()))
    }
}
