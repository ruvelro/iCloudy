import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// The window sets `model` when it appears, which is after a cold start's first requests; the model registers
    /// itself as soon as it exists, so quitting before any window was shown still saves the queue.
    @MainActor private var current: AppModel? { model ?? AppModel.shared }
    private let services = ServicesProvider()
    /// Clicking the Dock icon with no window open must bring the explorer back, not just activate a headless process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // "Subir a iCloudy" in any app's Services menu, declared in Info.plist and handled in this process.
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
    /// Files dropped on the Dock icon, or opened with "Abrir con", go to the folder currently shown. When the drop is
    /// what launches the app this arrives before the model exists, so it waits for the accounts instead of being lost.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        ColdStart.deliver { $0.enqueueUploads(files) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard current?.hasActiveTransfers == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Hay transferencias pendientes")
        alert.informativeText = L("La cola se guardará en pausa. Al volver a abrir podrás reanudarla. Los elementos ya completados se conservarán.")
        alert.addButton(withTitle: L("Continuar en iCloudy"))
        alert.addButton(withTitle: L("Salir"))
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        current?.queue.pauseAll()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        current?.queue.flush() // coalesced checkpoints still in memory
        current?.localCopies.flush() // and the index of what a finished transfer put on this Mac
        if let model = current { model.workspaceStore.save(model.workspace) } // tabs changed in the last second
        current?.preview.close()
    }
}
