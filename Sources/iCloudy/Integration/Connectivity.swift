import Foundation
import Network

/// Tracks whether the Mac has a usable network path. The queue pauses on loss and resumes on recovery instead of
/// burning its retries, and the explorer shows a banner rather than a generic error for each failed request.
@MainActor
final class Connectivity: ObservableObject {
    @Published private(set) var isOnline = true
    var onChange: ((Bool) -> Void)?
    /// True on a hotspot, a cellular link or with Low Data Mode on: the queue can wait for a cheaper network.
    @Published private(set) var isCostly = false
    var onCostChange: ((Bool) -> Void)?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let costly = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.update(online); self?.updateCost(costly) }
        }
        monitor.start(queue: DispatchQueue(label: "icloudy.connectivity"))
    }
    /// Also the seam for tests and for the demo's offline switch.
    func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
    func updateCost(_ costly: Bool) {
        guard costly != isCostly else { return }
        isCostly = costly
        onCostChange?(costly)
    }
    deinit { monitor.cancel() }
}
