import AppKit

/// What an entry point from outside the window needs to know about the model before acting on it.
@MainActor
protocol AccountLoading: AnyObject {
    var loadingAccounts: Bool { get }
    var accountLoadError: Error? { get }
}
extension AppModel: AccountLoading {}

/// Files dropped on the Dock icon, the Services menu and Shortcuts can all launch the app, and they arrive before
/// SwiftUI has built the model or before the Keychain has handed back the accounts. Acting then found no model, or a
/// model with no account selected, and the request was dropped without a word or answered with a misleading error.
/// Every such entry point waits here instead, for a bounded time, and says why when it gives up.
@MainActor
enum ColdStart {
    /// Long enough for the person to answer the Keychain's own dialog, which macOS shows whenever the app's signature
    /// changes, and short enough that a Shortcut does not hang forever on an app that will never be ready.
    static let timeout: Duration = .seconds(60)
    private static let poll: Duration = .milliseconds(20)

    /// The running model once its accounts are loaded.
    static func model() async throws -> AppModel { try await ready(timeout: timeout) { AppModel.shared } }

    /// Waits until `lookup` returns a model that has finished loading its accounts.
    static func ready<Model: AccountLoading>(timeout: Duration, lookup: () -> Model?) async throws -> Model {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let model = lookup(), !model.loadingAccounts {
                if let error = model.accountLoadError { throw ColdStartError.accountsUnreadable(error.localizedDescription) }
                return model
            }
            guard clock.now < deadline else { throw lookup() == nil ? ColdStartError.notRunning : ColdStartError.stillLoading }
            try await Task.sleep(for: poll)
        }
    }

    /// Runs a request that came from outside the window as soon as the accounts are there, or explains why it could
    /// not. The request is never dropped silently.
    static func deliver(_ action: @escaping @MainActor (AppModel) -> Void) {
        Task { @MainActor in
            do { action(try await model()) }
            catch { report(error) }
        }
    }

    /// Shows the reason in the window's alert, or in an alert of its own when there is no model to show it.
    static func report(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        if let model = AppModel.shared { model.error = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = L("No se pudo completar la operación")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

enum ColdStartError: LocalizedError, Equatable {
    case notRunning
    case stillLoading
    case accountsUnreadable(String)
    var errorDescription: String? {
        switch self {
        case .notRunning: return L("iCloudy no está listo todavía. Abre la app e inténtalo de nuevo.")
        case .stillLoading: return L("iCloudy sigue leyendo las cuentas guardadas en el Llavero. Si macOS ha pedido permiso para acceder a ellas, acéptalo e inténtalo de nuevo.")
        case .accountsUnreadable(let message): return L("No se pudieron leer las cuentas guardadas: \(message)")
        }
    }
}
