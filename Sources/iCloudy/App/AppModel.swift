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
    /// SwiftUI presents one alert at a time, so an error and a piece of good news arriving together meant the second
    /// one never appeared at all. They share a presentation now: the error goes first and the other waits its turn.
    var alertTitle: String { error != nil ? L("No se pudo completar la operación") : L("iCloudy") }
    var alertMessage: String? { error ?? info }
    func dismissAlert() { if error != nil { error = nil } else { info = nil } }
    /// File awaiting confirmation before a public link is created for it.
    @Published var pendingShare: (file: CloudFile, account: Account)?
    /// Items awaiting confirmation before being sent to the provider's trash.
    @Published var pendingTrash: [CloudFile]?
    /// The item whose sharing sheet is open.
    @Published var sharing: SharingRequest?
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
    @Published var search = "" { didSet { updateVisibleFiles() } }
    @Published var favorites: [Favorite] = [] { didSet { favoriteKeys = Set(favorites.map(\.id)) } }
    /// Filtered and sorted once per change of `files`, `search` or `sortMode`, not on every render.
    @Published var visibleFiles: [CloudFile] = []
    @Published var showGlobalSearch = false
    @Published var appearanceAccount: Account?
    @Published var appearances: [String: AccountAppearance] = [:]
    var storageQuotas: [String: StorageQuotaState] { quotas.states }
    /// Accounts whose provider rejected the stored credential. Shown in the sidebar until the user reconnects.
    @Published var expiredAccountIDs: Set<String> = []
    /// Why each of them ended, when the provider said anything worth repeating.
    @Published var expiryReasons: [String: String] = [:]
    @Published var viewMode = UserDefaults.standard.string(forKey: "viewMode") ?? "list" { didSet { UserDefaults.standard.set(viewMode, forKey: "viewMode") } }
    @Published var sortMode = "name" { didSet { updateVisibleFiles() } }
    @Published var showNameDialog = false
    @Published var editName = ""
    @Published var editingFile: CloudFile?
    @Published var demoOffline = false { didSet { demo?.offline = demoOffline } }
    let queue = TransferQueue()
    let remoteCopies = RemoteCopies()
    let history = TransferHistory()
    let connectivity = Connectivity()
    let mirrors = MirrorManager()
    let spotlight = SpotlightIndex()
    let localCopies = LocalCopyIndex()
    /// The running model, so App Intents and the Services menu can reach it. Intents run inside the app process.
    @MainActor static private(set) weak var shared: AppModel?
    let listings = ListingCache()
    @Published var isOnline = true
    /// True while the table shows the last known listing instead of a fresh answer from the provider.
    @Published var showingCachedListing = false
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
    var navigationTask: Task<Void, Never>?
    var navigationID = UUID()
    var favoriteKeys: Set<String> = []
    var subscription: AnyCancellable?
    var keepAlive: Task<Void, Never>?
    var wakeObserver: NSObjectProtocol?
    var lastKeepAlive: [String: Date] = [:]
    /// Accounts with a keep-alive request in flight, so a slow one is not asked again on the next round.
    var touching: Set<String> = []
    /// Accounts whose session is being renewed in the background, so it is only attempted once at a time.
    @Published var renewingAccountIDs: Set<String> = []
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

    var account: Account? { accounts.first { $0.id == selectedAccountID } }
    var folderID: String { path.last?.id ?? collection.rootID }
    /// Recents and shared lists are not folders: nothing can be uploaded or created in them until a real folder is opened.
    var canWrite: Bool { account != nil && (collection == .files || !path.isEmpty) }
    /// The trash shows what was binned; the only things to do with it are restoring it and deleting it for good.
    var inTrash: Bool { collection == .trash }
    var transfers: [Transfer] { queue.items }
    var hasActiveTransfers: Bool { queue.hasActive }
    var location: String { ([account?.email ?? ""] + (collection == .files ? [] : [collection.title]) + path.map(\.name)).joined(separator: " / ") }
    func updateVisibleFiles() {
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
            // Whatever failed while offline is worth one automatic retry now, and a session that goes quiet while the
            // network is away is one the provider may have given up on: the first thing to do is prove it is alive.
            if online {
                touchIdleSessions(force: true, note: "ha vuelto la red")
                if account != nil { reload() }
            }
        }
        queue.didComplete = { [weak self] id in
            guard let self else { return }
            if self.selectedAccountID == id { self.reload(fresh: true) }
            if let account = self.accounts.first(where: { $0.id == id }) { self.refreshStorage(account, force: true) }
        }
        // Only structural queue changes reach the explorer; progress ticks re-render the transfer panel alone.
        quotaSubscription = quotas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        subscription = queue.stateChanges.sink { [weak self] _ in self?.objectWillChange.send() }
        if let message = queue.persistenceError { error = message }
        listings.enabled = Prefs.bool(Prefs.listingCache, default: true)
        queue.cleanScratch()
        mirrors.queue = queue
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
