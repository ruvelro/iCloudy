import AppKit
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var selectedAccountID: String?
    @Published var files: [CloudFile] = [] { didSet { updateVisibleFiles() } }
    @Published var path: [CloudFile] = []
    @Published var loading = false
    @Published var error: String?
    @Published var connecting = false
    @Published var connectionError: String?
    @Published var showConnect = false
    @Published var search = "" { didSet { updateVisibleFiles() } }
    @Published var favorites: [Favorite] = [] { didSet { favoriteKeys = Set(favorites.map(\.id)) } }
    /// Filtered and sorted once per change of `files`, `search` or `sortMode`, not on every render.
    @Published private(set) var visibleFiles: [CloudFile] = []
    @Published var showGlobalSearch = false
    @Published var appearanceAccount: Account?
    @Published private(set) var appearances: [String: AccountAppearance] = [:]
    @Published private(set) var storageQuotas: [String: StorageQuotaState] = [:]
    /// Accounts whose provider rejected the stored credential. Shown in the sidebar until the user reconnects.
    @Published private(set) var expiredAccountIDs: Set<String> = []
    @Published var viewMode = UserDefaults.standard.string(forKey: "viewMode") ?? "list" { didSet { UserDefaults.standard.set(viewMode, forKey: "viewMode") } }
    @Published var sortMode = "name" { didSet { updateVisibleFiles() } }
    @Published var showNameDialog = false
    @Published var editName = ""
    @Published var editingFile: CloudFile?
    @Published var demoOffline = false { didSet { demo?.offline = demoOffline } }
    let queue = TransferQueue()
    let oauth = OAuth()
    let preview = PreviewWindow()
    let globalSearch = GlobalSearch()
    private var appearanceStore: AppearanceStore?
    private var demo: DemoStore?
    private var clients: [String: CloudAPI] = [:]
    private var navigationTask: Task<Void, Never>?
    private var navigationID = UUID()
    private var quotaTasks: [String: Task<Void, Never>] = [:]
    private var quotaRequestIDs: [String: UUID] = [:]
    private var quotaFetched: [String: Date] = [:]
    private var favoriteKeys: Set<String> = []
    private var subscription: AnyCancellable?
    private var editContext: (Account, String)?
    private let favoritesURL = LocalStore.directory.appendingPathComponent("favorites.json")
    /// Opening folders refreshes the quota at most this often; explicit requests and finished transfers always do.
    static let quotaRefreshInterval: TimeInterval = 300

    var account: Account? { accounts.first { $0.id == selectedAccountID } }
    var folderID: String { path.last?.id ?? "root" }
    var transfers: [Transfer] { queue.items }
    var hasActiveTransfers: Bool { queue.hasActive }
    var location: String { ([account?.email ?? ""] + path.map(\.name)).joined(separator: " / ") }
    private func updateVisibleFiles() {
        let term = search, mode = sortMode
        visibleFiles = files.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if mode == "size", a.size != b.size { return (a.size ?? 0) > (b.size ?? 0) }
            if mode == "date", a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    init() {
        do { let store = try AppearanceStore(); appearanceStore = store; appearances = store.values }
        catch { self.error = "No se pudo cargar la personalización: \(error.localizedDescription)" }
        do {
            accounts = try Vault.read([Account].self, key: "accounts") ?? []
            favorites = try LocalStore.read([Favorite].self, from: favoritesURL) ?? []
        } catch { self.error = error.localizedDescription }
        // Property observers do not run while an initializer sets its own properties.
        favoriteKeys = Set(favorites.map(\.id))
        if UserDefaults.standard.bool(forKey: "demoEnabled") { enableDemo(select: false) }
        selectedAccountID = accounts.first?.id
        queue.client = { [weak self] id in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) else { throw CloudError.message("Vuelve a conectar la cuenta de esta transferencia.") }
            return try self.client(account)
        }
        queue.didComplete = { [weak self] id in
            guard let self else { return }
            if self.selectedAccountID == id { self.reload() }
            if let account = self.accounts.first(where: { $0.id == id }) { self.refreshStorage(account, force: true) }
        }
        // Only structural queue changes reach the explorer; progress ticks re-render the transfer panel alone.
        subscription = queue.stateChanges.sink { [weak self] _ in self?.objectWillChange.send() }
        if let message = queue.persistenceError { error = message }
        if account != nil { reload() }
        for account in accounts where account.id != selectedAccountID { refreshStorage(account) }
        preview.download = { [weak self] file, account in
            Task { await self?.saveMany([file], targetAccount: account) }
        }
        preview.openBrowser = { [weak self] file in self?.openBrowser(file) }
    }
    func client(_ account: Account) throws -> CloudAPI {
        if let client = clients[account.id] { return client }
        if account.isDemo && demo == nil { demo = try DemoStore() }
        let client = CloudAPI(account: account, demo: account.isDemo ? demo : nil)
        client.sessionDidExpire = { [weak self] in self?.expiredAccountIDs.insert(account.id) }
        clients[account.id] = client
        return client
    }
    func isExpired(_ account: Account) -> Bool { expiredAccountIDs.contains(account.id) }
    /// Starts the provider's sign-in for the same cloud; signing in with the same identity replaces the expired session.
    func reconnect(_ account: Account) async {
        await connect(cloud: account.cloud)
        if let message = connectionError, !showConnect { error = message; connectionError = nil }
    }
    func enableDemo(select shouldSelect: Bool = true) {
        do {
            if demo == nil { demo = try DemoStore() }
            if !accounts.contains(where: \.isDemo) { accounts.append(.demo) }
            UserDefaults.standard.set(true, forKey: "demoEnabled")
            if shouldSelect { select(Account.demo.id); showConnect = false }
        } catch { self.error = error.localizedDescription }
    }
    func appearance(for account: Account) -> AccountAppearance {
        appearances[account.id] ?? AccountAppearance(tint: account.cloud == .google ? .green : .blue)
    }
    func accountTitle(_ account: Account) -> String { appearance(for: account).title(for: account) }
    func saveAppearance(_ value: AccountAppearance, for account: Account) throws {
        guard let appearanceStore else { throw CloudError.message("No se puede guardar la personalización. Se conserva el archivo anterior; revisa el error de carga.") }
        try appearanceStore.save(value, for: account.id); appearances = appearanceStore.values
    }
    func failNextDemoTransfer() { demo?.failNext = true }
    func connect(cloud: Cloud) async {
        guard !connecting else { return }
        connectionError = nil; connecting = true
        defer { connecting = false }
        do {
            let configuration = try OAuthConfiguration.load()
            let client = try configuration.client(for: cloud)
            let (account, credential) = try await oauth.signIn(cloud: cloud, clientID: client.id, clientSecret: client.secret)
            try Vault.save(credential, key: account.id)
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; clients[account.id]?.invalidate(); clients[account.id] = nil
            expiredAccountIDs.remove(account.id)
            select(account.id); showConnect = false
        } catch is CancellationError {} catch { connectionError = error.localizedDescription }
    }
    func canDisconnect(_ account: Account) -> Bool {
        accounts.contains { $0.id == account.id } && !queue.hasActive(accountID: account.id)
    }
    func disconnect(_ account: Account) {
        guard canDisconnect(account) else {
            error = "Pausa o termina las transferencias de esta cuenta antes de desconectarla."
            return
        }
        do {
            if preview.model.account?.id == account.id { preview.close() }
            let updated = accounts.filter { $0.id != account.id }
            if account.isDemo { UserDefaults.standard.set(false, forKey: "demoEnabled") }
            else { try Vault.save(updated.filter { !$0.isDemo }, key: "accounts"); try Vault.delete(key: account.id) }
            quotaTasks.removeValue(forKey: account.id)?.cancel()
            quotaRequestIDs[account.id] = nil; storageQuotas[account.id] = nil
            clients[account.id]?.invalidate(); clients[account.id] = nil
            expiredAccountIDs.remove(account.id)
            accounts = updated
            globalSearch.removeAccount(account.id)
            if selectedAccountID == account.id { select(accounts.first?.id) }
        } catch { self.error = error.localizedDescription }
    }
    func refreshStorage(_ account: Account, force: Bool = false) {
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        if !force, case .available = storageQuotas[account.id], let fetched = quotaFetched[account.id], Date().timeIntervalSince(fetched) < Self.quotaRefreshInterval { return }
        quotaTasks[account.id]?.cancel()
        let requestID = UUID(); quotaRequestIDs[account.id] = requestID
        // Keep an already displayed value visible while refreshing it.
        if case .available = storageQuotas[account.id] {} else { storageQuotas[account.id] = .loading }
        quotaTasks[account.id] = Task { [weak self] in
            guard let self else { return }
            defer { if quotaRequestIDs[account.id] == requestID { quotaTasks[account.id] = nil } }
            do {
                let quota = try await client(account).storageQuota()
                try Task.checkCancellation()
                guard quotaRequestIDs[account.id] == requestID else { return }
                storageQuotas[account.id] = .available(quota); quotaFetched[account.id] = Date()
            } catch {
                guard !Task.isCancelled, quotaRequestIDs[account.id] == requestID else { return }
                storageQuotas[account.id] = .unavailable(error.localizedDescription)
            }
        }
    }
    func select(_ id: String?) { preview.close(); globalSearch.cancel(); showGlobalSearch = false; selectedAccountID = id; path = []; search = ""; files = []; reload() }
    func previewSearchHit(_ hit: SearchHit) {
        guard let account = accounts.first(where: { $0.id == hit.accountID }) else { return }
        do { preview.show(file: hit.file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }
    func openSearchLocation(_ hit: SearchHit) {
        guard let account = accounts.first(where: { $0.id == hit.accountID }), let target = hit.file.isFolder ? hit.file.id : hit.parentID else { return }
        navigationTask?.cancel(); let request = UUID(); navigationID = request; loading = true
        navigationTask = Task {
            do {
                let trail = try await client(account).folderTrail(id: target)
                try Task.checkCancellation()
                guard navigationID == request else { return }
                preview.close(); globalSearch.cancel(); showGlobalSearch = false
                selectedAccountID = account.id; path = trail; search = ""; files = []; reload()
            } catch {
                guard navigationID == request else { return }
                loading = false
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func showPreview(_ file: CloudFile) {
        guard let account else { return }
        do { preview.show(file: file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }
    func navigate(_ file: CloudFile) { guard file.isFolder else { return }; preview.close(); path.append(file); search = ""; files = []; reload() }
    func back(to count: Int) { preview.close(); path = Array(path.prefix(count)); search = ""; files = []; reload() }
    func reload() {
        navigationTask?.cancel()
        let requestID = UUID(); navigationID = requestID
        guard let account else { files = []; loading = false; return }
        refreshStorage(account)
        let parent = folderID; loading = true
        navigationTask = Task {
            do {
                // Intermediate pages appear as they arrive; `loading` stays on until the last one.
                let result = try await client(account).list(parent: parent) { [weak self] partial in
                    guard let self, self.navigationID == requestID else { return }
                    self.files = partial
                }
                guard navigationID == requestID else { return }
                files = result; loading = false
            } catch {
                guard navigationID == requestID else { return }
                loading = false
                // An expired session already shows a banner with a reconnect button; an extra alert would only repeat it.
                if (error as? CloudError)?.isSessionExpired == true { return }
                if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func openBrowser(_ file: CloudFile) {
        guard let url = file.webURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { error = "No hay un enlace web disponible."; return }
        NSWorkspace.shared.open(url)
    }
    func pickUpload() async {
        guard let account else { return }
        let parent = folderID, destination = location
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.prompt = "Subir"
        if await panel.begin() == .OK { enqueueUploads(panel.urls, target: (account, parent, destination)) }
    }
    func enqueueUploads(_ urls: [URL], target: (Account, String, String)? = nil) {
        guard let account = target?.0 ?? account else { return }
        let batch = UUID()
        do {
            let jobs = try urls.filter(\.isFileURL).map { url -> Transfer in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Transfer(batchID: batch, name: url.lastPathComponent, destination: target?.2 ?? location, accountID: account.id, direction: .upload, localURL: url, bookmark: try TransferQueue.bookmark(url), parent: target?.1 ?? folderID)
            }
            try queue.add(jobs)
        } catch { self.error = error.localizedDescription }
    }
    func save(_ file: CloudFile, export: (mime: String, ext: String)? = nil) async { await saveMany([file], export: export) }
    func saveMany(_ files: [CloudFile], export: (mime: String, ext: String)? = nil, targetAccount: Account? = nil) async {
        guard let account = targetAccount ?? account, accounts.contains(where: { $0.id == account.id }), !files.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Guardar aquí"
        panel.message = "Los documentos de Google dentro de carpetas se guardan como enlaces. Si hay nombres repetidos, podrás decidir qué hacer."
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        do {
            let bookmark = try TransferQueue.bookmark(folder), batch = UUID()
            try queue.add(files.map { file in Transfer(batchID: batch, name: file.name, destination: folder.path, accountID: account.id, direction: .download, localURL: folder, bookmark: bookmark, file: file, exportMime: export?.mime, exportExtension: export?.ext) })
        } catch { self.error = error.localizedDescription }
    }
    func promptName(_ file: CloudFile? = nil) {
        guard let account else { return }
        editingFile = file; editName = file?.name ?? ""; editContext = (account, folderID); showNameDialog = true
    }
    func commitName() async {
        guard let (account, parent) = editContext else { return }
        let file = editingFile, name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = FileNames.problem(with: name, for: account.cloud) { error = problem; return }
        do {
            let api = try client(account)
            let siblings = try await api.list(parent: parent)
            guard !siblings.contains(where: { $0.id != file?.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw CloudError.message("Ya existe un elemento con ese nombre. Elige otro.") }
            if let file {
                try await api.rename(file: file, name: name)
                let updated = CloudFile(id: file.id, name: name, mime: file.mime, size: file.size, modified: Date(), webURL: file.webURL, isFolder: file.isFolder)
                for i in favorites.indices where favorites[i].accountID == account.id {
                    if favorites[i].file.id == file.id { favorites[i].file = updated }
                    favorites[i].path = favorites[i].path.map { $0.id == file.id ? updated : $0 }
                }
                try LocalStore.save(favorites, to: favoritesURL)
            } else { _ = try await api.createFolder(name: name, parent: parent) }
            showNameDialog = false; reload()
        } catch { self.error = error.localizedDescription }
    }
    func isFavorite(_ file: CloudFile) -> Bool { favoriteKeys.contains((selectedAccountID ?? "") + ":" + file.id) }
    func toggleFavorite(_ file: CloudFile) {
        guard let account else { return }
        if isFavorite(file) { favorites.removeAll { $0.accountID == account.id && $0.file.id == file.id } }
        else { favorites.append(Favorite(accountID: account.id, file: file, path: path)) }
        do { try LocalStore.save(favorites, to: favoritesURL) } catch { self.error = error.localizedDescription }
    }
    func openFavorite(_ favorite: Favorite) {
        guard accounts.contains(where: { $0.id == favorite.accountID }) else { error = "Conecta la cuenta de este favorito."; return }
        preview.close()
        showGlobalSearch = false; globalSearch.cancel()
        selectedAccountID = favorite.accountID; path = favorite.path + (favorite.file.isFolder ? [favorite.file] : []); files = []; search = ""; reload()
    }
}
