import SwiftUI

/// Which accounts Spotlight knows whole, and how far a walk may go. By default Spotlight only finds what was opened
/// and the favorites; this adds the names of everything, never the contents.
struct SpotlightSettings: View {
    let model: AppModel
    @State private var enabled = SpotlightFullIndex.enabled
    @State private var limit = SpotlightFullIndex.limit

    var body: some View {
        Form {
            Section {
                Text("Spotlight encuentra siempre lo que has abierto y tus favoritos. Aquí puedes añadir los nombres de todo lo que hay en una cuenta, recorriéndola carpeta a carpeta hasta el límite. Nunca se indexa el contenido ni se descarga nada; se repite una vez al día al abrir iCloudy.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Stepper(value: $limit, in: 500...100_000, step: 500) {
                    Text("Como máximo \(limit) elementos por cuenta")
                }.onChange(of: limit) { _, value in SpotlightFullIndex.limit = value }
            }
            Section("Indexar la cuenta entera") {
                ForEach(model.accounts.filter { !$0.isCryptomatorVault }) { account in
                    HStack {
                        Toggle(isOn: Binding(get: { enabled.contains(account.id) }, set: { on in
                            if on { enabled.insert(account.id) } else { enabled.remove(account.id) }
                            model.setFullIndex(account, enabled: on)
                        })) {
                            VStack(alignment: .leading) {
                                Text(verbatim: model.accountTitle(account))
                                if let state = model.spotlight.fullState(account.id), let date = state.indexed {
                                    Text(state.truncated ? "\(state.entries.count) elementos (límite alcanzado) · \(date.formatted(date: .abbreviated, time: .shortened))"
                                                         : "\(state.entries.count) elementos · \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if enabled.contains(account.id) {
                            Button("Reindexar") { Task { await model.indexWholeAccount(account) } }.buttonStyle(.link)
                        }
                    }
                }
            }
        }.formStyle(.grouped).padding()
    }
}
