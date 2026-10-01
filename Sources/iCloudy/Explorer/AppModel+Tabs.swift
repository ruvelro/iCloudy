import AppKit
import SwiftUI
import Combine

/// Keeps the window's tabs and panes between launches.
@MainActor
final class WorkspaceStore {
    /// Nil under XCTest, so a test never overwrites the tabs of whoever runs it.
    let url: URL?
    private var subscription: AnyCancellable?
    private var saved: Data?

    init(url: URL? = NSClassFromString("XCTestCase") != nil ? nil : LocalStore.directory.appendingPathComponent("explorer-tabs.json")) {
        self.url = url
    }

    /// What the last session left. A damaged file costs the tabs, never the launch.
    func load() -> ExplorerWorkspace? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        saved = data
        return try? JSONDecoder().decode(ExplorerWorkspace.self, from: data)
    }

    /// Writes a second after the last change: a listing arriving page by page is not worth a write per page.
    func watch(_ changes: Published<ExplorerWorkspace>.Publisher) {
        subscription = changes.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main).sink { [weak self] in self?.save($0) }
    }

    func save(_ workspace: ExplorerWorkspace) {
        guard let url, let data = try? JSONEncoder().encode(workspace), data != saved else { return }
        do { try LocalStore.save(workspace, to: url); saved = data } catch {}
    }
}

extension AppModel {
    /// What ⌘T does: a tab right after the focused one, where it stands.
    func newTab(in pane: Int? = nil) { addTab(at: nil, in: pane) }

    /// Middle-click, ⌘-double-click or "Abrir en una pestaña nueva" on a folder of the focused tab.
    func openInNewTab(_ folder: CloudFile) {
        guard folder.isFolder, let account, !inTrash else { return }
        noteForSpotlight(folder, account: account)
        addTab(at: BrowserLocation(accountID: account.id, collection: collection, path: path + [folder]), in: nil)
    }

    private func addTab(at place: BrowserLocation?, in pane: Int?) {
        let pane = pane ?? workspace.focusedPane
        guard workspace.panes.indices.contains(pane) else { return }
        preview.close(); globalSearch.cancel(); showGlobalSearch = false
        let id = workspace.panes[pane].addTab(at: place)
        workspace.focus(pane)
        reload(tab: id)
    }

    /// Closes a tab, the focused one unless told which. Returns false when it was the last of its pane, which stays.
    @discardableResult func closeTab(_ id: BrowserState.ID? = nil) -> Bool {
        let id = id ?? workspace.current.id
        guard let pane = workspace.panes.firstIndex(where: { $0.tabs.contains { $0.id == id } }) else { return false }
        let wasShowing = workspace.current.id == id
        guard workspace.panes[pane].closeTab(id) else { return false }
        navigationTasks[id]?.cancel(); navigationTasks[id] = nil
        if wasShowing { preview.close() }
        tabCameIntoView(workspace.panes[pane].current.id)
        return true
    }

    /// ⌘W: the tab if there are others; with the last one, the pane if there are two, and the window otherwise.
    func closeTabOrWindow(_ window: NSWindow?) {
        if closeTab() { return }
        if workspace.split { closePane(workspace.focusedPane) } else { window?.performClose(nil) }
    }

    func closeOtherTabs(than id: BrowserState.ID) {
        guard let pane = workspace.panes.firstIndex(where: { $0.tabs.contains { $0.id == id } }) else { return }
        for tab in workspace.panes[pane].tabs where tab.id != id { closeTab(tab.id) }
    }

    /// A click on a tab: it shows, and its pane takes the focus.
    func activateTab(_ id: BrowserState.ID) {
        guard let pane = workspace.panes.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let index = workspace.panes[pane].tabs.firstIndex(where: { $0.id == id }) else { return }
        let changed = workspace.panes[pane].activeTab != index || workspace.focusedPane != pane
        guard changed else { return }
        workspace.panes[pane].activeTab = index
        workspace.focus(pane)
        tabsDidSwitch()
    }

    func showTab(number: Int) { if workspace.panes[workspace.focusedPane].showTab(number: number) { tabsDidSwitch() } }

    func cycleTabs(forward: Bool) { if workspace.panes[workspace.focusedPane].cycleTabs(forward: forward) { tabsDidSwitch() } }

    func moveTab(_ id: BrowserState.ID, to target: BrowserState.ID) {
        guard let pane = workspace.panes.firstIndex(where: { $0.tabs.contains { $0.id == id } }) else { return }
        workspace.panes[pane].moveTab(id, to: target)
    }

    var tabCount: Int { workspace.panes[workspace.focusedPane].tabs.count }

    /// The folder's name, or the collection's, or the account's at its root: what the Finder puts on a tab.
    func tabTitle(_ tab: BrowserState) -> String {
        if let folder = tab.path.last { return folder.name }
        guard let account = accounts.first(where: { $0.id == tab.accountID }) else { return L("iCloudy") }
        return tab.collection == .files ? accountTitle(account) : tab.collection.title
    }

    private func tabsDidSwitch() {
        preview.close(); globalSearch.cancel(); showGlobalSearch = false
        tabCameIntoView(workspace.current.id)
    }

    /// A tab that has never been listed, or whose account changed while it was out of sight, lists now.
    func tabCameIntoView(_ id: BrowserState.ID) {
        guard let tab = workspace.tab(id), tab.accountID != nil, tab.stale || (tab.files.isEmpty && !tab.loading) else { return }
        reload(tab: id)
    }

    /// Tabs of accounts that have just been disconnected fall back to the first account, as the selected one does.
    func retargetTabs(leaving ids: Set<String>) {
        let fallback = accounts.first?.id
        var moved: [BrowserState.ID] = []
        workspace.updateAll { tab in
            tab.forgetHistory(of: ids)
            guard let id = tab.accountID, ids.contains(id) else { return }
            tab.open(BrowserLocation(accountID: fallback), remember: false)
            moved.append(tab.id)
        }
        let visible = Set(workspace.visibleTabs.map(\.id))
        for id in moved where visible.contains(id) { reload(tab: id) }
    }
}
