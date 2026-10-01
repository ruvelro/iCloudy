import Foundation

/// The silent renewals in flight, at most one per account, owned by the account they renew.
///
/// A renewal spends up to half a minute in a hidden web view and then writes a new session to the Keychain. It used
/// to be a loose task that nothing could reach: disconnecting the account while one was running let it finish and
/// write the account straight back, credential and all, as if the person had never asked for it to go. Signing in by
/// hand during one was no better, because the slower of the two won.
///
/// So each account has a generation, bumped whenever its credential is replaced or removed. A renewal remembers the
/// generation it started under, and its result is only adopted while that is still the account's current one.
/// Bumping also cancels the renewal, which is what stops the hidden web view instead of letting it run to the end.
@MainActor
final class O2RenewalTasks {
    private var running: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    private var generations: [String: Int] = [:]

    func isRunning(_ accountID: String) -> Bool { running[accountID] != nil }

    /// The account's credential has just been replaced or removed. Whatever a renewal started before this brings
    /// back belongs to a session nobody wants any more, so it is cancelled and its result will not be adopted.
    func invalidate(_ accountID: String) {
        generations[accountID, default: 0] += 1
        running.removeValue(forKey: accountID)?.task.cancel()
    }

    /// Starts a renewal unless one is already running for this account, and says whether it did.
    ///
    /// `adopt` receives the result with a check to make right before writing anything: adopting awaits too (the new
    /// session is proved against the server first), and the account may be disconnected during that wait as well.
    /// `finished` runs when the renewal ends while still being the account's own, and not after `invalidate`, whose
    /// caller is already tidying up.
    @discardableResult
    func start<Result>(_ accountID: String,
                       attempt: @escaping @MainActor () async -> Result?,
                       adopt: @escaping @MainActor (Result, _ isCurrent: @escaping @MainActor () -> Bool) async -> Void,
                       finished: @escaping @MainActor () -> Void = {}) -> Bool {
        guard running[accountID] == nil else { return false }
        let generation = generations[accountID, default: 0]
        let task = Task { @MainActor [weak self] in
            let result = await attempt()
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                self?.generations[accountID, default: 0] == generation
            }
            if let result, isCurrent() { await adopt(result, isCurrent) }
            guard let self, self.running[accountID]?.generation == generation else { return }
            self.running[accountID] = nil
            finished()
        }
        running[accountID] = (generation, task)
        return true
    }
}
