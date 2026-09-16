import AppIntents
import Foundation

/// Reaches the running app from an intent. Intents declared by an app run inside it, and the system launches it first
/// when it is not open, so this is set by then.
enum IntentBridge {
    @MainActor static func model() throws -> AppModel {
        guard let model = AppModel.shared else { throw AppModelUnavailable() }
        return model
    }
}
struct AppModelUnavailable: LocalizedError {
    var errorDescription: String? { L("iCloudy no está listo todavía. Abre la app e inténtalo de nuevo.") }
}

struct PauseTransfersIntent: AppIntent {
    static var title: LocalizedStringResource = "Pausar transferencias de iCloudy"
    static var description = IntentDescription("Pausa todas las transferencias en curso y en cola. Se reanudan con el atajo de reanudar o desde la app.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try IntentBridge.model()
        let affected = model.queue.items.filter { [.running, .queued].contains($0.state) }.count
        model.queue.pauseAll()
        return .result(dialog: IntentDialog(stringLiteral: affected == 0 ? L("No había transferencias activas.") : L("\(affected) transferencias en pausa.")))
    }
}

struct ResumeTransfersIntent: AppIntent {
    static var title: LocalizedStringResource = "Reanudar transferencias de iCloudy"
    static var description = IntentDescription("Reanuda las transferencias en pausa, incluidas las recuperadas al abrir la app.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try IntentBridge.model()
        let resumed = model.queue.resumeAll()
        return .result(dialog: IntentDialog(stringLiteral: resumed == 0 ? L("No había transferencias en pausa.") : L("\(resumed) transferencias reanudadas.")))
    }
}

struct SyncMirrorsIntent: AppIntent {
    static var title: LocalizedStringResource = "Sincronizar reflejos de iCloudy"
    static var description = IntentDescription("Comprueba ahora las carpetas reflejadas y sube lo que haya cambiado.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try IntentBridge.model()
        let count = model.syncAllMirrors()
        return .result(dialog: IntentDialog(stringLiteral: count == 0 ? L("No hay carpetas reflejadas.") : L("Comprobando \(count) carpetas reflejadas.")))
    }
}

struct StorageReportIntent: AppIntent {
    static var title: LocalizedStringResource = "Espacio de las nubes de iCloudy"
    static var description = IntentDescription("Indica el espacio usado y total de cada cuenta conectada, según el último dato del proveedor.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = try IntentBridge.model()
        let report = model.storageSummary()
        return .result(value: report, dialog: IntentDialog(stringLiteral: report))
    }
}

struct SearchCloudsIntent: AppIntent {
    static var title: LocalizedStringResource = "Buscar en las nubes de iCloudy"
    static var description = IntentDescription("Abre iCloudy y busca el término en todas las cuentas conectadas.")
    static var openAppWhenRun = true

    @Parameter(title: "Texto que buscar")
    var query: String

    @MainActor func perform() async throws -> some IntentResult {
        let model = try IntentBridge.model()
        model.startGlobalSearch(query)
        return .result()
    }
}

struct UploadFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Subir archivos a iCloudy"
    static var description = IntentDescription("Añade los archivos a la cola de subida, en la carpeta abierta en iCloudy.")
    static var openAppWhenRun = true

    @Parameter(title: "Archivos")
    var files: [IntentFile]

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try IntentBridge.model()
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else { throw AppModelUnavailable() }
        let accepted = model.enqueueUploads(urls)
        return .result(dialog: IntentDialog(stringLiteral: accepted ? L("\(urls.count) archivos en cola hacia \(model.location).") : L("Abre una carpeta de «Mis archivos» en iCloudy antes de subir.")))
    }
}

struct iCloudyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PauseTransfersIntent(), phrases: ["Pausar transferencias en \(.applicationName)"],
                    shortTitle: "Pausar transferencias", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeTransfersIntent(), phrases: ["Reanudar transferencias en \(.applicationName)"],
                    shortTitle: "Reanudar transferencias", systemImageName: "play.circle")
        AppShortcut(intent: SyncMirrorsIntent(), phrases: ["Sincronizar reflejos de \(.applicationName)"],
                    shortTitle: "Sincronizar reflejos", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: StorageReportIntent(), phrases: ["Cuánto espacio queda en \(.applicationName)"],
                    shortTitle: "Espacio de las nubes", systemImageName: "chart.pie")
        AppShortcut(intent: SearchCloudsIntent(), phrases: ["Buscar en \(.applicationName)"],
                    shortTitle: "Buscar en las nubes", systemImageName: "magnifyingglass")
    }
}
