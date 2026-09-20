import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

struct ConflictView: View {
    @ObservedObject var queue: TransferQueue
    let request: ConflictRequest
    @State private var applyToBatch = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Ya existe «\(request.name)»", systemImage: "doc.on.doc").font(.title2)
            Text(request.folder ? L("Combinar conserva los elementos exclusivos del destino y aplica las decisiones de conflicto a los archivos coincidentes.") : L("Reemplazar actualiza el contenido del archivo existente. Guardar otra copia conserva ambos.")).fixedSize(horizontal: false, vertical: true)
            Toggle("Aplicar a los siguientes conflictos de este lote", isOn: $applyToBatch)
            HStack {
                Button("Cancelar transferencia") { queue.cancel(request.transferID) }
                Spacer()
                Button("Omitir") { queue.resolve(.skip, applyToBatch: applyToBatch) }
                Button("Guardar otra copia") { queue.resolve(.copy, applyToBatch: applyToBatch) }.keyboardShortcut(.defaultAction)
                Button(request.folder ? "Combinar" : "Reemplazar") { queue.resolve(.replace, applyToBatch: applyToBatch) }.disabled(!request.canReplace)
            }
        }.padding(24).frame(width: 620).interactiveDismissDisabled()
    }
}
