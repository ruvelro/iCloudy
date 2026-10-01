import AppKit
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    /// Panes and tabs, each with its own place and listing. The properties below forward to the focused pane's
    /// active tab, so everything that asks for "the open folder" keeps getting exactly that.
    @Published var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [AppModel.newBrowser()])])
    let workspaceStore = WorkspaceStore()
    /// A move from one pane to another account, waiting for confirmation.
    @Published var pendingPaneMove: PaneMoveRequest?
    let paneTransfers = PaneTransfers()
    var selectedAccountID: String? {
        get { workspace.current.accountID }
        set { workspace.current.accountID = newValue }
    }
    var files: [CloudFile] {
        get { workspace.current.files }
        set { workspace.current.files = newValue }
    }
    var path: [CloudFile] {
        get { workspace.current.path }
        set { workspace.current.path = newValue }
    }
    /// Which top-level view of the selected account is showing. `path` hangs below it.
    var collection: Collection {
        get { workspace.current.collection }
        set { workspace.current.collection = newValue }
    }
    var loading: Bool {
        get { workspace.current.loading }
        set { workspace.current.loading = newValue }
    }
    /// What is selected in the focused tab. Each tab keeps its own, so switching back finds it as it was left.
    var selectedIDs: Set<CloudFile.ID> {
        get { workspace.current.selection }
        set { workspace.current.selection = newValue }
    }
    @Published var error: String?
    /// Non-error feedback, e.g. "link copied". Shown in a plain alert.
    @Published var info: String?
    /// SwiftUI presents one alert at a time, so an error and a piece of good news arriving together meant the second
    /// one never appeared at all. They share a presentation now: the error goes first and the other waits its turn.
    var alertTitle: String { error != nil ? L("No se pudo completar la operación") : L("iCloudy") }
    var alertMessage: String? { error ?? info }
    func dismissAlert() { if error != nil { error = nil } else { info = nil } }
    /// File awaiting confirmation before a public link is created for it.
    @Published var pendingShare: (file: CloudFile, account: Account)?
    /// S3 file awaiting the choice of how long its presigned link lives.
    @Published var pendingTemporaryLink: (file: CloudFile, account: Account)?
    /// Items awaiting confirmation before being sent to the provider's trash.
    @Published var pendingTrash: [CloudFile]?
    /// The item whose sharing sheet is open.
    @Published var sharing: SharingRequest?
    /// The item whose public links sheet is open, and the account whose list of every link is open.
    @Published var publicLinkManager: PublicLinksRequest?
    @Published var linkInventory: Account?
    /// The file whose versions sheet is open.
    @Published var versionHistory: VersionsRequest?
    /// Items awaiting confirmation before being deleted for good, from the trash or straight from the tree.
    @Published var pendingPurge: [CloudFile]?
    /// True while the confirmation to empty the whole trash is showing.
    @Published var pendingEmptyTrash = false
    /// Move or copy in progress of being targeted; drives the folder picker sheet.
    @Published var relocation: Relocation?
    /// Cross-cloud transfer waiting for its destination account.
    @Published var crossCloud: CrossCloudRequest?
    /// Self-hosted provider whose credentials form is open, if any.
    @Published var serverLogin: Cloud?
    /// The account that form was opened to reconnect, so it arrives with its address and user already written.
    /// Retyping a NAS address from memory to fix a session is a poor way to ask somebody for a password.
    @Published var reconnecting: Account?
    /// True while the advanced sheet for shared drives and document libraries is open.
    /// Host of the O2 account being connected, which also drives the sign-in window.
    @Published var o2Login: O2LoginRequest?
    @Published var showAdvanced = false
    @Published var connecting = false
    @Published var connectionError: String?
    @Published var showConnect = false
    var search: String {
        get { workspace.current.search }
        set { workspace.current.search = newValue }
    }
    @Published var favorites: [Favorite] = [] { didSet { favoriteKeys = Set(favorites.map(\.id)) } }
    /// Filtered and sorted once per change of `files`, `search` or `sortMode`, not on every render.
    var visibleFiles: [CloudFile] { workspace.current.visibleFiles }
    @Published var showGlobalSearch = false
    @Published var appearanceAccount: Account?
    @Published var appearances: [String: AccountAppearance] = [:]
    var storageQuotas: [String: StorageQuotaState] { quotas.states }
    /// Accounts whose provider rejected the stored credential. Shown in the sidebar until the user reconnects.
    @Published var expiredAccountIDs: Set<String> = []
    /// Why each of them ended, when the provider said anything worth repeating.
    @Published var expiryReasons: [String: String] = [:]
    /// The last one chosen is also what a brand-new tab starts with.
    var viewMode: String {
        get { workspace.current.viewMode }
        set { workspace.current.viewMode = newValue; UserDefaults.standard.set(newValue, forKey: "viewMode") }
    }
    var sortMode: String {
        get { workspace.current.sortMode }
        set { workspace.current.sortMode = newValue }
    }
    @Published var showNameDialog = false
    @Published var editName = ""
    @Published var editingFile: CloudFile?
    @Published var demoOffline = false { didSet { demo?.offline = demoOffline } }
    let queue = TransferQueue()
    let remoteCopies = RemoteCopies()
    let history = TransferHistory()
    let planner = TransferPlanCoordinator()
    let connectivity = Connectivity()
    let mirrors = MirrorManager()
    let spotlight = SpotlightIndex()
    let localCopies = LocalCopyIndex()
    /// Managed offline copies ("Disponible sin conexión") and what keeps them current.
    let offline = OfflineStore()
    lazy var offlineRefresher = OfflineRefresher(store: offline)
    /// Cryptomator vaults unlocked in this run, each browsed as an account of its own.
    let cryptomator = CryptomatorVaults()
    /// The running model, so App Intents and the Services menu can reach it. Intents run inside the app process.
    @MainActor static private(set) weak var shared: AppModel?
    let listings = ListingCache()
    @Published var isOnline = true
    /// True while the table shows the last known listing instead of a fresh answer from the provider.
    var showingCachedListing: Bool {
        get { workspace.current.showingCachedListing }
        set { workspace.current.showingCachedListing = newValue }
    }
    /// True until the stored accounts have been read from the Keychain, which happens after the window is on screen.
    @Published var loadingAccounts = true
    let oauth = OAuth()
    let preview = PreviewWindow()
    let globalSearch = GlobalSearch()
    var appearanceStore: AppearanceStore?
    var demo: DemoStore?
    let sessions = AccountClientRegistry()
    let quotas = StorageQuotaController(refreshInterval: AppModel.quotaRefreshInterval)
    var quotaSubscription: AnyCancellable?
    var domainSubscription: AnyCancellable?
    /// The listing each tab is waiting for, so a new request for the same tab cancels the old one.
    var navigationTasks: [BrowserState.ID: Task<Void, Never>] = [:]
    var favoriteKeys: Set<String> = []
    var subscription: AnyCancellable?
    var keepAlive: Task<Void, Never>?
    var wakeObserver: NSObjectProtocol?
    var lastKeepAlive: [String: Date] = [:]
    /// Accounts with a keep-alive request in flight, so a slow one is not asked again on the next round.
    var touching: Set<String> = []
    /// Accounts whose session is being renewed in the background, so it is only attempted once at a time.
    @Published var renewingAccountIDs: Set<String> = []
    /// The renewals themselves, so disconnecting or signing in again can cancel one and refuse what it brings back.
    let o2Renewals = O2RenewalTasks()
    /// Moving O2 accounts signed in before WebKit stores were kept apart into stores of their own. Renewals wait for
    /// it, so none runs in a store that is being emptied.
    var o2StoreMigration: Task<Void, Never>?
    var editContext: (Account, String)?
    let favoritesURL = LocalStore.directory.appendingPathComponent("favorites.json")
    /// Opening folders refreshes the quota at most this often; explicit requests and finished transfers always do.
    static let quotaRefreshInterval: TimeInterval = 300
    /// How long a session may go untouched. Measured against O2's server, which let 68 minutes pass and refused at
    /// 80, so a quarter of an hour leaves room for several missed rounds.
    static let keepAliveInterval: TimeInterval = 15 * 60
    /// How often that is checked. Shorter than the interval on purpose: deciding by the clock rather than by how long
    /// the sleep actually lasted is what survives a Mac that spends the night waking in the dark and going back to
    /// sleep. (An earlier note here claimed the system stretched a twenty-minute sleep to forty. It did not: the
    /// script that measured it was dropping one line in three. The shape of the fix stands; the reason given did not.)
    static let keepAliveCheck: TimeInterval = 4 * 60

    var account: Account? { accounts.first { $0.id == selectedAccountID } ?? cryptomator.account(selectedAccountID) }
    var folderID: String { path.last?.id ?? collection.rootID }
    /// Recents and shared lists are not folders: nothing can be uploaded or created in them until a real folder is opened.
    var canWrite: Bool { account != nil && workspace.current.isWritableLocation }
    /// The trash shows what was binned; the only things to do with it are restoring it and deleting it for good.
    var inTrash: Bool { collection == .trash }
    var transfers: [Transfer] { queue.items }
    var hasActiveTransfers: Bool { queue.hasActive }
    var location: String { ([account?.email ?? ""] + (collection == .files ? [] : [collection.title]) + path.map(\.name)).joined(separator: " / ") }
    func updateVisibleFiles() { workspace.current.updateVisibleFiles() }
    /// A tab as the explorer opens one from nothing: no account yet, and the list drawn the way it was drawn last.
    static func newBrowser() -> BrowserState {
        BrowserState(viewMode: UserDefaults.standard.string(forKey: "viewMode") ?? "list")
    }
    init() {
        do { let store = try AppearanceStore(); appearanceStore = store; appearances = store.values }
        catch { self.error = L("No se pudo cargar la personalización: \(error.localizedDescription)") }
        do { favorites = try LocalStore.read([Favorite].self, from: favoritesURL) ?? [] }
        catch { self.error = error.localizedDescription }
        // Property observers do not run while an initializer sets its own properties.
        favoriteKeys = Set(favorites.map(\.id))
        // The tabs of the last session, put right against the accounts once those have been read.
        if let restored = workspaceStore.load() { workspace = restored }
        workspaceStore.watch($workspace)
        if UserDefaults.standard.bool(forKey: "demoEnabled") { enableDemo(select: false) }
        queue.client = { [weak self] id in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) ?? self.cryptomator.account(id) else {
                throw CloudError.message(CryptomatorVaults.isVaultAccount(id) ? L("Desbloquea la bóveda de esta transferencia para continuar.") : L("Vuelve a conectar la cuenta de esta transferencia."))
            }
            return try self.client(account)
        }
        queue.didFinish = { [weak self] transfer in
            self?.history.record(transfer); self?.mirrors.handleFinished(transfer)
            self?.finishPaneMove(transfer)
        }
        queue.didStoreLocalCopy = { [weak self] copy in self?.localCopies.record(copy) }
        connectivity.onChange = { [weak self] online in
            guard let self else { return }
            isOnline = online
            queue.setOnline(online)
            // Whatever failed while offline is worth one automatic retry now, and a session that goes quiet while the
            // network is away is one the provider may have given up on: the first thing to do is prove it is alive.
            if online {
                touchIdleSessions(force: true, note: "ha vuelto la red")
                reloadVisible()
            }
        }
        queue.didComplete = { [weak self] id in
            guard let self else { return }
            self.reloadVisible(accountID: id, fresh: true)
            if let account = self.accounts.first(where: { $0.id == id }) { self.refreshStorage(account, force: true) }
        }
        // Only structural queue changes reach the explorer; progress ticks re-render the transfer panel alone.
        quotaSubscription = quotas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        subscription = queue.stateChanges.sink { [weak self] _ in self?.objectWillChange.send() }
        // The Finder's list of locations follows the list of accounts, for as long as the person wants it to.
        domainSubscription = $accounts.dropFirst().removeDuplicates { $0.map(\.id) == $1.map(\.id) }.sink { [weak self] _ in self?.syncFinderDomains() }
        if let message = queue.persistenceError { error = message }
        listings.enabled = Prefs.bool(Prefs.listingCache, default: true)
        queue.cleanScratch()
        mirrors.queue = queue
        configureTransferPolicy()
        mirrors.accountLookup = { [weak self] id in self?.accounts.first { $0.id == id } }
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
        startOffline()
        Self.shared = self
    }

    // MARK: - System integration

    /// A Spotlight result opened before the stored accounts had been read. The Keychain is read after the window is
    /// on screen, so a cold start always got here first and the answer was always that the result was gone.
    var pendingSpotlightItem: String?

    var downloadedCount: Int {
        guard let account else { return 0 }
        return files.filter { !$0.isFolder && localCopies.status(for: $0, accountID: account.id).copy != nil }.count
    }

    var accountLoadError: Error?

    // Keychain ACLs are deliberately preserved. Signature/ACL migration is separate from credential writes;
    // startup must never read and rewrite stale tokens while another client is refreshing them.

    /// Accounts that can host a shared drive or a document library.
    var driveHosts: [Account] { accounts.filter { [.google, .microsoft].contains($0.cloud) && $0.driveID == nil } }

}
