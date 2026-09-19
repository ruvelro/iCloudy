// iCloudy — todas tus nubes en una sola ventana del Mac.
// Copyright (C) 2026 ruvelro
//
// This program is free software: you can redistribute it and/or modify it under the terms of the GNU General
// Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
// Public License for more details. You should have received a copy of it along with this program; if not, see
// <https://www.gnu.org/licenses/>.

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
        // A WindowGroup always restores a window at launch and when the Dock icon is clicked; a `Window` scene that
        // the user (or a crash) closed stays closed, leaving the app running with nothing on screen. "Nueva ventana"
        // is removed below, so this still behaves as a single-window app over one shared model.
        WindowGroup(id: "explorer") {
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
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
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
        Settings { SettingsView(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { services.model = model } }
    private let services = ServicesProvider()
    /// Clicking the Dock icon with no window open must bring the explorer back, not just activate a headless process.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
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

/// One horizontal margin for every block of the detail column, so titles, banners, rows and the footer share an edge.
enum Layout {
    static let margin: CGFloat = 22
    static let sidebarOuter: CGFloat = 10
    static let sidebarInner: CGFloat = 12
    /// Difference between a Table's built-in cell inset and `margin`, measured on screen.
    static let tableCorrection: CGFloat = 4
    static let footerHeight: CGFloat = 38
    /// One height for everything the eye reads as a button in this window: las dos pestañas de la barra lateral, la
    /// fila de colecciones, las migas y el campo de filtro. macOS dibuja sus controles más bajos que el resto de
    /// esta ventana, así que los suyos van en tamaño grande y los dibujados a mano se ajustan a la misma cifra.
    static let controlHeight: CGFloat = 28
    /// Width of the transfers drawer on the right.
    static let transferDrawer: CGFloat = 360
}

/// A hairline between two groups of toolbar buttons, so a row of nine icons reads as four errands instead of one
/// long strip. Drawn by hand rather than with `Divider()`: inside a toolbar the system rule takes the full height
/// of the bar and looks like the window has been split in two.
struct ToolbarSeparator: View {
    static let height: CGFloat = 16
    var body: some View {
        Rectangle().fill(.quaternary)
            .frame(width: 1, height: Self.height)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

struct ExplorerView: View {
    @ObservedObject var model: AppModel
    @State private var selected: Set<CloudFile.ID> = []
    @State private var dropTarget = false
    /// The transfers drawer starts closed and opens itself when something is transferring.
    @State private var showTransfers = false
    @State private var confirmDisconnect = false
    @State private var disconnectTarget: Account?
    @State private var previewFollow: Task<Void, Never>?
    @State private var sidebarVisible = true
    /// Which half of the sidebar is showing. Favourites used to live under every account, so reaching them on a Mac
    /// with six clouds connected meant scrolling past all of them.
    @State private var sidebarTab = SidebarTab.clouds
    @FocusState private var gridFocused: Bool

    private var navigation: some View {
        // The toolbar belongs to the window, not a navigation column. An ordinary split view keeps its
        // leading controls anchored to the traffic lights when the sidebar is resized or hidden.
        HSplitView {
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Label("iCloudy", systemImage: "cloud.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 20)
                Button { model.preview.close(); model.showGlobalSearch = true } label: {
                    Label("Buscar en todas las nubes", systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(Layout.sidebarInner)
                        .contentShape(Rectangle())
                        .sidebarRow(selected: model.showGlobalSearch)
                }.buttonStyle(.plain)
                Picker("", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Text(tab == .favourites && !model.favorites.isEmpty ? "\(tab.title) (\(model.favorites.count))" : tab.title).tag(tab)
                    }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
                ScrollView {
                  if sidebarTab == .clouds {
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
                                }.padding(Layout.sidebarInner).contentShape(Rectangle())
                                    .sidebarRow(selected: model.selectedAccountID == account.id && !model.showGlobalSearch,
                                                tint: model.appearance(for: account).tint.color)
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
                        if model.loadingAccounts {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Abriendo el Llavero…").font(.caption).foregroundStyle(.secondary)
                            }.padding(Layout.sidebarInner)
                        }
                        if !model.mirrors.mirrors.isEmpty { MirrorList(model: model, mirrors: model.mirrors, disconnectTarget: $disconnectTarget) }
                    }
                  } else {
                    FavoritesList(model: model)
                  }
                }
                Spacer(minLength: 0)
                // One small, quiet action, kept apart from the list by a rule so it reads as the edge of the
                // sidebar rather than as one more row of it. Configuración used to sit here too, which said the
                // same thing twice: the toolbar carries it, and the toolbar is where it stays.
                Divider().padding(.top, 4)
                Button { model.showConnect = true } label: {
                    Label("Añadir cuenta", systemImage: "plus.circle").font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)

            }.padding(.horizontal, Layout.sidebarOuter).padding(.bottom, 16)
                Divider()
                Label(model.isOnline ? L("Solo se descarga lo que eliges") : L("Sin conexión"), systemImage: model.isOnline ? "internaldrive" : "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, Layout.margin)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: Layout.footerHeight)
            }
            // Keep both panes alive when collapsed: changing the split's children would recreate the
            // detail view, losing table scroll position or cancelling an in-flight global search.
            .frame(minWidth: sidebarVisible ? 230 : 0, idealWidth: sidebarVisible ? 260 : 0,
                   maxWidth: sidebarVisible ? 320 : 0, maxHeight: .infinity)
            .background(VisualEffect(material: .sidebar).ignoresSafeArea())
            .clipped().opacity(sidebarVisible ? 1 : 0)
            .accessibilityHidden(!sidebarVisible).allowsHitTesting(sidebarVisible)
            Group {
            if model.showGlobalSearch {
                GlobalSearchView(model: model, search: model.globalSearch)
            } else {
            VStack(spacing: 0) {
                header
                Divider()
                // The file area and the transfers drawer sit side by side, so opening the drawer narrows the
                // listing instead of eating the height where the files are.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                    if model.account == nil {
                        // Greedy, so the block above it stays anchored to the top instead of floating in the middle.
                        ContentUnavailableView {
                            Label("Tus archivos, en un solo lugar", systemImage: "cloud")
                        } description: {
                            Text("Conecta una nube para explorar tus carpetas y transferir archivos cuando lo necesites.")
                        } actions: {
                            Button("Conectar una cuenta") { model.showConnect = true }.buttonStyle(.borderedProminent)
                            Button("Explorar demo sin cuenta") { model.enableDemo() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        if model.account?.isDemo == true {
                            HStack {
                                Label("DEMO LOCAL · Ningún archivo se envía a Internet", systemImage: "testtube.2").font(.caption)
                                Spacer()
                                Toggle("Sin conexión", isOn: $model.demoOffline).toggleStyle(.checkbox)
                                Button("Simular corte") { model.failNextDemoTransfer() }.help("La siguiente operación fallará una vez para probar el reintento")
                            }.padding(.horizontal, Layout.margin).padding(.vertical, 10).background(Color.orange.opacity(0.12))
                        }
                        if !model.isOnline {
                            HStack {
                                Label("Sin conexión. Las transferencias se han pausado y se reanudarán solas al volver la red; los listados pueden no estar al día.", systemImage: "wifi.slash")
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }.padding(.horizontal, Layout.margin).padding(.vertical, 10).background(Color.orange.opacity(0.12))
                        }
                        if let account = model.account, model.isExpired(account) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    if model.isRenewing(account) {
                                        Label("Renovando la sesión sin molestarte. Si no sale, aparecerá el botón para entrar a mano.", systemImage: "arrow.clockwise")
                                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Label("La sesión de esta cuenta ha caducado o se ha revocado. Los archivos no se pueden consultar hasta volver a conectarla.", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                                    }
                                    // What the provider said, when it said anything. Without this, a provider that
                                    // drops sessions for its own reasons is impossible to diagnose from a report.
                                    if let reason = model.expiryReason(account) {
                                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                if model.isRenewing(account) { ProgressView().controlSize(.small) }
                                else { Button("Volver a conectar…") { Task { await model.reconnect(account) } }.disabled(model.connecting) }
                            }.padding(.horizontal, Layout.margin).padding(.vertical, 10).background(Color.orange.opacity(0.12))
                        }
                        fileBrowser
                    }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if showTransfers {
                        Divider()
                        TransferPanel(model: model, queue: model.queue, history: model.history)
                            .frame(width: Layout.transferDrawer)
                            .transition(.move(edge: .trailing))
                    }
                }
                Divider()
                HStack {
                    Text(model.visibleFiles.count == 1 ? L("1 elemento") : L("\(model.visibleFiles.count) elementos"))
                    if selectedCount > 0 {
                        Text("·")
                        Text(selectedCount == 1 ? L("1 seleccionado") : L("\(selectedCount) seleccionados"))
                            .foregroundStyle(.primary)
                    }
                    if model.downloadedCount > 0 {
                        Text("·")
                        Label("\(model.downloadedCount) en este Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    if model.canWrite { Text("Arrastra aquí para subir una copia") }
                    else if model.account != nil { Text("Lista de solo lectura · abre una carpeta para subir") }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, Layout.margin).frame(height: Layout.footerHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(model.account.map { model.accountTitle($0) } ?? "iCloudy")
            // Something started moving, so show it. Closing the drawer by hand keeps it closed until the next one.
            .onChange(of: model.transfers.count) { _, count in
                guard count > 0, !showTransfers else { return }
                withAnimation(.easeInOut(duration: 0.18)) { showTransfers = true }
            }
            }
            }
            .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(ExplorerWindowChrome())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { sidebarVisible.toggle() }
                } label: { Label("Barra lateral", systemImage: "sidebar.left") }
                .help(sidebarVisible ? "Ocultar barra lateral" : "Mostrar barra lateral")
                .keyboardShortcut("s", modifiers: [.command, .control])
                Text(model.account.map { model.accountTitle($0) } ?? "iCloudy")
                    .font(.headline).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
                    .help(model.account.map { model.accountTitle($0) } ?? "iCloudy")
                // A flexible space is the only way to send the action buttons to the trailing edge: without it the
                // toolbar packs every item against the leading side, whatever placement they declare.
                Spacer()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink { Label("Configuración", systemImage: "gearshape") }
                    .help("Abrir Configuración (⌘,)")
                if !model.showGlobalSearch { explorerActions }
            }
        }
    }

    var body: some View {
        navigation
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
            guard model.preview.isVisible, Prefs.bool(Prefs.previewFollowsSelection, default: true) else { return }
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
            Text(model.account?.capabilities.reversibleTrash == false
                 ? L("Este servidor no tiene papelera: lo que elimines se borra de forma definitiva, con todo el contenido de las carpetas. iCloudy no puede deshacerlo.")
                 : L("Los elementos van a la papelera de \(model.account?.cloud.title ?? "la nube") y se pueden restaurar desde su web. Las carpetas se envían con todo su contenido. iCloudy no borra nada de forma definitiva."))
        }
        .confirmationDialog("¿Desconectar esta cuenta?", isPresented: $confirmDisconnect, titleVisibility: .visible, presenting: disconnectTarget) { account in
            Button("Desconectar", role: .destructive) { model.disconnect(account) }
            Button("Cancelar", role: .cancel) {}
        } message: { account in
            Text("\(account.cloud.title) · \(account.email)\nSe eliminará la sesión local, sin borrar archivos de la nube ni descargas. Los favoritos y las transferencias pausadas se conservan para cuando vuelvas a conectar esta cuenta. No se revoca el permiso en el proveedor.")
        }
    }

    /// Configuración | recargar, subir, crear, descargar, ver | modo de lista | transferencias. The rules are what
    /// make those four groups visible; without them the toolbar was one undifferentiated row of icons.
    @ViewBuilder private var explorerActions: some View {
        Group {
            ToolbarSeparator()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Actualizar carpeta").disabled(model.account == nil || model.loading)
            Button { Task { await model.pickUpload() } } label: { Label("Subir", systemImage: "square.and.arrow.up") }.disabled(!model.canWrite)
            Button { model.promptName() } label: { Label("Nueva carpeta", systemImage: "folder.badge.plus") }.disabled(!model.canWrite)
            Button { Task { await model.saveMany(model.selection(selected)) } } label: { Label("Descargar selección", systemImage: "square.and.arrow.down") }.disabled(selected.isEmpty)
            Button { previewSelection() } label: { Image(systemName: "eye") }.help("Vista previa (Espacio)").disabled(selected.count != 1)
            ToolbarSeparator()
            Group {
                Picker("Vista", selection: $model.viewMode) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                }.pickerStyle(.segmented).frame(width: 80)
                // The sort used to live down in the header, beside the breadcrumbs. It answers the same question as
                // the two buttons on its left — how this list is drawn — so it now sits in the same group.
                Menu {
                    Picker("Orden", selection: $model.sortMode) {
                        Label("Nombre", systemImage: "textformat").tag("name")
                        Label("Más recientes", systemImage: "clock").tag("date")
                        Label("Mayor tamaño", systemImage: "arrow.up.arrow.down").tag("size")
                    }.pickerStyle(.inline).labelsHidden()
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help("Ordenar la lista")
            }
            ToolbarSeparator()
            // Personalizar and Desconectar used to hang off an ⋯ menu here. They belong to a cloud, not to the
            // window, so they now live where the cloud itself is: the right-click menu of its row in the sidebar.
            Button { withAnimation(.easeInOut(duration: 0.18)) { showTransfers.toggle() } } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .symbolVariant(model.transfers.isEmpty ? .none : .fill)
            }.help(showTransfers ? "Ocultar transferencias" : "Mostrar transferencias")
        }
    }

    /// Selected items that are actually on screen: filtering the folder leaves ids selected that the list no longer
    /// shows, and a footer counting those would be counting something the user cannot see.
    private var selectedCount: Int { model.visibleFiles.reduce(0) { selected.contains($1.id) ? $0 + 1 : $0 } }

    /// What the collection picker offers. Never empty, so the row it lives in always has the same height.
    private var collectionChoices: [Collection] {
        model.account.map { AppModel.collections(for: $0) } ?? [.files]
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
            CollectionPicker(choices: collectionChoices, selection: model.collection) { model.show($0) }
            HStack {
                Button { model.back(to: max(0, model.path.count - 1)) } label: { Image(systemName: "chevron.left") }.disabled(model.path.isEmpty)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Crumb(title: model.collection == .files ? L("Inicio") : model.collection.title,
                              symbol: model.collection.icon, current: model.path.isEmpty) { model.back(to: 0) }
                        ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Crumb(title: folder.name, symbol: nil, current: index == model.path.count - 1) { model.back(to: index + 1) }
                        }
                    }.padding(.vertical, 1)
                }
                ChromeField("Filtrar esta carpeta", symbol: "line.3.horizontal.decrease", text: $model.search).frame(width: 210)
            }
        }.padding(.horizontal, Layout.margin).padding(.top, 20).padding(.bottom, 14)
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
                HStack(spacing: 8) {
                    // Folders carry no badge: iCloudy cannot claim that everything inside is present and current.
                    Group {
                        if file.isFolder { Color.clear } else { LocalCopyBadge(status: model.localStatus(file)) }
                    }.frame(width: 15)
                    FileIcon(file: file)
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
        }
        // A Table insets its own cells; this brings their text onto the margin shared by the title and the footer.
        .padding(.horizontal, Layout.tableCorrection)
        .onDeleteCommand { model.requestTrash(model.selection(selected)) }
        .contextMenu(forSelectionType: CloudFile.ID.self) { ids in
            if ids.count > 1 {
                Button("Descargar \(ids.count) elementos…") { Task { await model.saveMany(model.selection(ids)) } }
                Button("Mover \(ids.count) elementos a…") { model.requestRelocation(model.selection(ids), copy: false) }
                Button("Copiar \(ids.count) elementos a…") { model.requestRelocation(model.selection(ids), copy: true) }
                if model.accounts.count > 1 { Button("Enviar \(ids.count) elementos a otra nube…") { model.requestCrossCloud(model.selection(ids)) } }
                Divider()
                Button("Enviar \(ids.count) elementos a la papelera…", role: .destructive) { model.requestTrash(model.selection(ids)) }
            } else if let file = model.selection(ids).first { fileActions(file) }
        } primaryAction: { ids in
            guard let file = model.selection(ids).first else { return }
            if file.isFolder { model.navigate(file) }
            else if file.isGoogleDocument { model.openBrowser(file) }
            else { Task { await model.save(file) } }
        }
    }

    private func previewSelection() {
        guard selected.count == 1, let file = model.selection(selected).first else { return }
        model.showPreview(file)
    }

    private var fileBrowser: some View {
        Group {
            if model.viewMode == "grid" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 18) {
                        ForEach(model.visibleFiles) { file in
                            VStack(spacing: 10) {
                                FileIcon(file: file, size: 42)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !file.isFolder {
                                            LocalCopyBadge(status: model.localStatus(file), size: 14)
                                                .background(Circle().fill(.background).padding(-1))
                                                .offset(x: 8, y: 2)
                                        }
                                    }
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
                    }.padding(.horizontal, Layout.margin).padding(.vertical, 18)
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
            .disabled((file.isFolder && model.account?.cloud == .google) || model.account?.capabilities.copy == false)
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
        if let copy = model.localStatus(file).copy {
            Divider()
            Button("Mostrar la copia de este Mac en el Finder") { model.revealLocalCopy(file) }
                .help(copy.path)
            Button("Olvidar la copia local") { model.forgetLocalCopy(file) }
                .help(L("Quita la marca de descargado. No borra el archivo del Mac."))
        }
        Divider()
        if file.webURL != nil { Button("Copiar enlace") { model.copyLink(file) } }
        if let account = model.account, account.capabilities.publicLinks {
            Button("Crear enlace público de solo lectura…") { model.pendingShare = (file, account) }
        }
        Divider()
        Button(model.account?.capabilities.reversibleTrash == false ? "Eliminar del servidor…" : "Enviar a la papelera…", role: .destructive) { model.requestTrash([file]) }
    }

}

