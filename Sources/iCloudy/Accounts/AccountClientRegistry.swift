import Foundation

/// Owns client lifetimes. Reconnecting replaces and invalidates the old provider before it can be reused.
@MainActor
final class AccountClientRegistry {
    private var clients: [String: CloudAPI] = [:]
    func cached(for accountID: String) -> CloudAPI? { clients[accountID] }
    func store(_ client: CloudAPI) {
        if let previous = clients[client.account.id], previous !== client { previous.invalidate() }
        clients[client.account.id] = client
    }
    func remove(_ accountID: String) { clients.removeValue(forKey: accountID)?.invalidate() }
    func remove(where predicate: (String) -> Bool) {
        for id in Array(clients.keys) where predicate(id) { remove(id) }
    }
}
