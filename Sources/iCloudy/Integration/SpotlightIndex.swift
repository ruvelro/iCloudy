import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Seam over CoreSpotlight so indexing can be exercised without touching the user's real Spotlight database.
@MainActor
protocol SearchableIndexing {
    func index(_ items: [CSSearchableItem]) async throws
    func deleteItems(withDomainIdentifiers identifiers: [String]) async throws
    func deleteItems(withIdentifiers identifiers: [String]) async throws
    /// Everything this app ever published, including entries a previous version left behind and no list remembers.
    func deleteAllItems() async throws
}

struct SystemSearchableIndex: SearchableIndexing {
    nonisolated init() {}
    func index(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func deleteItems(withDomainIdentifiers identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: identifiers) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func deleteItems(withIdentifiers identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func deleteAllItems() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteAllSearchableItems { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// One remote item worth finding again from Spotlight: a favorite, or something the user previewed, transferred or opened.
struct IndexedItem: Codable, Equatable {
    let accountID: String
    let file: CloudFile
    /// Breadcrumbs shown as the item's description, so two files with the same name stay distinguishable.
    let path: [String]
    var seen: Date
}

/// Publishes names and locations of chosen items to Spotlight. Contents are never indexed: iCloudy would have to
/// download them, and the whole point of the app is that nothing is downloaded unless the user asks.
@MainActor
final class SpotlightIndex {
    static let separator = "\u{1F}"
    /// Bounded so the index never grows without limit; the oldest entries fall off, here and in the system's index.
    var limit = 500
    private let index: SearchableIndexing
    let storeURL: URL
    private(set) var items: [IndexedItem] = []
    /// Identifiers of the favorites the last refresh published. The limit never evicts them: a favorite that fell off
    /// would vanish from the system's search until the favorites list happened to change again.
    private var pinned: Set<String> = []
    /// Every request to the system index, chained in the order it was made. Each one used to run in a task of its
    /// own, so a deletion could overtake the publication it was meant to undo, or «Vaciar» could run before a
    /// publication that was asked for earlier, and in both cases the entry stayed in Spotlight.
    private var tail: Task<Void, Never>?

    init(index: SearchableIndexing = SystemSearchableIndex(), storeURL: URL = LocalStore.directory.appendingPathComponent("spotlight.json")) {
        self.index = index; self.storeURL = storeURL
        items = (try? LocalStore.read([IndexedItem].self, from: storeURL)) ?? []
    }

    static func identifier(accountID: String, fileID: String) -> String { accountID + separator + fileID }
    /// Inverse of `identifier`, used when Spotlight hands an activation back to the app.
    static func decode(identifier: String) -> (accountID: String, fileID: String)? {
        let parts = identifier.components(separatedBy: separator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    static func searchableItem(for entry: IndexedItem, accountLabel: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: contentType(for: entry.file))
        attributes.title = entry.file.name
        attributes.displayName = entry.file.name
        attributes.contentDescription = ([accountLabel] + entry.path).joined(separator: " / ")
        attributes.path = entry.path.joined(separator: "/")
        attributes.contentModificationDate = entry.file.modified
        attributes.fileSize = entry.file.size.map(NSNumber.init(value:))
        attributes.keywords = [accountLabel, L("iCloudy")]
        attributes.contentURL = entry.file.webURL
        return CSSearchableItem(uniqueIdentifier: identifier(accountID: entry.accountID, fileID: entry.file.id),
                                domainIdentifier: entry.accountID, attributeSet: attributes)
    }
    private static func contentType(for file: CloudFile) -> UTType {
        if file.isFolder { return .folder }
        if let type = UTType(mimeType: file.mime), type != .data { return type }
        let ext = (file.name as NSString).pathExtension
        return ext.isEmpty ? .item : (UTType(filenameExtension: ext) ?? .item)
    }

    /// Records an item the user acted on. Repeats refresh its position instead of duplicating it.
    func note(_ file: CloudFile, accountID: String, path: [CloudFile], accountLabel: String) {
        let entry = IndexedItem(accountID: accountID, file: file, path: path.map(\.name), seen: Date())
        items.removeAll { $0.accountID == accountID && $0.file.id == file.id }
        items.insert(entry, at: 0)
        let evicted = trim()
        persist()
        publish([entry], label: accountLabel)
        retire(evicted)
    }
    /// Re-publishes every favorite; called whenever the favorites list changes.
    func refreshFavorites(_ favorites: [Favorite], label: (String) -> String) {
        pinned = Set(favorites.map { Self.identifier(accountID: $0.accountID, fileID: $0.file.id) })
        for favorite in favorites {
            let entry = IndexedItem(accountID: favorite.accountID, file: favorite.file, path: favorite.path.map(\.name), seen: Date())
            if let position = items.firstIndex(where: { $0.accountID == entry.accountID && $0.file.id == entry.file.id }) { items[position] = entry }
            else { items.insert(entry, at: 0) }
            publish([entry], label: label(favorite.accountID))
        }
        let evicted = trim()
        persist()
        retire(evicted)
    }
    /// Retires everything iCloudy published, leaving the system search without any of its entries. The local list
    /// only knows what it still holds: entries evicted by an older version, or published for an account whose items
    /// were dropped before the list existed, would survive a deletion by identifier or by account.
    func clear() {
        items = []
        persist()
        enqueue { try await $0.deleteAllItems() }
    }
    /// Disconnecting an account must leave nothing of it in Spotlight.
    func removeAccount(_ accountID: String) {
        items.removeAll { $0.accountID == accountID }
        persist()
        enqueue { try await $0.deleteItems(withDomainIdentifiers: [accountID]) }
    }
    /// Drops one item, which is what sending it to the bin means for Spotlight. A hit left behind opens on a file
    /// that is not there any more, and the app can only answer that the result is no longer available.
    func forget(accountID: String, fileID: String) {
        guard items.contains(where: { $0.accountID == accountID && $0.file.id == fileID }) else { return }
        items.removeAll { $0.accountID == accountID && $0.file.id == fileID }
        persist()
        let identifier = Self.identifier(accountID: accountID, fileID: fileID)
        enqueue { try await $0.deleteItems(withIdentifiers: [identifier]) }
    }
    /// Keeps an indexed item's name current, because a rename left Spotlight offering the old one.
    func rename(_ file: CloudFile, accountID: String, accountLabel: String) {
        guard let position = items.firstIndex(where: { $0.accountID == accountID && $0.file.id == file.id }) else { return }
        items[position] = IndexedItem(accountID: accountID, file: file, path: items[position].path, seen: Date())
        persist()
        publish([items[position]], label: accountLabel)
    }
    func remap(_ change: RemoteIdentityChange, accountID: String, accountLabel: String, oldParent: [String] = [], newParent: [String]? = nil) {
        let old = items.filter { $0.accountID == accountID && (change.id($0.file.id) != $0.file.id || $0.file.id == change.oldID) }
        let updated = old.map { entry -> IndexedItem in
            let trail: [String]
            if entry.file.id == change.oldID { trail = newParent ?? entry.path }
            else if entry.path.starts(with: oldParent) {
                trail = (newParent ?? oldParent) + [change.name] + entry.path.dropFirst(oldParent.count + 1)
            } else { trail = [] }
            return IndexedItem(accountID: accountID, file: change.file(entry.file), path: trail, seen: Date())
        }
        items.removeAll { entry in old.contains { $0.accountID == entry.accountID && $0.file.id == entry.file.id } }
        items.append(contentsOf: updated); persist()
        guard !old.isEmpty else { return }
        let stale = old.map { Self.identifier(accountID: accountID, fileID: $0.file.id) }
        let searchable = updated.map { Self.searchableItem(for: $0, accountLabel: accountLabel) }
        enqueue { try await $0.deleteItems(withIdentifiers: stale) }
        enqueue { try await $0.index(searchable) }
    }
    /// Waits until every request made so far has reached the system index, in order.
    func settle() async { await tail?.value }

    private func publish(_ entries: [IndexedItem], label: String) {
        let searchable = entries.map { Self.searchableItem(for: $0, accountLabel: label) }
        enqueue { try await $0.index(searchable) }
    }
    /// Drops the oldest entries over the limit, skipping pinned favorites, and returns what it dropped.
    private func trim() -> [IndexedItem] {
        var evicted: [IndexedItem] = []
        var position = items.count - 1
        while items.count > limit, position >= 0 {
            if !pinned.contains(Self.identifier(accountID: items[position].accountID, fileID: items[position].file.id)) {
                evicted.append(items.remove(at: position))
            }
            position -= 1
        }
        return evicted
    }
    /// Takes entries the local list no longer holds out of the system index, so the limit bounds both.
    private func retire(_ entries: [IndexedItem]) {
        guard !entries.isEmpty else { return }
        let identifiers = entries.map { Self.identifier(accountID: $0.accountID, fileID: $0.file.id) }
        enqueue { try await $0.deleteItems(withIdentifiers: identifiers) }
    }
    /// Runs one request after every request made before it. A failure is not retried: the system index is a
    /// convenience, and the next publication or «Vaciar» is the recovery path.
    private func enqueue(_ operation: @escaping @MainActor (SearchableIndexing) async throws -> Void) {
        let previous = tail
        tail = Task { [index] in
            await previous?.value
            try? await operation(index)
        }
    }
    private func persist() { try? LocalStore.save(items, to: storeURL) }
}
