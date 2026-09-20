import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { services.model = model } }
    private let services = ServicesProvider()
    /// Clicking the Dock icon with no window open must bring the explorer back, not just activate a headless process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // "Subir a iCloudy" in any app's Services menu, declared in Info.plist and handled in this process.
        services.model = model
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
    /// Files dropped on the Dock icon, or opened with "Abrir con", go to the folder currently shown.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let model else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in model.enqueueUploads(files) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasActiveTransfers == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Hay transferencias pendientes")
        alert.informativeText = L("La cola se guardará en pausa. Al volver a abrir podrás reanudarla. Los elementos ya completados se conservarán.")
        alert.addButton(withTitle: L("Continuar en iCloudy"))
        alert.addButton(withTitle: "Salir")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        model?.queue.pauseAll()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.queue.flush() // coalesced checkpoints still in memory
        model?.localCopies.flush() // and the index of what a finished transfer put on this Mac
        model?.preview.close()
    }
}
