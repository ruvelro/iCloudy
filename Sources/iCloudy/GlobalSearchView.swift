import SwiftUI

struct GlobalSearchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: GlobalSearch
    @State private var selected: Set<SearchHit.ID> = []
    private var selectedHit: SearchHit? { selected.count == 1 ? search.visibleHits.first { selected.contains($0.id) } : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Buscar en todas las nubes").font(.system(size: 27, weight: .semibold))
                Text("Archivos y carpetas de tus cuentas, sin descargar contenido.").foregroundStyle(.secondary)
                // The same height as the explorer's own header, so moving between the two does not change the size
                // of the chrome under the title.
                HStack {
                    ChromeField("Nombre o texto que buscar…", text: $search.query) { run() }
                    Button("Buscar") { run() }.buttonStyle(.borderedProminent).disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.accounts.isEmpty)
                    if !search.loadingIDs.isEmpty { Button("Cancelar") { search.cancel() } }
                }.controlSize(.large)
                HStack {
                    Picker("Tipo", selection: $search.filters.type) { ForEach(SearchFileType.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    Picker("Fecha", selection: $search.filters.age) { ForEach(SearchAge.allCases) { Text($0.title).tag($0) } }
                    Picker("Tamaño", selection: $search.filters.size) { ForEach(SearchSize.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                }.labelsHidden().controlSize(.large)
                HStack {
                    Picker("Cuenta", selection: $search.filters.accountID) {
                        Text("Todas las cuentas").tag("")
                        ForEach(model.accounts) { Text(model.accountTitle($0) + " · " + $0.email).tag($0.id) }
                    }.controlSize(.large).frame(maxWidth: 360)
                    Button("Quitar filtros") { search.filters = SearchFilters() }.buttonStyle(.link)
                    Spacer()
                    if !search.submittedQuery.isEmpty { Text("Resultados para «\(search.submittedQuery)»").font(.caption).lineLimit(1) }
                }
            }.padding(22)
            Divider()
            Table(search.visibleHits, selection: $selected) {
                TableColumn("Nombre") { hit in HStack(spacing: 7) { FileIcon(file: hit.file); Text(hit.file.name).lineLimit(1) } }.width(min: 180, ideal: 280)
                TableColumn("Cuenta") { hit in
                    if let account = model.accounts.first(where: { $0.id == hit.accountID }) {
                        HStack(spacing: 7) {
                            AccountIcon(account: account, appearance: model.appearance(for: account), size: 20)
                            VStack(alignment: .leading) {
                                Text(model.accountTitle(account)).foregroundStyle(model.appearance(for: account).tint.color)
                                Text(account.email).font(.caption2).foregroundStyle(.secondary)
                            }.lineLimit(1)
                        }.help(account.cloud.title + " · " + account.email)
                    }
                }.width(min: 120, ideal: 200)
                TableColumn("Modificado") { hit in Text(hit.file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary) }.width(115)
                TableColumn("Tamaño") { hit in Text(hit.file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").foregroundStyle(.secondary) }.width(80)
            }
            .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
                if ids.count == 1, let hit = search.visibleHits.first(where: { ids.contains($0.id) }) { actions(hit) }
            } primaryAction: { ids in
                if let hit = search.visibleHits.first(where: { ids.contains($0.id) }) {
                    if hit.file.isFolder { model.openSearchLocation(hit) }
                    else if hit.file.isGoogleDocument { model.openBrowser(hit.file) }
                    else { model.previewSearchHit(hit) }
                }
            }
            .onKeyPress(.space) {
                guard let selectedHit else { return .ignored }
                model.previewSearchHit(selectedHit); return .handled
            }
            .overlay {
                if search.visibleHits.isEmpty {
                    ContentUnavailableView {
                        Label(search.submittedQuery.isEmpty ? "Todas tus cuentas, una búsqueda" : (search.loadingIDs.isEmpty ? L("Sin resultados con estos filtros") : L("Buscando…")), systemImage: "magnifyingglass")
                    } description: {
                        Text(search.submittedQuery.isEmpty ? L("Escribe un término y pulsa Intro. Cada proveedor usa su propio índice de nombres y contenido.") : L("Los filtros se aplican a los resultados recibidos. Si quedan páginas, carga más; si hubo errores, reintenta la cuenta."))
                    }.allowsHitTesting(false)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if search.wasCancelled { Text("Búsqueda detenida. Los resultados pueden estar incompletos; pulsa Buscar para repetirla.").foregroundStyle(.orange) }
                ForEach(model.accounts) { account in
                    if search.loadingIDs.contains(account.id) || search.errors[account.id] != nil || search.cursors[account.id] != nil || search.incompleteIDs.contains(account.id) {
                        HStack {
                            Text(model.accountTitle(account) + " · " + account.email).lineLimit(1)
                            if search.loadingIDs.contains(account.id) { ProgressView().controlSize(.small); Text("Buscando…") }
                            else if let message = search.errors[account.id] {
                                Text(message).foregroundStyle(.red).lineLimit(2).help(message)
                                Button("Reintentar") { search.loadMore(account.id) }
                            } else if search.cursors[account.id] != nil { Button("Cargar más resultados") { search.loadMore(account.id) } }
                            if search.incompleteIDs.contains(account.id) { Text("Resultados incompletos del proveedor").foregroundStyle(.orange) }
                        }
                    }
                }
                Text("\(search.visibleHits.count) resultados visibles · \(search.hits.count) recibidos. Tipo y fecha se envían a Google Drive al pulsar Buscar; OneDrive y el tamaño se filtran en local. Tamaños/fechas desconocidos quedan fuera de filtros específicos.").foregroundStyle(.secondary)
            }.font(.caption).padding(12)
        }
        .navigationTitle("Buscar en todas las nubes")
        .toolbar {
            Button("Volver al explorador") { model.showGlobalSearch = false; search.cancel(); model.preview.close() }
            Button { if let selectedHit { model.previewSearchHit(selectedHit) } } label: { Image(systemName: "eye") }.disabled(selectedHit == nil).help("Vista previa (Espacio)")
                .accessibilityLabel("Vista previa")
        }
        .onDisappear { search.cancel() }
        .onChange(of: search.submittedQuery) { selected = []; model.preview.close() }
    }
    private func run() {
        guard search.query.count <= 256 else { model.error = L("Usa una búsqueda de hasta 256 caracteres."); return }
        selected = []
        model.startGlobalSearch(search.query)
    }
    @ViewBuilder private func actions(_ hit: SearchHit) -> some View {
        Button("Vista previa") { model.previewSearchHit(hit) }
        if hit.file.isFolder || hit.parentID != nil {
            Button(hit.file.isFolder ? L("Abrir carpeta") : L("Mostrar en su carpeta")) { model.openSearchLocation(hit) }
        }
        if let account = model.accounts.first(where: { $0.id == hit.accountID }), !hit.file.isGoogleDocument {
            Button("Descargar…") { Task { await model.saveMany([hit.file], targetAccount: account) } }
        }
        if hit.file.webURL != nil {
            Button("Abrir en navegador") { model.openBrowser(hit.file) }
            Button("Copiar enlace") { model.copyLink(hit.file) }
        }
        // The explorer checks this and the search did not, so here the action was offered for FTP and for a volume
        // and answered with the provider's refusal.
        if let account = model.accounts.first(where: { $0.id == hit.accountID }), account.capabilities.publicLinks {
            Button("Crear enlace público de solo lectura…") { model.pendingShare = (hit.file, account) }
        }
        ForEach(hit.file.exportOptions, id: \.ext) { option in
            if let account = model.accounts.first(where: { $0.id == hit.accountID }) {
                Button("Exportar como \(option.title)…") { Task { await model.saveMany([hit.file], export: (option.mime, option.ext), targetAccount: account) } }
            }
        }
    }
}
