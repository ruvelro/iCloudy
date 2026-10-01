import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// One transfer, as a card.
///
/// The old row was a stack of five short lines of grey text and a bare progress bar, which at the width of this
/// column read as a paragraph rather than as a thing in motion. A card gives it an edge, puts the percentage where
/// the eye already goes, and — the part that was missing altogether — shows the icon of the cloud the bytes are
/// going to, so a queue with three accounts in it can be read without opening anything.
struct TransferCard: View {
    let model: AppModel
    @ObservedObject var queue: TransferQueue
    let transfer: Transfer
    @State private var showReport = false

    /// Where the bytes end up: the far account of a cross-cloud copy, the target of an upload, and for a download
    /// the source, because that is the only cloud involved.
    private var cloud: Account? {
        let id = transfer.targetAccountID ?? transfer.accountID
        return model.accounts.first { $0.id == id }
    }
    private var accent: Color {
        if transfer.failed { return .red }
        if transfer.state == .completed { return .green }
        if transfer.state == .paused { return .orange }
        return .accentColor
    }
    private var badge: String {
        switch transfer.direction {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .transfer: return "arrow.left.arrow.right"
        }
    }
    private var header: some View {
        HStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                if let cloud {
                    AccountIcon(account: cloud, appearance: model.appearance(for: cloud), size: 20)
                } else {
                    Image(systemName: "cloud.fill").font(.caption).foregroundStyle(.tertiary).frame(width: 20)
                }
                Image(systemName: badge)
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    .padding(2).background(accent, in: Circle())
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: 3, y: 2)
            }
            Text(transfer.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if transfer.finished {
                Image(systemName: transfer.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(transfer.failed ? .red : .green)
            } else if transfer.progress > 0 {
                Text(transfer.progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if hasReport {
                Button("Ver informe") { showReport = true }
                    .help("Qué ha pasado con cada archivo, y qué hay ya en el destino")
            }
            if transfer.needsRestart, transfer.state == .failed {
                Button("Empezar de cero") { queue.restartFromZero(transfer.id) }
                    .help("Sube entero el archivo que cambió, tal como está ahora. Lo ya completado no se repite.")
            } else if [.failed, .paused, .cancelled].contains(transfer.state) {
                Button(transfer.state == .failed ? "Reintentar" : "Reanudar") { queue.retry(transfer.id) }
            }
            if queue.isMovable(transfer) {
                Button { queue.prioritize(transfer.id) } label: { Image(systemName: "arrow.up.to.line") }
                    .accessibilityLabel("Pasar al principio")
                    .help("Pasar al principio de la cola")
                Button { queue.deprioritize(transfer.id) } label: { Image(systemName: "arrow.down.to.line") }
                    .accessibilityLabel("Pasar al final")
                    .help("Pasar al final de la cola")
            }
            if [.running, .queued].contains(transfer.state) {
                Button { queue.cancel(transfer.id, pause: true) } label: { Image(systemName: "pause.circle") }.help("Pausar")
                    .accessibilityLabel("Pausar")
                Button { queue.cancel(transfer.id) } label: { Image(systemName: "xmark.circle") }.help("Cancelar")
                    .accessibilityLabel("Cancelar")
                if queue.pendingBatchMates(of: transfer.id) > 0 {
                    Button("Cancelar el resto") { queue.cancelBatch(transfer.batchID) }
                        .help("Cancela este elemento y los \(queue.pendingBatchMates(of: transfer.id)) pendientes que se añadieron con él")
                }
            }
        }.buttonStyle(.borderless)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            Text(transfer.destination).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(transfer.status).foregroundStyle(transfer.failed ? .red : .secondary).lineLimit(2)
                Spacer(minLength: 0)
                Text(transfer.metrics).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
            }
            if !transfer.finished {
                // A rail is always drawn, so a queued item has the same height as a running one and the list does
                // not jump every time one starts.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.22)).frame(height: 4)
                    GeometryReader { geometry in
                        Capsule().fill(accent).frame(width: geometry.size.width * transfer.progress, height: 4)
                    }.frame(height: 4)
                }
            }
            if !actionsAreEmpty { actions.padding(.top, 1) }
        }
        .font(.caption)
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(transfer.state == .running ? 0.35 : 0.14), lineWidth: 1))
        .textSelection(.enabled)
        .sheet(isPresented: $showReport) { TransferReportView(model: model, queue: queue, batchID: transfer.batchID) }
    }
    private var actionsAreEmpty: Bool {
        transfer.state == .completed && !queue.isMovable(transfer) && !hasReport
    }
    /// A report is worth a button once a job with more than one file, or a batch of several, has stopped moving.
    private var hasReport: Bool {
        guard ![.queued, .running].contains(transfer.state) else { return false }
        return transfer.report.count > 1 || queue.items.contains { $0.batchID == transfer.batchID && $0.id != transfer.id }
    }
}
