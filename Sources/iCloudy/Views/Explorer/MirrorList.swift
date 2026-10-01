import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Sidebar section with every mirrored folder and its state; observes the manager so status lines stay current.
struct MirrorList: View {
    let model: AppModel
    @ObservedObject var mirrors: MirrorManager
    @State private var removing: FolderMirror?
    @State private var editingExclusions: FolderMirror?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        Divider().padding(.vertical, 8)
        Text("REFLEJOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(mirrors.mirrors) { (mirror: FolderMirror) in
            VStack(alignment: .leading, spacing: 2) {
                Label(mirror.localURL.lastPathComponent, systemImage: mirror.mode == .twoWay ? "arrow.left.arrow.right" : "arrow.triangle.2.circlepath").lineLimit(1)
                Text((mirror.mode == .twoWay ? "⇄ " : "→ ") + mirror.remoteName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(mirrors.status(of: mirror)).font(.caption2).foregroundStyle(mirror.lastError == nil ? Color.secondary : Color.red).lineLimit(2)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Sincronizar ahora") { mirrors.syncNow(mirror.id) }
                if mirror.mode == .twoWay {
                    Button("Sincronizar aplicando los borrados") { mirrors.syncNow(mirror.id, applyingMassDeletion: true) }
                        .help("Solo hace falta cuando la sincronización se detuvo por borrar la mayor parte de un lado")
                }
                Button("Exclusiones…") { editingExclusions = mirror }
                Divider()
                Button("Abrir carpeta remota") { model.openFolder(accountID: mirror.accountID, folderID: mirror.remoteFolderID) }
                Button("Mostrar carpeta local en el Finder") { model.revealLocal(mirror) }
                Divider()
                Button("Dejar de reflejar…", role: .destructive) { removing = mirror }
            }
        }
        }
        .confirmationDialog("¿Dejar de reflejar «\(removing?.localURL.lastPathComponent ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Dejar de reflejar", role: .destructive) { if let removing { mirrors.remove(removing.id) }; removing = nil }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: { Text("Se deja de vigilar la carpeta. No se borra nada, ni en el Mac ni en la nube.") }
        .sheet(item: $editingExclusions) { mirror in MirrorExclusionsSheet(mirror: mirror, manager: mirrors) }
    }
}
