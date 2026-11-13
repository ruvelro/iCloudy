import SwiftUI

/// Pairs two cloud folders in a two-way sync. Marked experimental where it is offered and in the sidebar.
struct CloudPairEditor: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var first: JobEndpoint?
    @State private var second: JobEndpoint?
    @State private var choosingFirst = false
    @State private var choosingSecond = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sincronizar dos carpetas de nubes").font(.title3)
            Label("Experimental", systemImage: "flask").foregroundStyle(.orange).font(.caption)
            Text("Las dos carpetas se mantienen iguales en los dos sentidos, con la misma línea base, papelera y freno de borrados que la sincronización con el Mac. Cada archivo que cambia pasa por este Mac, entero y de uno en uno, y la copia temporal se borra al momento. Un archivo cortado a medias se vuelve a copiar entero en la siguiente pasada, y la pasada no tiene informe por archivo; sí queda en el historial.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("Primera carpeta") {
                    HStack { Text(verbatim: first?.title ?? L("Sin elegir")).lineLimit(1).truncationMode(.middle); Button("Elegir…") { choosingFirst = true } }
                }
                LabeledContent("Segunda carpeta") {
                    HStack { Text(verbatim: second?.title ?? L("Sin elegir")).lineLimit(1).truncationMode(.middle); Button("Elegir…") { choosingSecond = true } }
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sincronizar") { create() }.keyboardShortcut(.defaultAction).disabled(first == nil || second == nil)
            }
        }
        .padding(20).frame(width: 540)
        .sheet(isPresented: $choosingFirst) { RemoteItemChooser(model: model, title: "Primera carpeta") { first = $0 } }
        .sheet(isPresented: $choosingSecond) { RemoteItemChooser(model: model, title: "Segunda carpeta") { second = $0 } }
    }

    private func create() {
        guard case .remote(let a, let folderA, _, _, let nameA)? = first, case .remote(let b, let folderB, _, _, let nameB)? = second,
              let accountA = model.accounts.first(where: { $0.id == a }), let accountB = model.accounts.first(where: { $0.id == b }) else { return }
        do {
            try model.mirrors.addPair(first: accountA, firstFolder: folderA, firstName: nameA, second: accountB, secondFolder: folderB, secondName: nameB)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
