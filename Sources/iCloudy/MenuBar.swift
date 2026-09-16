import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Status-bar menu: what the queue is doing right now, plus the actions worth reaching without switching windows.
struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: TransferQueue
    @Environment(\.openWindow) private var openWindow

    private var active: Transfer? { queue.items.first { $0.state == .running } }
    private var waiting: Int { queue.items.filter { $0.state == .queued }.count }
    private var paused: Int { queue.items.filter { $0.state == .paused }.count }
    private var failed: Int { queue.items.filter { $0.state == .failed }.count }

    var body: some View {
        if let active {
            Text(active.name)
            Text(active.metrics)
            if waiting > 0 { Text("\(waiting) en espera") }
        } else if waiting > 0 {
            Text("\(waiting) transferencias en espera")
        } else if !model.isOnline {
            Text("Sin conexión")
        } else {
            Text("Sin transferencias activas")
        }
        if paused > 0 { Text("\(paused) en pausa") }
        if failed > 0 { Text("\(failed) con error") }
        Divider()
        Button("Abrir iCloudy") { activate() }
        Button("Subir el portapapeles…") { activate(); model.uploadFromPasteboard() }
            .disabled(!model.canWrite)
        Button("Buscar en todas las nubes") { activate(); model.preview.close(); model.showGlobalSearch = true }
        Divider()
        if queue.hasActive { Button("Pausar todas") { queue.pauseAll() } }
        if paused + failed > 0 { Button("Reanudar todas") { _ = queue.resumeAll() } }
        if !model.mirrors.mirrors.isEmpty {
            Button("Sincronizar reflejos") { _ = model.syncAllMirrors() }
        }
        Divider()
        ForEach(model.accounts) { account in
            Text(model.accountTitle(account) + " · " + storage(account))
        }
        Divider()
        Button("Salir de iCloudy") { NSApp.terminate(nil) }
    }
    private func storage(_ account: Account) -> String {
        switch model.storageQuotas[account.id] {
        case .available(let quota): return quota.summary
        case .unavailable: return L("espacio no disponible")
        default: return L("consultando…")
        }
    }
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "explorer")
    }
}

/// Receives files and text sent from any app through the Services menu. It runs inside iCloudy, so it needs neither an
/// app extension nor an App Group; the pasteboard carries the sandbox extensions that grant read access to the files.
final class ServicesProvider: NSObject {
    weak var model: AppModel?

    @objc func uploadToICloudy(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(\.isFileURL)
        let text = pasteboard.string(forType: .string)
        guard !urls.isEmpty || !(text ?? "").isEmpty else {
            error.pointee = L("No hay archivos ni texto que subir.") as NSString
            return
        }
        Task { @MainActor [weak self] in
            guard let model = self?.model else { return }
            NSApp.activate(ignoringOtherApps: true)
            if !urls.isEmpty { _ = model.enqueueUploads(urls) }
            else if let text { model.uploadText(text) }
        }
    }
}
