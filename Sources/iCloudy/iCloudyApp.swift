import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

@main
struct iCloudyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    var body: some Scene {
        // A single window: every window of a WindowGroup would mirror the same account, folder and selection.
        Window("iCloudy", id: "explorer") {
            ExplorerView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.model = model }
                // Opening a Spotlight result brings the app forward on the indexed item.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    model.openSpotlightItem(identifier: id)
                }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Añadir cuenta…") { model.showConnect = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Subir archivos…") { Task { await model.pickUpload() } }.disabled(!model.canWrite)
                Button("Subir el portapapeles") { model.uploadFromPasteboard() }.disabled(!model.canWrite)
                Button("Buscar en todas las nubes") { model.preview.close(); model.showGlobalSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Mostrar iCloudy en la barra de menús", isOn: $menuBarEnabled)
            }
        }
        MenuBarExtra("iCloudy", systemImage: "cloud.fill", isInserted: $menuBarEnabled) {
            MenuBarContent(model: model, queue: model.queue)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { services.model = model } }
    private let services = ServicesProvider()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // "Subir a iCloudy" in any app's Services menu, declared in Info.plist and handled in this process.
        services.model = model
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
    /// Files dropped on the Dock icon, or opened with "Abrir con", go to the folder currently shown.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, let model else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in model.enqueueUploads(files) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasActiveTransfers == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Hay transferencias pendientes")
        alert.informativeText = L("La cola se guardará en pausa. Al volver a abrir podrás reanudarla. Los elementos ya completados se conservarán.")
        alert.addButton(withTitle: L("Continuar en iCloudy"))
        alert.addButton(withTitle: "Salir")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        model?.queue.pauseAll()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.queue.flush() // coalesced checkpoints still in memory
        model?.preview.close()
    }
}

