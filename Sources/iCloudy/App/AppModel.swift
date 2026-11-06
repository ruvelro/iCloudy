import AppKit
import SwiftUI
import Combine

/// Observed property by property: a view redraws when something it reads changes, not whenever anything in the
/// model does. The model used to be an `ObservableObject` with 37 published properties, and every one of the views
/// watching it redrew on any change: a quota arriving, a transfer ticking, a tab being renamed.
@MainActor
@Observable
final class AppModel {
    /// The accounts, their sessions and the Keychain entry they are saved in.
    let directory = AccountDirectory()
    /// O2's keep-alive, silent renewals and WebKit stores.
    @ObservationIgnored private(set) lazy var o2 = O2SessionKeeper(directory: directory)
    /// What the views read. Setting it changes this run only: connecting, reordering and removing go through
    /// `directory`, which saves.
    var accounts: [Account] {
        get { directory.accounts }
        set { directory.accounts = newValue }
    }
    /// Panes and tabs, each with its own place and listing. The properties below forward to the focused pane's
    /// active tab, so everything that asks for "the open folder" keeps getting exactly that.
    var workspace = ExplorerWorkspace(panes: [ExplorerPane(tabs: [AppModel.newBrowser()])]) {
        didSet { workspaceChanges.send(workspace) }
    }
    /// The workspace as a stream, for the store that saves it and the offline refresh that watches the open folder.
    @ObservationIgnored lazy var workspaceChanges = CurrentValueSubject<ExplorerWorkspace, Never>(workspace)
    @ObservationIgnored let workspaceStore = WorkspaceStore()
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
    /// Alerts, confirmations and sheets: the window's state, kept apart from the model's.
    let ui = ExplorerPresentation()
    /// The model reports what went wrong, and what went well, through these two; the window shows them.
    var error: String? {
        get { ui.error }
        set { ui.error = newValue }
    }
    var info: String? {
        get { ui.info }
        set { ui.info = newValue }
    }
    var search: String {
        get { workspace.current.search }
        set { workspace.current.search = newValue }
    }
    /// The folders the column view shows above the open one.
    let columnListings = ColumnListings()
    /// Files open in other apps from private copies, and their way back to the cloud.
    let editor = ExternalEditor()
    /// The last folders visited, in any tab.
    let recents = RecentLocationsStore()
    /// How the lists are drawn: their columns, for every tab alike.
    let explorer = ExplorerSettings()
    /// The favorites and their file. Read-only here: every change goes through the store, which saves it.
    let favoriteStore = FavoritesStore()
    var favorites: [Favorite] { favoriteStore.items }
    /// Filtered and sorted once per change of `files`, `search` or `sortMode`, not on every render.
    var visibleFiles: [CloudFile] { workspace.current.visibleFiles }
    var appearances: [String: AccountAppearance] = [:]
    var storageQuotas: [String: StorageQuotaState] { quotas.states }
    /// The last one chosen is also what a brand-new tab starts with.
    var viewMode: String {
        get { workspace.current.viewMode }
        set { workspace.current.viewMode = newValue; Prefs.defaults.set(newValue, forKey: "viewMode") }
    }
    var sortMode: String {
        get { workspace.current.sortMode }
        set { workspace.current.sortMode = newValue }
    }
    var demoOffline = false { didSet { demo?.offline = demoOffline } }
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
    @ObservationIgnored lazy var offlineRefresher = OfflineRefresher(store: offline)
    /// Cryptomator vaults unlocked in this run, each browsed as an account of its own.
    let cryptomator = CryptomatorVaults()
    /// The running model, so App Intents and the Services menu can reach it. Intents run inside the app process.
    @MainActor static private(set) weak var shared: AppModel?
    let listings = ListingCache()
    var isOnline = true { didSet { onlineChanges.send(isOnline) } }
    @ObservationIgnored let onlineChanges = PassthroughSubject<Bool, Never>()
    /// True while the table shows the last known listing instead of a fresh answer from the provider.
    var showingCachedListing: Bool {
        get { workspace.current.showingCachedListing }
        set { workspace.current.showingCachedListing = newValue }
    }
    /// True until the stored accounts have been read from the Keychain, which happens after the window is on screen.
    var loadingAccounts = true { didSet { if !loadingAccounts, oldValue { accountsLoaded.send() } } }
    /// Fires once the stored accounts have been read, for what waits on them.
    @ObservationIgnored let accountsLoaded = PassthroughSubject<Void, Never>()
    let oauth = OAuth()
    let preview = PreviewWindow()
    let globalSearch = GlobalSearch()
    let thumbnails = ThumbnailStore()
    let savedSearches = SavedSearches()
    let notifier = TransferNotifier()
    /// The explorer window's, so ⌘Z reaches what was done there. Set by the window when it appears.
    @ObservationIgnored weak var undoManager: UndoManager?
    var appearanceStore: AppearanceStore?
    var demo: DemoStore?
    var sessions: AccountClientRegistry { directory.sessions }
    let quotas = StorageQuotaController(refreshInterval: AppModel.quotaRefreshInterval)
    /// The listing each tab is waiting for, so a new request for the same tab cancels the old one.
    @ObservationIgnored var navigationTasks: [BrowserState.ID: Task<Void, Never>] = [:]
    @ObservationIgnored var subscription: AnyCancellable?
    @ObservationIgnored var editContext: (Account, String)?
    /// Opening folders refreshes the quota at most this often; explicit requests and finished transfers always do.
    static let quotaRefreshInterval: TimeInterval = 300

