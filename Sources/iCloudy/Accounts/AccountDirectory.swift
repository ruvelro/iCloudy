import Foundation

/// Where the list of accounts is written. A seam so tests can watch what reaches the Keychain, and fail it.
struct AccountKeychain: Sendable {
    var saveAccounts: @Sendable ([Account]) throws -> Void
    var saveCredential: @Sendable (Credential, String) throws -> Void
    var deleteCredential: @Sendable (String) throws -> Void

    static let vault = AccountKeychain(
        saveAccounts: { try Vault.save($0, key: AccountDirectory.storageKey) },
        saveCredential: { try Vault.save($0, key: $1) },
        deleteCredential: { try Vault.delete(key: $0) })
}

/// The connected accounts, the state of their sessions, and the only code that writes them to the Keychain.
///
/// The model used to do this from nine places, each with its own copy of "save the list, then replace it, then drop
/// the client, then clear the expiry", and four of them forgot a step. Every change goes through here now, always in
/// the same order: the Keychain first, so a failed write leaves the list in memory as it was.
@MainActor
@Observable
final class AccountDirectory {
    nonisolated static let storageKey = "accounts"

    /// Assigning it directly changes this run only; the methods below are what persist a change.
    var accounts: [Account] = [] {
        didSet { if Set(oldValue.map(\.id)) != Set(accounts.map(\.id)) { membershipChanged?() } }
    }
    /// Accounts whose provider rejected the stored credential. Shown in the sidebar until the user reconnects.
    private(set) var expiredAccountIDs: Set<String> = []
    /// Why each of them ended, when the provider said anything worth repeating.
    private(set) var expiryReasons: [String: String] = [:]
    /// Accounts whose session is being renewed in the background, so the sidebar can say so instead of alarming.
    var renewingAccountIDs: Set<String> = []
    /// The live client of each account.
    @ObservationIgnored let sessions = AccountClientRegistry()
    /// Accounts were added or removed, not merely reordered or edited. The Finder's locations follow this.
    @ObservationIgnored var membershipChanged: (() -> Void)?
    @ObservationIgnored let keychain: AccountKeychain

    init(keychain: AccountKeychain = .vault) { self.keychain = keychain }

    func account(_ id: Account.ID?) -> Account? { accounts.first { $0.id == id } }
    func isExpired(_ id: Account.ID) -> Bool { expiredAccountIDs.contains(id) }
    func isRenewing(_ id: Account.ID) -> Bool { renewingAccountIDs.contains(id) }
    func expiryReason(_ id: Account.ID) -> String? { expiryReasons[id] }

    /// Accounts that live off this one's credential: the shared drives and document libraries derived from it. They
    /// have no sign-in of their own, so whatever happens to the parent's session happens to them.
    static func dependents(of account: Account, in accounts: [Account]) -> [Account] {
        accounts.filter { $0.id != account.id && $0.credentialKey == account.id }
    }

    /// The list with this account in it: where it already was when it is being reconnected or renewed, at the end when
    /// it is new. Taking it out and appending it sent an O2 account to the bottom on every silent renewal, undoing
    /// whatever order the person had given the sidebar.
    static func placing(_ account: Account, in accounts: [Account]) -> [Account] {
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account } else { updated.append(account) }
        return updated
    }

    /// The list with one account moved to where another one is, as dragging it there in the sidebar does.
    static func moving(_ id: Account.ID, to target: Account.ID, in accounts: [Account]) -> [Account] {
        guard id != target, let from = accounts.firstIndex(where: { $0.id == id }),
              let to = accounts.firstIndex(where: { $0.id == target }) else { return accounts }
        var updated = accounts
        updated.insert(updated.remove(at: from), at: to)
        return updated
    }

    /// The list with one account moved a number of places up (negative) or down, stopping at either end.
    static func moving(_ id: Account.ID, by offset: Int, in accounts: [Account]) -> [Account] {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return accounts }
        let to = min(max(from + offset, 0), accounts.count - 1)
        guard to != from else { return accounts }
        var updated = accounts
        updated.insert(updated.remove(at: from), at: to)
        return updated
    }

    /// Adds an account, or puts a reconnected one back where it was, with a fresh session for it and for the accounts
    /// borrowing its credential. Without resetting those, a shared drive stayed "expired" until the next launch.
    func adopt(_ account: Account, credential: Credential?) throws {
        if let credential { try keychain.saveCredential(credential, account.id) }
        try replace(Self.placing(account, in: accounts))
        forgetSessions([account.id] + Self.dependents(of: account, in: accounts).map(\.id))
    }

    /// Writes a new list and then shows it. The demo account is never stored: it is local and comes back by itself.
    func replace(_ updated: [Account]) throws {
        try keychain.saveAccounts(updated.filter { !$0.isDemo })
        accounts = updated
    }

    /// The order lives in the same Keychain entry as the accounts, so it is the order they come back in on the next
    /// launch. Returns false when there was nothing to change.
    @discardableResult
    func reorder(_ updated: [Account]) throws -> Bool {
        guard updated.map(\.id) != accounts.map(\.id) else { return false }
        // Moved in memory even if the write fails: the person sees what they did, and is told it will not last.
        accounts = updated
        try keychain.saveAccounts(updated.filter { !$0.isDemo })
        return true
    }

    /// Changes one stored account in place, such as a bookmark the system had to renew.
    func update(_ id: Account.ID, _ change: (inout Account) -> Void) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = accounts
        change(&updated[index])
        guard updated[index] != accounts[index] else { return }
        // In memory either way: the change works for this run even when it cannot be saved for the next one.
        accounts = updated
        try keychain.saveAccounts(updated.filter { !$0.isDemo })
    }

    /// Takes an account out with the ones that borrow its credential, and deletes that credential. Returns who left.
    @discardableResult
    func remove(_ account: Account) throws -> [Account] {
        let leaving = [account] + Self.dependents(of: account, in: accounts)
        let ids = Set(leaving.map(\.id))
        let updated = accounts.filter { !ids.contains($0.id) }
        if !account.isDemo {
            try keychain.saveAccounts(updated.filter { !$0.isDemo })
            try keychain.deleteCredential(account.id)
        }
        forgetSessions(Array(ids))
        accounts = updated
        return leaving
    }

    /// The provider refused the session. The account stays listed, marked, until it is reconnected or renewed.
    func markExpired(_ id: Account.ID, reason: String?) {
        expiredAccountIDs.insert(id)
        if let reason { expiryReasons[id] = reason }
    }

    /// Drops the clients and the expiry marks, so the next request starts a session from what is stored.
    func forgetSessions(_ ids: [Account.ID]) {
        for id in ids {
            sessions.remove(id)
            expiredAccountIDs.remove(id); expiryReasons[id] = nil
        }
    }
}
