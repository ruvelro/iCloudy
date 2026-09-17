import AppKit
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var selectedAccountID: String?
    @Published var files: [CloudFile] = [] { didSet { updateVisibleFiles() } }
    @Published var path: [CloudFile] = []
    /// Which top-level view of the selected account is showing. `path` hangs below it.
    @Published var collection: Collection = .files
    @Published var loading = false
    @Published var error: String?
    /// Non-error feedback, e.g. "link copied". Shown in a plain alert.
    @Published var info: String?
    /// File awaiting confirmation before a public link is created for it.
    @Published var pendingShare: (file: CloudFile, account: Account)?
    /// Items awaiting confirmation before being sent to the provider's trash.
    @Published var pendingTrash: [CloudFile]?
    /// Move or copy in progress of being targeted; drives the folder picker sheet.
    @Published var relocation: Relocation?
    /// Cross-cloud transfer waiting for its destination account.
    @Published var crossCloud: CrossCloudRequest?
    /// Self-hosted provider whose credentials form is open, if any.
    @Published var serverLogin: Cloud?
    /// True while the advanced sheet for shared drives and document libraries is open.
    /// Host of the O2 account being connected, which also drives the sign-in window.
    @Published var o2Login: O2LoginRequest?
    @Published var showAdvanced = false
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
    /// Why each of them ended, when the provider said anything worth repeating.
    @Published private(set) var expiryReasons: [String: String] = [:]
    @Published var viewMode = UserDefaults.standard.string(forKey: "viewMode") ?? "list" { didSet { UserDefaults.standard.set(viewMode, forKey: "viewMode") } }
    @Published var sortMode = "name" { didSet { updateVisibleFiles() } }
    @Published var showNameDialog = false
    @Published var editName = ""
    @Published var editingFile: CloudFile?
    @Published var demoOffline = false { didSet { demo?.offline = demoOffline } }
    let queue = TransferQueue()
    let history = TransferHistory()
    let connectivity = Connectivity()
    let mirrors = MirrorManager()
    let spotlight = SpotlightIndex()
    let localCopies = LocalCopyIndex()
    /// The running model, so App Intents and the Services menu can reach it. Intents run inside the app process.
    @MainActor static private(set) weak var shared: AppModel?
    let listings = ListingCache()
    @Published private(set) var isOnline = true
    /// True while the table shows the last known listing instead of a fresh answer from the provider.
    @Published private(set) var showingCachedListing = false
    /// True until the stored accounts have been read from the Keychain, which happens after the window is on screen.
    @Published private(set) var loadingAccounts = true
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
    var folderID: String { path.last?.id ?? collection.rootID }
    /// Recents and shared lists are not folders: nothing can be uploaded or created in them until a real folder is opened.
    var canWrite: Bool { account != nil && (collection == .files || !path.isEmpty) }
    var transfers: [Transfer] { queue.items }
    var hasActiveTransfers: Bool { queue.hasActive }
    var location: String { ([account?.email ?? ""] + (collection == .files ? [] : [collection.title]) + path.map(\.name)).joined(separator: " / ") }
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
        catch { self.error = L("No se pudo cargar la personalización: \(error.localizedDescription)") }
        do { favorites = try LocalStore.read([Favorite].self, from: favoritesURL) ?? [] }
        catch { self.error = error.localizedDescription }
        // Property observers do not run while an initializer sets its own properties.
        favoriteKeys = Set(favorites.map(\.id))
        if UserDefaults.standard.bool(forKey: "demoEnabled") { enableDemo(select: false) }
        queue.client = { [weak self] id in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) else { throw CloudError.message(L("Vuelve a conectar la cuenta de esta transferencia.")) }
            return try self.client(account)
        }
        queue.didFinish = { [weak self] transfer in self?.history.record(transfer); self?.mirrors.handleFinished(transfer) }
        queue.didStoreLocalCopy = { [weak self] copy in self?.localCopies.record(copy) }
        connectivity.onChange = { [weak self] online in
            guard let self else { return }
            isOnline = online
            queue.setOnline(online)
            // Whatever failed while offline is worth one automatic retry now.
            if online, account != nil { reload() }
        }
        queue.didComplete = { [weak self] id in
            guard let self else { return }
            if self.selectedAccountID == id { self.reload(fresh: true) }
            if let account = self.accounts.first(where: { $0.id == id }) { self.refreshStorage(account, force: true) }
        }
        // Only structural queue changes reach the explorer; progress ticks re-render the transfer panel alone.
        subscription = queue.stateChanges.sink { [weak self] _ in self?.objectWillChange.send() }
        if let message = queue.persistenceError { error = message }
        queue.cleanScratch()
        mirrors.queue = queue
        mirrors.accountLookup = { [weak self] id in self?.accounts.first { $0.id == id } }
        mirrors.start()
        loadAccounts()
        preview.download = { [weak self] file, account in
            Task { await self?.saveMany([file], targetAccount: account) }
        }
        preview.openBrowser = { [weak self] file in self?.openBrowser(file) }
        preview.didSaveCopy = { [weak self] file, account, destination in
            self?.localCopies.record(LocalCopy(accountID: account.id, fileID: file.id, name: file.name, path: destination.path,
                                               bookmark: try? TransferQueue.bookmark(destination), size: file.size ?? 0,
                                               remoteModified: file.modified, savedAt: Date(), origin: .preview))
        }
        Self.shared = self
    }

    // MARK: - System integration

    /// Queues the given local files; returns false when the current view cannot receive uploads.
    @discardableResult func uploadFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(\.isFileURL)
        if !urls.isEmpty { return enqueueUploads(urls) }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = L("El portapapeles no contiene archivos ni texto.")
            return false
        }
        return uploadText(text)
    }
    /// Writes clipboard text to a temporary .txt and queues it. The temporary file lives in iCloudy's own cache.
    @discardableResult func uploadText(_ text: String) -> Bool {
        guard canWrite else { error = L("Abre una carpeta de «Mis archivos» para subir aquí. Recientes y Compartido conmigo son listas, no carpetas."); return false }
        do {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Pasteboard", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let url = FileNames.available(in: folder, name: "Portapapeles \(stamp).txt")
            try Data(text.utf8).write(to: url, options: .atomic)
            return enqueueUploads([url])
        } catch { self.error = error.localizedDescription; return false }
    }
    func syncAllMirrors() -> Int {
        for mirror in mirrors.mirrors { mirrors.syncNow(mirror.id) }
        return mirrors.mirrors.count
    }
    func storageSummary() -> String {
        guard !accounts.isEmpty else { return L("No hay ninguna cuenta conectada en iCloudy.") }
        return accounts.map { account in
            switch storageQuotas[account.id] {
            case .available(let quota): return accountTitle(account) + " (" + account.email + "): " + quota.summary
            case .unavailable(let message): return accountTitle(account) + " (" + account.email + "): " + message
            default: return accountTitle(account) + " (" + account.email + "): " + L("consultando…")
            }
        }.joined(separator: "\n")
    }
    /// Shared by the search view, the menu bar and the Shortcuts action.
    func startGlobalSearch(_ term: String) {
        preview.close()
        showGlobalSearch = true
        globalSearch.query = String(term.prefix(256))
        // Providers without a search API would only add an error row to every search.
        globalSearch.start(accounts: accounts.filter { $0.capabilities.search }) { [weak self] account, query, cursor in
            guard let self else { throw CancellationError() }
            return try await self.client(account).searchPage(term: query, cursor: cursor, filters: self.globalSearch.filters)
        }
    }
    /// Handles a Spotlight result: folders open in place, files open their preview, because only the item itself was indexed.
    func openSpotlightItem(identifier: String) {
        guard let decoded = SpotlightIndex.decode(identifier: identifier),
              let entry = spotlight.items.first(where: { $0.accountID == decoded.accountID && $0.file.id == decoded.fileID }),
              let account = accounts.first(where: { $0.id == decoded.accountID }) else {
            error = L("Ese resultado ya no está disponible en iCloudy. Vuelve a conectar la cuenta o búscalo de nuevo.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if entry.file.isFolder { openFolder(accountID: account.id, folderID: entry.file.id) }
        else {
            showGlobalSearch = false
            selectedAccountID = account.id
            do { preview.show(file: entry.file, account: account, client: try client(account)) }
            catch { self.error = error.localizedDescription }
        }
    }
    /// Where this file stands: only in the cloud, downloaded, or downloaded but behind the cloud.
    func localStatus(_ file: CloudFile) -> LocalCopyStatus {
        guard let account else { return .cloudOnly }
        return localCopies.status(for: file, accountID: account.id)
    }
    var downloadedCount: Int {
        guard let account else { return 0 }
        return files.filter { !$0.isFolder && localCopies.status(for: $0, accountID: account.id).copy != nil }.count
    }
    func revealLocalCopy(_ file: CloudFile) {
        guard let copy = localStatus(file).copy else { return }
        if !localCopies.reveal(copy) {
            error = L("«\(copy.name)» ya no está en \(copy.path). Se ha quitado de la lista de copias locales.")
            localCopies.forget(accountID: copy.accountID, fileID: copy.fileID)
        }
    }
    func forgetLocalCopy(_ file: CloudFile) {
        guard let account else { return }
        localCopies.forget(accountID: account.id, fileID: file.id)
    }
    private func noteForSpotlight(_ file: CloudFile, account: Account) {
        spotlight.note(file, accountID: account.id, path: path, accountLabel: accountTitle(account))
    }
    /// Reads the stored accounts off the main thread. The Keychain call can block for a long time: macOS asks the user
    /// for permission whenever the app's signature changes, and doing that inside `init` froze the launch before SwiftUI
    /// had built any window, leaving a running app with nothing on screen.
    private func loadAccounts() {
        loadingAccounts = true
        Task { [favoritesKey = "accounts"] in
            let stored: [Account]
            do { stored = try await Task.detached { try Vault.read([Account].self, key: favoritesKey) ?? [] }.value }
            catch {
                loadingAccounts = false
                self.error = L("No se pudieron leer las cuentas guardadas: \(error.localizedDescription)")
                return
            }
            loadingAccounts = false
            // The demo account is local and may already be in the list.
            accounts = stored + accounts.filter(\.isDemo)
            if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
            spotlight.refreshFavorites(favorites) { [weak self] id in self?.accounts.first { $0.id == id }.map { self?.accountTitle($0) ?? $0.email } ?? id }
            if account != nil { reload() }
            for account in accounts where account.id != selectedAccountID { refreshStorage(account) }
        }
    }
    func client(_ account: Account) throws -> CloudAPI {
        if let client = clients[account.id] { return client }
        if account.isDemo && demo == nil { demo = try DemoStore() }
        let client = CloudAPI(account: account, demo: account.isDemo ? demo : nil)
        client.sessionDidExpire = { [weak self] reason in
            self?.expiredAccountIDs.insert(account.id)
            if let reason { self?.expiryReasons[account.id] = reason }
        }
        clients[account.id] = client
        return client
    }
    func isExpired(_ account: Account) -> Bool { expiredAccountIDs.contains(account.id) }
    /// What the provider said when it dropped the session, if anything.
    func expiryReason(_ account: Account) -> String? { expiryReasons[account.id] }
    /// Top-level views this account's provider can actually produce. Static because it depends only on the account,
    /// and because the header's layout rests on this never being empty, which is worth testing on its own.
    static func collections(for account: Account) -> [Collection] {
        let capabilities = account.capabilities
        return Collection.allCases.filter {
            switch $0 {
            case .files: return true
            case .recent: return capabilities.recents
            case .shared: return capabilities.sharedWithMe
            }
        }
    }
    /// Connects a folder of this Mac or of a mounted volume. macOS does the SMB, AFP or NFS work; iCloudy only needs
    /// the user to point at the folder once, which is also what grants access under the sandbox.
    func connectVolume() async {
        guard !connecting else { return }
        connectionError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = L("Conectar")
        panel.message = L("Elige la carpeta o el volumen que quieres usar como nube. Para un recurso de red, conéctalo antes en el Finder con ⌘K.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        connecting = true
        defer { connecting = false }
        do {
            let standardized = folder.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey])
            let account = Account(id: "volume:" + standardized.path, cloud: .volume,
                                  name: standardized.lastPathComponent,
                                  email: values?.volumeName.map { $0 + " · " + standardized.path } ?? standardized.path,
                                  clientID: "", clientSecret: nil, serverURL: standardized.path,
                                  bookmark: try TransferQueue.bookmark(folder))
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; clients[account.id]?.invalidate(); clients[account.id] = nil
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            select(account.id); showConnect = false
        } catch { connectionError = error.localizedDescription }
    }
    /// Accounts that can host a shared drive or a document library.
    var driveHosts: [Account] { accounts.filter { [.google, .microsoft].contains($0.cloud) && $0.driveID == nil } }
    /// Adds the shared drive as its own account. It borrows the credential of the account it came from, so there is no
    /// second sign-in and no second copy of the tokens.
    func addScopedDrive(_ drive: RemoteDrive, from parent: Account) {
        let account = Account.scoped(to: drive.id, named: drive.name, from: parent)
        do {
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; clients[account.id]?.invalidate(); clients[account.id] = nil
            showAdvanced = false
            select(account.id); showConnect = false
        } catch { self.error = error.localizedDescription }
    }
    /// Stores the session O2 handed out on its own pages. iCloudy never saw the password or the code.
    func completeO2(host: String, validationKey: String, cookies: [HTTPCookie], userAgent: String?) async {
        connectionError = nil; connecting = true
        defer { connecting = false }
        do {
            guard !validationKey.isEmpty else {
                throw CloudError.message(L("El acceso no terminó de completarse. Vuelve a intentarlo desde la página de O2."))
            }
            let state = O2Session(host: host, validationKey: validationKey, cookies: cookies, userAgent: userAgent)
            let probe = URLSession(configuration: .ephemeral)
            defer { probe.invalidateAndCancel() }
            // Asking who this is proves the session works before anything is written to the Keychain.
            let identity = try await O2API.identity(host: host, state: state, session: probe)

            let account = Account(id: "o2:\(host):\(identity)", cloud: .o2, name: L("O2 Cloud"), email: identity,
                                  clientID: "", clientSecret: nil, serverURL: "https://" + host, bookmark: nil,
                                  options: ["host": host])
            let credential = Credential(accessToken: "", refreshToken: "", expires: .distantFuture,
                                        secret: O2API.store(validationKey: validationKey, cookies: cookies,
                                                            userAgent: userAgent))
            try Vault.save(credential, key: account.id)
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; clients[account.id]?.invalidate(); clients[account.id] = nil
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            select(account.id); showConnect = false
        } catch { connectionError = error.localizedDescription }
    }

    /// Opens the Finder's own "Connect to Server" flow. Mounting is not something a sandboxed app may do itself.
    func openFinderConnect() {
        guard let url = URL(string: "smb://") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Connects a server the user hosts: WebDAV or FTP. The password goes straight to the Keychain and never leaves
    /// this Mac except to that server.
    func connectServer(cloud: Cloud, server: String, username: String, password: String, flavor: String? = nil) async {
        guard !connecting else { return }
        connectionError = nil; connecting = true
        defer { connecting = false }
        do {
            let result: (Account, Credential)
            switch cloud {
            case .webdav: result = try await oauth.signInWebDAV(server: server, username: username, password: password)
            case .ftp: result = try await oauth.signInFTP(server: server, username: username, password: password)
            case .mega: result = try await oauth.signInMega(email: username, password: password)
            default: throw CloudError.message(L("\(cloud.title) no se conecta con usuario y contraseña."))
            }
            var (account, credential) = result
            if let flavor { account.options["flavor"] = flavor }
            try Vault.save(credential, key: account.id)
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; clients[account.id]?.invalidate(); clients[account.id] = nil
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            serverLogin = nil
            select(account.id); showConnect = false
        } catch { connectionError = error.localizedDescription }
    }
    /// Starts the provider's sign-in for the same cloud; signing in with the same identity replaces the expired session.
    /// Reconnecting has to take the same road the account was created by. Sending a provider that never used OAuth
    /// down the OAuth path produced a message about configuration that had nothing to do with the problem.
    func reconnect(_ account: Account) async {
        connectionError = nil
        switch account.cloud {
        case .volume:
            await connectVolume()
        case let cloud where cloud.usesWebLogin || cloud.usesPasswordLogin:
            // These two sign in from inside the connection sheet, so it has to be on screen to present them.
            showConnect = true
            if cloud.usesWebLogin { o2Login = O2LoginRequest(id: account.options["host"] ?? "cloud.o2online.es") }
            else { serverLogin = cloud }
        default:
            await connect(cloud: account.cloud)
        }
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
        appearances[account.id] ?? AccountAppearance(tint: Self.defaultTint(account.cloud))
    }
    static func defaultTint(_ cloud: Cloud) -> AccountTint {
        switch cloud {
        case .google: return .green
        case .microsoft: return .blue
        case .dropbox: return .purple
        case .box: return .teal
        case .webdav: return .gray
        case .ftp: return .orange
        case .volume: return .gray
        case .mega: return .red
        case .o2: return .pink
        }
    }
    func accountTitle(_ account: Account) -> String { appearance(for: account).title(for: account) }
    func saveAppearance(_ value: AccountAppearance, for account: Account) throws {
        guard let appearanceStore else { throw CloudError.message(L("No se puede guardar la personalización. Se conserva el archivo anterior; revisa el error de carga.")) }
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
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            select(account.id); showConnect = false
        } catch is CancellationError {} catch { connectionError = error.localizedDescription }
    }
    func canDisconnect(_ account: Account) -> Bool {
        accounts.contains { $0.id == account.id } && !queue.hasActive(accountID: account.id)
    }
    func disconnect(_ account: Account) {
        guard canDisconnect(account) else {
            error = L("Pausa o termina las transferencias de esta cuenta antes de desconectarla.")
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
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            listings.removeAll(accountID: account.id)
            mirrors.removeAll(accountID: account.id)
            spotlight.removeAccount(account.id)
            localCopies.removeAccount(account.id)
            accounts = updated
            globalSearch.removeAccount(account.id)
            if selectedAccountID == account.id { select(accounts.first?.id) }
        } catch { self.error = error.localizedDescription }
    }
    func refreshStorage(_ account: Account, force: Bool = false) {
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        // Asking a provider that has no quota command would only produce a pointless error every time.
        guard account.capabilities.quota else {
            storageQuotas[account.id] = .unavailable(L("\(account.cloud.title) no informa del espacio disponible."))
            return
        }
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
    func select(_ id: String?) { preview.close(); globalSearch.cancel(); showGlobalSearch = false; selectedAccountID = id; collection = .files; path = []; search = ""; files = []; reload() }
    func show(_ target: Collection) {
        guard let account, target != collection || !path.isEmpty else { return }
        guard Self.collections(for: account).contains(target) else { return }
        preview.close(); collection = target; path = []; search = ""; files = []
        // Recents only make sense in time order; the user can switch back afterwards.
        if target == .recent { sortMode = "date" } else if sortMode == "date" && target == .files { sortMode = "name" }
        reload()
    }
    func previewSearchHit(_ hit: SearchHit) {
        guard let account = accounts.first(where: { $0.id == hit.accountID }) else { return }
        do { preview.show(file: hit.file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }
    func openSearchLocation(_ hit: SearchHit) {
        guard let target = hit.file.isFolder ? hit.file.id : hit.parentID else { return }
        openFolder(accountID: hit.accountID, folderID: target)
    }
    /// Jumps to a remote folder of any connected account, rebuilding the breadcrumbs from the provider.
    func openFolder(accountID: String, folderID target: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { error = L("Conecta la cuenta de esta transferencia para abrir su carpeta."); return }
        navigationTask?.cancel(); let request = UUID(); navigationID = request; loading = true
        navigationTask = Task {
            do {
                let trail = try await client(account).folderTrail(id: target)
                try Task.checkCancellation()
                guard navigationID == request else { return }
                preview.close(); globalSearch.cancel(); showGlobalSearch = false
                selectedAccountID = account.id; collection = .files; path = trail; search = ""; files = []; reload()
            } catch {
                guard navigationID == request else { return }
                loading = false
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func showPreview(_ file: CloudFile) {
        guard let account else { return }
        noteForSpotlight(file, account: account)
        do { preview.show(file: file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }
    func navigate(_ file: CloudFile) {
        guard file.isFolder, let account else { return }
        noteForSpotlight(file, account: account)
        preview.close(); path.append(file); search = ""; files = []; reload()
    }
    func back(to count: Int) { preview.close(); path = Array(path.prefix(count)); search = ""; files = []; reload() }
    /// `fresh` skips the cached copy, e.g. right after a write the cache cannot know about yet.
    func reload(fresh: Bool = false) {
        navigationTask?.cancel()
        let requestID = UUID(); navigationID = requestID
        guard let account else { files = []; loading = false; showingCachedListing = false; return }
        refreshStorage(account)
        let parent = folderID; loading = true
        // Show what was there last time at once; the provider's answer replaces it when it arrives.
        if !fresh, Prefs.bool(Prefs.listingCache, default: true), files.isEmpty,
           let cached = listings.cached(accountID: account.id, parent: parent) { files = cached; showingCachedListing = true }
        else if fresh { showingCachedListing = false }
        navigationTask = Task {
            do {
                // Intermediate pages appear as they arrive; `loading` stays on until the last one.
                let result = try await client(account).list(parent: parent) { partial in
                    guard self.navigationID == requestID else { return }
                    self.files = partial; self.showingCachedListing = false
                }
                guard navigationID == requestID else { return }
                files = result; loading = false; showingCachedListing = false
                listings.store(result, accountID: account.id, parent: parent)
                // Drop entries whose local file the user has moved or deleted meanwhile.
                localCopies.verify(result, accountID: account.id)
            } catch {
                guard navigationID == requestID else { return }
                loading = false
                // An expired session already shows a banner with a reconnect button; an extra alert would only repeat it.
                if (error as? CloudError)?.isSessionExpired == true { return }
                if !isOnline { return } // the banner already says so
                if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
            }
        }
    }
    /// Copies the provider's own web link; it opens only for people who already have access.
    func copyLink(_ file: CloudFile) {
        guard let url = file.webURL else { error = L("Este elemento no tiene enlace web."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        info = L("Enlace copiado. Solo funciona para quien ya tenga acceso a «\(file.name)».")
    }
    /// Sharing with anyone is irreversible from the app, so the view asks for confirmation before calling this.
    func createPublicLink(_ file: CloudFile, account target: Account? = nil) async {
        guard let account = target ?? account else { return }
        do {
            let link = try await client(account).publicLink(for: file)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            info = L("Enlace público copiado. Cualquiera que lo tenga podrá ver «\(file.name)». Para revocarlo, usa la web del proveedor.")
        } catch { self.error = error.localizedDescription }
    }
    func requestRelocation(_ files: [CloudFile], copy: Bool) {
        guard let account, !files.isEmpty else { return }
        if copy, account.cloud == .google, files.contains(where: \.isFolder) {
            error = L("Google Drive no permite copiar carpetas. Copia los archivos que contiene."); return
        }
        if copy, !account.capabilities.copy { error = L("\(account.cloud.title) no permite copiar desde iCloudy."); return }
        relocation = Relocation(files: files, kind: copy ? .copy : .move, account: account, origin: path.isEmpty && collection != .files ? nil : folderID)
    }
    func requestCrossCloud(_ files: [CloudFile]) {
        guard let account, !files.isEmpty else { return }
        guard accounts.count > 1 else { error = L("Conecta otra cuenta para poder enviar archivos entre nubes."); return }
        crossCloud = CrossCloudRequest(files: files, source: account)
    }
    /// Queues one job per item; the queue stages each file locally and uploads it with checkpoints and verification.
    func enqueueCrossCloud(_ files: [CloudFile], from source: Account, to target: Account, parent: String, destinationPath: [CloudFile]) {
        let label = ([target.email] + destinationPath.map(\.name)).joined(separator: " / ")
        let batch = UUID()
        let jobs = files.map { file -> Transfer in
            var job = Transfer(batchID: batch, name: file.name, destination: label, accountID: source.id, direction: .transfer, localURL: URL(fileURLWithPath: "/"), parent: parent, file: file)
            job.localURL = queue.scratchDirectory(for: job.id)
            job.targetAccountID = target.id
            return job
        }
        do { try queue.add(jobs); info = L("\(jobs.count == 1 ? L("«\(files[0].name)»") : L("\(jobs.count) elementos")) en cola hacia \(accountTitle(target)). Sigue el progreso en Transferencias.") }
        catch { self.error = error.localizedDescription }
    }
    /// Checks cycles and name clashes first, then processes item by item and stops at the first failure.
    func relocate(_ request: Relocation, to destination: String, destinationPath: [CloudFile]) async {
        if case .transfer(let source) = request.kind {
            enqueueCrossCloud(request.files, from: source, to: request.account, parent: destination, destinationPath: destinationPath); return
        }
        let ids = Set(request.files.map(\.id))
        guard !ids.contains(destination), !destinationPath.contains(where: { ids.contains($0.id) }) else {
            error = L("Una carpeta no puede moverse ni copiarse dentro de sí misma."); return
        }
        var done = 0
        do {
            let api = try client(request.account)
            let siblings = try await api.list(parent: destination)
            let clashes = request.files.filter { file in siblings.contains { $0.id != file.id && $0.name.localizedCaseInsensitiveCompare(file.name) == .orderedSame } }
            guard clashes.isEmpty else {
                throw CloudError.message(L("En la carpeta de destino ya existe ") + clashes.map { "«\($0.name)»" }.joined(separator: ", ") + ". Renombra antes de mover o copiar.")
            }
            for file in request.files {
                if request.isMove { try await api.move(file: file, to: destination) } else { try await api.copy(file: file, to: destination) }
                done += 1
                if request.isMove {
                    for i in favorites.indices where favorites[i].accountID == request.account.id && favorites[i].file.id == file.id {
                        favorites[i].path = destinationPath; favorites[i].collection = .files
                    }
                }
            }
            if request.isMove { try LocalStore.save(favorites, to: favoritesURL) }
            let target = destinationPath.last?.name ?? "Mis archivos"
            let verb = request.isMove ? (done == 1 ? "movido" : "movidos") : (done == 1 ? "copiado" : "copiados")
            info = L("\(done == 1 ? L("«\(request.files[0].name)»") : L("\(done) elementos")) \(verb) a «\(target)».") + (!request.isMove && request.account.cloud == .microsoft ? L(" OneDrive puede tardar unos segundos en mostrar la copia.") : L(""))
        } catch {
            self.error = (done > 0 ? L("Se completaron \(done) de \(request.files.count). ") : L("")) + error.localizedDescription
        }
        reload(fresh: true)
    }
    /// Asks for a local folder and mirrors it, one way, into the given remote folder of the current account.
    func pickMirrorSource(for folder: CloudFile) async {
        guard let account, folder.isFolder else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Reflejar"
        panel.message = L("Los archivos de la carpeta elegida se subirán a «\(folder.name)» y se mantendrán al día. Solo en un sentido: iCloudy nunca borra ni modifica lo local, y no elimina en la nube lo que borres aquí.")
        guard await panel.begin() == .OK, let local = panel.url else { return }
        do {
            try mirrors.add(local: local, account: account, folder: folder, path: path)
            info = L("«\(local.lastPathComponent)» se refleja en «\(folder.name)». La primera sincronización está en cola.")
        } catch { self.error = error.localizedDescription }
    }
    func revealLocal(_ mirror: FolderMirror) { NSWorkspace.shared.activateFileViewerSelecting([mirror.localURL]) }
    func requestTrash(_ files: [CloudFile]) {
        guard account != nil, !files.isEmpty else { return }
        pendingTrash = files
    }
    /// Sends the items to the trash one by one and stops at the first failure so the user sees exactly what remains.
    func trash(_ files: [CloudFile]) async {
        guard let account else { return }
        var moved = 0
        do {
            let api = try client(account)
            for file in files {
                try await api.trash(file: file)
                moved += 1
                favorites.removeAll { $0.accountID == account.id && ($0.file.id == file.id || $0.path.contains { $0.id == file.id }) }
            }
            try LocalStore.save(favorites, to: favoritesURL)
            info = moved == 1 ? L("«\(files[0].name)» está en la papelera de \(account.cloud.title). Puedes restaurarlo desde su web.") : L("\(moved) elementos enviados a la papelera de \(account.cloud.title).")
        } catch {
            self.error = (moved > 0 ? L("Se enviaron \(moved) de \(files.count) elementos. ") : L("")) + error.localizedDescription
        }
        reload(fresh: true)
    }
    /// Shows a downloaded item in the Finder, going through its security-scoped bookmark under the sandbox.
    func reveal(_ entry: HistoryEntry) {
        guard let target = entry.localURL else { return }
        var folder = target.deletingLastPathComponent()
        if let bookmark = entry.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { folder = resolved }
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let item = folder.appendingPathComponent(target.lastPathComponent)
        guard FileManager.default.fileExists(atPath: item.path) else { error = L("«\(target.lastPathComponent)» ya no está en \(folder.path)."); return }
        NSWorkspace.shared.activateFileViewerSelecting([item])
    }
    func openBrowser(_ file: CloudFile) {
        guard let url = file.webURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { error = L("No hay un enlace web disponible."); return }
        NSWorkspace.shared.open(url)
    }
    func pickUpload() async {
        guard let account, canWrite else { return }
        let parent = folderID, destination = location
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.prompt = "Subir"
        if await panel.begin() == .OK { enqueueUploads(panel.urls, target: (account, parent, destination)) }
    }
    @discardableResult func enqueueUploads(_ urls: [URL], target: (Account, String, String)? = nil) -> Bool {
        guard let account = target?.0 ?? account, target != nil || canWrite else {
            if !canWrite { error = L("Abre una carpeta de «Mis archivos» para subir aquí. Recientes y Compartido conmigo son listas, no carpetas.") }
            return false
        }
        let batch = UUID()
        do {
            let jobs = try urls.filter(\.isFileURL).map { url -> Transfer in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Transfer(batchID: batch, name: url.lastPathComponent, destination: target?.2 ?? location, accountID: account.id, direction: .upload, localURL: url, bookmark: try TransferQueue.bookmark(url), parent: target?.1 ?? folderID)
            }
            try queue.add(jobs)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func save(_ file: CloudFile, export: (mime: String, ext: String)? = nil) async { await saveMany([file], export: export) }
    func saveMany(_ files: [CloudFile], export: (mime: String, ext: String)? = nil, targetAccount: Account? = nil) async {
        guard let account = targetAccount ?? account, accounts.contains(where: { $0.id == account.id }), !files.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = L("Guardar aquí")
        panel.message = L("Los documentos de Google dentro de carpetas se guardan como enlaces. Si hay nombres repetidos, podrás decidir qué hacer.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        do {
            let bookmark = try TransferQueue.bookmark(folder), batch = UUID()
            try queue.add(files.map { file in Transfer(batchID: batch, name: file.name, destination: folder.path, accountID: account.id, direction: .download, localURL: folder, bookmark: bookmark, file: file, exportMime: export?.mime, exportExtension: export?.ext) })
        } catch { self.error = error.localizedDescription }
    }
    func promptName(_ file: CloudFile? = nil) {
        guard let account, file != nil || canWrite else { return }
        editingFile = file; editName = file?.name ?? ""; editContext = (account, folderID); showNameDialog = true
    }
    func commitName() async {
        guard let (account, parent) = editContext else { return }
        let file = editingFile, name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = FileNames.problem(with: name, for: account.cloud) { error = problem; return }
        do {
            let api = try client(account)
            let siblings = try await api.list(parent: parent)
            guard !siblings.contains(where: { $0.id != file?.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw CloudError.message(L("Ya existe un elemento con ese nombre. Elige otro.")) }
            if let file {
                try await api.rename(file: file, name: name)
                let updated = CloudFile(id: file.id, name: name, mime: file.mime, size: file.size, modified: Date(), webURL: file.webURL, isFolder: file.isFolder)
                for i in favorites.indices where favorites[i].accountID == account.id {
                    if favorites[i].file.id == file.id { favorites[i].file = updated }
                    favorites[i].path = favorites[i].path.map { $0.id == file.id ? updated : $0 }
                }
                try LocalStore.save(favorites, to: favoritesURL)
            } else { _ = try await api.createFolder(name: name, parent: parent) }
            showNameDialog = false; reload(fresh: true)
        } catch { self.error = error.localizedDescription }
    }
    func isFavorite(_ file: CloudFile) -> Bool { favoriteKeys.contains((selectedAccountID ?? "") + ":" + file.id) }
    func toggleFavorite(_ file: CloudFile) {
        guard let account else { return }
        if isFavorite(file) { favorites.removeAll { $0.accountID == account.id && $0.file.id == file.id } }
        else { favorites.append(Favorite(accountID: account.id, file: file, path: path, collection: collection)) }
        do { try LocalStore.save(favorites, to: favoritesURL) } catch { self.error = error.localizedDescription }
        spotlight.refreshFavorites(favorites) { [weak self] id in self?.accounts.first { $0.id == id }.map { self?.accountTitle($0) ?? $0.email } ?? id }
    }
    func openFavorite(_ favorite: Favorite) {
        guard accounts.contains(where: { $0.id == favorite.accountID }) else { error = L("Conecta la cuenta de este favorito."); return }
        preview.close()
        showGlobalSearch = false; globalSearch.cancel()
        selectedAccountID = favorite.accountID; collection = favorite.collection; path = favorite.path + (favorite.file.isFolder ? [favorite.file] : []); files = []; search = ""; reload()
    }
}
