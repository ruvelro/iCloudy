import Foundation
import Network

/// Tracks whether the Mac has a usable network path. The queue pauses on loss and resumes on recovery instead of
/// burning its retries, and the explorer shows a banner rather than a generic error for each failed request.
@MainActor
final class Connectivity: ObservableObject {
    @Published private(set) var isOnline = true
    var onChange: ((Bool) -> Void)?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "icloudy.connectivity"))
    }
    /// Also the seam for tests and for the demo's offline switch.
    func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
    deinit { monitor.cancel() }
}