/// The row that picks between a provider's collections. It is a view of its own for one reason: its height has to
/// be the same for every provider, and that is worth a test rather than an assumption.
///
/// Providers differ in how many collections they have. Google Drive has three, a WebDAV server has one. Leaving the
/// row out for the ones with a single collection moved everything below it, so changing account looked like the
/// window had shifted. The picker is therefore always built, and merely invisible when there is nothing to choose:
/// opacity never affects layout, while omitting the row, or reserving a guessed height for it, does.
struct CollectionPicker: View {
    let choices: [Collection]
    let selection: Collection
    let select: (Collection) -> Void
    private var choosable: Bool { choices.count > 1 }

    var body: some View {
        Picker("Vista", selection: Binding(get: { selection }, set: select)) {
            ForEach(choices) { Label($0.title, systemImage: $0.icon).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(maxWidth: 420)
        .opacity(choosable ? 1 : 0)
        .allowsHitTesting(choosable)
        .accessibilityHidden(!choosable)
    }
}

/// Which slice of the transfers the panel is showing. One list held all of them at once — running, just finished,
/// and whatever had failed days ago — so the thing the panel was opened for was never the thing at the top of it.
enum TransferTab: String, CaseIterable, Identifiable {
    case active, done, error, history
    var id: Self { self }
    var title: String {
        switch self {
        case .active: return L("En curso")
        case .done: return L("Finalizadas")
        case .error: return L("Error")
        case .history: return L("Historial")
        }
    }
}

/// The error tab tells two different stories: a transfer that broke on its own, and one the user stopped by hand.
/// Both are over and neither will resume, which is why they share a tab; only the filter tells them apart.
enum TransferErrorFilter: String, CaseIterable, Identifiable {
    case all, failed, cancelled
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return L("Todas")
        case .failed: return L("Fallidas")
        case .cancelled: return L("Canceladas")
        }
    }
    func matches(_ state: TransferState) -> Bool {
        switch self {
        case .all: return [.failed, .cancelled].contains(state)
        case .failed: return state == .failed
        case .cancelled: return state == .cancelled
        }
    }
}

