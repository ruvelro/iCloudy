import AppKit
import UserNotifications

/// One notification when a run of transfers ends, never one per file. A run starts with the first job the queue takes
/// and ends when nothing is left running or waiting; what finished in between is summed up in a single line.
///
/// Mirror syncs are left out: they run on their own every few minutes, and a notification for each pass would teach
/// people to ignore the ones that matter. Nothing is shown while iCloudy is the active app, where the panel says it.
@MainActor
final class TransferNotifier {
    struct Summary: Equatable { var completed = 0, failed = 0, bytes: Int64 = 0 }

    private(set) var summary = Summary()
    private var wasActive = false
    /// Shows the notification. Replaced in tests; the default needs a real app bundle.
    var post: @MainActor (String, String) -> Void = TransferNotifier.deliver
    var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? true }
    static func isEnabled() -> Bool { Prefs.bool(Prefs.notifyTransfers, default: true) }

    func finished(_ transfer: Transfer) {
        guard transfer.mirrorEntries == nil else { return }
        switch transfer.state {
        case .completed: summary.completed += 1; summary.bytes += transfer.total
        case .failed: summary.failed += 1
        default: break
        }
    }

    /// Called whenever the queue changes. The run is over on the change that leaves it with nothing active.
    func queueChanged(active: Bool) {
        defer { wasActive = active }
        guard wasActive, !active else { return }
        let ended = summary
        summary = Summary()
        guard ended.completed + ended.failed > 0, Self.isEnabled(), !isAppActive() else { return }
        let message = Self.message(ended)
        post(message.title, message.body)
    }

    static func message(_ summary: Summary) -> (title: String, body: String) {
        let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        if summary.failed == 0 {
            return (L("Transferencias terminadas"), summary.completed == 1 ? L("1 transferencia completada (\(size)).") : L("\(summary.completed) transferencias completadas (\(size))."))
        }
        let failed = summary.failed == 1 ? L("1 con errores") : L("\(summary.failed) con errores")
        return (L("Transferencias terminadas con errores"), L("\(summary.completed) completadas, \(failed). Ábrelas en el panel de transferencias para reintentarlas."))
    }

    /// Asks for permission the first time it is needed, which is also when macOS shows its own prompt.
    static func requestPermission() {
        guard canNotify else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// A process without a bundle (the test runner, `swift run`) has no notification center and traps if asked.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && !Diagnostics.underTest }

    private static func deliver(_ title: String, _ body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}
