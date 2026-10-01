import Foundation

extension AppModel {
    /// Hands the queue what it cannot know by itself: the provider behind each account, whether the network costs
    /// money, and the settings. Called once from `init`.
    func configureTransferPolicy() {
        queue.cloud = { [weak self] id in self?.accounts.first { $0.id == id }?.cloud }
        connectivity.onCostChange = { [weak self] costly in self?.queue.setCostlyNetwork(costly) }
        queue.setCostlyNetwork(connectivity.isCostly)
        applyTransferPolicy()
    }
    /// Reads the transfer settings again. The settings window calls it after every change, so a new limit, schedule
    /// or concurrency applies to what is already in the queue.
    func applyTransferPolicy() {
        queue.policy = TransferPolicy.stored()
    }
}