    var account: Account? { accounts.first { $0.id == selectedAccountID } ?? cryptomator.account(selectedAccountID) }
    var folderID: String { path.last?.id ?? collection.rootID }
    /// Recents and shared lists are not folders: nothing can be uploaded or created in them until a real folder is opened.
    var canWrite: Bool { account != nil && workspace.current.isWritableLocation }
    /// The trash shows what was binned; the only things to do with it are restoring it and deleting it for good.
    var inTrash: Bool { collection == .trash }
    /// The queue as of its last structural change: progress ticks redraw the transfer panel alone.
    var transfers: [Transfer] { queue.structuralItems }
    var hasActiveTransfers: Bool { queue.structuralItems.contains { [.queued, .running].contains($0.state) } }
    var location: String { ([account?.email ?? ""] + (collection == .files ? [] : [collection.title]) + path.map(\.name)).joined(separator: " / ") }
    func updateVisibleFiles() { workspace.current.updateVisibleFiles() }
    /// A tab as the explorer opens one from nothing: no account yet, and the list drawn the way it was drawn last.
    static func newBrowser() -> BrowserState {
        BrowserState(viewMode: Prefs.defaults.string(forKey: "viewMode") ?? "list")
    }
    init() {
        do { let store = try AppearanceStore(); appearanceStore = store; appearances = store.values }
        catch { self.error = L("No se pudo cargar la personalización: \(error.localizedDescription)") }
        if let problem = favoriteStore.loadError { self.error = problem }
        if let problem = recents.loadError { self.error = problem }
        recents.saveFailed = { [weak self] message in self?.error = message }
        favoriteStore.saveFailed = { [weak self] message in self?.error = message }
        favoriteStore.didChange = { [weak self] in self?.refreshSpotlightFavorites() }
        // The tabs of the last session, put right against the accounts once those have been read.
        if let restored = workspaceStore.load() { workspace = restored }
        workspaceStore.watch(workspaceChanges.eraseToAnyPublisher())
        if Prefs.defaults.bool(forKey: "demoEnabled") { enableDemo(select: false) }
        queue.client = { [weak self] id in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) ?? self.cryptomator.account(id) else {
                throw CloudError.message(CryptomatorVaults.isVaultAccount(id) ? L("Desbloquea la bóveda de esta transferencia para continuar.") : L("Vuelve a conectar la cuenta de esta transferencia."))
            }
            return try self.client(account)
        }
        queue.didFinish = { [weak self] transfer in
            self?.history.record(transfer); self?.mirrors.handleFinished(transfer)
            self?.notifier.finished(transfer)
            self?.finishPaneMove(transfer)
            self?.editingTransferFinished(transfer)
        }
        thumbnails.client = { [weak self] account in
            guard let self else { throw CancellationError() }
            return try self.client(account)
        }
        queue.didStoreLocalCopy = { [weak self] copy in self?.localCopies.record(copy) }
        connectivity.onChange = { [weak self] online in
            guard let self else { return }
            isOnline = online
            queue.setOnline(online)
            // Whatever failed while offline is worth one automatic retry now, and a session that goes quiet while the
            // network is away is one the provider may have given up on: the first thing to do is prove it is alive.
            if online {
                o2.touchIdleSessions(force: true, note: "ha vuelto la red")
                reloadVisible()
            }
        }
        queue.didComplete = { [weak self] id in
            guard let self else { return }
            self.reloadVisible(accountID: id, fresh: true)
            if let account = self.accounts.first(where: { $0.id == id }) { self.refreshStorage(account, force: true) }
        }
        subscription = queue.stateChanges.sink { [weak self] _ in
            guard let self else { return }
            notifier.queueChanged(active: queue.hasActive)
            editingQueueChanged()
        }
        if let message = queue.persistenceError { error = message }
        listings.enabled = Prefs.bool(Prefs.listingCache, default: true)
        queue.cleanScratch()
        editor.didChange = { [weak self] id in
            guard let self, editor.autoUpload else { return }
            Task { await self.uploadEdits(id) }
        }
        // Copies left by an earlier run are not watched by anyone any more; those a paused upload reads stay.
        if !AppEnvironment.isTesting { editor.removeLeftovers(protecting: queue.protectedLocalURLs) }
        mirrors.queue = queue
        configureTransferPolicy()
        mirrors.accountLookup = { [weak self] id in self?.accounts.first { $0.id == id } }
        directory.membershipChanged = { [weak self] in self?.syncFinderDomains() }
        o2.touch = { [weak self] account, answered in self?.refreshStorage(account, force: true, then: answered) }
        o2.didRenew = { [weak self] account in self?.reloadVisible(accountID: account.id) }
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
