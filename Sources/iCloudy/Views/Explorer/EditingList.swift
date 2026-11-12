import SwiftUI
import AppKit

/// Sidebar section with the files opened for editing; observes the manager so each status line stays current.
struct EditingList: View {
    let model: AppModel
    @ObservedObject var editing: EditSessions
    @State private var ending: EditSession?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 8)
            Text("EN EDICIÓN").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(editing.sessions) { (session: EditSession) in
                VStack(alignment: .leading, spacing: 2) {
                    Label(session.file.name, systemImage: session.state == .failed ? "exclamationmark.triangle" : "pencil.circle").lineLimit(1)
                    Text(session.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(editing.status(of: session)).font(.caption2).foregroundStyle(session.state == .failed ? Color.red : Color.secondary).lineLimit(3)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("Abrir de nuevo") { _ = editing.open(session.localURL) }.disabled(session.state == .preparing)
                    Button("Subir los cambios ahora") { editing.uploadNow(session.id) }.disabled(session.state == .preparing)
                    Button("Mostrar la copia en el Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.localURL]) }
                    Button("Ir a su carpeta en la nube") { model.openFolder(accountID: session.accountID, folderID: session.parent) }
                    Divider()
                    Button("Terminar la edición…", role: .destructive) {
                        if editing.hasUnsavedChanges(session.id) { ending = session } else { editing.end(session.id) }
                    }
                }
            }
        }
        .confirmationDialog("¿Terminar la edición de «\(ending?.file.name ?? "")»?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), titleVisibility: .visible) {
            Button("Terminar y descartar lo que no se ha subido", role: .destructive) { if let ending { editing.end(ending.id) }; ending = nil }
            Button("Cancelar", role: .cancel) { ending = nil }
        } message: {
            Text("La copia tiene cambios que todavía no están en la nube. Si terminas ahora se pierden.")
        }
    }
}

/// Shows the list only while something is being edited. A view of its own so that it observes the sessions: the
/// sidebar reads the model, which does not change when a session starts.
struct EditingSection: View {
    let model: AppModel
    @ObservedObject var editing: EditSessions
    var body: some View {
        if !editing.sessions.isEmpty { EditingList(model: model, editing: editing) }
    }
}