/// "Completadas hoy" used to be a section pinned under the queue, answering the same question as the history with
/// a shorter list. It is a filter over the history now, rather than a second list saying half of the same thing.
enum TransferHistoryFilter: String, CaseIterable, Identifiable {
    case all, today
    var id: Self { self }
    var title: String { self == .all ? L("Todas") : L("Hoy") }
}

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
            if [.failed, .paused, .cancelled].contains(transfer.state) {
                Button(transfer.state == .failed ? "Reintentar" : "Reanudar") { queue.retry(transfer.id) }
            }
            if queue.isMovable(transfer) {
                Button { queue.prioritize(transfer.id) } label: { Image(systemName: "arrow.up.to.line") }
                    .help("Pasar al principio de la cola")
            }
            if [.running, .queued].contains(transfer.state) {
                Button { queue.cancel(transfer.id, pause: true) } label: { Image(systemName: "pause.circle") }.help("Pausar")
                Button { queue.cancel(transfer.id) } label: { Image(systemName: "xmark.circle") }.help("Cancelar")
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
    }
    private var actionsAreEmpty: Bool {
        transfer.state == .completed && !queue.isMovable(transfer)
    }
}

struct ConnectView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Añade tu nube", systemImage: "cloud").font(.title.weight(.semibold))
                Text("Elige tu proveedor y autoriza el acceso a tus archivos. Puedes añadir tantas cuentas como necesites.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("SERVICIOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    providerButton(.google, title: "Continuar con Google", subtitle: "Google Drive", icon: "externaldrive")
                    providerButton(.microsoft, title: "Continuar con Microsoft", subtitle: "OneDrive · Outlook, Hotmail o Microsoft 365", icon: "cloud.fill")
                    providerButton(.dropbox, title: "Continuar con Dropbox", subtitle: "Dropbox personal o de equipo", icon: "shippingbox")
                    providerButton(.box, title: "Continuar con Box", subtitle: "Box personal o de empresa", icon: "square.stack.3d.up")
                    providerButton(.mega, title: "Conectar Mega", subtitle: "Cifrado de extremo a extremo, con correo y contraseña", icon: "lock.icloud")
                    providerButton(.o2, title: "Conectar O2 Cloud", subtitle: "Inicias sesión en las páginas de O2, con tu móvil o tu NIF", icon: "antenna.radiowaves.left.and.right")
                }.disabled(model.connecting)
                Text("TU PROPIO SERVIDOR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    providerButton(.webdav, title: "Conectar WebDAV", subtitle: "Nextcloud, ownCloud, Synology y otros NAS", icon: "server.rack")
                    providerButton(.ftp, title: "Conectar FTP", subtitle: "FTP y FTPS implícito, con usuario y contraseña", icon: "arrow.up.arrow.down.square")
                    providerButton(.volume, title: "Conectar un volumen o carpeta", subtitle: "SMB, AFP, NFS, discos externos y carpetas del Mac", icon: "externaldrive.connected.to.line.below")
                }.disabled(model.connecting)
                Button("Conectar a un servidor en el Finder…") { model.openFinderConnect() }
                    .buttonStyle(.link).font(.caption)
                    .help("Monta el recurso de red y vuelve aquí para elegir su carpeta")
                Text("AVANZADOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button {
                    model.connectionError = nil; model.showAdvanced = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.2.badge.gearshape").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unidad compartida o biblioteca").font(.headline)
                            Text("Unidades compartidas de Google y bibliotecas de SharePoint").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                }.buttonStyle(.plain).disabled(model.driveHosts.isEmpty || model.connecting)
                if model.driveHosts.isEmpty {
                    Text("Conecta antes una cuenta de Google o de Microsoft.").font(.caption2).foregroundStyle(.secondary)
                }
                Button("Probar demo local sin iniciar sesión") { model.enableDemo() }.disabled(model.connecting)
                if let error = model.connectionError, model.serverLogin == nil {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if model.connecting { HStack { ProgressView().controlSize(.small); Text("Esperando el inicio de sesión en el navegador…").font(.caption) } }
                Text("Con Google, Microsoft, Dropbox y Box tu contraseña se introduce únicamente en la web del proveedor. Las credenciales de un servidor propio las escribes aquí y se guardan en el Llavero de este Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancelar") { model.oauth.cancel(); model.showConnect = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }.padding(30)
        }.frame(width: 470, height: 640).interactiveDismissDisabled(model.connecting)
            .onAppear { model.connectionError = nil }
            .sheet(item: $model.serverLogin) { cloud in ServerLoginView(model: model, cloud: cloud) }
            .sheet(isPresented: $model.showAdvanced) { AdvancedDriveView(model: model) }
            .sheet(item: $model.o2Login) { request in O2WebLoginView(model: model, host: request.host) }
    }

    private func providerButton(_ cloud: Cloud, title: String, subtitle: String, icon: String) -> some View {
        Button {
            // A self-hosted provider needs an address and credentials before anything can be attempted.
            if cloud == .volume { Task { await model.connectVolume() } }
            else if cloud.usesWebLogin { model.connectionError = nil; model.o2Login = O2LoginRequest(id: "cloud.o2online.es") }
            else if cloud.usesPasswordLogin { model.connectionError = nil; model.serverLogin = cloud }
            else { Task { await model.connect(cloud: cloud) } }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint(cloud)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if cloud.isExperimental {
                            Text("Experimental").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: cloud.isSelfHosted || cloud.usesPasswordLogin ? "chevron.right" : "arrow.up.right").foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }.buttonStyle(.plain)
    }
    private func tint(_ cloud: Cloud) -> Color {
        switch cloud {
        case .google: return .green
        case .microsoft: return .blue
        case .dropbox: return .indigo
        case .box: return .cyan
        case .webdav: return .gray
        case .ftp: return .orange
        case .volume: return .brown
        case .mega: return .red
        case .o2: return .mint
        }
    }
}