struct ExplorerView: View {
    @ObservedObject var model: AppModel
    @State private var selected: Set<CloudFile.ID> = []
    @State private var dropTarget = false
    @State private var showTransfers = true
    @State private var confirmDisconnect = false
    @State private var disconnectTarget: Account?
    @State private var previewFollow: Task<Void, Never>?
    @FocusState private var gridFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Label("iCloudy", systemImage: "cloud.fill")
                    .font(.system(size: 24, weight: .semibold)).padding(.horizontal, 12).padding(.top, 20)
                Text("TUS NUBES").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
                Button { model.preview.close(); model.showGlobalSearch = true } label: {
                    Label("Buscar en todas las nubes", systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(model.showGlobalSearch ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(model.accounts) { account in
                            Button { model.select(account.id) } label: {
                                HStack(spacing: 10) {
                                    AccountIcon(account: account, appearance: model.appearance(for: account))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.accountTitle(account)).fontWeight(.medium).foregroundStyle(model.appearance(for: account).tint.color).lineLimit(1)
                                        Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        if !model.appearance(for: account).alias.isEmpty { Text(account.cloud.title).font(.caption2).foregroundStyle(.secondary) }
                                        StorageUsageView(account: account, state: model.storageQuotas[account.id]).padding(.top, 3)
                                        if model.isExpired(account) {
                                            Label("Sesión caducada · Vuelve a conectar", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).contentShape(Rectangle())
                                    .background(model.selectedAccountID == account.id && !model.showGlobalSearch ? model.appearance(for: account).tint.color.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    if model.isExpired(account) {
                                        Button("Volver a conectar…") { Task { await model.reconnect(account) } }.disabled(model.connecting)
                                        Divider()
                                    }
                                    Button("Personalizar nube…") { model.appearanceAccount = account }
                                    Button("Actualizar espacio") { model.refreshStorage(account, force: true) }
                                    Divider()
                                    Button("Desconectar cuenta…", role: .destructive) {
                                        disconnectTarget = account; confirmDisconnect = true
                                    }.disabled(!model.canDisconnect(account))
                                    if !model.canDisconnect(account) {
                                        Text("Pausa o termina las transferencias de esta cuenta")
                                    }
                                }
                        }
                        if !model.mirrors.mirrors.isEmpty { MirrorList(model: model, mirrors: model.mirrors, disconnectTarget: $disconnectTarget) }
                        if !model.favorites.isEmpty {
                            Divider().padding(.vertical, 8)
                            Text("FAVORITOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(model.favorites) { favorite in
                                Button { model.openFavorite(favorite) } label: {
                                    Label(favorite.file.name, systemImage: "star.fill").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }.buttonStyle(.plain).help(model.accounts.first(where: { $0.id == favorite.accountID })?.email ?? "Cuenta desconectada")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Button { model.showConnect = true } label: { Label("Añadir cuenta", systemImage: "plus.circle") }.buttonStyle(.plain).padding(12)
                Button { model.enableDemo() } label: { Label("Probar demo local", systemImage: "play.circle") }.buttonStyle(.plain).padding(.horizontal, 12)
                Divider()
                Label(model.isOnline ? L("Solo se descarga lo que eliges") : L("Sin conexión"), systemImage: model.isOnline ? "internaldrive" : "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 12)
            }.padding(.horizontal, 10)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            if model.showGlobalSearch {
                GlobalSearchView(model: model, search: model.globalSearch)
            } else {
            VStack(spacing: 0) {
                header
                Divider()
                if model.account == nil {
                    ContentUnavailableView {
                        Label("Tus archivos, en un solo lugar", systemImage: "cloud")
                    } description: {
                        Text("Conecta Google Drive o OneDrive para explorar tus carpetas y transferir archivos cuando lo necesites.")
                    } actions: {
                        Button("Conectar una cuenta") { model.showConnect = true }.buttonStyle(.borderedProminent)
                        Button("Explorar demo sin cuenta") { model.enableDemo() }
                    }
                } else {
                    if model.account?.isDemo == true {
                        HStack {
                            Label("DEMO LOCAL · Ningún archivo se envía a Internet", systemImage: "testtube.2").font(.caption)
                            Spacer()
                            Toggle("Sin conexión", isOn: $model.demoOffline).toggleStyle(.checkbox)
                            Button("Simular corte") { model.failNextDemoTransfer() }.help("La siguiente operación fallará una vez para probar el reintento")
                        }.padding(10).background(Color.orange.opacity(0.12))
                    }
                    if !model.isOnline {
                        HStack {
                            Label("Sin conexión. Las transferencias se han pausado y se reanudarán solas al volver la red; los listados pueden no estar al día.", systemImage: "wifi.slash")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }.padding(10).background(Color.orange.opacity(0.12))
                    }
                    if let account = model.account, model.isExpired(account) {
                        HStack {
                            Label("La sesión de esta cuenta ha caducado o se ha revocado. Los archivos no se pueden consultar hasta volver a conectarla.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Volver a conectar…") { Task { await model.reconnect(account) } }.disabled(model.connecting)
                        }.padding(10).background(Color.orange.opacity(0.12))
                    }
                    fileBrowser
                }
                // Keep the panel visible while the saved queue is unreadable, otherwise the recovery button would never appear.
                if showTransfers && (!model.transfers.isEmpty || model.queue.persistenceError != nil) { TransferPanel(model: model, queue: model.queue, history: model.history) }
                Divider()
                HStack {
                    Text("\(model.visibleFiles.count) elementos")
                    Spacer()
                    if model.canWrite { Text("Arrastra aquí para subir una copia") }
                    else if model.account != nil { Text("Lista de solo lectura · abre una carpeta para subir") }
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .navigationTitle(model.account.map { model.accountTitle($0) } ?? "iCloudy")
            .toolbar {
                ToolbarItemGroup {
                    Button { model.reload(fresh: true) } label: { Image(systemName: "arrow.clockwise") }.help("Actualizar carpeta").disabled(model.account == nil || model.loading)
                    Button { Task { await model.pickUpload() } } label: { Label("Subir", systemImage: "square.and.arrow.up") }.disabled(!model.canWrite)
                    Button { model.promptName() } label: { Label("Nueva carpeta", systemImage: "folder.badge.plus") }.disabled(!model.canWrite)
                    Button { Task { await model.saveMany(model.files.filter { selected.contains($0.id) }) } } label: { Label("Descargar selección", systemImage: "square.and.arrow.down") }.disabled(selected.isEmpty)
                    Button { previewSelection() } label: { Image(systemName: "eye") }.help("Vista previa (Espacio)").disabled(selected.count != 1)
                    Picker("Vista", selection: $model.viewMode) {
                        Image(systemName: "list.bullet").tag("list")
                        Image(systemName: "square.grid.2x2").tag("grid")
                    }.pickerStyle(.segmented).frame(width: 80)
                    Button { showTransfers.toggle() } label: { Image(systemName: "arrow.up.arrow.down.circle") }.help("Transferencias")
                    Menu {
                        Button("Personalizar nube…") { model.appearanceAccount = model.account }.disabled(model.account == nil)
                        Button("Desconectar cuenta…", role: .destructive) {
                            disconnectTarget = model.account; confirmDisconnect = true
                        }.disabled(model.account.map { !model.canDisconnect($0) } ?? true)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            }
        }
        .sheet(isPresented: $model.showConnect) { ConnectView(model: model) }
        .sheet(item: $model.appearanceAccount) { account in AccountAppearanceEditor(model: model, account: account) }
        .sheet(isPresented: $model.showNameDialog) {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.editingFile == nil ? L("Nueva carpeta") : L("Renombrar")).font(.title2)
                TextField("Nombre", text: $model.editName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancelar") { model.showNameDialog = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Guardar") { Task { await model.commitName() } }.keyboardShortcut(.defaultAction).disabled(model.editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 390)
        }
        .sheet(item: $model.relocation) { request in FolderPickerView(model: model, request: request) }
        .sheet(item: $model.crossCloud) { request in CloudTargetPicker(model: model, request: request) }
        .sheet(item: Binding(get: { model.queue.conflict }, set: { _ in })) { request in
            ConflictView(queue: model.queue, request: request)
        }
        .onChange(of: model.folderID) { selected.removeAll() }
        .onChange(of: model.selectedAccountID) { selected.removeAll() }
        .onChange(of: selected) {
            guard model.preview.isVisible else { return }
            // Follow the selection like Quick Look, but wait for the arrow keys to settle: each preview is a download.
            previewFollow?.cancel()
            if selected.count == 1 {
                previewFollow = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    previewSelection()
                }
            } else { model.preview.close() }
        }
        .onDisappear { model.preview.close() }
        .alert("No se pudo completar la operación", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Aceptar") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("iCloudy", isPresented: Binding(get: { model.info != nil }, set: { if !$0 { model.info = nil } })) { Button("Aceptar") { model.info = nil } } message: { Text(model.info ?? "") }
        .confirmationDialog("¿Crear un enlace público?", isPresented: Binding(get: { model.pendingShare != nil }, set: { if !$0 { model.pendingShare = nil } }), titleVisibility: .visible) {
            Button("Crear y copiar enlace") {
                if let pending = model.pendingShare { Task { await model.createPublicLink(pending.file, account: pending.account) } }
                model.pendingShare = nil
            }
            Button("Cancelar", role: .cancel) { model.pendingShare = nil }
        } message: {
            Text("Cualquier persona con el enlace podrá ver «\(model.pendingShare?.file.name ?? "")» sin iniciar sesión. El permiso queda en \(model.pendingShare?.account.cloud.title ?? "la nube") hasta que lo revoques desde su web.")
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }), titleVisibility: .visible) {
            Button("Enviar a la papelera", role: .destructive) {
                if let files = model.pendingTrash { Task { await model.trash(files) } }
                model.pendingTrash = nil
            }
            Button("Cancelar", role: .cancel) { model.pendingTrash = nil }
        } message: {
            Text("Los elementos van a la papelera de \(model.account?.cloud.title ?? "la nube") y se pueden restaurar desde su web. Las carpetas se envían con todo su contenido. iCloudy no borra nada de forma definitiva.")
        }
        .confirmationDialog("¿Desconectar esta cuenta?", isPresented: $confirmDisconnect, titleVisibility: .visible, presenting: disconnectTarget) { account in
            Button("Desconectar", role: .destructive) { model.disconnect(account) }
            Button("Cancelar", role: .cancel) {}
        } message: { account in
            Text("\(account.cloud.title) · \(account.email)\nSe eliminará la sesión local, sin borrar archivos de la nube ni descargas. Los favoritos y las transferencias pausadas se conservan para cuando vuelvas a conectar esta cuenta. No se revoca el permiso en el proveedor.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.path.last?.name ?? model.collection.title).font(.system(size: 27, weight: .semibold))
                    Text(model.account?.email ?? "Un explorador sencillo para tus nubes").foregroundStyle(.secondary)
                }
                Spacer()
                if model.showingCachedListing {
                    Label(model.loading ? L("Última copia conocida · actualizando…") : L("Última copia conocida · sin respuesta del proveedor"), systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.loading { ProgressView().controlSize(.small) }
            }
            Picker("Vista", selection: Binding(get: { model.collection }, set: { model.show($0) })) {
                ForEach(Collection.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420).disabled(model.account == nil)
            HStack {
                Button { model.back(to: max(0, model.path.count - 1)) } label: { Image(systemName: "chevron.left") }.disabled(model.path.isEmpty)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        Button(model.collection == .files ? "Inicio" : model.collection.title) { model.back(to: 0) }.buttonStyle(.link)
                        ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Button(folder.name) { model.back(to: index + 1) }.buttonStyle(.link)
                        }
                    }
                }
                TextField("Filtrar esta carpeta", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 210)
                Picker("Orden", selection: $model.sortMode) { Text("Nombre").tag("name"); Text("Más recientes").tag("date"); Text("Mayor tamaño").tag("size") }.labelsHidden().frame(width: 130)
            }
        }.padding(22)
    }

    private var trashTitle: String {
        guard let files = model.pendingTrash else { return "" }
        return files.count == 1 ? L("¿Enviar «\(files[0].name)» a la papelera?") : L("¿Enviar \(files.count) elementos a la papelera?")
    }
    private var emptyTitle: String {
        if !model.search.isEmpty { return L("Sin resultados") }
        if model.path.isEmpty {
            switch model.collection {
            case .recent: return L("Todavía no hay elementos recientes")
            case .shared: return L("Nadie ha compartido nada contigo")
            case .files: break
            }
        }
        return L("Esta carpeta está vacía")
    }
    private var emptyDescription: String {
        model.canWrite ? L("Arrastra archivos o carpetas para subirlos aquí.") : L("Esta lista la calcula el proveedor y no admite subidas.")
    }

    private var fileList: some View {
        Table(model.visibleFiles, selection: $selected) {
            TableColumn("Nombre") { file in
                HStack(spacing: 10) {
                    Image(systemName: file.icon).foregroundStyle(file.isFolder ? Color.accentColor : Color.secondary).frame(width: 22)
                    Text(file.name).lineLimit(1)
                    if model.isFavorite(file) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }.padding(.vertical, 5)
            }.width(min: 200, ideal: 320)
            TableColumn("Modificado") { file in
                Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
            }.width(125)
            TableColumn("Tamaño") { file in
                Text(file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").foregroundStyle(.secondary)
            }.width(85)
            TableColumn("") { file in
                Menu {
                    fileActions(file)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
            }.width(35)
        }
        .onDeleteCommand { model.requestTrash(model.files.filter { selected.contains($0.id) }) }
        .contextMenu(forSelectionType: CloudFile.ID.self) { ids in
            if ids.count > 1 {
                Button("Descargar \(ids.count) elementos…") { Task { await model.saveMany(model.files.filter { ids.contains($0.id) }) } }
                Button("Mover \(ids.count) elementos a…") { model.requestRelocation(model.files.filter { ids.contains($0.id) }, copy: false) }
                Button("Copiar \(ids.count) elementos a…") { model.requestRelocation(model.files.filter { ids.contains($0.id) }, copy: true) }
                if model.accounts.count > 1 { Button("Enviar \(ids.count) elementos a otra nube…") { model.requestCrossCloud(model.files.filter { ids.contains($0.id) }) } }
                Divider()
                Button("Enviar \(ids.count) elementos a la papelera…", role: .destructive) { model.requestTrash(model.files.filter { ids.contains($0.id) }) }
            } else if let id = ids.first, let file = model.files.first(where: { $0.id == id }) { fileActions(file) }
        } primaryAction: { ids in
            guard let id = ids.first, let file = model.files.first(where: { $0.id == id }) else { return }
            if file.isFolder { model.navigate(file) }
            else if file.isGoogleDocument { model.openBrowser(file) }
            else { Task { await model.save(file) } }
        }
    }

    private func previewSelection() {
        guard selected.count == 1, let file = model.files.first(where: { selected.contains($0.id) }) else { return }
        model.showPreview(file)
    }

    private var fileBrowser: some View {
        Group {
            if model.viewMode == "grid" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 18) {
                        ForEach(model.visibleFiles) { file in
                            VStack(spacing: 10) {
                                Image(systemName: file.icon).font(.system(size: 42)).foregroundStyle(file.isFolder ? Color.accentColor : .secondary)
                                Text(file.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                                if model.isFavorite(file) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                            }.frame(maxWidth: .infinity).frame(height: 112).padding(8)
                                .background(selected.contains(file.id) ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if file.isFolder { model.navigate(file) }
                                    else if file.isGoogleDocument { model.openBrowser(file) }
                                    else { Task { await model.save(file) } }
                                }
                                .onTapGesture {
                                    gridFocused = true
                                    if NSEvent.modifierFlags.contains(.command) {
                                        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                                    } else { selected = [file.id] }
                                }
                                .contextMenu { fileActions(file) }
                                .accessibilityLabel(file.name)
                        }
                    }.padding(20)
                }.focusable().focusEffectDisabled().focused($gridFocused)
            } else { fileList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.space) {
            guard selected.count == 1 else { return .ignored }
            previewSelection(); return .handled
        }
        .overlay {
            if model.visibleFiles.isEmpty && !model.loading {
                ContentUnavailableView(emptyTitle, systemImage: model.path.isEmpty ? model.collection.icon : "folder", description: Text(emptyDescription))
                    .allowsHitTesting(false)
            }
            if dropTarget {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)).overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                }.overlay { Label("Subir a esta carpeta", systemImage: "arrow.up.doc.fill").font(.title2).padding().background(.regularMaterial, in: Capsule()) }.padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let local = urls.filter(\.isFileURL)
            guard !local.isEmpty else { return false }
            model.enqueueUploads(local); return true
        } isTargeted: { dropTarget = $0 }
    }

    @ViewBuilder private func fileActions(_ file: CloudFile) -> some View {
        Button("Vista previa") { model.showPreview(file) }
        Divider()
        Button(model.isFavorite(file) ? L("Quitar de favoritos") : L("Añadir a favoritos")) { model.toggleFavorite(file) }
        Button("Renombrar…") { model.promptName(file) }
        Button("Mover a…") { model.requestRelocation([file], copy: false) }
        Button("Copiar a…") { model.requestRelocation([file], copy: true) }
            .disabled(file.isFolder && model.account?.cloud == .google)
        if model.accounts.count > 1 { Button("Enviar a otra nube…") { model.requestCrossCloud([file]) } }
        Divider()
        if file.isFolder {
            Button("Abrir carpeta") { model.navigate(file) }
            Button("Reflejar una carpeta local aquí…") { Task { await model.pickMirrorSource(for: file) } }
            Button("Descargar carpeta…") { Task { await model.save(file) } }
        } else if !file.isGoogleDocument {
            Button("Descargar…") { Task { await model.save(file) } }
        }
        if file.webURL != nil { Button("Abrir en navegador") { model.openBrowser(file) } }
        ForEach(file.exportOptions, id: \.ext) { option in
            Button("Exportar como \(option.title)…") { Task { await model.save(file, export: (option.mime, option.ext)) } }
        }
        Divider()
        if file.webURL != nil { Button("Copiar enlace") { model.copyLink(file) } }
        if let account = model.account { Button("Crear enlace público de solo lectura…") { model.pendingShare = (file, account) } }
        Divider()
        Button("Enviar a la papelera…", role: .destructive) { model.requestTrash([file]) }
    }

}

/// Observes the queue directly: progress ticks re-render this panel only, not the whole explorer.
struct TransferPanel: View {
    let model: AppModel
    @ObservedObject var queue: TransferQueue
    @ObservedObject var history: TransferHistory
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transferencias").font(.headline)
                Spacer()
                Button("Historial (\(history.entries.count))") { showHistory = true }.buttonStyle(.link).font(.caption)
                Button("Pausar todas") { queue.pauseAll() }.buttonStyle(.link).font(.caption)
                Button("Limpiar completadas") { queue.clearCompleted() }.buttonStyle(.link).font(.caption)
                    .help("Quita las completadas del panel; el historial las conserva")
            }
            .sheet(isPresented: $showHistory) { TransferHistoryView(model: model, history: history) }
            // Queue order, oldest first: the running job sits on top and waiting jobs can be dragged to re-prioritise.
            List {
                ForEach(queue.items) { transfer in
                    HStack(alignment: .top) {
                        Image(systemName: transfer.failed ? "exclamationmark.circle.fill" : (transfer.finished ? "checkmark.circle.fill" : (transfer.direction == .transfer ? "cloud.fill" : "arrow.up.arrow.down.circle")))
                            .foregroundStyle(transfer.failed ? .red : (transfer.finished ? .green : .secondary))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(transfer.name).fontWeight(.medium)
                            Text(transfer.destination).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Text(transfer.status).foregroundStyle(transfer.failed ? .red : .secondary).textSelection(.enabled)
                            Text(transfer.metrics).monospacedDigit().foregroundStyle(.secondary)
                            if !transfer.finished {
                                if transfer.progress > 0 { ProgressView(value: transfer.progress) }
                                else if transfer.status != "En cola" { ProgressView().controlSize(.mini) }
                            }
                        }.font(.caption)
                        Spacer()
                        if [.failed, .paused, .cancelled].contains(transfer.state) {
                            Button(transfer.state == .failed ? "Reintentar" : "Reanudar") { queue.retry(transfer.id) }
                        }
                        if queue.isMovable(transfer) {
                            Button { queue.prioritize(transfer.id) } label: { Image(systemName: "arrow.up.to.line") }.help("Pasar al principio de la cola")
                        }
                        if [.running, .queued].contains(transfer.state) {
                            Button { queue.cancel(transfer.id, pause: true) } label: { Image(systemName: "pause.circle") }.help("Pausar")
                            Button { queue.cancel(transfer.id) } label: { Image(systemName: "xmark.circle") }.help("Cancelar")
                            if queue.pendingBatchMates(of: transfer.id) > 0 {
                                Button("Cancelar el resto del lote") { queue.cancelBatch(transfer.batchID) }.font(.caption)
                                    .help("Cancela este elemento y los \(queue.pendingBatchMates(of: transfer.id)) pendientes que se añadieron con él")
                            }
                        }
                    }
                    .moveDisabled(!queue.isMovable(transfer))
                    .listRowSeparator(.hidden)
                }
                .onMove { from, to in queue.move(fromOffsets: from, toOffset: to) }
            }.listStyle(.plain).scrollContentBackground(.hidden).frame(maxHeight: 220)
            if let message = queue.persistenceError {
                HStack(alignment: .top) {
                    Text(message).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if queue.canDiscardSavedQueue {
                        Button("Descartar cola guardada") { queue.discardSavedQueue() }.font(.caption)
                            .help("Aparta el archivo dañado con una copia junto al original y permite crear transferencias nuevas.")
                    }
                }
            }
        }.padding(16).background(.quaternary.opacity(0.4))
    }
}

struct ConnectView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Añade tu nube", systemImage: "cloud").font(.title.weight(.semibold))
            Text("Elige tu cuenta y autoriza el acceso a tus archivos. Puedes añadir tantas cuentas como necesites.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                providerButton(.google, title: "Continuar con Google", subtitle: "Google Drive", icon: "externaldrive")
                providerButton(.microsoft, title: "Continuar con Microsoft", subtitle: "OneDrive · Outlook, Hotmail o Microsoft 365", icon: "cloud.fill")
            }.disabled(model.connecting)
            Button("Probar demo local sin iniciar sesión") { model.enableDemo() }.disabled(model.connecting)
            if let error = model.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.connecting { HStack { ProgressView().controlSize(.small); Text("Esperando el inicio de sesión en el navegador…").font(.caption) } }
            Text("Tu contraseña se introduce únicamente en Google o Microsoft. iCloudy guarda la sesión de forma segura en este Mac.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancelar") { model.oauth.cancel(); model.showConnect = false }.keyboardShortcut(.cancelAction)
                Spacer()
            }
        }.padding(30).frame(width: 460).interactiveDismissDisabled(model.connecting)
            .onAppear { model.connectionError = nil }
    }

    private func providerButton(_ cloud: Cloud, title: String, subtitle: String, icon: String) -> some View {
        Button { Task { await model.connect(cloud: cloud) } } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(cloud == .google ? .green : .blue).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity).contentShape(Rectangle())
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }.buttonStyle(.plain)
    }
}

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


