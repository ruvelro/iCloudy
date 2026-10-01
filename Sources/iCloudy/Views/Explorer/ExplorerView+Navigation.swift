import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

extension ExplorerView {
    var navigation: some View {
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
                                        if model.isRenewing(account) {
                                            Label("Renovando la sesión…", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary)
                                        } else if model.isExpired(account) {
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
                                    if account.capabilities.links.manage {
                                        Button("Enlaces compartidos…") { model.requestLinkInventory(account) }
                                    }
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
                        if !model.mirrors.mirrors.isEmpty { MirrorList(model: model, mirrors: model.mirrors) }
                        if !model.offline.pins.isEmpty || !model.offline.notices.isEmpty { OfflineList(model: model, store: model.offline) }
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
                    else if model.inTrash { Text("Papelera · restaura o elimina definitivamente") }
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

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.path.last?.name ?? model.collection.title).font(.system(size: 27, weight: .semibold))
                    Text(model.account?.email ?? L("Un explorador sencillo para tus nubes")).foregroundStyle(.secondary)
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
                Button { model.back(to: max(0, model.path.count - 1)) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Volver a la carpeta anterior").help("Volver a la carpeta anterior")
                    .keyboardShortcut(.upArrow, modifiers: .command).disabled(model.path.isEmpty)
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

    /// What the collection picker offers. Never empty, so the row it lives in always has the same height.
    var collectionChoices: [Collection] {
        model.account.map { AppModel.collections(for: $0) } ?? [.files]
    }
}
