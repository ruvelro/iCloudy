import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Seam over CoreSpotlight so indexing can be exercised without touching the user's real Spotlight database.
protocol SearchableIndexing {
    func index(_ items: [CSSearchableItem]) async throws
    func deleteItems(withDomainIdentifiers identifiers: [String]) async throws
    func deleteItems(withIdentifiers identifiers: [String]) async throws
}

struct SystemSearchableIndex: SearchableIndexing {
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
    /// Bounded so the index never grows without limit; the oldest entries fall off.
    var limit = 500
    private let index: SearchableIndexing
    let storeURL: URL
    private(set) var items: [IndexedItem] = []

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
        while items.count > limit { items.removeLast() }
        persist()
        publish([entry], label: accountLabel)
    }
    /// Re-publishes every favorite; called whenever the favorites list changes.
    func refreshFavorites(_ favorites: [Favorite], label: (String) -> String) {
        for favorite in favorites {
            let entry = IndexedItem(accountID: favorite.accountID, file: favorite.file, path: favorite.path.map(\.name), seen: Date())
            if let position = items.firstIndex(where: { $0.accountID == entry.accountID && $0.file.id == entry.file.id }) { items[position] = entry }
            else { items.insert(entry, at: 0) }
            publish([entry], label: label(favorite.accountID))
        }
        persist()
    }
    /// Retires everything iCloudy published, leaving the system search without any of its entries.
    func clear() {
        let domains = Set(items.map(\.accountID))
        items = []
        persist()
        guard !domains.isEmpty else { return }
        Task { [index] in try? await index.deleteItems(withDomainIdentifiers: Array(domains)) }
    }
    /// Disconnecting an account must leave nothing of it in Spotlight.
    func removeAccount(_ accountID: String) {
        items.removeAll { $0.accountID == accountID }
        persist()
        Task { [index] in try? await index.deleteItems(withDomainIdentifiers: [accountID]) }
    }
    /// Drops one item, which is what sending it to the bin means for Spotlight. A hit left behind opens on a file
    /// that is not there any more, and the app can only answer that the result is no longer available.
    func forget(accountID: String, fileID: String) {
        guard items.contains(where: { $0.accountID == accountID && $0.file.id == fileID }) else { return }
        items.removeAll { $0.accountID == accountID && $0.file.id == fileID }
        persist()
        let identifier = Self.identifier(accountID: accountID, fileID: fileID)
        Task { [index] in try? await index.deleteItems(withIdentifiers: [identifier]) }
    }
    /// Keeps an indexed item's name current, because a rename left Spotlight offering the old one.
    func rename(_ file: CloudFile, accountID: String, accountLabel: String) {
        guard let position = items.firstIndex(where: { $0.accountID == accountID && $0.file.id == file.id }) else { return }
        items[position] = IndexedItem(accountID: accountID, file: file, path: items[position].path, seen: Date())
        persist()
        publish([items[position]], label: accountLabel)
    }
    private func publish(_ entries: [IndexedItem], label: String) {
        let searchable = entries.map { Self.searchableItem(for: $0, accountLabel: label) }
        Task { [index] in try? await index.index(searchable) }
    }
    private func persist() { try? LocalStore.save(items, to: storeURL) }
}
