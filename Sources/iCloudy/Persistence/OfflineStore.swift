import Foundation

/// Something the user asked to keep on this Mac, file or folder, so it can be opened without a network.
struct OfflinePin: Codable, Identifiable, Equatable {
    let accountID: String
    /// The remote item as last seen. Its id follows renames and moves through `RemoteIdentityChange`.
    var file: CloudFile
    /// The folder the item was listed in, when it was pinned from a real folder. Listing it is how a refresh learns
    /// whether the item is still there on providers that cannot describe a single item.
    var parentID: String?
    /// Directory of this pin's copies inside the account's folder. Random and never renamed: a rename or a move in the
    /// cloud changes nothing on disk, and every copy of the pin can be found by it, whatever the item is called now.
    let folder: String
    var pinnedAt: Date
    var lastRefresh: Date?
    var lastError: String?
    var id: String { folder }
}

/// One file kept in the managed offline folder: a copy of a pinned item, or a preview kept as cache.
struct OfflineEntry: Codable, Identifiable, Equatable {
    let accountID: String
    var fileID: String
    var name: String
    /// Path below the offline root. Only ever built from sanitised names, never taken from the provider as is.
    var relativePath: String
    /// Bytes on disk, which the verified download made equal to what the provider listed.
    var size: Int64
    var remoteModified: Date?
    var checksum: ContentHash?
    /// The pin (its `folder`) that keeps this copy, or nil for a preview kept as cache, which may be evicted.
    var pinFolder: String?
    var savedAt: Date
    var lastAccess: Date
    var id: String { OfflineStore.key(accountID: accountID, fileID: fileID) }
    var isPinned: Bool { pinFolder != nil }
}

/// What the explorer badge says about a pinned item.
enum OfflineStatus: Equatable {
    case available, updating, outdated, failed(String)

    var symbol: String {
        switch self {
        case .available: return "arrow.down.circle.fill"
        case .updating: return "arrow.triangle.2.circlepath.circle"
        case .outdated: return "exclamationmark.arrow.circlepath"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .available: return L("Disponible sin conexión")
        case .updating: return L("Actualizando la copia sin conexión")
        case .outdated: return L("Copia sin conexión desactualizada")
        case .failed: return L("Error en la copia sin conexión")
        }
    }
}

/// A message about something the app did on its own: an item unpinned because it is gone, a pin over the budget.
struct OfflineNotice: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Settings of the offline copies. Read where they are used, so a change in the settings window applies at once.
enum OfflineSettings {
    static let budgetKey = "offlineBudgetGB"
    static let refreshKey = "offlineRefreshMinutes"
    static let keepPreviewsKey = "offlineKeepPreviews"
    /// Gigabytes the user can choose from; 0 means no limit.
    static let budgetChoices = [5, 10, 20, 50, 0]
    static let refreshChoices = [0, 15, 60, 360, 1440]
    /// Unlike `Prefs.int`, zero is a real choice here: no limit, or no periodic refresh.
    static var budgetGB: Int { UserDefaults.standard.object(forKey: budgetKey) as? Int ?? 10 }
    static var budget: Int64? { budgetGB > 0 ? Int64(budgetGB) * 1_000_000_000 : nil }
    static var refreshMinutes: Int { UserDefaults.standard.object(forKey: refreshKey) as? Int ?? 60 }
    static var keepPreviews: Bool { Prefs.bool(keepPreviewsKey, default: true) }
}

/// The decisions of the offline copies, kept apart from any state so they can be tested on their own.
enum OfflinePolicy {
    /// Whether a copy has to be fetched again. Only what both sides carry is compared: a field one of them lacks is
    /// not evidence of a change, the same rule the download check uses to tell a changed file from a damaged one.
    static func needsDownload(_ entry: OfflineEntry?, remote: CloudFile, localExists: Bool) -> Bool {
        guard let entry, localExists else { return true }
        return changed(entry, remote)
    }
    static func changed(_ entry: OfflineEntry, _ remote: CloudFile) -> Bool {
        if let size = remote.size, size >= 0, size != entry.size { return true }
        // A second of slack: some servers round the date they list differently from the one they return later.
        if let listed = remote.modified, let kept = entry.remoteModified, abs(listed.timeIntervalSince(kept)) > 1 { return true }
        if let listed = remote.checksum, let kept = entry.checksum, listed.algorithm == kept.algorithm, !listed.matches(kept.value) { return true }
        return false
    }

