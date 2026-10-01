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
    /// Places visited before this one, the most recent last, and those left by going back. Each tab has its own,
    /// so each pane does too.
    var back: [BrowserLocation] = []
    var forward: [BrowserLocation] = []
    /// Enough to retrace a session; a tab is not a log of everything ever opened in it.
    static let historyLimit = 50
    /// Set on a tab out of sight when something changed its account; it lists again when it comes back into view.
    var stale = false

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
    /// The old place goes into the history unless `remember` is false, which is how going back and forward move.
    mutating func open(_ target: BrowserLocation, remember: Bool = true) {
        if remember, target != location, accountID != nil {
            back.append(location)
            if back.count > Self.historyLimit { back.removeFirst(back.count - Self.historyLimit) }
            forward = []
        }
        location = target; search = ""; files = []; selection = []
    }

    /// The place before this one, skipping those `usable` rejects (an account disconnected since, for instance).
    /// Returns false when there is nowhere to go back to.
    mutating func goBack(where usable: (BrowserLocation) -> Bool = { _ in true }) -> Bool {
        while let previous = back.popLast() {
            guard usable(previous) else { continue }
            forward.append(location)
            open(previous, remember: false)
            return true
        }
        return false
    }

    mutating func goForward(where usable: (BrowserLocation) -> Bool = { _ in true }) -> Bool {
        while let next = forward.popLast() {
            guard usable(next) else { continue }
            back.append(location)
            open(next, remember: false)
            return true
        }
        return false
    }

    /// Forgets every place of the accounts that left, so going back never lands on one that cannot be listed.
    mutating func forgetHistory(of accountIDs: Set<String>) {
        back.removeAll { $0.accountID.map(accountIDs.contains) ?? true }
        forward.removeAll { $0.accountID.map(accountIDs.contains) ?? true }
    }

    /// Follows a rename or a move of an item of `accountID` in the place shown, the listing and the history.
    mutating func remap(_ change: RemoteIdentityChange, accountID: String) {
        func follow(_ location: BrowserLocation) -> BrowserLocation {
            guard location.accountID == accountID else { return location }
            var moved = location; moved.path = location.path.map(change.file); return moved
        }
        back = back.map(follow); forward = forward.map(follow)
        guard self.accountID == accountID else { return }
        path = path.map(change.file); files = files.map(change.file)
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

    /// Opens a tab right after the active one and shows it. Like the Finder's ⌘T, it starts where the active tab
    /// stands and draws the list the same way, with a history of its own.
    @discardableResult mutating func addTab(at place: BrowserLocation? = nil) -> BrowserState.ID {
        let model = current
        var tab = BrowserState(accountID: model.accountID, collection: model.collection, path: model.path,
                               sortMode: model.sortMode, viewMode: model.viewMode)
        if let place { tab.location = place }
        tabs.insert(tab, at: activeTab + 1)
        activeTab += 1
        return tab.id
    }

    /// Closes a tab and shows its neighbour, the one to its right if there is one. The last tab is never closed:
    /// returns false so the caller can close the window (or the pane) instead.
    @discardableResult mutating func closeTab(_ id: BrowserState.ID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let showing = tabs[activeTab].id
        tabs.remove(at: index)
        if let still = tabs.firstIndex(where: { $0.id == showing }) { activeTab = still }
        else { activeTab = min(index, tabs.count - 1) }
        return true
    }

    /// ⌘1 to ⌘8 pick that tab and ⌘9 the last one, as in a browser. Nothing happens beyond the last.
    @discardableResult mutating func showTab(number: Int) -> Bool {
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index), index != activeTab else { return false }
        activeTab = index
        return true
    }

    /// ⌃Tab and ⌃⇧Tab, round and round.
    @discardableResult mutating func cycleTabs(forward: Bool) -> Bool {
        guard tabs.count > 1 else { return false }
        activeTab = (activeTab + (forward ? 1 : tabs.count - 1)) % tabs.count
        return true
    }

    /// Drags a tab to where another one is; the active tab stays the active tab wherever it ends up.
    mutating func moveTab(_ id: BrowserState.ID, to target: BrowserState.ID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let showing = tabs[activeTab].id
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeTab = tabs.firstIndex { $0.id == showing } ?? 0
    }
}

/// Everything the explorer window shows: its panes, which one has the focus and whether the second one is open.
/// What used to read "the current folder" — the preview, the status bar, favourites, uploads from the Dock, the
/// Services menu, Shortcuts — reads the focused pane's active tab through `current`.
struct ExplorerWorkspace {
    var panes: [ExplorerPane]
    var focusedPane = 0
    /// True while the window shows two panes side by side. The second pane keeps its tabs when it is closed, so
    /// opening it again finds them where they were.
    private(set) var split = false

    init(panes: [ExplorerPane] = [ExplorerPane(tabs: [BrowserState()])], focusedPane: Int = 0, split: Bool = false) {
        self.panes = Array((panes.isEmpty ? [ExplorerPane(tabs: [BrowserState()])] : panes).prefix(2))
        self.split = split && self.panes.count == 2
        // With one pane on screen, that pane has the focus.
        self.focusedPane = self.split ? min(max(0, focusedPane), 1) : 0
    }

    var current: BrowserState {
        get { panes[focusedPane].current }
        set { panes[focusedPane].current = newValue }
    }

    /// The panes on screen: the first one, and the second while the window is split.
    var visiblePanes: Range<Int> { 0..<(split ? 2 : 1) }

    /// The tab each pane on screen is showing; these are the listings worth keeping fresh.
    var visibleTabs: [BrowserState] { visiblePanes.map { panes[$0].current } }

