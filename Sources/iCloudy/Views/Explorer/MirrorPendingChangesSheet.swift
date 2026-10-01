import SwiftUI

/// What the next sync of a mirror would do, worked out by the sync's own planner and without changing anything.
struct MirrorPendingChangesSheet: View {
    let mirror: FolderMirror
    @ObservedObject var manager: MirrorManager
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MirrorPreview?
    @State private var error: String?
    @State private var loading = false
    /// Long lists are cut so the sheet stays responsive; the header still gives the full count.
    private let rowsPerSection = 300

    private var paused: Bool { manager.mirrors.first { $0.id == mirror.id }?.paused ?? mirror.paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cambios pendientes de «\(mirror.localURL.lastPathComponent)»").font(.headline)
            Group {
                if mirror.mode == .twoWay {
                    Text("Calculado ahora con la carpeta del Mac y la de la nube. No se ha cambiado nada en ninguno de los dos lados.")
                } else {
                    Text("Calculado con la carpeta del Mac. Lo que ya exista en la nube y no haya subido este reflejo se preguntará al sincronizar.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content.frame(minHeight: 260, maxHeight: .infinity)
            HStack {
                Button("Actualizar") { Task { await load() } }.disabled(loading)
                Spacer()
                Button("Cerrar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if paused {
                    Button("Reanudar y sincronizar") { manager.setPaused(false, for: mirror.id); dismiss() }
                } else {
                    Button("Sincronizar ahora") { manager.syncNow(mirror.id); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview?.isEmpty ?? true)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading, preview == nil {
            ProgressView("Calculando…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview {
            VStack(alignment: .leading, spacing: 8) {
                if let refused = preview.massDeletion {
                    Label(refused, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preview.resumesQueuedUpload {
                    Label("Hay una subida de este reflejo a medias en la cola: se reanudará esa antes de volver a comparar.", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if preview.isEmpty, mirror.mode == .twoWay {
                    Label("Nada pendiente: los dos lados coinciden.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else if preview.isEmpty {
                    Label("Nada pendiente: la nube ya tiene lo último de esta carpeta.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                List {
                    ForEach(PendingChange.Kind.allCases, id: \.self) { kind in
                        let rows = preview.changes(kind)
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows.prefix(rowsPerSection)) { change in
                                    Label(change.path, systemImage: change.isFolder ? "folder" : "doc").lineLimit(1).truncationMode(.middle)
                                }
                                if rows.count > rowsPerSection { Text("… y \(rows.count - rowsPerSection) más").foregroundStyle(.secondary) }
                            } header: {
                                HStack {
                                    Label(title(kind), systemImage: symbol(kind))
                                    Spacer()
                                    Text(verbatim: "\(rows.count)")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { preview = try await manager.preview(mirror.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func title(_ kind: PendingChange.Kind) -> LocalizedStringKey {
        switch kind {
        case .upload: return "Se subirán"
        case .download: return "Se bajarán"
        case .trashRemote: return "Irán a la papelera de la nube"
        case .trashLocal: return "Irán a la papelera del Mac"
        case .conflict: return "Conflictos: se conservarán las dos versiones"
        case .excluded: return "Excluidos: no se tocan"
        }
    }
    private func symbol(_ kind: PendingChange.Kind) -> String {
        switch kind {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .trashRemote: return "icloud.slash"
        case .trashLocal: return "trash"
        case .conflict: return "exclamationmark.2"
        case .excluded: return "nosign"
        }
    }
}
