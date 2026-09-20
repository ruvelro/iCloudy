import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Finished transfers, newest first, with a way back to where each one landed.
struct TransferHistoryView: View {
    let model: AppModel
    @ObservedObject var history: TransferHistory
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Historial de transferencias").font(.title2)
                Spacer()
                Button("Vaciar historial") { history.clear() }.disabled(history.entries.isEmpty)
            }
            Text("Se conservan las \(history.limit) transferencias completadas más recientes, aunque se limpien del panel. No incluye las canceladas ni las fallidas.").font(.caption).foregroundStyle(.secondary)
            List(history.entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.direction == .download ? "arrow.down.circle" : (entry.direction == .transfer ? "cloud" : "arrow.up.circle")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).fontWeight(.medium)
                        Text(entry.destination).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(entry.finishedAt.formatted(date: .abbreviated, time: .shortened) + " · " + ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file) + (entry.summary.isEmpty ? "" : " · " + entry.summary))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if entry.direction == .download {
                        Button("Mostrar en el Finder") { model.reveal(entry) }
                    } else {
                        Button("Ir a la carpeta") { model.openFolder(accountID: entry.targetAccountID ?? entry.accountID, folderID: entry.parent); dismiss() }
                    }
                }.padding(.vertical, 2)
            }
            .overlay { if history.entries.isEmpty { Text("Todavía no hay transferencias completadas.").foregroundStyle(.secondary) } }
            if let message = history.persistenceError { Text(message).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 640, height: 460)
    }
}