/// Address and credentials for a server the user runs: WebDAV or FTP. Both store the password in the Keychain and
/// send it only to that host.
struct ServerLoginView: View {
    @ObservedObject var model: AppModel
    let cloud: Cloud
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var secureFTP = false
    @State private var nextcloud = false
    @State private var showAdvanced = false

    /// WebDAV and FTP need a full server address; Mega has only one.
    private var needsServer: Bool { cloud != .mega }
    private var icon: String {
        switch cloud {
        case .webdav: return "server.rack"
        case .mega: return "lock.icloud"
        default: return "arrow.up.arrow.down.square"
        }
    }
    private var placeholder: String {
        cloud == .webdav ? "https://nube.ejemplo.com/remote.php/dav/files/ana" : "servidor.ejemplo.com/carpeta"
    }
    private var explanation: String {
        switch cloud {
        case .webdav: return L("Para Nextcloud, ownCloud, Synology, otros NAS y cualquier servidor WebDAV. La dirección es la ruta WebDAV completa.")
        case .mega: return L("Tu contraseña no sale de este Mac: se usa para derivar las claves con las que Mega cifra los nombres y el contenido.")
        default: return L("Para servidores FTP propios y NAS. iCloudy usa siempre modo pasivo. Sin FTPS, la contraseña y los archivos viajan sin cifrar.")
        }
    }
    private var address: String {
        guard cloud == .ftp else { return server }
        let clean = server.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ftps://", with: "").replacingOccurrences(of: "ftp://", with: "")
        return (secureFTP ? "ftps://" : "ftp://") + clean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(cloud.title, systemImage: icon).font(.title2)
                if cloud.isExperimental {
                    Text("Experimental").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cloud.isExperimental {
                Label("Mega no publica su API ni se compromete a mantenerla. Puede dejar de funcionar sin aviso.", systemImage: "flask")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if cloud == .ftp {
                Picker("Seguridad", selection: $secureFTP) {
                    Text("FTP sin cifrar").tag(false)
                    Text("FTPS implícito (puerto 990)").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if !secureFTP {
                    Label("Sin cifrar: usa esta opción solo en tu red local.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if needsServer { TextField(placeholder, text: $server).textFieldStyle(.roundedBorder) }
            TextField(needsServer ? "Usuario" : "Correo de la cuenta", text: $username).textFieldStyle(.roundedBorder)
            SecureField(needsServer ? "Contraseña o contraseña de aplicación" : "Contraseña", text: $password).textFieldStyle(.roundedBorder)
            Text(needsServer
                 ? "Si tu servidor usa verificación en dos pasos, crea una contraseña de aplicación en su configuración."
                 : "Si la cuenta tiene verificación en dos pasos, escribe la contraseña, un espacio y el código de seis dígitos.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cloud == .webdav {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    Toggle("Servidor Nextcloud u ownCloud", isOn: $nextcloud)
                    Text("Habilita «Crear enlace público» usando su API de compartición, que WebDAV por sí solo no tiene. Déjalo desactivado si no sabes qué servidor es.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Avanzado").font(.caption)
                }
            }
            if let error = model.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancelar") { model.serverLogin = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                Button("Conectar") {
                    Task {
                        await model.connectServer(cloud: cloud, server: address, username: username, password: password,
                                                  flavor: cloud == .webdav && nextcloud ? "nextcloud" : nil)
                        password = ""
                        if model.connectionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connecting || (needsServer && server.isEmpty) || username.isEmpty || password.isEmpty)
            }
        }.padding(24).frame(width: 470)
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


/// The favourites half of the sidebar.
///
/// The old list marked every row with the same star, which said "this is a favourite" — something the list already
/// said by existing. What it never said is which cloud the item lives in, and that is exactly what you need when six
/// of them are connected, so the star gives way to the account's own icon.
struct FavoritesList: View {
    @ObservedObject var model: AppModel

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "star").font(.title2).foregroundStyle(.tertiary)
            Text("Sin favoritos").font(.callout).foregroundStyle(.secondary)
            Text("Marca una carpeta o un archivo con la estrella y aparecerá aquí, sea de la nube que sea.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }.padding(.horizontal, 10).padding(.top, 28)
    }
    @ViewBuilder private func row(_ favorite: Favorite) -> some View {
        let account = model.accounts.first { $0.id == favorite.accountID }
        HStack(spacing: 9) {
            if let account {
                AccountIcon(account: account, appearance: model.appearance(for: account), size: 18)
            } else {
                Image(systemName: "questionmark.circle").frame(width: 18).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(favorite.file.name).lineLimit(1)
                Text(account.map { model.accountTitle($0) } ?? L("Cuenta desconectada"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !favorite.file.isFolder { FileIcon(file: favorite.file, size: 11) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    var body: some View {
        VStack(spacing: 3) {
            if model.favorites.isEmpty { empty }
            ForEach(model.favorites) { favorite in
                Button { model.openFavorite(favorite) } label: { row(favorite) }
                    .buttonStyle(.plain)
                    .sidebarRow(selected: false)
                    .help(model.accounts.first { $0.id == favorite.accountID }?.email ?? L("Cuenta desconectada"))
            }
        }
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


/// Picks a shared drive or a document library from an account that is already connected. Kept out of the main list
/// because most people never need one, and it needs an existing sign-in rather than a new one.
struct AdvancedDriveView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: Account?
    @State private var drives: [RemoteDrive] = []
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unidad compartida o biblioteca").font(.title2)
            Text("Se añade como una nube más, reutilizando la sesión de la cuenta elegida. No hay que iniciar sesión otra vez.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Cuenta", selection: Binding(get: { host }, set: { host = $0; Task { await load() } })) {
                Text("Elige una cuenta").tag(Account?.none)
                ForEach(model.driveHosts) { account in
                    Text(model.accountTitle(account) + " · " + account.email).tag(Account?.some(account))
                }
            }.labelsHidden()
            List(drives) { drive in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.person.crop").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(drive.name).fontWeight(.medium)
                        Text(drive.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus.circle")
                }.contentShape(Rectangle())
                    .onTapGesture { if let host { model.addScopedDrive(drive, from: host); dismiss() } }
            }
            .frame(minHeight: 200)
            .overlay {
                if loading { ProgressView() }
                else if host == nil { Text("Elige primero una cuenta.").foregroundStyle(.secondary).font(.callout) }
                else if drives.isEmpty { Text("Esa cuenta no tiene unidades compartidas ni bibliotecas disponibles.").foregroundStyle(.secondary).font(.callout).multilineTextAlignment(.center).padding() }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Cerrar") { model.showAdvanced = false; dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520)
    }
    private func load() async {
        guard let host else { return }
        loading = true; failure = nil; drives = []
        do { drives = try await model.client(host).availableDrives() }
        catch { failure = error.localizedDescription }
        loading = false
    }
}