    struct BudgetPlan: Equatable {
        /// Cached entries to delete, least recently used first. Never a pinned one.
        var evict: [String]
        /// What the pinned copies take, counting the incoming one when it is pinned.
        var pinnedBytes: Int64
        /// False when the incoming copy does not fit even after evicting every cached one.
        var fits: Bool
    }

    /// Makes room for `incoming` bytes under `budget`. Cached previews go first, oldest access first; pinned copies
    /// are never evicted, so when they alone exceed the budget the answer is a refusal, not a silent deletion.
    /// `replacing` is the entry the incoming copy will replace, whose bytes are about to be freed anyway.
    static func plan(_ entries: [OfflineEntry], budget: Int64?, incoming: Int64 = 0, pinned incomingPinned: Bool = true,
                     replacing: String? = nil) -> BudgetPlan {
        let others = entries.filter { $0.id != replacing }
        let pinned = others.filter(\.isPinned).reduce(Int64(0)) { $0 + $1.size } + (incomingPinned ? incoming : 0)
        guard let budget else { return BudgetPlan(evict: [], pinnedBytes: pinned, fits: true) }
        let fixed = pinned + (incomingPinned ? 0 : incoming)
        let cached = others.filter { !$0.isPinned }.sorted { $0.lastAccess < $1.lastAccess }
        // Evicting previews to end up over the budget anyway would only throw them away for nothing. With nothing
        // incoming this is a lowered budget being applied, and no preview fits beside the pinned copies any more.
        guard fixed <= budget else { return BudgetPlan(evict: incoming == 0 ? cached.map(\.id) : [], pinnedBytes: pinned, fits: false) }
        var total = fixed + cached.reduce(Int64(0)) { $0 + $1.size }
        var evict: [String] = []
        for entry in cached where total > budget {
            evict.append(entry.id)
            total -= entry.size
        }
        return BudgetPlan(evict: evict, pinnedBytes: pinned, fits: true)
    }
}

enum OfflineError: LocalizedError, Equatable {
    case overBudget(name: String, needed: Int64, budget: Int64)
    var errorDescription: String? {
        switch self {
        case .overBudget(let name, let needed, let budget):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return L("«\(name)» no cabe en el espacio para copias sin conexión: lo marcado ocuparía \(format(needed)) y el límite es \(format(budget)). Sube el límite en Configuración › Sin conexión o quita otros elementos.")
        }
    }
}

/// The managed offline copies: which items are pinned, which files are kept for them, and where. The files live in
/// iCloudy's own container (Application Support/iCloudy/Offline/<cuenta>/<carpeta del elemento>), are read-only, and
/// are only ever written by the verified download path. Nothing here is synchronised back: editing goes through
/// a two-way sync, not through these copies.
@MainActor
final class OfflineStore: ObservableObject {
    @Published private(set) var pins: [OfflinePin] = []
    @Published private(set) var entries: [String: OfflineEntry] = [:]
    /// Pins whose refresh is running now.
    @Published private(set) var refreshing: Set<String> = []
    @Published var notices: [OfflineNotice] = []
    let root: URL
    let indexURL: URL
    /// The budget in bytes, or nil for no limit. A closure so tests can set it without touching the user's defaults.
    var budget: () -> Int64? = { OfflineSettings.budget }
    var keepPreviews: () -> Bool = { OfflineSettings.keepPreviews }
    /// Delay before a coalesced write. A folder pin records one entry per file, and writing the index for each one
    /// turned a refresh of thousands of files into thousands of growing writes on the main actor.
    var flushDelay: Duration = .seconds(2)
    private var dirty = false
    private var flushTask: Task<Void, Never>?

    init(root: URL = LocalStore.directory.appendingPathComponent("Offline", isDirectory: true),
         indexURL: URL = LocalStore.directory.appendingPathComponent("offline.json")) {
        self.root = root
        self.indexURL = indexURL
        if let snapshot = try? LocalStore.read(Snapshot.self, from: indexURL) {
            pins = snapshot.pins
            entries = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        }
    }
    nonisolated static func key(accountID: String, fileID: String) -> String { accountID + "\u{1F}" + fileID }

