import SwiftUI

/// The settings of one mirror or sync: what happens on a conflict, deletions, comparison and schedule. Exclusions
/// and filters have their own sheet, with a way to try a path against them.
struct MirrorSettingsSheet: View {
    let mirror: FolderMirror
    let manager: MirrorManager
    @Environment(\.dismiss) private var dismiss
    @State private var options: MirrorOptions

    init(mirror: FolderMirror, manager: MirrorManager) {
        self.mirror = mirror
        self.manager = manager
        _options = State(initialValue: mirror.options)
    }

    private var policy: Binding<ConflictPolicy> {
        Binding(get: { options.conflictPolicy ?? mirror.conflictPolicy }, set: { options.conflictPolicy = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ajustes de «\(mirror.localURL.lastPathComponent)»").font(.headline)
            Form {
                Section("Conflictos") {
                    Picker("Si un archivo cambió en los dos lados", selection: policy) {
                        ForEach(ConflictPolicy.allCases) { Text(verbatim: mirror.title(of: $0)).tag($0) }
                    }
                    Text(verbatim: mirror.explanation(of: policy.wrappedValue))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { manager.setOptions(options, for: mirror.id); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

extension FolderMirror {
    /// A policy named after the two ends of this mirror.
    func title(of policy: ConflictPolicy) -> String { policy.title }
    /// What the policy does for this kind of mirror, in a sentence.
    func explanation(of policy: ConflictPolicy) -> String {
        switch (mode, policy) {
        case (.twoWay, .keepBoth): return L("La versión del Mac se renombra con «conflicto» y la fecha, y las dos quedan en los dos lados.")
        case (.twoWay, .ask): return L("El archivo se deja como está en los dos lados hasta que elijas qué hacer en «Cambios pendientes».")
        case (_, .keepBoth): return L("La que llega se guarda con otro nombre, «(2)», junto a la que ya estaba.")
        case (_, .ask): return L("Se pregunta en cada archivo, como en cualquier transferencia.")
        case (_, .newestWins): return L("Gana la que tenga la fecha de modificación más reciente. Si falta alguna fecha, se conservan las dos o se pregunta.")
        case (_, .thisSideWins): return L("La del Mac sustituye a la otra. La que pierde va a la papelera cuando se puede.")
        case (_, .otherSideWins): return L("La de la nube sustituye a la otra. La que pierde va a la papelera cuando se puede.")
        }
    }
}
