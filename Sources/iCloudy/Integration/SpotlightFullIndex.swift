import Foundation

/// The optional full index: for the accounts the person chooses, the names and places of the whole tree, walked
/// folder by folder up to a cap, besides what was opened and the favorites. Still only names: nothing is downloaded.
///
/// It is kept apart from the recent list: its own file (`spotlight-full.json`), its own Spotlight domain per account
/// and identifiers that end in `full`, so dropping it never takes a favorite or a recent item with it, and the
/// recent list's limit never evicts it.
struct FullIndexState: Codable, Equatable {
    var entries: [IndexedItem] = []
    var indexed: Date?
    /// The walk stopped at the cap before the tree ended.
    var truncated = false
}

@MainActor
enum SpotlightFullIndex {
    static let enabledKey = "spotlightFullIndexAccounts"
    static let limitKey = "spotlightFullIndexLimit"
    static let defaultLimit = 5_000
    /// A walk is repeated at launch once the last one is older than this.
    static let refreshInterval: TimeInterval = 24 * 3600
    static let marker = "full"

    static var enabled: Set<String> {
        get { Set(Prefs.defaults.stringArray(forKey: enabledKey) ?? []) }
        set { Prefs.defaults.set(newValue.sorted(), forKey: enabledKey) }
    }
    static var limit: Int {
        get { let value = Prefs.defaults.integer(forKey: limitKey); return value > 0 ? value : defaultLimit }
        set { Prefs.defaults.set(max(100, min(newValue, 100_000)), forKey: limitKey) }
    }
    static func domain(_ accountID: String) -> String { accountID + SpotlightIndex.separator + marker }
    static func identifier(accountID: String, fileID: String) -> String {
        SpotlightIndex.identifier(accountID: accountID, fileID: fileID) + SpotlightIndex.separator + marker
    }
}

extension AppModel {
    /// Switches the full index of `account` on (and walks it now) or off (and takes it out of Spotlight).
    func setFullIndex(_ account: Account, enabled: Bool) {
        var accounts = SpotlightFullIndex.enabled
        if enabled { accounts.insert(account.id) } else { accounts.remove(account.id) }
        SpotlightFullIndex.enabled = accounts
        if enabled { Task { await indexWholeAccount(account) } } else { spotlight.dropFull(account.id) }
    }

    /// Walks the tree breadth first, one listing at a time and paced like the comparison's walks, until the cap,
    /// and publishes what it found in place of the previous walk. A vault's names are never published.
    func indexWholeAccount(_ account: Account, limit: Int = SpotlightFullIndex.limit, pacer: ListingPacer? = nil) async {
        guard let state = await walkForFullIndex(account, limit: limit, pacer: pacer) else { return }
        spotlight.replaceFull(account.id, with: state, label: accountTitle(account))
    }

    /// The walk itself, without publishing: nil for a vault, a disconnected account or a cancelled walk.
    func walkForFullIndex(_ account: Account, limit: Int, pacer: ListingPacer? = nil) async -> FullIndexState? {
        guard !CryptomatorVaults.isVaultAccount(account.id), let api = try? client(account) else { return nil }
        let pace = pacer ?? (account.isDemo ? ListingPacer(interval: .zero) : ListingPacer.shared(for: account.id))
        var queue: [(id: String, path: [String])] = [((try? await api.rootID()) ?? account.cloud.rootAlias, [])]
        var entries: [IndexedItem] = []
        var truncated = false
        let now = Date()
        while !queue.isEmpty {
            guard !Task.isCancelled else { return nil }
            guard entries.count < limit else { truncated = true; break }
            let folder = queue.removeFirst()
            try? await pace.wait()
            guard let children = try? await api.list(parent: folder.id) else { continue }
            for child in children {
                guard entries.count < limit else { truncated = true; break }
                entries.append(IndexedItem(accountID: account.id, file: child, path: folder.path, seen: now))
                if child.isFolder { queue.append((child.id, folder.path + [child.name])) }
            }
        }
        return FullIndexState(entries: entries, indexed: now, truncated: truncated)
    }

    /// At launch: walks again the enabled accounts whose last walk is a day old, one after the other.
    func refreshFullIndexIfDue() {
        let due = accounts.filter { account in
            SpotlightFullIndex.enabled.contains(account.id)
                && (spotlight.fullState(account.id)?.indexed.map { Date().timeIntervalSince($0) > SpotlightFullIndex.refreshInterval } ?? true)
        }
        guard !due.isEmpty else { return }
        Task { for account in due { await indexWholeAccount(account) } }
    }
}

extension SpotlightIndex {
    static let fullStoreName = "spotlight-full.json"
}
