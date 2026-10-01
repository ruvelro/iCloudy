import Foundation

/// Where a browser stands: an account, one of its top-level views and the folders opened below it.
struct BrowserLocation: Codable, Equatable {
    var accountID: String?
    var collection: Collection = .files
    var path: [CloudFile] = []
}

/// One place being browsed, with everything about it that used to be a single set of properties on the model: the
/// account and folder, what is selected, how the list is sorted and drawn, and the listing itself. A tab is one of
/// these, so each tab (and each pane) keeps its own instead of all of them sharing the model's.
struct BrowserState: Identifiable {
    var id = UUID()
    var accountID: String?
    /// Which top-level view of the account is showing. `path` hangs below it.
    var collection: Collection = .files
    var path: [CloudFile] = []
    var selection: Set<CloudFile.ID> = []
    var sortMode = "name" { didSet { updateVisibleFiles() } }
    var viewMode = "list"
    var search = "" { didSet { updateVisibleFiles() } }
    var files: [CloudFile] = [] { didSet { updateVisibleFiles() } }
    /// Filtered and sorted once per change of `files`, `search` or `sortMode`, not on every render.
    private(set) var visibleFiles: [CloudFile] = []
    var loading = false
    /// True while the list shows the last known listing instead of a fresh answer from the provider.
    var showingCachedListing = false
    /// The listing request this tab is waiting for; an answer to any other one arrived too late and is dropped.
    var navigationID = UUID()

    init(id: UUID = UUID(), accountID: String? = nil, collection: Collection = .files, path: [CloudFile] = [],
         sortMode: String = "name", viewMode: String = "list") {
        self.id = id; self.accountID = accountID; self.collection = collection; self.path = path
        self.sortMode = sortMode; self.viewMode = viewMode
    }

    var folderID: String { path.last?.id ?? collection.rootID }
    /// Recents and shared lists are not folders: nothing can be uploaded or created in them until a real folder is opened.
    var isWritableLocation: Bool { collection == .files || !path.isEmpty }

    var location: BrowserLocation {
        get { BrowserLocation(accountID: accountID, collection: collection, path: path) }
        set { accountID = newValue.accountID; collection = newValue.collection; path = newValue.path }
    }

    /// Moves to another place and drops what belonged to the old one: its listing, its filter and its selection.
    mutating func open(_ target: BrowserLocation) {
        location = target; search = ""; files = []; selection = []
    }

    mutating func updateVisibleFiles() { visibleFiles = Self.visible(files, search: search, sortMode: sortMode) }

    static func visible(_ files: [CloudFile], search term: String, sortMode mode: String) -> [CloudFile] {
        files.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if mode == "size", a.size != b.size { return (a.size ?? 0) > (b.size ?? 0) }
            if mode == "date", a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// A column of the explorer: its tabs and the one showing.
struct ExplorerPane: Identifiable {
    var id = UUID()
    var tabs: [BrowserState]
    var activeTab = 0

    init(id: UUID = UUID(), tabs: [BrowserState], activeTab: Int = 0) {
        self.id = id
        // A pane always has a tab: the explorer has nothing to show otherwise.
        self.tabs = tabs.isEmpty ? [BrowserState()] : tabs
        self.activeTab = min(max(0, activeTab), self.tabs.count - 1)
    }

    var current: BrowserState {
        get { tabs[activeTab] }
        set { tabs[activeTab] = newValue }
    }
}

/// Everything the explorer window shows: its panes, which one has the focus and whether the second one is open.
/// What used to read "the current folder" — the preview, the status bar, favourites, uploads from the Dock, the
/// Services menu, Shortcuts — reads the focused pane's active tab through `current`.
struct ExplorerWorkspace {
    var panes: [ExplorerPane]
    var focusedPane = 0

    init(panes: [ExplorerPane] = [ExplorerPane(tabs: [BrowserState()])], focusedPane: Int = 0) {
        self.panes = panes.isEmpty ? [ExplorerPane(tabs: [BrowserState()])] : panes
        self.focusedPane = min(max(0, focusedPane), self.panes.count - 1)
    }

    var current: BrowserState {
        get { panes[focusedPane].current }
        set { panes[focusedPane].current = newValue }
    }

    /// The tab each pane on screen is showing; these are the listings worth keeping fresh.
    var visibleTabs: [BrowserState] { panes.map(\.current) }

    var allTabs: [BrowserState] { panes.flatMap(\.tabs) }

    func tab(_ id: BrowserState.ID) -> BrowserState? {
        for pane in panes { if let tab = pane.tabs.first(where: { $0.id == id }) { return tab } }
        return nil
    }

    /// Changes one tab wherever it is. A tab closed while its listing was on the way is simply not there any more.
    mutating func update(_ id: BrowserState.ID, _ change: (inout BrowserState) -> Void) {
        for p in panes.indices {
            if let t = panes[p].tabs.firstIndex(where: { $0.id == id }) { change(&panes[p].tabs[t]); return }
        }
    }

    /// Changes every tab, for what has to follow an account or an item wherever it is shown.
    mutating func updateAll(_ change: (inout BrowserState) -> Void) {
        for p in panes.indices { for t in panes[p].tabs.indices { change(&panes[p].tabs[t]) } }
    }
}
