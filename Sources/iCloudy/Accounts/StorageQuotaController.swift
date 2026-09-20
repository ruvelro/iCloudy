import Foundation
import Combine

/// Quota requests outlive navigation. Generations prevent a removed account or an older request from restoring stale data.
@MainActor
final class StorageQuotaController: ObservableObject {
    @Published private(set) var states: [String: StorageQuotaState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var fetched: [String: Date] = [:]
    let refreshInterval: TimeInterval
    init(refreshInterval: TimeInterval = 300) { self.refreshInterval = refreshInterval }

    func remove(_ accountID: String) {
        tasks.removeValue(forKey: accountID)?.cancel()
        generations[accountID] = nil
        fetched[accountID] = nil
        states[accountID] = nil
    }

    func refresh(_ account: Account, force: Bool = false, fetch: @escaping () async throws -> StorageQuota, completion: ((Bool) -> Void)? = nil) {
        guard account.capabilities.quota else {
            states[account.id] = .unavailable(L("\(account.cloud.title) no informa del espacio disponible."))
            completion?(false)
            return
        }
        if !force, case .available = states[account.id], let date = fetched[account.id], Date().timeIntervalSince(date) < refreshInterval {
            completion?(true)
            return
        }
        tasks[account.id]?.cancel()
        let generation = UUID()
        generations[account.id] = generation
        if case .available = states[account.id] {} else { states[account.id] = .loading }
        tasks[account.id] = Task { [weak self] in
            guard let self else { return }
            defer { if generations[account.id] == generation { tasks[account.id] = nil } }
            do {
                let quota = try await fetch()
                try Task.checkCancellation()
                guard generations[account.id] == generation else { completion?(false); return }
                states[account.id] = .available(quota)
                fetched[account.id] = Date()
                completion?(true)
            } catch {
                guard !Task.isCancelled, generations[account.id] == generation else { completion?(false); return }
                states[account.id] = .unavailable(error.localizedDescription)
                completion?(false)
            }
        }
    }
}
