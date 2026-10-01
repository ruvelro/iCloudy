import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The per-file report of a batch, opened from any of its cards. It answers the question a long transfer leaves
/// behind — what is at the destination now, and what is not — and exports the answer for whoever needs it.
struct TransferReportView: View {
    let model: AppModel
    @ObservedObject var queue: TransferQueue
    let batchID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var filter: FileOutcome?
    @State private var exportMessage: String?
    @State private var checking: Task<Void, Never>?
    @State private var checked = (done: 0, total: 0)
    @State private var recoveryMessage: String?

    private var jobs: [Transfer] { queue.items.filter { $0.batchID == batchID } }
    private var report: TransferReport { TransferReport(jobs: jobs) }
    private var title: String {
        jobs.count == 1 ? jobs[0].name : L("\(jobs.count) elementos")
    }

    var body: some View {
        let report = report
        let shown = filter.map { outcome in report.lines.filter { $0.record.outcome == outcome } } ?? report.lines
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Informe de la transferencia").font(.title2)
                Text(title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text(Self.explanation(report)).fixedSize(horizontal: false, vertical: true)
            if report.incomplete {
                Label("Esta transferencia empezó sin plan y se detuvo antes de terminar: solo se listan los archivos a los que llegó.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Picker("Mostrar", selection: $filter) {
                    Text("Todos (\(report.lines.count))").tag(FileOutcome?.none)
                    ForEach(FileOutcome.allCases.filter { report.count($0) > 0 }) { outcome in
                        Text("\(outcome.title) (\(report.count(outcome)))").tag(FileOutcome?.some(outcome))
                    }
                }.frame(maxWidth: 320)
                Spacer()
            }
            List(shown) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.record.outcome.symbol).foregroundStyle(Self.tint(line.record.outcome)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.record.path).lineLimit(1).truncationMode(.middle)
                        if let reason = line.record.reason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(line.record.outcome.title).font(.caption).foregroundStyle(.secondary)
                    Text(line.record.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary).frame(width: 70, alignment: .trailing)
                }.textSelection(.enabled)
            }.frame(minHeight: 240)
            recovery(report)
            HStack {
                Button("Exportar CSV…") { export(report, csv: true) }
                Button("Exportar JSON…") { export(report, csv: false) }
                if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 680, height: 600)
            .onDisappear { checking?.cancel() }
    }

    /// The two ways out of a transfer that did not end well, with what each of them will and will not touch.
    @ViewBuilder private func recovery(_ report: TransferReport) -> some View {
        let busy = jobs.contains { [.queued, .running].contains($0.state) }
        let checkable = report.copied + report.count(.uncertain) > 0
        let recoverable = !queue.recoverable(batchID).isEmpty
        if recoverable || checkable {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if recoverable {
                        Button("Reintentar solo lo pendiente") {
                            let count = queue.retryPending(batchID)
                            recoveryMessage = L("\(count) en cola de nuevo. Lo que ya está en el destino no se vuelve a copiar.")
                        }.disabled(checking != nil || busy)
                    }
                    if checkable {
                        if checking == nil {
                            Button("Verificar lo copiado") { verify() }.disabled(busy)
                        } else {
                            ProgressView(value: Double(checked.done), total: Double(max(1, checked.total))).frame(width: 120)
                            Text("Comprobando \(checked.done) de \(checked.total)…").font(.caption).monospacedDigit()
                            Button("Detener") { checking?.cancel() }
                        }
                    }
                    Spacer()
                }
                Text(recoveryMessage ?? L("Reintentar solo vuelve a transferir lo fallido y lo pendiente; lo copiado y lo omitido no se repiten. Verificar pregunta al destino por cada archivo copiado y compara su tamaño y, si el proveedor la da, su suma; lo que falte o no coincida vuelve a quedar pendiente."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func verify() {
        recoveryMessage = nil
        checked = (0, 0)
        checking = Task {
            do {
                let summary = try await queue.verifyCopied(batchID) { done, total in checked = (done, total) }
                recoveryMessage = summary.text
            } catch is CancellationError {
                recoveryMessage = L("Comprobación detenida. Lo ya comprobado queda anotado en el informe.")
            } catch {
                recoveryMessage = Task.isCancelled ? L("Comprobación detenida. Lo ya comprobado queda anotado en el informe.") : error.localizedDescription
            }
            checking = nil
        }
    }

    /// What is already at the destination, said first: it is what decides whether repeating anything is needed.
    static func explanation(_ report: TransferReport) -> String {
        let size = ByteCountFormatter.string(fromByteCount: report.copiedBytes, countStyle: .file)
        var parts = [report.copied == 1 ? L("1 archivo ya está en el destino (\(size)).") : L("\(report.copied) archivos ya están en el destino (\(size)).")]
        let verified = report.count(.verified)
        if verified > 0 { parts.append(L("\(verified) de ellos se comprobaron con la suma del proveedor.")) }
        let skipped = report.count(.skipped) + report.count(.excluded)
        if skipped > 0 { parts.append(L("\(skipped) se dejaron fuera a propósito.")) }
        if report.outstanding > 0 { parts.append(L("Quedan \(report.outstanding) por transferir o por comprobar.")) }
        return parts.joined(separator: " ")
    }
    static func tint(_ outcome: FileOutcome) -> Color {
        switch outcome {
        case .verified: return .green
        case .unverified, .exported: return .accentColor
        case .skipped, .excluded, .pending: return .secondary
        case .failed: return .red
        case .uncertain: return .orange
        }
    }

    private func export(_ report: TransferReport, csv: Bool) {
        let panel = NSSavePanel()
        let base = FileNames.safe(L("Informe de \(title)"))
        panel.nameFieldStringValue = base + (csv ? ".csv" : ".json")
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            // The byte order mark is what makes Excel read the accents of a UTF-8 CSV instead of guessing Latin-1.
            let data = csv ? Data([0xEF, 0xBB, 0xBF]) + Data(report.csv().utf8) : try report.json()
            try data.write(to: destination, options: .atomic)
            exportMessage = L("Guardado")
        } catch { exportMessage = error.localizedDescription }
    }
}
