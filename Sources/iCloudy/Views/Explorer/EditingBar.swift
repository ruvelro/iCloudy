import SwiftUI

/// What is open in other apps, above the footer: one line per file, with what has changed and what to do about it.
struct EditingBar: View {
    let model: AppModel
    @Bindable var editor: ExternalEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(editor.sessions) { session in
                HStack(spacing: 8) {
                    Image(systemName: symbol(session)).foregroundStyle(tint(session)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.file.name).lineLimit(1).truncationMode(.middle)
                        Text(session.stateTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if session.state == .uploading || session.state == .downloading { ProgressView().controlSize(.small) }
                    if session.canUpload, [.changed].contains(session.state) || isFailed(session) {
                        Button("Subir cambios") { Task { await model.uploadEdits(session.id) } }
                            .help(L("Sube la copia guardada a su carpeta. Si alguien cambió el archivo mientras tanto, se conservan las dos versiones."))
                    }
                    Button(session.state == .changed || isFailed(session) ? L("Descartar") : L("Dejar de vigilar")) { model.stopEditing(session.id) }
                        .disabled(session.state == .uploading)
                        .help(session.state == .changed ? L("Olvida la copia sin subirla. Lo que guardaste en ella se pierde.") : L("Deja de vigilar la copia y la borra de este Mac."))
                }
                .font(.callout)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(session.file.name)
                .accessibilityValue(session.stateTitle)
            }
        }
        .padding(.horizontal, Layout.margin).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.07))
    }

    private func isFailed(_ session: EditSession) -> Bool {
        if case .failed = session.state { return true }
        return false
    }
    private func symbol(_ session: EditSession) -> String {
        switch session.state {
        case .changed: return "pencil.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle"
        default: return "eye.circle"
        }
    }
    private func tint(_ session: EditSession) -> Color {
        switch session.state {
        case .changed: return .accentColor
        case .failed: return .orange
        default: return .secondary
        }
    }
}
