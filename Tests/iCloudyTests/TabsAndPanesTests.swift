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
    /// An account over a folder of this Mac that does not exist. The model lists whatever a tab shows as soon as it
    /// shows it; with this, the listing fails at once without asking anybody for credentials, and nothing reaches the
    /// app's real listing cache or Spotlight index.
    private func phantom(_ name: String = UUID().uuidString) -> Account {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-existe-" + name).path
        return Account(id: "volume:" + root, cloud: .volume, name: name, email: "local", clientID: "", clientSecret: nil, serverURL: root)
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

    func testTheModelOpensClosesAndRetargetsTabs() {
        let model = AppModel()
        let drive = phantom(), box = phantom()
        model.accounts = [drive, box]
        model.workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: box.id, path: [folder("1")])])])
        model.openInNewTab(CloudFile(id: "f", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false))
        XCTAssertEqual(model.tabCount, 1, "Un archivo no se abre en una pestaña")
        model.newTab()
        XCTAssertEqual(model.tabCount, 2)
        XCTAssertEqual(model.path.map(\.id), ["1"], "La pestaña nueva empieza donde estaba la activa")
        XCTAssertEqual(model.tabTitle(model.workspace.current), "Carpeta 1")
        model.go(to: place(box.id, "1", "2"))
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

    // MARK: - Two panes

    func testSplittingOpensASecondPaneWhereTheFirstStands() {
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: "a", path: [folder("1")], viewMode: "grid")])])
        XCTAssertNil(workspace.otherPane)
        XCTAssertFalse(workspace.focus(1), "Sin segundo panel no hay a quién dar el foco")
        workspace.setSplit(true)
        XCTAssertEqual(workspace.panes.count, 2)
        XCTAssertEqual(workspace.panes[1].current.location, place("a", "1"))
        XCTAssertEqual(workspace.panes[1].current.viewMode, "grid")
        XCTAssertNotEqual(workspace.panes[1].current.id, workspace.panes[0].current.id)
        XCTAssertEqual(workspace.visibleTabs.count, 2)
        XCTAssertEqual(workspace.otherPane, 1)
        XCTAssertTrue(workspace.focus(1))
        XCTAssertEqual(workspace.otherPane, 0)
        workspace.current.open(place("b"))
        XCTAssertEqual(workspace.panes[0].current.location, place("a", "1"), "Cada panel tiene su propio sitio")
        let second = workspace.panes[1].current.id
        workspace.setSplit(false)
        XCTAssertEqual(workspace.focusedPane, 0, "Con un panel, el foco es suyo")
        XCTAssertEqual(workspace.visibleTabs.map(\.id), [workspace.panes[0].current.id])
        workspace.setSplit(true)
        XCTAssertEqual(workspace.panes[1].current.id, second, "Al volver a abrirlo, el segundo panel está como se dejó")
        workspace.closePane(0)
        XCTAssertFalse(workspace.split)
        XCTAssertEqual(workspace.current.id, second, "Cerrar el primero deja el segundo en su lugar")
    }

    func testTheSplitSurvivesARelaunchAndANonsensicalOneDoesNot() throws {
        var workspace = ExplorerWorkspace(panes: [pane("1"), pane("2")])
        workspace.setSplit(true); workspace.focus(1)
        let decoded = try JSONDecoder().decode(ExplorerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertTrue(decoded.split)
        XCTAssertEqual(decoded.focusedPane, 1)
        XCTAssertEqual(decoded.current.folderID, "2")
        let lonely = try JSONDecoder().decode(ExplorerWorkspace.self, from: Data(#"{"panes": [{}], "split": true, "focusedPane": 1}"#.utf8))
        XCTAssertFalse(lonely.split, "Dos paneles con uno solo guardado no tienen sentido")
        XCTAssertEqual(lonely.focusedPane, 0)
        let older = try JSONDecoder().decode(ExplorerWorkspace.self, from: Data(#"{"panes": [{}, {}], "focusedPane": 1}"#.utf8))
        XCTAssertFalse(older.split, "Un archivo sin el campo abre con un solo panel")
        XCTAssertEqual(older.focusedPane, 0)
    }

    private func splitModel() -> (AppModel, Account, Account) {
        let model = AppModel()
        let left = phantom("izquierda"), right = phantom("derecha")
        model.accounts = [left, right]
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: left.id)]),
                                                  ExplorerPane(tabs: [BrowserState(accountID: right.id, path: [folder("x")])])])
        workspace.setSplit(true)
        model.workspace = workspace
        return (model, left, right)
    }

    func testEverythingThatReadsTheOpenFolderFollowsTheFocusedPane() {
        let (model, left, right) = splitModel()
        XCTAssertEqual(model.account?.id, left.id)
        XCTAssertEqual(model.folderID, "root")
        model.focusPane(1)
        XCTAssertEqual(model.account?.id, right.id)
        XCTAssertEqual(model.folderID, "x", "Subir, el Dock y Servicios van a la carpeta del panel con el foco")
        XCTAssertTrue(model.canWrite)
        XCTAssertTrue(model.location.hasSuffix("Carpeta x"))
        model.selectedIDs = ["s"]
        XCTAssertEqual(model.workspace.panes[1].current.selection, ["s"])
        XCTAssertTrue(model.workspace.panes[0].current.selection.isEmpty)
        model.select(left.id)
        XCTAssertEqual(model.workspace.panes[1].current.location, BrowserLocation(accountID: left.id), "La barra lateral cambia el panel con el foco")
        XCTAssertEqual(model.workspace.panes[0].current.location, BrowserLocation(accountID: left.id))
        XCTAssertEqual(model.isFavorite(folder("x"), in: model.workspace.panes[0].current), false)
        model.focusOtherPane()
        XCTAssertEqual(model.workspace.focusedPane, 0)
        model.toggleSplit()
        XCTAssertFalse(model.isSplit)
        model.focusPane(1)
        XCTAssertEqual(model.workspace.focusedPane, 0, "Un panel que no se ve no recibe el foco")
    }

    func testEachPaneKeepsItsOwnHistory() {
        let (model, left, right) = splitModel()
        model.go(to: place(left.id, "1"))
        model.go(to: place(left.id, "1", "2"))
        model.focusPane(1)
        XCTAssertFalse(model.canGoBack, "El historial del otro panel no cuenta")
        model.go(to: place(right.id, "y"))
        model.goBack()
        XCTAssertEqual(model.workspace.panes[1].current.location, place(right.id, "x"))
        XCTAssertEqual(model.workspace.panes[0].current.location, place(left.id, "1", "2"), "Volver en un panel no mueve el otro")
        model.focusPane(0)
        model.goBack()
        XCTAssertEqual(model.path.map(\.id), ["1"])
        XCTAssertTrue(model.canGoForward)
        model.focusPane(1)
        XCTAssertTrue(model.canGoForward)
        model.goForward()
        XCTAssertEqual(model.workspace.panes[1].current.location, place(right.id, "y"))
        XCTAssertEqual(model.workspace.panes[0].current.location, place(left.id, "1"))
    }

    func testWhatGoingToTheOtherPaneMeans() {
        let drive = Account(id: "google:ana", cloud: .google, name: "Ana", email: "ana@ejemplo.com", clientID: "id", clientSecret: nil)
        let box = Account(id: "box:ana", cloud: .box, name: "Ana", email: "ana@box", clientID: "id", clientSecret: nil)
        let file = CloudFile(id: "f", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        let document = CloudFile(id: "d", name: "Informe", mime: "application/vnd.google-apps.document", size: nil, modified: nil, webURL: nil, isFolder: false)
        let here = BrowserState(accountID: drive.id, path: [folder("1")])
        let there = BrowserState(accountID: drive.id, path: [folder("2")])
        func plan(_ files: [CloudFile], _ from: BrowserState, _ fromAccount: Account?, _ to: BrowserState, _ toAccount: Account?, move: Bool) -> PaneTransfer {
            AppModel.paneTransfer(files, from: from, account: fromAccount, to: to, account: toAccount, move: move)
        }
        XCTAssertEqual(plan([file], here, drive, there, drive, move: true), .sameAccount(move: true))
        XCTAssertEqual(plan([file], here, drive, there, drive, move: false), .sameAccount(move: false))
        XCTAssertEqual(plan([file], here, drive, BrowserState(accountID: box.id), box, move: false), .crossCloud(move: false))
        XCTAssertEqual(plan([file], here, drive, BrowserState(accountID: box.id), box, move: true), .crossCloud(move: true))
        func refused(_ result: PaneTransfer) -> Bool { if case .refused = result { return true } else { return false } }
        XCTAssertTrue(refused(plan([], here, drive, there, drive, move: true)), "Sin selección no hay nada que hacer")
        XCTAssertTrue(refused(plan([file], here, drive, there, nil, move: true)), "El otro panel necesita una cuenta")
        XCTAssertTrue(refused(plan([file], here, drive, here, drive, move: true)), "La misma carpeta en los dos paneles")
        XCTAssertTrue(refused(plan([folder("2")], here, drive, BrowserState(accountID: drive.id, path: [folder("2"), folder("3")]), drive, move: true)),
                      "Una carpeta dentro de sí misma")
        XCTAssertTrue(refused(plan([folder("9")], here, drive, there, drive, move: false)), "Drive no copia carpetas")
        XCTAssertEqual(plan([folder("9")], here, drive, there, drive, move: true), .sameAccount(move: true), "Pero sí las mueve")
        XCTAssertTrue(refused(plan([file], BrowserState(accountID: drive.id, collection: .trash), drive, there, drive, move: true)))
        XCTAssertTrue(refused(plan([file], here, drive, BrowserState(accountID: box.id, collection: .recent), box, move: false)), "Recientes no es una carpeta")
        XCTAssertTrue(refused(plan([document], here, drive, BrowserState(accountID: box.id), box, move: true)),
                      "Un documento de Google llega convertido: se copia, no se mueve")
        XCTAssertEqual(plan([document], here, drive, BrowserState(accountID: box.id), box, move: false), .crossCloud(move: false))
    }

    func testF6AcrossAccountsAsksBeforeMovingAndRefusalsAreExplained() {
        let (model, left, right) = splitModel()
        let file = CloudFile(id: "f", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        model.workspace.current.files = [file]
        model.selectedIDs = ["f"]
        model.sendSelectionToOtherPane(move: true)
        let request = model.pendingPaneMove
        XCTAssertEqual(request?.files.map(\.id), ["f"])
        XCTAssertEqual(request?.source.id, left.id)
        XCTAssertEqual(request?.target.id, right.id)
        XCTAssertEqual(request?.parent, "x", "Al otro panel: su carpeta, no la de este")
        XCTAssertEqual(request?.destinationPath.map(\.id), ["x"])
        XCTAssertTrue(model.queue.items.allSatisfy { $0.file?.id != "f" }, "Nada se pone en cola antes de confirmar")
        model.pendingPaneMove = nil
        model.selectedIDs = []
        model.sendSelectionToOtherPane(move: false)
        XCTAssertEqual(model.error, L("Selecciona lo que quieras copiar o mover al otro panel."))
        XCTAssertNil(model.pendingPaneMove)
    }

    func testDroppingOnTheOtherPane() {
        XCTAssertTrue(AppModel.dropMoves(sameAccount: true, modifiers: []), "En la misma cuenta, arrastrar mueve")
        XCTAssertFalse(AppModel.dropMoves(sameAccount: true, modifiers: .option), "Y con ⌥ copia")
        XCTAssertFalse(AppModel.dropMoves(sameAccount: false, modifiers: []), "Entre cuentas, copia")
        XCTAssertTrue(AppModel.dropMoves(sameAccount: false, modifiers: .command), "Y con ⌘ mueve, preguntando antes")
        let (model, _, right) = splitModel()
        let a = CloudFile(id: "a", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        let b = CloudFile(id: "b", name: "b.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        model.workspace.current.files = [a, b]
        model.selectedIDs = ["a", "b"]
        _ = model.paneDragProvider(for: a, pane: 0)
        XCTAssertEqual(model.paneTransfers.drag?.files.map(\.id), ["a", "b"], "Arrastrar algo seleccionado lleva toda la selección")
        _ = model.paneDragProvider(for: b, pane: 0)
        model.selectedIDs = ["a"]
        _ = model.paneDragProvider(for: b, pane: 0)
        XCTAssertEqual(model.paneTransfers.drag?.files.map(\.id), ["b"], "Y algo sin seleccionar va solo")
        let token = model.paneTransfers.drag?.token ?? ""
        XCTAssertFalse(model.dropOnPane("icloudy-pane:otro", pane: 1, modifiers: .command), "Un arrastre que no es este no hace nada")
        XCTAssertFalse(model.dropOnPane(token, pane: 0, modifiers: .command), "Soltar en el mismo panel no hace nada")
        XCTAssertTrue(model.dropOnPane(token, pane: 1, modifiers: .command))
        XCTAssertEqual(model.pendingPaneMove?.target.id, right.id)
        XCTAssertNil(model.paneTransfers.drag, "Cada arrastre se usa una vez")
        XCTAssertFalse(model.dropOnPane(token, pane: 1, modifiers: .command))
    }

    private func copyJob(_ change: (inout Transfer) -> Void) -> Transfer {
        var job = Transfer(name: "a", destination: "", accountID: "a", direction: .transfer, localURL: URL(fileURLWithPath: "/"))
        job.state = .completed; job.completedPaths = [".", "./x"]; job.names = [".": "a", "./x": "x"]; job.verifiedFiles = 1
        change(&job)
        return job
    }

    func testTheOriginalGoesOnlyAfterEverythingArrivedVerified() {
        XCTAssertTrue(AppModel.copyAllowsRemovingSource(copyJob { _ in }))
        XCTAssertFalse(AppModel.copyAllowsRemovingSource(copyJob { $0.state = .failed }))
        XCTAssertFalse(AppModel.copyAllowsRemovingSource(copyJob { $0.state = .cancelled }))
        XCTAssertFalse(AppModel.copyAllowsRemovingSource(copyJob { $0.unverifiedFiles = 1 }), "Algo sin suma que comparar")
        XCTAssertFalse(AppModel.copyAllowsRemovingSource(copyJob { $0.names["./x"] = nil }), "Algo omitido por un nombre repetido")
        XCTAssertFalse(AppModel.copyAllowsRemovingSource(copyJob { $0.completedPaths = []; $0.names = [:] }))
        XCTAssertFalse(AppModel.copyAllowsRemovingSource(copyJob { $0.direction = .upload }))
        XCTAssertTrue(AppModel.copyAllowsRemovingSource(copyJob { $0.verifiedFiles = 0; $0.completedPaths = ["."]; $0.names = [".": "Vacía"] }),
                      "Una carpeta vacía copiada no tiene archivos que verificar")
    }

    func testAMoveWhoseCopyCouldNotBeVerifiedKeepsTheOriginal() {
        let (model, left, _) = splitModel()
        let file = CloudFile(id: "f", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        let job = copyJob { $0.unverifiedFiles = 1 }
        model.paneTransfers.pending[job.id] = PaneTransfers.Pending(sourceAccountID: left.id, file: file, targetTitle: "Destino")
        model.finishPaneMove(job)
        XCTAssertNil(model.paneTransfers.pending[job.id])
        XCTAssertEqual(model.error, L("«a.txt» se ha copiado a Destino, pero no todo pudo verificarse o algo se omitió. El original se queda donde estaba."))
        model.error = nil
        model.finishPaneMove(copyJob { _ in })
        XCTAssertNil(model.error, "Un trabajo que no es de un movimiento no toca nada")
    }
}
