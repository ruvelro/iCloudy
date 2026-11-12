import Foundation

/// One item a provider says has changed since a cursor: created, edited, moved, renamed or deleted. Which of those
/// is not said, because nothing here applies the change: a sync that hears of one still compares both trees itself.
struct RemoteChange: Equatable, Sendable {
    /// The item, in the same id space as `CloudFile.id` for that provider.
    var id: String?
    /// The folders it sits in now, when the provider says. An item that just arrived is known only by these.
    var parents: [String] = []
}

/// What a provider's change feed answered since a cursor.
struct ChangeBatch: Equatable, Sendable {
    var changes: [RemoteChange] = []
    /// Where to ask from next time.
    var cursor: String
    /// The provider scoped the feed to the folder that was asked about, so every change is inside it.
    var scoped = false
    /// The cursor was too old, or there was more than is worth reading: anything may have changed.
    var reset = false

    /// Whether this batch says something may have changed inside the tree a sync looks after.
    ///
    /// `known` holds the ids of that tree as last seen, folders included, plus its root. An item of the tree that
    /// changed, moved away or was deleted is in it; an item that arrived names one of its folders as parent. Where
    /// the tree is the whole account its root is only an alias the provider never repeats, so any change counts.
    func touches(root: String, known: Set<String>, rootAlias: String) -> Bool {
        if reset { return true }
        guard !changes.isEmpty else { return false }
        if scoped || root == rootAlias || root == "root" { return true }
        return changes.contains { change in
            (change.id.map { known.contains($0) || $0 == root } ?? false) || change.parents.contains { known.contains($0) || $0 == root }
        }
    }
}

extension CloudProvider {
    func changeCursor(for folder: String) async throws -> String? { nil }
    func changes(since cursor: String, in folder: String) async throws -> ChangeBatch {
        throw CloudError.message(L("\(account.cloud.title) no informa de cambios."))
    }
}

extension CloudAPI {
    /// The provider's "now" for changes under `folder`, or nil where there is no feed and the only way to learn of
    /// a change is to list the tree again.
    func changeCursor(for folder: String) async throws -> String? {
        if demo != nil { return nil }
        return try await provider.changeCursor(for: folder)
    }
    func changes(since cursor: String, in folder: String) async throws -> ChangeBatch {
        try await provider.changes(since: cursor, in: folder)
    }
}

/// How much of a feed is read in one go. Past this the account has changed so much that listing the tree is the
/// cheaper way to find out what happened to it.
enum ChangeFeedLimits {
    static let pages = 20
}
