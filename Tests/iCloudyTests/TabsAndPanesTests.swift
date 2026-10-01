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
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    /// An account over a temporary folder of this Mac.
    private func volume() throws -> Account {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return Account(id: "volume:" + root.standardizedFileURL.path, cloud: .volume, name: root.lastPathComponent, email: "local",
                       clientID: "", clientSecret: nil, serverURL: root.standardizedFileURL.path)
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

    // MARK: - Tabs

    private func pane(_ titles: String...) -> ExplorerPane {
        ExplorerPane(tabs: titles.map { BrowserState(accountID: "a", path: [folder($0)]) })
    }

    func testANewTabStartsWhereTheActiveOneStandsAndOpensBesideIt() {
        var tabs = pane("1", "2", "3")
        tabs.activeTab = 0
        tabs.current.sortMode = "size"; tabs.current.viewMode = "grid"
        tabs.current.open(place("a", "9"))
        let id = tabs.addTab()
        XCTAssertEqual(tabs.tabs.map(\.folderID), ["9", "9", "2", "3"])
        XCTAssertEqual(tabs.activeTab, 1)
        XCTAssertEqual(tabs.current.id, id)
        XCTAssertEqual(tabs.current.sortMode, "size")
        XCTAssertEqual(tabs.current.viewMode, "grid")
        XCTAssertTrue(tabs.current.back.isEmpty, "La pestaña nueva empieza su propio historial")
        tabs.addTab(at: place("b", "x"))
        XCTAssertEqual(tabs.current.location, place("b", "x"))
        XCTAssertEqual(tabs.activeTab, 2)
    }

    func testClosingATabShowsItsNeighbourAndTheLastOneStays() {
        var tabs = pane("1", "2", "3")
        tabs.activeTab = 1
        XCTAssertTrue(tabs.closeTab(tabs.tabs[1].id))
        XCTAssertEqual(tabs.current.folderID, "3", "Se muestra la de la derecha")
        XCTAssertTrue(tabs.closeTab(tabs.tabs[1].id))
        XCTAssertEqual(tabs.current.folderID, "1", "Sin derecha, la de la izquierda")
        XCTAssertFalse(tabs.closeTab(tabs.tabs[0].id), "La última pestaña no se cierra: se cierra la ventana")
        XCTAssertEqual(tabs.tabs.count, 1)
        var other = pane("1", "2", "3")
        other.activeTab = 2
        XCTAssertTrue(other.closeTab(other.tabs[0].id))
        XCTAssertEqual(other.current.folderID, "3", "Cerrar otra pestaña no cambia la que se ve")
        XCTAssertFalse(other.closeTab(UUID()))
    }

    func testSwitchingAndReorderingTabs() {
        var tabs = pane("1", "2", "3", "4")
        XCTAssertTrue(tabs.showTab(number: 3)); XCTAssertEqual(tabs.current.folderID, "3")
        XCTAssertTrue(tabs.showTab(number: 9)); XCTAssertEqual(tabs.current.folderID, "4", "⌘9 es la última")
        XCTAssertFalse(tabs.showTab(number: 6), "Más allá de la última no pasa nada")
        XCTAssertTrue(tabs.cycleTabs(forward: true)); XCTAssertEqual(tabs.current.folderID, "1", "Da la vuelta")
        XCTAssertTrue(tabs.cycleTabs(forward: false)); XCTAssertEqual(tabs.current.folderID, "4")
        let showing = tabs.current.id
        tabs.moveTab(tabs.tabs[3].id, to: tabs.tabs[0].id)
        XCTAssertEqual(tabs.tabs.map(\.folderID), ["4", "1", "2", "3"])
        XCTAssertEqual(tabs.current.id, showing, "La activa sigue siéndolo donde acabe")
        tabs.moveTab(tabs.tabs[1].id, to: tabs.tabs[3].id)
        XCTAssertEqual(tabs.tabs.map(\.folderID), ["4", "2", "3", "1"])
        XCTAssertEqual(tabs.current.id, showing)
        var single = pane("1")
        XCTAssertFalse(single.cycleTabs(forward: true))
    }

    // MARK: - Persistence

    func testTabsSurviveARoundTrip() throws {
        var tabs = pane("1", "2")
        tabs.activeTab = 1
        tabs.current.selection = ["x"]; tabs.current.sortMode = "date"; tabs.current.viewMode = "grid"
        tabs.current.open(place("a", "2", "3"))
        tabs.current.selection = ["y"]
        tabs.current.files = [folder("no se guarda")]
        let workspace = ExplorerWorkspace(panes: [tabs])
        let decoded = try JSONDecoder().decode(ExplorerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded.panes[0].tabs.map(\.id), tabs.tabs.map(\.id))
        XCTAssertEqual(decoded.panes[0].activeTab, 1)
        let restored = decoded.current
        XCTAssertEqual(restored.location, place("a", "2", "3"))
        XCTAssertEqual(restored.selection, ["y"])
        XCTAssertEqual(restored.sortMode, "date")
        XCTAssertEqual(restored.viewMode, "grid")
        XCTAssertEqual(restored.back, [BrowserLocation(accountID: "a", collection: .files, path: [folder("2")])])
        XCTAssertTrue(restored.files.isEmpty, "El listado se vuelve a pedir, no se guarda")
    }

    func testAFileWithMissingOrUnknownFieldsStillOpens() throws {
        let empty = try JSONDecoder().decode(ExplorerWorkspace.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.panes.count, 1)
        XCTAssertEqual(empty.panes[0].tabs.count, 1, "Siempre queda una pestaña")
        let sparse = """
        {"panes": [{"tabs": [{"accountID": "a", "collection": "algo-nuevo"}, {}], "activeTab": 7}], "focusedPane": 4}
        """
        let decoded = try JSONDecoder().decode(ExplorerWorkspace.self, from: Data(sparse.utf8))
        XCTAssertEqual(decoded.focusedPane, 0)
        XCTAssertEqual(decoded.panes[0].activeTab, 1, "Un índice fuera de rango se ajusta")
        let first = decoded.panes[0].tabs[0]
        XCTAssertEqual(first.accountID, "a")
        XCTAssertEqual(first.collection, .files, "Una colección desconocida vuelve a Mis archivos")
        XCTAssertEqual(first.sortMode, "name")
        XCTAssertEqual(first.viewMode, "list")
        XCTAssertTrue(first.back.isEmpty && first.path.isEmpty && first.selection.isEmpty)
        XCTAssertNil(decoded.panes[0].tabs[1].accountID)
        XCTAssertNotEqual(decoded.panes[0].tabs[0].id, decoded.panes[0].tabs[1].id)
    }

    func testRestoredTabsOfAccountsThatAreGoneFallBackToTheFirstAccount() {
        let drive = Account(id: "google:ana", cloud: .google, name: "Ana", email: "ana@ejemplo.com", clientID: "id", clientSecret: nil)
        let nas = Account(id: "webdav:nas", cloud: .webdav, name: "NAS", email: "ana@nas", clientID: "", clientSecret: nil, serverURL: "https://nas")
        var kept = BrowserState(accountID: nas.id, path: [folder("1")])
        kept.open(BrowserLocation(accountID: "dropbox:gone", collection: .files, path: [folder("x")]))
        kept.open(BrowserLocation(accountID: nas.id, collection: .files, path: [folder("2")]))
        kept.selection = ["s"]
        let gone = BrowserState(accountID: "dropbox:gone", path: [folder("x")])
        // WebDAV has no recents, so a tab left there has nowhere to stay.
        let unsupported = BrowserState(accountID: nas.id, collection: .recent)
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [kept, gone, unsupported, BrowserState()])])
        workspace.reconcile(with: [drive, nas])
        let tabs = workspace.panes[0].tabs
        XCTAssertEqual(tabs[0].location, BrowserLocation(accountID: nas.id, collection: .files, path: [folder("2")]))
        XCTAssertEqual(tabs[0].selection, ["s"], "Lo que sigue en su sitio conserva su selección")
        XCTAssertEqual(tabs[0].back.map(\.accountID), [nas.id], "El historial olvida la cuenta que ya no está")
        XCTAssertEqual(tabs[1].location, BrowserLocation(accountID: drive.id), "A la raíz de la primera cuenta")
        XCTAssertEqual(tabs[2].location, BrowserLocation(accountID: nas.id))
        XCTAssertEqual(tabs[3].location, BrowserLocation(accountID: drive.id))
        var nothing = ExplorerWorkspace(panes: [ExplorerPane(tabs: [gone])])
        nothing.reconcile(with: [])
        XCTAssertNil(nothing.current.accountID)
    }

    func testTheStoreWritesOnlyWhatChangedAndReadsItBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        XCTAssertNil(store.load())
        let workspace = ExplorerWorkspace(panes: [pane("1", "2")])
        store.save(workspace)
        XCTAssertEqual(WorkspaceStore(url: url).load()?.panes[0].tabs.map(\.id), workspace.panes[0].tabs.map(\.id))
        try Data("no es json".utf8).write(to: url)
        XCTAssertNil(WorkspaceStore(url: url).load(), "Un archivo dañado cuesta las pestañas, no el arranque")
        XCTAssertNil(WorkspaceStore(url: nil).load())
    }

    func testTheModelOpensClosesAndRetargetsTabs() throws {
        let model = AppModel()
        // Folders of this Mac: listing them asks nobody for credentials.
        let drive = try volume(), box = try volume()
        model.accounts = [drive, box]
        model.workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: box.id, path: [folder("1")])])])
        model.workspace.current.files = [folder("2")]
        model.openInNewTab(folder("2"))
        XCTAssertEqual(model.tabCount, 2)
        XCTAssertEqual(model.path.map(\.id), ["1", "2"], "Se abre la carpeta en la pestaña nueva, que pasa a ser la activa")
        XCTAssertEqual(model.tabTitle(model.workspace.current), "Carpeta 2")
        model.openInNewTab(CloudFile(id: "f", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false))
        XCTAssertEqual(model.tabCount, 2, "Un archivo no se abre en una pestaña")
        model.newTab()
        XCTAssertEqual(model.tabCount, 3)
        XCTAssertEqual(model.workspace.panes[0].activeTab, 2)
        model.showTab(number: 1)
        XCTAssertEqual(model.path.map(\.id), ["1"])
        model.retargetTabs(leaving: [box.id])
        XCTAssertTrue(model.workspace.allTabs.allSatisfy { $0.location == BrowserLocation(accountID: drive.id) },
                      "Las pestañas de una cuenta desconectada pasan a la primera")
        XCTAssertTrue(model.closeTab())
        XCTAssertTrue(model.closeTab())
        XCTAssertFalse(model.closeTab(), "La última se queda")
        XCTAssertEqual(model.tabCount, 1)
    }
}