    /// The folder of an account: its id made safe for a file name, plus a hash so two ids that sanitise alike never
    /// share a folder. WebDAV ids carry a whole URL.
    nonisolated static func accountFolder(_ accountID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let readable = String(accountID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(60))
        let hash = accountID.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return readable + "-" + String(hash, radix: 16)
    }
    func url(of entry: OfflineEntry) -> URL { root.appendingPathComponent(entry.relativePath) }
    func directory(of pin: OfflinePin) -> URL {
        root.appendingPathComponent(Self.accountFolder(pin.accountID), isDirectory: true).appendingPathComponent(pin.folder, isDirectory: true)
    }
    /// Where the pin's own item lives: the file itself, or the top folder of a folder pin.
    func location(of pin: OfflinePin) -> URL { directory(of: pin).appendingPathComponent(FileNames.safe(pin.file.name)) }

    // MARK: - Pins

    enum PinResult: Equatable { case pinned(OfflinePin), alreadyPinned, refused(String) }

    func pin(_ file: CloudFile, accountID: String, parentID: String?) -> PinResult {
        if file.isGoogleDocument {
            return .refused(L("Los documentos de Google no son un archivo que se pueda guardar sin conexión. Expórtalo como Word o PDF y guarda esa copia."))
        }
        if pin(for: file.id, accountID: accountID) != nil || entries[Self.key(accountID: accountID, fileID: file.id)]?.isPinned == true {
            return .alreadyPinned
        }
        // A folder's size is not known until it is walked; the refresh stops at the limit and says so.
        if !file.isFolder, let size = file.size, let budget = budget() {
            let plan = OfflinePolicy.plan(Array(entries.values), budget: budget, incoming: size,
                                          replacing: Self.key(accountID: accountID, fileID: file.id))
            if !plan.fits { return .refused(OfflineError.overBudget(name: file.name, needed: plan.pinnedBytes, budget: budget).localizedDescription) }
        }
        let pin = OfflinePin(accountID: accountID, file: file, parentID: parentID, folder: UUID().uuidString, pinnedAt: Date())
        pins.append(pin)
        persist()
        return .pinned(pin)
    }
    func pin(for fileID: String, accountID: String) -> OfflinePin? {
        pins.first { $0.accountID == accountID && $0.file.id == fileID }
    }
    func pin(folder: String) -> OfflinePin? { pins.first { $0.folder == folder } }
    /// Removes the pin and deletes every copy it kept. Only iCloudy's own container is touched.
    func unpin(_ folder: String, notice: String? = nil) {
        guard let pin = pin(folder: folder) else { return }
        pins.removeAll { $0.folder == folder }
        for entry in entries.values where entry.pinFolder == folder { entries[entry.id] = nil }
        delete(directory(of: pin))
        refreshing.remove(folder)
        if let notice { notices.append(OfflineNotice(text: notice)) }
        persist()
    }
    func updatePin(_ folder: String, _ change: (inout OfflinePin) -> Void) {
        guard let index = pins.firstIndex(where: { $0.folder == folder }) else { return }
        var pin = pins[index]
        change(&pin)
        guard pin != pins[index] else { return }
        pins[index] = pin
        persist(coalesce: true)
    }
    func beginRefresh(_ folder: String) { refreshing.insert(folder) }
    func endRefresh(_ folder: String, error: String?) {
        refreshing.remove(folder)
        updatePin(folder) { $0.lastError = error; if error == nil { $0.lastRefresh = Date() } }
        persist()
    }

    // MARK: - Entries

    func record(_ entry: OfflineEntry) {
        entries[entry.id] = entry
        persist(coalesce: true)
    }
    func removeEntry(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        delete(url(of: entry))
        persist(coalesce: true)
    }
    /// Drops the copies of a pin whose remote item is no longer under it, after a complete walk of the pin.
    func dropEntries(of folder: String, except kept: Set<String>) {
        for entry in entries.values where entry.pinFolder == folder && !kept.contains(entry.fileID) { removeEntry(entry.id) }
    }
    func entries(of folder: String) -> [OfflineEntry] { entries.values.filter { $0.pinFolder == folder } }
    func usage(of pin: OfflinePin) -> Int64 { entries(of: pin.folder).reduce(0) { $0 + $1.size } }
    func bytes(accountID: String? = nil) -> Int64 {
        entries.values.reduce(0) { $0 + (accountID == nil || $1.accountID == accountID ? $1.size : 0) }
    }
    var pinnedBytes: Int64 { entries.values.reduce(0) { $0 + ($1.isPinned ? $1.size : 0) } }
    var cachedBytes: Int64 { entries.values.reduce(0) { $0 + ($1.isPinned ? 0 : $1.size) } }
    /// True when the pinned copies alone exceed the budget: nothing is evicted, but the user has to be told.
    var overBudget: Bool { budget().map { pinnedBytes > $0 } ?? false }
    func touch(_ id: String) {
        guard entries[id] != nil else { return }
        entries[id]?.lastAccess = Date()
        persist(coalesce: true)
    }

