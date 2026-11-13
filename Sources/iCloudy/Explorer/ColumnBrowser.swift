import Foundation

/// One column of the column view: the contents of one folder.
struct BrowserColumn: Identifiable, Equatable {
    enum Role: Equatable {
        /// A folder above the open one, with the folder that leads down highlighted.
        case ancestor
        /// The open folder: the tab's own listing, filter and selection.
        case current
        /// The contents of the folder selected in the open one, as a look ahead.
        case preview
    }
    /// The folder whose contents this is.
    let parent: String
    let level: Int
    let role: Role
    /// Nil while the listing is on its way.
    let files: [CloudFile]?
    /// What the column highlights: the folder leading down, or the tab's selection in the open folder.
    let highlighted: Set<CloudFile.ID>
    var id: String { "\(level):\(parent)" }
}

/// Listings of the folders the column view shows besides the open one. The open folder's listing is the tab's;
/// these are the ones above it and the one being looked into, kept per account and folder for as long as the app runs.
@MainActor
@Observable
final class ColumnListings {
    private(set) var entries: [String: [CloudFile]] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    static func key(_ accountID: String, _ parent: String) -> String { accountID + "\u{1F}" + parent }

    func files(accountID: String, parent: String) -> [CloudFile]? { entries[Self.key(accountID, parent)] }

    func store(_ files: [CloudFile], accountID: String, parent: String) { entries[Self.key(accountID, parent)] = files }

    /// Lists a folder once at a time; a second request for the same one waits for nothing and returns.
    func load(accountID: String, parent: String, using list: () async throws -> [CloudFile]) async {
        let key = Self.key(accountID, parent)
        guard loading.insert(key).inserted else { return }
        defer { loading.remove(key) }
        if let files = try? await list() { entries[key] = files }
    }

    /// An account that changed or left: its listings are no longer what the cloud has.
    func forget(accountID: String) { entries = entries.filter { !$0.key.hasPrefix(accountID + "\u{1F}") } }
}

extension AppModel {
    /// The columns of a pane: one per folder from the top of the collection down to the open one, and a look into
    /// the folder selected there. Pure: listings that are missing come back as nil and are asked for by the view.
    func columns(inPane pane: Int) -> [BrowserColumn] {
        let tab = tab(inPane: pane)
        guard let accountID = tab.accountID else { return [] }
        var result: [BrowserColumn] = []
        for (level, folder) in tab.path.enumerated() {
            let parent = level == 0 ? tab.collection.rootID : tab.path[level - 1].id
            result.append(BrowserColumn(parent: parent, level: level, role: .ancestor,
                                        files: columnFiles(accountID: accountID, parent: parent, sortedLike: tab),
                                        highlighted: [folder.id]))
        }
        result.append(BrowserColumn(parent: tab.folderID, level: tab.path.count, role: .current, files: tab.visibleFiles,
                                    highlighted: tab.selection))
        let chosen = Self.selected(tab.selection, among: tab.visibleFiles)
        if chosen.count == 1, let folder = chosen.first, folder.isFolder, tab.collection != .trash {
            result.append(BrowserColumn(parent: folder.id, level: tab.path.count + 1, role: .preview,
                                        files: columnFiles(accountID: accountID, parent: folder.id, sortedLike: tab), highlighted: []))
        }
        return result
    }

    /// A folder's listing for a column, from this run's own or from the listing cache, sorted the way the tab sorts.
    private func columnFiles(accountID: String, parent: String, sortedLike tab: BrowserState) -> [CloudFile]? {
        guard let files = listings.cached(accountID: accountID, parent: parent) ?? columnListings.files(accountID: accountID, parent: parent) else { return nil }
        return BrowserState.visible(files, search: "", sortMode: tab.sortMode, ascending: tab.sortAscending)
    }

    /// Lists a column's folder if nothing has it yet.
    func loadColumn(_ column: BrowserColumn, inPane pane: Int) async {
        guard column.role != .current, column.files == nil, let account = account(of: tab(inPane: pane)) else { return }
        await columnListings.load(accountID: account.id, parent: column.parent) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await client(account).list(parent: column.parent)
        }
    }

    /// A click on an item of a column. In the open folder it selects; above it, the tab climbs to that folder and
    /// selects the item; in the look ahead, the tab goes into the folder being looked at and selects the item there.
    /// Nothing opens on a single click: a selected folder shows what it holds in the next column.
    func columnClick(_ file: CloudFile, column: BrowserColumn, pane: Int, extend: Bool = false) {
        focusPane(pane)
        let tab = tab(inPane: pane)
        switch column.role {
        case .current:
            workspace.update(tab.id) { state in
                if extend { if state.selection.contains(file.id) { state.selection.remove(file.id) } else { state.selection.insert(file.id) } }
                else { state.selection = [file.id] }
            }
        case .ancestor:
            go(to: BrowserLocation(accountID: tab.accountID, collection: tab.collection, path: Array(tab.path.prefix(column.level))), tab: tab.id)
            workspace.update(tab.id) { $0.selection = [file.id] }
        case .preview:
            guard let folder = Self.selected(tab.selection, among: tab.visibleFiles).first else { return }
            stashColumn(of: tab)
            go(to: BrowserLocation(accountID: tab.accountID, collection: tab.collection, path: tab.path + [folder]), tab: tab.id)
            workspace.update(tab.id) { $0.selection = [file.id] }
        }
    }

    /// ←: up to the enclosing folder, with the folder that was open selected in it.
    func columnLeft(pane: Int) {
        let tab = tab(inPane: pane)
        guard let current = tab.path.last else { return }
        stashColumn(of: tab)
        go(to: BrowserLocation(accountID: tab.accountID, collection: tab.collection, path: Array(tab.path.dropLast())), tab: tab.id)
        workspace.update(tab.id) { $0.selection = [current.id] }
    }

    /// →: into the selected folder. Returns the folder entered, whose first item the view selects once it is listed.
    @discardableResult func columnRight(pane: Int) -> CloudFile? {
        let tab = tab(inPane: pane)
        let chosen = Self.selected(tab.selection, among: tab.visibleFiles)
        guard chosen.count == 1, let folder = chosen.first, folder.isFolder, tab.collection != .trash else { return nil }
        stashColumn(of: tab)
        go(to: BrowserLocation(accountID: tab.accountID, collection: tab.collection, path: tab.path + [folder]), tab: tab.id)
        // What was looked into is already known: shown at once, then listed again as any folder is.
        if let known = columnListings.files(accountID: tab.accountID ?? "", parent: folder.id) {
            workspace.update(tab.id) { if $0.files.isEmpty { $0.files = known } }
        }
        return folder
    }

    /// ↑ and ↓ in the open folder; nothing selected starts at the first (or last) item.
    func columnStep(_ delta: Int, pane: Int) {
        let tab = tab(inPane: pane)
        let files = tab.visibleFiles
        guard !files.isEmpty else { return }
        let index = files.lastIndex { tab.selection.contains($0.id) }
        let target = index.map { min(max(0, $0 + delta), files.count - 1) } ?? (delta > 0 ? 0 : files.count - 1)
        workspace.update(tab.id) { $0.selection = [files[target].id] }
    }

    /// The open folder's listing, kept so the column it becomes when the tab moves away is drawn at once.
    private func stashColumn(of tab: BrowserState) {
        guard let accountID = tab.accountID, !tab.files.isEmpty else { return }
        columnListings.store(tab.files, accountID: accountID, parent: tab.folderID)
    }
}
