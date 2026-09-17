import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TransferSettings(model: model).tabItem { Label("Transferencias", systemImage: "arrow.up.arrow.down") }
            StorageSettings(model: model).tabItem { Label("Almacenamiento", systemImage: "internaldrive") }
        }.frame(width: 540, height: 430)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.menuBar) private var menuBar = true
    @AppStorage(Prefs.previewFollowsSelection) private var previewFollows = true
    @AppStorage(Prefs.previewConsentMB) private var previewConsent = 100
    @AppStorage(Prefs.listingCache) private var listingCache = true
    @AppStorage(Prefs.storageStyle) private var storageStyle = StorageStyle.pie.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Mostrar iCloudy en la barra de menús", isOn: $menuBar)
                Toggle("Seguir la selección con la vista previa abierta", isOn: $previewFollows)
                Text("Con esto activado, recorrer la lista con la vista previa abierta descarga cada archivo por el que pasas, tras una pausa corta.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Preguntar antes de descargar más de") {
                    HStack {
                        TextField("", value: $previewConsent, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                        Text("MB")
                        Stepper("", value: $previewConsent, in: 10...2000, step: 10).labelsHidden()
                    }
                }
                Text("Se aplica a la vista previa. Un archivo de tamaño desconocido siempre pide confirmación.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Espacio de cada cuenta", selection: $storageStyle) {
                    ForEach(StorageStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Text("Cómo se dibuja el espacio en la barra lateral. Las dos formas muestran lo mismo —archivos, papelera y otros servicios— y las barras tienen todas el mismo ancho, así que se pueden comparar de un vistazo.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Recordar el último listado de cada carpeta", isOn: $listingCache)
                Text("Muestra al instante lo que había la última vez mientras el proveedor responde, y deja navegar sin conexión. Solo nombres y metadatos.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}

private struct TransferSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Prefs.historyLimit) private var historyLimit = 200

    var body: some View {
        Form {
            Section {
                LabeledContent("Transferencias guardadas en el historial") {
                    HStack {
                        TextField("", value: $historyLimit, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                        Stepper("", value: $historyLimit, in: 20...2000, step: 20).labelsHidden()
                    }
                }
                .onChange(of: historyLimit) { model.history.limit = max(20, historyLimit) }
                LabeledContent("En el historial ahora") { Text("\(model.history.entries.count)") }
            }
            Section {
                LabeledContent("Cola") {
                    HStack {
                        Button("Pausar todas") { model.queue.pauseAll() }.disabled(!model.queue.hasActive)
                        Button("Reanudar todas") { _ = model.queue.resumeAll() }
                    }
                }
                LabeledContent("Carpetas reflejadas") {
                    HStack {
                        Text("\(model.mirrors.mirrors.count)")
                        Button("Sincronizar ahora") { _ = model.syncAllMirrors() }.disabled(model.mirrors.mirrors.isEmpty)
                    }
                }
                Text("Las transferencias se reanudan solas al recuperar la red y al abrir la app quedan en pausa, nunca se pierden.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}

private struct StorageSettings: View {
    @ObservedObject var model: AppModel
    @State private var sizes: [Maintenance.Kind: Int64] = [:]
    @State private var measuring = true
    @State private var confirming: Maintenance.Kind?
    @State private var failure: String?

    private var total: Int64 { sizes.values.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Datos de iCloudy en este Mac").font(.headline)
                    Text(measuring ? L("Midiendo…") : L("\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) en total. Tus archivos descargados no están aquí: viven donde tú los guardaste."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Abrir carpeta") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.directory]) }
            }.padding(Layout.margin)
            Divider()
            List(Maintenance.Kind.allCases) { kind in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).fontWeight(.medium)
                        Text(kind.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(sizes[kind].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Vaciar") {
                        if kind.needsConfirmation { confirming = kind } else { clear(kind) }
                    }.disabled((sizes[kind] ?? 0) == 0 && kind != .spotlight)
                }.padding(.vertical, 4)
            }
            Divider()
            HStack {
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Vaciar todo lo recreable") { for kind in Maintenance.Kind.allCases where !kind.needsConfirmation { clear(kind) } }
            }.padding(Layout.margin)
        }
        .task { await measure() }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Vaciar", role: .destructive) { if let confirming { clear(confirming) }; confirming = nil }
            Button("Cancelar", role: .cancel) { confirming = nil }
        } message: { Text(confirming?.detail ?? "") }
    }

    private func measure() async {
        measuring = true
        let measured = (try? await blockingIO {
            Dictionary(uniqueKeysWithValues: Maintenance.Kind.allCases.map { ($0, Maintenance.size(of: $0)) })
        }) ?? [:]
        sizes = measured
        measuring = false
    }
    private func clear(_ kind: Maintenance.Kind) {
        failure = nil
        // Indexes kept in memory are cleared through their owner, which rewrites the file as it goes.
        switch kind {
        case .localCopies: model.localCopies.clear()
        case .history: model.history.clear()
        case .spotlight: model.spotlight.clear()
        default: break
        }
        do { try Maintenance.clear(kind) } catch { failure = error.localizedDescription }
        Task { await measure() }
    }
}