    /// Makes room for a copy about to be written, evicting cached previews if needed. Throws when the pinned copies
    /// would exceed the budget: pinned copies are never evicted to make room for other pinned copies.
    func reserve(_ bytes: Int64, for file: CloudFile, accountID: String) throws {
        guard let budget = budget() else { return }
        let plan = OfflinePolicy.plan(Array(entries.values), budget: budget, incoming: bytes,
                                      replacing: Self.key(accountID: accountID, fileID: file.id))
        guard plan.fits else { throw OfflineError.overBudget(name: file.name, needed: plan.pinnedBytes, budget: budget) }
        for id in plan.evict { removeEntry(id) }
    }
    /// Applies a lowered budget at once: cached previews go, pinned copies stay and the warning shows.
    func enforceBudget() {
        let plan = OfflinePolicy.plan(Array(entries.values), budget: budget(), incoming: 0)
        for id in plan.evict { removeEntry(id) }
    }
    func clearCache() {
        for entry in entries.values where !entry.isPinned { removeEntry(entry.id) }
        persist()
    }

    /// Keeps a finished preview as an evictable cache entry, so it can be seen again without a network. The bytes
    /// were already checked by the preview's own download; nothing is fetched for this.
    func cachePreview(_ file: CloudFile, accountID: String, from source: URL) {
        guard keepPreviews(), !file.isFolder, !file.isGoogleDocument, let size = file.size, size > 0 else { return }
        let id = Self.key(accountID: accountID, fileID: file.id)
        if let existing = entries[id] {
            // A pinned copy is the refresh's business; an unchanged cached one only needs its access time.
            if existing.isPinned || !OfflinePolicy.changed(existing, file) { touch(id); return }
            removeEntry(id)
        }
        let plan = OfflinePolicy.plan(Array(entries.values), budget: budget(), incoming: size, pinned: false)
        guard plan.fits else { return }
        for evicted in plan.evict { removeEntry(evicted) }
        let relative = Self.accountFolder(accountID) + "/cache/" + UUID().uuidString + "/" + FileNames.safe(file.name)
        let target = root.appendingPathComponent(relative), modified = file.modified
        Task {
            do {
                try await blockingIO { try Self.place(copyOf: source, at: target, modified: modified) }
                // The account may have been disconnected meanwhile; its folder is gone and so must this copy be.
                guard self.entries[id] == nil, FileManager.default.fileExists(atPath: target.path) else {
                    self.delete(target.deletingLastPathComponent()); return
                }
                self.record(OfflineEntry(accountID: accountID, fileID: file.id, name: file.name, relativePath: relative, size: size,
                                         remoteModified: file.modified, checksum: file.checksum, pinFolder: nil, savedAt: Date(), lastAccess: Date()))
            } catch { self.delete(target.deletingLastPathComponent()) }
        }
    }

