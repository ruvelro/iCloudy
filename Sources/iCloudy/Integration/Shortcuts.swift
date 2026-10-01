import AppIntents
import Foundation

// Intents declared by an app run inside it, and the system launches it first when it is not open. That launch is a
// cold start like any other, so every intent reaches the model through `ColdStart`, which waits for the accounts.

struct PauseTransfersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pausar transferencias de iCloudy"
    static let description = IntentDescription("Pausa todas las transferencias en curso y en cola. Se reanudan con el atajo de reanudar o desde la app.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let affected = model.queue.items.filter { [.running, .queued].contains($0.state) }.count
        model.queue.pauseAll()
        return .result(dialog: IntentDialog(stringLiteral: affected == 0 ? L("No había transferencias activas.") : L("\(affected) transferencias en pausa.")))
    }
}

struct ResumeTransfersIntent: AppIntent {
    static let title: LocalizedStringResource = "Reanudar transferencias de iCloudy"
    static let description = IntentDescription("Reanuda las transferencias en pausa, incluidas las recuperadas al abrir la app.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let resumed = model.queue.resumeAll()
        return .result(dialog: IntentDialog(stringLiteral: resumed == 0 ? L("No había transferencias en pausa.") : L("\(resumed) transferencias reanudadas.")))
    }
}

struct SyncMirrorsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sincronizar reflejos de iCloudy"
    static let description = IntentDescription("Comprueba ahora las carpetas reflejadas y sube lo que haya cambiado.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let paused = model.mirrors.mirrors.filter(\.paused).count
        let count = model.syncAllMirrors()
        return .result(dialog: IntentDialog(stringLiteral: Self.summary(started: count, paused: paused)))
    }
    static func summary(started: Int, paused: Int) -> String {
        switch (started, paused) {
        case (0, 0): return L("No hay carpetas reflejadas.")
        case (0, _): return L("Todas las carpetas reflejadas están en pausa; no se ha comprobado ninguna.")
        case (_, 0): return L("Comprobando \(started) carpetas reflejadas.")
        default: return L("Comprobando \(started) carpetas reflejadas; \(paused) en pausa se quedan como están.")
        }
    }
}

struct StorageReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Espacio de las nubes de iCloudy"
    static let description = IntentDescription("Indica el espacio usado y total de cada cuenta conectada, según el último dato del proveedor.")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = try await ColdStart.model()
        let report = model.storageSummary()
        return .result(value: report, dialog: IntentDialog(stringLiteral: report))
    }
}

struct SearchCloudsIntent: AppIntent {
    static let title: LocalizedStringResource = "Buscar en las nubes de iCloudy"
    static let description = IntentDescription("Abre iCloudy y busca el término en todas las cuentas conectadas.")
    static let openAppWhenRun = true

    @Parameter(title: "Texto que buscar")
    var query: String

    @MainActor func perform() async throws -> some IntentResult {
        let model = try await ColdStart.model()
        model.startGlobalSearch(query)
        return .result()
    }
}

struct UploadFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Subir archivos a iCloudy"
    static let description = IntentDescription("Añade los archivos a la cola de subida, en la carpeta abierta en iCloudy.")
    static let openAppWhenRun = true

    @Parameter(title: "Archivos")
    var files: [IntentFile]

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else { throw CloudError.message(L("No se ha recibido ningún archivo que subir.")) }
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