    /// The pane F5 and F6 send things to.
    var otherPane: Int? { split ? 1 - focusedPane : nil }

    /// Opens or closes the second pane. Opened for the first time, it starts where the first one stands.
    mutating func setSplit(_ on: Bool) {
        if on, panes.count < 2 {
            let model = panes[0].current
            panes.append(ExplorerPane(tabs: [BrowserState(accountID: model.accountID, collection: model.collection, path: model.path,
                                                          sortMode: model.sortMode, viewMode: model.viewMode)]))
        }
        split = on
        if !on { focusedPane = 0 }
    }

    /// Closes a pane by hiding it: what stays on screen is the other one, which becomes the first.
    mutating func closePane(_ pane: Int) {
        guard split, visiblePanes.contains(pane) else { return }
        if pane == 0 { panes.swapAt(0, 1) }
        setSplit(false)
    }

    /// Gives the focus to a pane on screen; returns false when it already had it or is not showing.
    @discardableResult mutating func focus(_ pane: Int) -> Bool {
        guard visiblePanes.contains(pane), pane != focusedPane else { return false }
        focusedPane = pane
        return true
    }

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

    /// Takes every tab showing `accountID` to the root of `replacement`, in both panes. Returns the tabs it moved.
    @discardableResult
    mutating func leave(_ accountID: String, for replacement: String?) -> [BrowserState.ID] {
        var moved: [BrowserState.ID] = []
        updateAll { tab in
            guard tab.accountID == accountID else { return }
            tab.open(BrowserLocation(accountID: replacement), remember: false)
            moved.append(tab.id)
        }
        return moved
    }
}

extension ExplorerWorkspace {
    /// Puts every tab on an account that exists. Tabs come back from the last session before the accounts are read,
    /// and an account may have been disconnected meanwhile: those tabs fall back to the first account's root, as the
    /// sidebar would, and their history forgets what can no longer be listed.
    @MainActor mutating func reconcile(with accounts: [Account]) {
        let known = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mentioned = allTabs.flatMap { [$0.accountID] + $0.back.map(\.accountID) + $0.forward.map(\.accountID) }.compactMap { $0 }
        let gone = Set(mentioned).subtracting(known.keys)
        updateAll { tab in
            tab.forgetHistory(of: gone)
            if let id = tab.accountID, let account = known[id] {
                // A collection the provider no longer offers is no place to stay either.
                if !AppModel.collections(for: account).contains(tab.collection) { tab.open(BrowserLocation(accountID: id), remember: false) }
            } else {
                tab.open(BrowserLocation(accountID: accounts.first?.id), remember: false)
            }
        }
    }
}

// MARK: - Persistence

/// Tabs survive a relaunch: where each one stands, what it had selected, how it sorts and draws its list, and its
/// history. The listing itself is not kept; it is asked for again. Every field is optional on the way in, so a file
/// written by another version still opens.
extension BrowserState: Codable {
    enum CodingKeys: String, CodingKey { case id, accountID, collection, path, selection, sortMode, viewMode, back, forward }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? values.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  accountID: (try? values.decodeIfPresent(String.self, forKey: .accountID)),
                  collection: (try? values.decodeIfPresent(String.self, forKey: .collection)).flatMap(Collection.init(rawValue:)) ?? .files,
                  path: (try? values.decodeIfPresent([CloudFile].self, forKey: .path)) ?? [],
                  sortMode: (try? values.decodeIfPresent(String.self, forKey: .sortMode)) ?? "name",
                  viewMode: (try? values.decodeIfPresent(String.self, forKey: .viewMode)) ?? "list")
        selection = (try? values.decodeIfPresent(Set<CloudFile.ID>.self, forKey: .selection)) ?? []
        back = Array(((try? values.decodeIfPresent([BrowserLocation].self, forKey: .back)) ?? []).suffix(Self.historyLimit))
        forward = Array(((try? values.decodeIfPresent([BrowserLocation].self, forKey: .forward)) ?? []).suffix(Self.historyLimit))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(accountID, forKey: .accountID)
        try values.encode(collection.rawValue, forKey: .collection)
        try values.encode(path, forKey: .path)
        try values.encode(selection, forKey: .selection)
        try values.encode(sortMode, forKey: .sortMode)
        try values.encode(viewMode, forKey: .viewMode)
        try values.encode(back, forKey: .back)
        try values.encode(forward, forKey: .forward)
    }
}

extension BrowserLocation {
    enum CodingKeys: String, CodingKey { case accountID, collection, path }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = (try? values.decodeIfPresent(String.self, forKey: .accountID))
        collection = (try? values.decodeIfPresent(String.self, forKey: .collection)).flatMap(Collection.init(rawValue:)) ?? .files
        path = (try? values.decodeIfPresent([CloudFile].self, forKey: .path)) ?? []
    }
}

extension ExplorerPane: Codable {
    enum CodingKeys: String, CodingKey { case id, tabs, activeTab }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? values.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  tabs: (try? values.decodeIfPresent([BrowserState].self, forKey: .tabs)) ?? [],
                  activeTab: (try? values.decodeIfPresent(Int.self, forKey: .activeTab)) ?? 0)
    }
}

extension ExplorerWorkspace: Codable {
    enum CodingKeys: String, CodingKey { case panes, focusedPane, split }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(panes: (try? values.decodeIfPresent([ExplorerPane].self, forKey: .panes)) ?? [],
                  focusedPane: (try? values.decodeIfPresent(Int.self, forKey: .focusedPane)) ?? 0,
                  split: (try? values.decodeIfPresent(Bool.self, forKey: .split)) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(panes, forKey: .panes)
        try values.encode(focusedPane, forKey: .focusedPane)
        try values.encode(split, forKey: .split)
    }
}
