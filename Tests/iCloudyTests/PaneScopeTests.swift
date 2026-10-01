import XCTest
@testable import iCloudy

/// Code written when there was one pane: what it did to "the open folder" after a wait landed on whichever pane had
/// the focus by then, vaults were invisible to the panes, and the queue-wide resume ignored a paused mirror.
@MainActor
final class PaneScopeTests: XCTestCase {
    private func folder(_ id: String) -> CloudFile {
        CloudFile(id: id, name: "Carpeta \(id)", mime: "folder", size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    /// A volume account over a folder that does not exist: its listings fail at once, with nothing written anywhere.
    private func phantom(_ name: String) -> Account {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-existe-" + name + UUID().uuidString).path
        return Account(id: "volume:" + root, cloud: .volume, name: name, email: "local", clientID: "", clientSecret: nil, serverURL: root)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out"); throw CloudError.message("timeout")
    }

    // MARK: - Reloading after a write

    func testAWriteThatFinishesAfterTheFocusMovedListsThePaneThatShowsTheAccount() {
        let model = AppModel()
        let left = phantom("izquierda"), right = phantom("derecha")
        model.accounts = [left, right]
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: left.id)]),
                                                  ExplorerPane(tabs: [BrowserState(accountID: right.id, path: [folder("x")])]),])
        workspace.setSplit(true)
        model.workspace = workspace
        let focused = model.workspace.panes[0].current.navigationID, other = model.workspace.panes[1].current.navigationID

        // A version of a file of the right-hand account was restored while the left pane had the focus.
        let file = CloudFile(id: "x/a.txt", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        model.versionRestored(file, account: right)
        XCTAssertNotEqual(model.workspace.panes[1].current.navigationID, other, "The pane that shows the account lists again")
        XCTAssertEqual(model.workspace.panes[0].current.navigationID, focused, "The focused pane shows another account and is left alone")

        // Nothing on screen shows the account: its tabs are marked to list again when they come back.
        model.workspace.panes[1].tabs.append(BrowserState(accountID: left.id))
        model.workspace.panes[1].activeTab = 1
        model.workspace.panes[0].current.accountID = left.id
        model.reloadAfterWrite(to: right)
        XCTAssertTrue(model.workspace.panes[1].tabs[0].stale)
    }

    // MARK: - Vaults in either pane

    func testEachPaneSaysForItselfWhetherItShowsALockedVault() {
        let model = AppModel()
        let left = phantom("izquierda"), right = phantom("derecha")
        model.accounts = [left, right]
        let marker = { (name: String) in CloudFile(id: name, name: name, mime: "application/octet-stream", size: 1, modified: nil, webURL: nil, isFolder: false) }
        var vaultTab = BrowserState(accountID: right.id, path: [folder("v")])
        vaultTab.files = [marker(CryptomatorVault.configName), marker(CryptomatorVault.masterkeyName)]
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: left.id)]), ExplorerPane(tabs: [vaultTab])])
        workspace.setSplit(true)
        model.workspace = workspace
        XCTAssertFalse(model.currentFolderIsLockedVault, "The focused pane shows an ordinary folder")
        XCTAssertTrue(model.folderIsLockedVault(in: model.tab(inPane: 1)), "The other pane offers to unlock its own vault")
        XCTAssertFalse(model.folderIsLockedVault(in: model.tab(inPane: 0)))
        // An id no stored account has, and no vault open with it: nothing to show, as before.
        XCTAssertNil(model.account(of: BrowserState(accountID: CryptomatorVaults.accountID(base: right.id, folder: "v"))))
        XCTAssertEqual(model.account(of: model.tab(inPane: 1))?.id, right.id)
    }

    func testLockingAVaultTakesEveryTabOutOfItInBothPanes() {
        let vault = CryptomatorVaults.accountID(base: "base", folder: "v")
        var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [BrowserState(accountID: vault, path: [folder("dentro")]), BrowserState(accountID: "otra")]),
                                                  ExplorerPane(tabs: [BrowserState(accountID: vault)])])
        workspace.setSplit(true)
        let moved = workspace.leave(vault, for: "base")
        XCTAssertEqual(moved.count, 2)
        XCTAssertFalse(workspace.allTabs.contains { $0.accountID == vault })
        XCTAssertEqual(workspace.panes[0].tabs[0].location, BrowserLocation(accountID: "base"))
        XCTAssertEqual(workspace.panes[0].tabs[1].accountID, "otra")
        XCTAssertEqual(workspace.panes[1].tabs[0].location, BrowserLocation(accountID: "base"))
    }

    // MARK: - Mirrors

    func testResumingEverythingLeavesAPausedMirrorsUploadForTheMirror() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: local.appendingPathComponent("a.txt"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { [weak manager] in manager?.handleFinished($0) }

        queue.setOnline(false)
        try manager.add(local: local, account: .demo, folder: remote, path: [])
        try await wait { manager.mirrors.first?.activeTransferID != nil }
        let id = manager.mirrors[0].id, held = try XCTUnwrap(manager.mirrors[0].activeTransferID)
        manager.setPaused(true, for: id)
        // And one the person paused by hand, which "Reanudar todas" is for.
        let loose = root.appendingPathComponent("suelto.txt"); try Data("b".utf8).write(to: loose)
        let manual = Transfer(name: "suelto.txt", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: loose)
        try queue.add([manual]); queue.cancel(manual.id, pause: true)
        queue.setOnline(true)

        XCTAssertEqual(queue.resumableCount, 1)
        XCTAssertEqual(queue.resumeAll(), 1)
        try await wait { queue.items.first { $0.id == manual.id }?.state == .completed }
        XCTAssertEqual(queue.items.first { $0.id == held }?.state, .paused, "The mirror is still paused, and so is its upload")
        XCTAssertNil(manager.mirrors[0].lastSync)

        manager.setPaused(false, for: id)
        try await wait { manager.mirrors[0].lastSync != nil }
        XCTAssertEqual(queue.items.first { $0.id == held }?.state, .completed)
    }

    func testTheSyncShortcutCountsOnlyTheMirrorsItChecks() {
        XCTAssertEqual(SyncMirrorsIntent.summary(started: 0, paused: 0), "No hay carpetas reflejadas.")
        XCTAssertTrue(SyncMirrorsIntent.summary(started: 0, paused: 2).contains("en pausa"))
        XCTAssertEqual(SyncMirrorsIntent.summary(started: 3, paused: 0), "Comprobando 3 carpetas reflejadas.")
        XCTAssertTrue(SyncMirrorsIntent.summary(started: 1, paused: 2).hasPrefix("Comprobando 1 carpetas"))
    }
}