    /// Copies a file into the container, read-only. A clone on APFS, so a preview costs no second copy of its bytes.
    nonisolated static func place(copyOf source: URL, at target: URL, modified: Date?) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: target)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o444]
        if let modified { attributes[.modificationDate] = modified }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
    }

    // MARK: - Lookups for the explorer

    /// The badge of an item in a listing, or nil when it is not kept offline. A cached preview has no badge: it may
    /// be evicted at any time, and the badge is a promise.
    func status(for file: CloudFile, accountID: String) -> OfflineStatus? {
        if let pin = pin(for: file.id, accountID: accountID) {
            if refreshing.contains(pin.folder) { return .updating }
            if let error = pin.lastError { return .failed(error) }
            if file.isFolder { return .available }
            guard let entry = entries[Self.key(accountID: accountID, fileID: file.id)], entry.pinFolder == pin.folder else { return .updating }
            return OfflinePolicy.changed(entry, file) ? .outdated : .available
        }
        guard let entry = entries[Self.key(accountID: accountID, fileID: file.id)], let folder = entry.pinFolder else { return nil }
        if refreshing.contains(folder) { return .updating }
        return OfflinePolicy.changed(entry, file) ? .outdated : .available
    }
    /// The local copy to open or preview instead of downloading, if there is one on disk. With `acceptChanged`
    /// false, a copy the listing shows to be behind the cloud is not used; offline, any copy is better than none.
    func localURL(for file: CloudFile, accountID: String, acceptChanged: Bool) -> URL? {
        guard !file.isFolder, let entry = entries[Self.key(accountID: accountID, fileID: file.id)] else { return nil }
        guard acceptChanged || !OfflinePolicy.changed(entry, file) else { return nil }
        let url = url(of: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Identity, deletion and accounts

    /// Follows a rename or a move made from iCloudy, so a pin is not lost when a path-addressed provider changes the
    /// id of the item and of everything below it. Files on disk stay where they are; the next refresh renames them.
    /// Returns the pins affected, so the caller can refresh them.
    @discardableResult
    func remap(_ change: RemoteIdentityChange, accountID: String, newParentID: String? = nil) -> Set<String> {
        var affected: Set<String> = []
        for index in pins.indices where pins[index].accountID == accountID {
            var pin = pins[index]
            let moved = pin.file.id == change.oldID
            let before = pin
            pin.file = Self.remapped(pin.file, change)
            pin.parentID = pin.parentID.map(change.id)
            if moved, let newParentID { pin.parentID = newParentID }
            if pin != before { pins[index] = pin; affected.insert(pin.folder) }
        }
        var updated: [String: OfflineEntry] = [:]
        for var entry in entries.values {
            if entry.accountID == accountID {
                let id = change.id(entry.fileID)
                if id != entry.fileID || entry.fileID == change.oldID {
                    if entry.fileID == change.oldID { entry.name = change.name }
                    entry.fileID = id
                    if let folder = entry.pinFolder { affected.insert(folder) }
                }
            }
            updated[entry.id] = entry
        }
        entries = updated
        persist()
        return affected
    }
    /// `RemoteIdentityChange.file` drops the checksum, which a pin of a file needs to keep.
    private static func remapped(_ file: CloudFile, _ change: RemoteIdentityChange) -> CloudFile {
        var result = change.file(file)
        result.checksum = file.checksum
        return result
    }

    /// An item sent to the trash or deleted from iCloudy: pins on it, or listed inside it, go with a notice. Pins
    /// further below a deleted folder are found by the next refresh, which cannot list them any more.
    func itemDeleted(_ file: CloudFile, accountID: String) {
        let prefix = file.id.hasSuffix("/") ? file.id : file.id + "/"
        for pin in pins where pin.accountID == accountID
            && (pin.file.id == file.id || pin.parentID == file.id || (file.isFolder && pin.file.id.hasPrefix(prefix))) {
            unpin(pin.folder, notice: L("«\(pin.file.name)» se ha borrado de la nube y ya no está disponible sin conexión."))
        }
        let id = Self.key(accountID: accountID, fileID: file.id)
        if entries[id] != nil { removeEntry(id) }
    }

    /// Everything kept for an account, pinned or cached, deleted with it.
    func removeAccount(_ accountID: String) {
        pins.removeAll { $0.accountID == accountID }
        for entry in entries.values where entry.accountID == accountID { entries[entry.id] = nil }
        delete(root.appendingPathComponent(Self.accountFolder(accountID), isDirectory: true))
        persist()
    }

    func dismiss(_ notice: OfflineNotice) { notices.removeAll { $0.id == notice.id } }

    // MARK: - Disk

    /// Deletes inside the offline root only. Copies are read-only, but unlinking needs only the directory's permission.
    private func delete(_ url: URL) {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func persist(coalesce: Bool = false) {
        guard coalesce else { flushTask?.cancel(); flushTask = nil; dirty = false; write(); return }
        dirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let delay = self?.flushDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }
    /// Writes whatever is pending. Called before the process exits.
    func flush() {
        guard dirty else { return }
        dirty = false
        write()
    }
    private func write() { try? LocalStore.save(Snapshot(pins: pins, entries: Array(entries.values)), to: indexURL) }

    private struct Snapshot: Codable {
        var pins: [OfflinePin]
        var entries: [OfflineEntry]
    }
}
