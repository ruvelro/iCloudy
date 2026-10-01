import SwiftUI
import AppKit

/// The badge of an item kept offline. Same size and place as the cloud/Mac indicator, with its own symbols, so the two
/// read as one family: filled when the copy is ready, an arrow while it updates, orange when behind, red on error.
struct OfflineBadge: View {
    let status: OfflineStatus
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size))
            .foregroundStyle(tint)
            .help(help)
            .accessibilityLabel(status.label)
    }
    private var tint: Color {
        switch status {
        case .available: return .accentColor
        case .updating: return .secondary
        case .outdated: return .orange
        case .failed: return .red
        }
    }
    private var help: String {
        switch status {
        case .available: return L("Disponible sin conexión. Se abre en solo lectura desde la copia de este Mac.")
        case .updating: return L("Actualizando la copia sin conexión…")
        case .outdated: return L("La copia sin conexión está desactualizada: la nube tiene una versión más reciente. Se actualizará en la próxima comprobación.")
        case .failed(let reason): return L("Error en la copia sin conexión: \(reason)")
        }
    }
}

/// The single indicator slot of a row: the user's own copy on this Mac when there is one, otherwise the managed
/// offline copy, otherwise the hollow cloud. Folders only ever show the offline badge, the one thing that can be
/// claimed about everything inside them.
struct FileStateBadge: View {
    let file: CloudFile
    let local: LocalCopyStatus
    let offline: OfflineStatus?
    var size: CGFloat = 13
    var body: some View {
        if let offline, file.isFolder || local == .cloudOnly { OfflineBadge(status: offline, size: size) }
        else if file.isFolder { Color.clear }
        else { LocalCopyBadge(status: local, size: size) }
    }
}

extension ExplorerView {
    /// The offline entries of a file's context menu.
    @ViewBuilder func offlineActions(_ file: CloudFile) -> some View {
        if model.isPinnedOffline(file) {
            Button("Quitar de Sin conexión") { model.unpinOffline(file) }
                .help("Borra la copia de este Mac. El archivo de la nube no cambia.")
        } else if !file.isGoogleDocument {
            Button("Disponible sin conexión") { model.pinOffline(file) }
                .help("Guarda una copia de solo lectura en este Mac y la mantiene al día")
        }
        if !file.isFolder, model.hasOfflineCopy(file) {
            Button("Abrir la copia sin conexión") { model.openOffline(file) }
                .help("Se abre en solo lectura. Los cambios no se suben a la nube: guarda una copia o usa la sincronización en ambos sentidos.")
            Button("Guardar una copia…") { Task { await model.saveOfflineCopy(file) } }
        }
    }
}

