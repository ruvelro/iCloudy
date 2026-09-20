import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Observes the queue directly: progress ticks re-render this panel only, not the whole explorer.
struct TransferPanel: View {
    let model: AppModel
    @ObservedObject var queue: TransferQueue
    @ObservedObject var history: TransferHistory
    @State private var showHistory = false
    /// The drawer is built when it opens and thrown away when it closes, so this always starts on what is moving.
    @State private var tab = TransferTab.active
    @State private var errorFilter = TransferErrorFilter.all
    @State private var historyFilter = TransferHistoryFilter.all
    @State private var confirmCancelActive = false
    /// The section bar holds a count on one tab and a segmented filter on another. Reserving one height for both
    /// keeps the list below it still when the tab changes; the measurement lives in a test.
    static let sectionBarHeight: CGFloat = 20

    private var active: [Transfer] { queue.items.filter { !$0.finished } }
    private var completed: [Transfer] { queue.items.filter { $0.state == .completed } }
    private var errored: [Transfer] { queue.items.filter { errorFilter.matches($0.state) } }
    private var historyEntries: [HistoryEntry] {
        guard historyFilter == .today else { return history.entries }
        let today = Calendar.current.startOfDay(for: Date())
        return history.entries.filter { $0.finishedAt >= today }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transferencias").font(.headline)
            RemoteCopyRows(copies: model.remoteCopies)
            Picker("", selection: $tab) {
                ForEach(TransferTab.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            // Every tab owns the row under it: what it is counting or filtering, and its own broom. Clearing one
            // list never touches another, which is the whole point of having taken them apart.
            sectionBar.frame(height: Self.sectionBarHeight)
            content.frame(maxHeight: .infinity)
            if let message = queue.persistenceError ?? (tab == .history ? history.persistenceError : nil) {
                HStack(alignment: .top) {
                    Text(message).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if queue.persistenceError != nil, queue.canDiscardSavedQueue {
                        Button("Descartar cola guardada") { queue.discardSavedQueue() }.font(.caption)
                            .help("Aparta el archivo dañado con una copia junto al original y permite crear transferencias nuevas.")
                    }
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.quaternary.opacity(0.4))
            .sheet(isPresented: $showHistory) { TransferHistoryView(model: model, history: history) }
            .confirmationDialog("¿Cancelar las transferencias en curso?", isPresented: $confirmCancelActive, titleVisibility: .visible) {
                Button("Cancelar \(active.count) y vaciar la lista", role: .destructive) { queue.cancelActive() }
                Button("Dejarlas como están", role: .cancel) {}
            } message: {
                Text("Se detiene lo que está en marcha y se quitan también las que esperan o están en pausa. Lo ya subido o descargado se conserva; lo que quedaba a medias habrá que empezarlo de nuevo.")
            }
    }

    /// A narrow column, so the actions are icons with their names in the tooltip rather than a row of links.
    @ViewBuilder private var sectionBar: some View {
        HStack(spacing: 6) {
            switch tab {
            case .active:
                Text(tally(active.count, L("1 en curso"), L("\(active.count) en curso"), L("Nada en curso")))
                Spacer(minLength: 0)
                Button { queue.pauseAll() } label: { Image(systemName: "pause.circle") }
                    .accessibilityLabel("Pausar todas las transferencias")
                    .buttonStyle(.borderless).help("Pausar todas")
                    .disabled(!queue.items.contains { [.running, .queued].contains($0.state) })
                broom(L("Cancelar y quitar todo lo que hay en curso"), enabled: !active.isEmpty) { confirmCancelActive = true }
            case .done:
                Text(tally(completed.count, L("1 finalizada"), L("\(completed.count) finalizadas"), L("Nada finalizado")))
                Spacer(minLength: 0)
                broom(L("Quitar las finalizadas del panel; el historial las conserva"), enabled: !completed.isEmpty) { queue.clearCompleted() }
            case .error:
                Picker("", selection: $errorFilter) {
                    ForEach(TransferErrorFilter.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                broom(clearErroredHelp, enabled: !errored.isEmpty) {
                    switch errorFilter {
                    case .all: queue.clearErrored()
                    case .failed: queue.clearFailed()
                    case .cancelled: queue.clearCancelled()
                    }
                }
            case .history:
                Picker("", selection: $historyFilter) {
                    ForEach(TransferHistoryFilter.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
                Spacer(minLength: 0)
                Button { showHistory = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Abrir el historial completo")
                    .buttonStyle(.borderless).help("Abrir el historial completo")
                broom(historyFilter == .today ? L("Borrar del historial lo de hoy") : L("Vaciar el historial"),
                      enabled: !historyEntries.isEmpty) {
                    if historyFilter == .today { history.clearToday() } else { history.clear() }
                }
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .active:
            queueList(active, reorderable: true).overlay {
                if active.isEmpty {
                    empty("No hay transferencias", "Aquí aparecen las copias y las subidas mientras se hacen.", symbol: "arrow.up.arrow.down.circle")
                }
            }
        case .done:
            queueList(completed, reorderable: false).overlay {
                if completed.isEmpty {
                    empty("Nada terminado todavía", "Lo que acabe bien se queda aquí hasta que lo quites.", symbol: "checkmark.circle")
                }
            }
        case .error:
            queueList(errored, reorderable: false).overlay {
                if errored.isEmpty {
                    empty(errorFilter == .cancelled ? L("No has cancelado nada") : L("Nada ha fallado"),
                          L("Lo que falle o canceles se queda aquí, con su botón de reintentar."),
                          symbol: "exclamationmark.triangle")
                }
            }
        case .history:
            historyList.overlay {
                if historyEntries.isEmpty {
                    empty(historyFilter == .today ? L("Hoy no se ha completado nada") : L("El historial está vacío"),
                          L("Se guardan las \(history.limit) transferencias completadas más recientes, aunque se limpien del panel."),
                          symbol: "clock.arrow.circlepath")
                }
            }
        }
    }

    /// Queue order, oldest first: the running job sits on top and waiting jobs can be dragged to re-prioritise.
    /// Only the in-progress tab reorders; on the others the order is already history.
    private func queueList(_ transfers: [Transfer], reorderable: Bool) -> some View {
        List {
            ForEach(transfers) { transfer in
                TransferCard(model: model, queue: queue, transfer: transfer)
                    .moveDisabled(!reorderable || !queue.isMovable(transfer))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
            }
            .onMove { from, to in
                guard reorderable else { return }
                queue.moveActive(fromOffsets: from, toOffset: to)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
    }

    private var historyList: some View {
        List(historyEntries) { entry in
            HStack(spacing: 7) {
                Image(systemName: entry.direction == .download ? "arrow.down.circle.fill" : (entry.direction == .transfer ? "cloud.fill" : "arrow.up.circle.fill"))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Text(entry.destination).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(Calendar.current.isDateInToday(entry.finishedAt)
                     ? entry.finishedAt.formatted(date: .omitted, time: .shortened)
                     : entry.finishedAt.formatted(date: .numeric, time: .omitted))
                    .foregroundStyle(.tertiary).monospacedDigit()
            }.font(.caption2)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
                .help(entry.summary.isEmpty ? entry.destination : entry.summary)
                .contextMenu {
                    if entry.direction == .download {
                        Button("Mostrar en el Finder") { model.reveal(entry) }
                    } else {
                        Button("Ir a la carpeta") { model.openFolder(accountID: entry.targetAccountID ?? entry.accountID, folderID: entry.parent) }
                    }
                }
        }.listStyle(.plain).scrollContentBackground(.hidden)
    }

    private func broom(_ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }
            .buttonStyle(.borderless).disabled(!enabled).help(help)
    }
    private var clearErroredHelp: String {
        switch errorFilter {
        case .all: return L("Quitar del panel las fallidas y las canceladas")
        case .failed: return L("Quitar del panel las fallidas")
        case .cancelled: return L("Quitar del panel las canceladas")
        }
    }
    private func tally(_ count: Int, _ one: String, _ many: String, _ none: String) -> String {
        switch count {
        case 0: return none
        case 1: return one
        default: return many
        }
    }
    private func empty(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(detail).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }.padding(.horizontal, 8).allowsHitTesting(false)
    }
}

private struct RemoteCopyRows: View {
    @ObservedObject var copies: RemoteCopies
    var body: some View {
        if !copies.items.isEmpty {
            DisclosureGroup("Copias en OneDrive (\(copies.items.count))") {
                ScrollView {
                    ForEach(copies.items) { item in
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(1)
                            Text(label(item.state)).font(.caption).foregroundStyle(.secondary)
                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxHeight: 120)
            }.font(.caption)
        }
    }
    private func label(_ state: RemoteCopy.State) -> String {
        switch state {
        case .starting: return L("Enviando solicitud…")
        case .monitoring: return L("Esperando confirmación de OneDrive…")
        case .completed: return L("Copia completada")
        case .failed: return L("Copia fallida")
        case .uncertain: return L("Resultado sin confirmar: revisa el destino")
        }
    }
}
