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

    private var verifyNote: LocalizedStringKey {
        mirror.mode == .twoWay
            ? "La verificación compara cada archivo de los dos lados por tamaño y suma, y avisa de lo que no coincide sin tocarlo."
            : "La verificación compara cada archivo de los dos lados por tamaño y suma; lo que falte o no coincida se vuelve a copiar en la siguiente pasada."
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
                Section("Comparación") {
                    Toggle("Comparar por suma de verificación donde el proveedor la dé", isOn: $options.compareChecksums)
                    Text("Un archivo con otra fecha pero el mismo contenido no se vuelve a copiar ni cuenta como conflicto. Donde no hay suma deciden el tamaño y la fecha, como siempre. Calcular la suma lee el archivo entero en el Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if mirror.mode == .upload {
                        Toggle("No subir lo que la nube ya tiene con la misma suma", isOn: $options.skipIdentical)
                    }
                    Picker("Verificar todo lo reflejado", selection: $options.verifyEvery) {
                        Text("Nunca").tag(TimeInterval?.none)
                        Text("Cada día").tag(TimeInterval?.some(86_400))
                        Text("Cada semana").tag(TimeInterval?.some(7 * 86_400))
                    }
                    Text(verifyNote)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if mirror.mode != .twoWay {
                    Section("Borrados") {
                        Toggle("Espejo exacto: llevar también los borrados", isOn: $options.exact)
                        Text(mirror.mode == .download
                             ? LocalizedStringKey("Lo que se borre en la nube se envía también a la Papelera del Mac, y lo que cambies aquí vuelve a quedar como en la nube (tu versión va a la Papelera). Solo se toca lo que trajo este reflejo y nadie cambió aquí después; lo que añadas tú se queda. Si fuera a borrar la mayor parte de la carpeta, se detiene y pregunta.")
                             : LocalizedStringKey("Lo que borres en el Mac se envía también a la papelera de la nube. Solo se borra lo que subió este reflejo y nadie cambió allí después; lo demás de la carpeta remota se queda. Si fuera a borrar la mayor parte, se detiene y pregunta. Revisa «Cambios pendientes» antes de activarlo."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
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