/// Sidebar section with everything kept offline: what it takes, how it stands, and the way to update or remove it.
struct OfflineList: View {
    let model: AppModel
    @ObservedObject var store: OfflineStore
    @State private var removing: OfflinePin?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 8)
            HStack {
                Text("SIN CONEXIÓN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !store.refreshing.isEmpty { ProgressView().controlSize(.mini) }
                Button { model.refreshOfflineNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Actualizar ahora").accessibilityLabel("Actualizar ahora")
                    .disabled(store.pins.isEmpty || !store.refreshing.isEmpty)
            }
            Text(usage).font(.caption2).foregroundStyle(.secondary)
            if store.overBudget {
                Label("Lo marcado supera el límite de espacio. No se borra nada por su cuenta: sube el límite en Configuración o quita elementos.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.notices) { notice in
                HStack(alignment: .top) {
                    Text(notice.text).font(.caption2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.dismiss(notice) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Descartar aviso")
                }.padding(6).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(store.pins) { pin in
                VStack(alignment: .leading, spacing: 2) {
                    Label(pin.file.name, systemImage: pin.file.isFolder ? "folder" : "doc").lineLimit(1)
                    Text(detail(pin)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(state(pin)).font(.caption2).foregroundStyle(pin.lastError == nil ? Color.secondary : Color.red).lineLimit(2)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .contextMenu {
                    if !pin.file.isFolder {
                        Button("Abrir la copia sin conexión") { model.openOffline(pin.file, accountID: pin.accountID) }
                            .disabled(!model.hasOfflineCopy(pin.file, accountID: pin.accountID))
                        Button("Guardar una copia…") { Task { await model.saveOfflineCopy(pin.file, accountID: pin.accountID) } }
                            .disabled(!model.hasOfflineCopy(pin.file, accountID: pin.accountID))
                    }
                    Button("Mostrar en el Finder") { model.revealOffline(pin) }
                    Button("Ir a la ubicación en la nube") { model.openOfflineLocation(pin) }
                        .disabled(!model.isOnline || (!pin.file.isFolder && pin.parentID == nil))
                    Button("Actualizar ahora") { model.refreshOfflineNow(pin) }.disabled(store.refreshing.contains(pin.folder))
                    Divider()
                    Button("Quitar…", role: .destructive) { removing = pin }
                }
            }
            Text("Copias de solo lectura: lo que edites se guarda aparte y no se sube a la nube. Para eso está la sincronización en ambos sentidos.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("¿Quitar «\(removing?.file.name ?? "")» de Sin conexión?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Quitar", role: .destructive) { if let removing { model.removeOfflinePin(removing) }; removing = nil }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: { Text("Se borra la copia de este Mac (\(ByteCountFormatter.string(fromByteCount: removing.map(store.usage) ?? 0, countStyle: .file))). El archivo de la nube no cambia.") }
    }

    private var usage: String {
        let used = ByteCountFormatter.string(fromByteCount: store.bytes(), countStyle: .file)
        guard let budget = store.budget() else { return L("\(used) en uso · sin límite") }
        return L("\(used) en uso de \(ByteCountFormatter.string(fromByteCount: budget, countStyle: .file))")
    }
    private func detail(_ pin: OfflinePin) -> String {
        let account = model.accounts.first { $0.id == pin.accountID }.map(model.accountTitle) ?? pin.accountID
        return account + " · " + ByteCountFormatter.string(fromByteCount: store.usage(of: pin), countStyle: .file)
    }
    private func state(_ pin: OfflinePin) -> String {
        if store.refreshing.contains(pin.folder) { return L("Actualizando…") }
        if let error = pin.lastError { return L("Error: \(error)") }
        guard let date = pin.lastRefresh else { return L("Pendiente de descargar") }
        return L("Actualizado \(date.formatted(.relative(presentation: .named)))")
    }
}

/// The "Sin conexión" tab of the settings window.
struct OfflineSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: OfflineStore
    @AppStorage(OfflineSettings.budgetKey) private var budgetGB = 10
    @AppStorage(OfflineSettings.refreshKey) private var refreshMinutes = 60
    @AppStorage(OfflineSettings.keepPreviewsKey) private var keepPreviews = true

    var body: some View {
        Form {
            Section {
                Picker("Espacio máximo", selection: $budgetGB) {
                    ForEach(OfflineSettings.budgetChoices, id: \.self) { value in
                        if value == 0 { Text("Sin límite").tag(value) } else { Text("\(value) GB").tag(value) }
                    }
                }.onChange(of: budgetGB) { store.enforceBudget() }
                LabeledContent("Marcado sin conexión") { Text(ByteCountFormatter.string(fromByteCount: store.pinnedBytes, countStyle: .file)).monospacedDigit() }
                LabeledContent("Vistas previas guardadas") { Text(ByteCountFormatter.string(fromByteCount: store.cachedBytes, countStyle: .file)).monospacedDigit() }
                if store.overBudget {
                    Label("Lo marcado sin conexión ya supera este límite. No se borra nada marcado: sube el límite o quita elementos desde la barra lateral.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("Cuando hace falta sitio se borran primero las vistas previas guardadas que hace más tiempo que no abres. Lo marcado como disponible sin conexión nunca se borra solo: si no cabe, iCloudy lo dice y no lo descarga.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Comprobar cambios", selection: $refreshMinutes) {
                    Text("Solo al abrir la app y al volver la red").tag(0)
                    Text("Cada 15 minutos").tag(15)
                    Text("Cada hora").tag(60)
                    Text("Cada 6 horas").tag(360)
                    Text("Cada día").tag(1440)
                }
                LabeledContent("Elementos marcados") {
                    HStack {
                        Text("\(store.pins.count)")
                        Button("Actualizar ahora") { model.refreshOfflineNow() }.disabled(store.pins.isEmpty || !store.refreshing.isEmpty)
                    }
                }
                Text("También se actualiza un elemento en cuanto un listado muestra que su tamaño, su fecha o su suma han cambiado. Cada copia se comprueba con el tamaño y la suma del proveedor antes de sustituir a la anterior.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Guardar las vistas previas para verlas sin conexión", isOn: $keepPreviews)
                Button("Vaciar vistas previas guardadas") { store.clearCache() }.disabled(store.cachedBytes == 0)
                Text("Lo que ya se descargó para la vista previa se conserva dentro de este límite, en lugar de tirarlo al cerrar el visor. No se descarga nada más para esto.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("Las copias sin conexión son de solo lectura. «Abrir la copia sin conexión» la abre sin permiso para guardar encima, y «Guardar una copia…» deja una editable donde elijas. Nada de eso se sube a la nube: para editar y sincronizar, usa «Sincronizar en ambos sentidos con una carpeta local…».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}