/// Sidebar section with every mirrored folder and its state; observes the manager so status lines stay current.
struct MirrorList: View {
    let model: AppModel
    @ObservedObject var mirrors: MirrorManager
    @Binding var disconnectTarget: Account?
    @State private var removing: FolderMirror?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        Divider().padding(.vertical, 8)
        Text("REFLEJOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(mirrors.mirrors) { (mirror: FolderMirror) in
            VStack(alignment: .leading, spacing: 2) {
                Label(mirror.localURL.lastPathComponent, systemImage: "arrow.triangle.2.circlepath").lineLimit(1)
                Text("→ " + mirror.remoteName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(mirrors.status(of: mirror)).font(.caption2).foregroundStyle(mirror.lastError == nil ? Color.secondary : Color.red).lineLimit(2)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Sincronizar ahora") { mirrors.syncNow(mirror.id) }
                Button("Abrir carpeta remota") { model.openFolder(accountID: mirror.accountID, folderID: mirror.remoteFolderID) }
                Button("Mostrar carpeta local en el Finder") { model.revealLocal(mirror) }
                Divider()
                Button("Dejar de reflejar…", role: .destructive) { removing = mirror }
            }
        }
        }
        .confirmationDialog("¿Dejar de reflejar «\(removing?.localURL.lastPathComponent ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Dejar de reflejar", role: .destructive) { if let removing { mirrors.remove(removing.id) }; removing = nil }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: { Text("Se deja de vigilar la carpeta. No se borra nada, ni en el Mac ni en la nube.") }
    }
}
