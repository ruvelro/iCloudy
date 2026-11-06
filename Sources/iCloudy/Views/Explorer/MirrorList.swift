import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Sidebar section with every mirrored folder and its state; observes the manager so status lines stay current.
struct MirrorList: View {
    let model: AppModel
    @Bindable var mirrors: MirrorManager
    @State private var removing: FolderMirror?
    @State private var editingExclusions: FolderMirror?
    @State private var previewing: FolderMirror?
    @State private var configuring: FolderMirror?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        Divider().padding(.vertical, 8)
        Text("REFLEJOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(mirrors.mirrors) { (mirror: FolderMirror) in
            VStack(alignment: .leading, spacing: 2) {
                Label(mirror.title, systemImage: mirror.paused ? "pause.circle" : mirror.symbol).lineLimit(1)
                Text(mirror.arrow + " " + mirror.remoteName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if mirror.mode == .cloudPair { Text("Entre dos nubes · experimental").font(.caption2).foregroundStyle(.orange) }
                Text(mirrors.status(of: mirror)).font(.caption2).foregroundStyle(mirror.lastError == nil ? Color.secondary : Color.red).lineLimit(2)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Sincronizar ahora") { mirrors.syncNow(mirror.id) }.disabled(mirror.paused)
                if mirror.isTwoWay || mirror.options.exact {
                    Button("Sincronizar aplicando los borrados") { mirrors.syncNow(mirror.id, applyingMassDeletion: true) }
                        .help("Solo hace falta cuando la sincronización se detuvo por borrar la mayor parte de un lado")
                        .disabled(mirror.paused)
                }
                if mirror.paused {
                    Button("Reanudar") { mirrors.setPaused(false, for: mirror.id) }
                } else {
                    Button("Pausar") { mirrors.setPaused(true, for: mirror.id) }
                        .help("Deja de sincronizar este reflejo hasta que lo reanudes, también tras cerrar la app")
                }
                Button("Cambios pendientes…") { previewing = mirror }
                    .help("Muestra lo que haría la próxima sincronización, sin hacerlo")
                Button("Exclusiones…") { editingExclusions = mirror }
                Button("Ajustes…") { configuring = mirror }
                Button("Verificar ahora") {
                    Task {
                        do { model.info = L("«\(mirror.title)»: \(try await mirrors.verify(mirror.id).text)") }
                        catch { model.error = error.localizedDescription }
                    }
                }.help("Compara cada archivo del reflejo en los dos lados por tamaño y, donde se pueda, por suma de verificación")
                Divider()
                Button("Abrir carpeta remota") { model.openFolder(accountID: mirror.accountID, folderID: mirror.remoteFolderID) }
                if mirror.mode != .cloudPair { Button("Mostrar carpeta local en el Finder") { model.revealLocal(mirror) } }
                Divider()
                Button("Dejar de reflejar…", role: .destructive) { removing = mirror }
            }
        }
        }
        .confirmationDialog("¿Dejar de reflejar «\(removing?.title ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Dejar de reflejar", role: .destructive) { if let removing { mirrors.remove(removing.id) }; removing = nil }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: { Text("Se deja de vigilar la carpeta. No se borra nada, ni en el Mac ni en la nube.") }
        .sheet(item: $editingExclusions) { mirror in MirrorExclusionsSheet(mirror: mirror, manager: mirrors) }
        .sheet(item: $previewing) { mirror in MirrorPendingChangesSheet(mirror: mirror, manager: mirrors) }
        .sheet(item: $configuring) { mirror in MirrorSettingsSheet(mirror: mirror, manager: mirrors) }
    }
}
