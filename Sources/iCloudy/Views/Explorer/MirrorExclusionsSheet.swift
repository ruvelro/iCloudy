import SwiftUI

/// Edits what one mirror leaves alone. A path can be tried against the rules before saving them, since a glob that
/// catches more than intended is the usual surprise.
struct MirrorExclusionsSheet: View {
    let mirror: FolderMirror
    let manager: MirrorManager
    @Environment(\.dismiss) private var dismiss
    @State private var rules: SyncExclusions
    @State private var text: String
    @State private var probe = ""
    @State private var error: String?
    private let caseInsensitive: Bool

    init(mirror: FolderMirror, manager: MirrorManager) {
        self.mirror = mirror
        self.manager = manager
        _rules = State(initialValue: mirror.exclusions)
        _text = State(initialValue: mirror.exclusions.patterns.joined(separator: "\n"))
        caseInsensitive = manager.exclusions(of: mirror).caseInsensitive
    }

    private var edited: SyncExclusions {
        var result = rules
        result.patterns = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return result
    }
    /// The defaults as a person can read them: Finder's custom-icon file ends in a carriage return.
    private var defaultsList: String {
        SyncExclusions.defaults.map { $0.replacingOccurrences(of: "\r", with: "\\r") }.joined(separator: "   ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclusiones de «\(mirror.localURL.lastPathComponent)»").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Excluir los archivos del sistema y de bloqueo habituales", isOn: $rules.useDefaults)
                Text(verbatim: defaultsList).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 20)
            }
            Toggle("Excluir los archivos y carpetas ocultos (los que empiezan por punto)", isOn: $rules.skipHidden)
            Toggle("Excluir los paquetes (.app, .photoslibrary, .bundle…)", isOn: $rules.skipPackages)
            Text("Patrones propios, uno por línea").font(.subheadline.weight(.semibold))
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            Text("«*» es cualquier texto dentro de un nombre, «?» un carácter, «[a-z]» uno de la lista y «**» cualquier número de carpetas. Si el patrón lleva «/», cuenta desde la carpeta reflejada; si no, vale para el nombre a cualquier profundidad. Una «/» al final lo limita a carpetas. Las líneas que empiezan por «#» son comentarios.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Prueba una ruta, por ejemplo Fotos/IMG_001.tmp", text: $probe).textFieldStyle(.roundedBorder)
                if !probe.isEmpty {
                    if edited.matcher(caseInsensitive: caseInsensitive).excludes(probe, isFolder: probe.hasSuffix("/")) {
                        Label("Excluido", systemImage: "nosign").foregroundStyle(.orange)
                    } else {
                        Label("Se sincroniza", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
            }
            Text("Cambiar las reglas no borra nada: lo que ya se sincronizó y ahora queda excluido se deja como está, en el Mac y en la nube.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    do { try manager.setExclusions(edited, for: mirror.id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
