import Foundation
import Combine
import CoreServices

/// Size and modification date of a local file the last time it was uploaded by a mirror.
struct FileStamp: Codable, Equatable {
    let size: Int64
    let modified: Date
}

/// A local folder tied to a remote one. In its original, one-way form the contents are pushed into the cloud and
/// deletions and renames are not mirrored: a removed local file stays in the cloud, a renamed one is uploaded under
/// its new name. In two-way form (`TwoWaySync`) changes travel both ways, against a baseline that records what both
/// sides looked like when they last agreed.
struct FolderMirror: Identifiable, Codable {
    enum Mode: String, Codable { case upload, twoWay }
    var id = UUID()
    var mode: Mode = .upload
    /// Two-way only: what both sides looked like after the last sync, per relative path.
    var baseline: [String: SyncEntry] = [:]
    var lastReport: SyncReport?
    let accountID: String
    var remoteFolderID: String
    /// Human-readable remote location, e.g. "user@example.com / Proyectos / Fotos".
    let remoteName: String
    let localURL: URL
    var bookmark: Data?
    var stamps: [String: FileStamp] = [:]
    /// Stamps taken when the running sync was planned; promoted to `stamps` once that transfer completes.
    var pendingStamps: [String: FileStamp]?
    var lastSync: Date?
    var activeTransferID: UUID?
    var lastError: String?
    var remoteEntries: [String: CloudFile] = [:]
    /// What this mirror never uploads, downloads or deletes. Records written before exclusions existed get the
    /// built-in defaults.
    var exclusions = SyncExclusions()
    /// Paused by the person: nothing is planned or transferred until they resume, across relaunches too.
    var paused = false
    /// Relative paths FSEvents reported while paused, for the sidebar's count. The run on resume compares the whole
    /// folder anyway, so this is never what decides what travels and losing it would lose nothing.
    var changesWhilePaused: Set<String> = []
}

extension FolderMirror {
    enum CodingKeys: String, CodingKey { case id, mode, baseline, lastReport, accountID, remoteFolderID, remoteName, localURL, bookmark, stamps, pendingStamps, lastSync, activeTransferID, lastError, remoteEntries, exclusions, paused, changesWhilePaused }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .upload
        baseline = try values.decodeIfPresent([String: SyncEntry].self, forKey: .baseline) ?? [:]
        lastReport = try values.decodeIfPresent(SyncReport.self, forKey: .lastReport)
        accountID = try values.decode(String.self, forKey: .accountID)
        remoteFolderID = try values.decode(String.self, forKey: .remoteFolderID)
        remoteName = try values.decodeIfPresent(String.self, forKey: .remoteName) ?? ""
        localURL = try values.decode(URL.self, forKey: .localURL)
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        stamps = try values.decodeIfPresent([String: FileStamp].self, forKey: .stamps) ?? [:]
        pendingStamps = try values.decodeIfPresent([String: FileStamp].self, forKey: .pendingStamps)
        lastSync = try values.decodeIfPresent(Date.self, forKey: .lastSync)
        activeTransferID = try values.decodeIfPresent(UUID.self, forKey: .activeTransferID)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        remoteEntries = try values.decodeIfPresent([String: CloudFile].self, forKey: .remoteEntries) ?? [:]
        exclusions = try values.decodeIfPresent(SyncExclusions.self, forKey: .exclusions) ?? SyncExclusions()
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        changesWhilePaused = try values.decodeIfPresent(Set<String>.self, forKey: .changesWhilePaused) ?? []
    }
}

/// Pure planning: which upload-tree keys can be marked completed because nothing under them changed.
enum MirrorPlanner {
    /// A local tree split by the exclusion rules. `excluded` holds only the outermost excluded items: nothing below an
    /// excluded folder is read at all, which also keeps unreadable system folders such as .Trashes from failing a scan.
    struct LocalScan {
        var stamps: [String: FileStamp] = [:]
        var excluded: [String: FileStamp] = [:]
        /// Both together, for the two-way planner, which partitions them again by the same rules.
        var all: [String: FileStamp] { stamps.merging(excluded) { kept, _ in kept } }
    }
    /// Relative path → stamp for every regular file under `root`. Symlinks are skipped, hidden files are included.
    nonisolated static func stamps(of root: URL) throws -> [String: FileStamp] { try scan(root, exclusions: .none).stamps }
    nonisolated static func scan(_ root: URL, exclusions: SyncExclusionMatcher) throws -> LocalScan {
        var result = LocalScan()
        let base = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: []) else { return result }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true || values.isDirectory == true else { continue }
            let modified = values.isDirectory == true ? Date(timeIntervalSince1970: 0) : (values.contentModificationDate ?? .distantPast)
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            let stamp = FileStamp(size: values.isDirectory == true ? -1 : Int64(values.fileSize ?? 0), modified: modified)
            // Parents come before their children, so checking the item alone is enough: an excluded parent was
            // never descended into.
            let name = relative.split(separator: "/").last ?? Substring(relative)
            if exclusions.excludesItself(relative, name: name, isFolder: values.isDirectory == true) {
                result.excluded[relative] = stamp
                if values.isDirectory == true { enumerator.skipDescendants() }
            } else {
                result.stamps[relative] = stamp
            }
        }
        return result
    }
    /// What a one-way run would mark completed, and whether it has anything to do at all. The run and its dry run
    /// both decide here, so the preview cannot drift from what the sync then does.
    static func oneWayPlan(current: [String: FileStamp], mirror: FolderMirror) -> (completed: Set<String>, nothingNew: Bool) {
        let completed = completedKeys(current: current, previous: mirror.stamps.filter { mirror.remoteEntries["./" + $0.key] != nil })
        let nothingNew = completed.count == current.count + completed.filter({ !current.keys.contains(String($0.dropFirst(2))) }).count
            && current.allSatisfy({ mirror.stamps[$0.key] == $0.value && mirror.remoteEntries["./" + $0.key] != nil }) && mirror.lastSync != nil
        return (completed, nothingNew)
    }
    /// Keys in the upload tree's format ("./a/b.txt", "./a") for unchanged files and for folders whose every file is
    /// unchanged. The root "." is never included, so the transfer always runs and re-checks the remote side.
    static func completedKeys(current: [String: FileStamp], previous: [String: FileStamp]) -> Set<String> {
        var keys: Set<String> = []
        var changedDirectories: Set<String> = []
        var allDirectories: Set<String> = []
        for (path, stamp) in current {
            let unchanged = previous[path] == stamp
            if stamp.size == -1 {
                allDirectories.insert(path)
                if !unchanged { changedDirectories.insert(path) }
            } else if unchanged { keys.insert("./" + path) }
            var components = path.split(separator: "/").map(String.init); components.removeLast()
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                allDirectories.insert(prefix)
                if !unchanged { changedDirectories.insert(prefix) }
            }
        }
        for directory in allDirectories where !changedDirectories.contains(directory) { keys.insert("./" + directory) }
        return keys
    }
}

/// Recursive FSEvents watcher for one folder; fires on the given queue after the system's own coalescing latency,
/// with the absolute paths of what changed.
final class FolderWatcher {
    /// What the FSEvents callback is handed. The stream keeps this alive and this keeps nothing alive, so an event
    /// already on its way when the watcher goes finds an empty box instead of freed memory.
    private final class Callback {
        var onChange: (([String]) -> Void)?
        init(_ onChange: @escaping ([String]) -> Void) { self.onChange = onChange }
    }
    private var stream: FSEventStreamRef?
    private let callback: Callback
    convenience init(url: URL, latency: TimeInterval = 2, onChange: @escaping () -> Void) {
        self.init(url: url, latency: latency, onPaths: { _ in onChange() })
    }
    init(url: URL, latency: TimeInterval = 2, onPaths: @escaping ([String]) -> Void) {
        callback = Callback(onPaths)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callback).toOpaque(), retain: nil,
                                           release: { info in Unmanaged<Callback>.fromOpaque(info!).release() },
                                           copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            // With UseCFTypes the paths arrive as a CFArray of CFStrings.
            let changed = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange?(changed)
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "icloudy.mirror.fsevents"))
            FSEventStreamStart(stream)
        }
    }
    func stop() {
        callback.onChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}

@MainActor
final class MirrorManager: ObservableObject {
    @Published private(set) var mirrors: [FolderMirror] = []
    @Published var persistenceError: String?
    /// Mirrors whose folder changed while a sync was running or waiting for the debounce.
    @Published private(set) var pending: Set<UUID> = []
    let storeURL: URL
    weak var queue: TransferQueue? {
        didSet { queue?.uploadExclusions = { [weak self] transfer in self?.exclusions(forTransfer: transfer) } }
    }
    var accountLookup: ((String) -> Account?)?
    /// Time to let a burst of file-system events settle before planning a sync.
    var debounce: Duration = .seconds(3)
    /// Tests turn this off: FSEvents on a temporary folder would race the assertions.
    var watching = true
    /// How often a two-way mirror asks the cloud for changes nobody made from this Mac.
    var remotePollInterval: Duration = .seconds(300)
    /// Two-way syncs in progress, and the ones that must run once more because something changed meanwhile.
    private(set) var running: Set<UUID> = []
    private var pollers: [UUID: Task<Void, Never>] = [:]
    /// Set by "Sincronizar aplicando los borrados" for the next run only.
    private var massDeletionAllowed: Set<UUID> = []
    private var watchers: [UUID: FolderWatcher] = [:]
    private var scopedURLs: [UUID: URL] = [:]
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var dirty: Set<UUID> = []
    private var subscription: AnyCancellable?
    /// Compiled rules per mirror, dropped whenever the rules change. Case sensitivity follows the local volume.
    private var matchers: [UUID: SyncExclusionMatcher] = [:]
    /// How many changed paths a paused mirror remembers; past this the sidebar just says "more than".
    static let pausedChangesLimit = 1000

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("mirrors.json")) {
        self.storeURL = storeURL
        do { mirrors = try LocalStore.read([FolderMirror].self, from: storeURL) ?? [] }
        catch { persistenceError = L("No se pudieron leer los reflejos: \(error.localizedDescription)") }
    }
    /// Called once the queue exists: watches every folder and runs a cheap catch-up sync for each mirror.
    func start() {
        subscription = queue?.stateChanges.sink { [weak self] _ in self?.noteFailures() }
        for mirror in mirrors { watch(mirror); scheduleSync(mirror.id, immediate: true, resumeInterrupted: true) }
    }
    func add(local: URL, account: Account, folder: CloudFile, path: [CloudFile], mode: FolderMirror.Mode = .upload) throws {
        let standardized = local.standardizedFileURL
        guard !mirrors.contains(where: { $0.localURL.standardizedFileURL == standardized && $0.remoteFolderID == folder.id }) else {
            throw CloudError.message(L("Esa carpeta ya se refleja en ese destino."))
        }
        guard !mirrors.contains(where: { $0.localURL.standardizedFileURL == standardized }) else {
            throw CloudError.message(L("Esa carpeta ya se refleja en otro destino. Deja de reflejarla antes de elegir uno nuevo."))
        }
        var mirror = FolderMirror(accountID: account.id, remoteFolderID: folder.id, remoteName: ([account.email] + path.map(\.name) + [folder.name]).joined(separator: " / "), localURL: standardized, bookmark: try? TransferQueue.bookmark(local))
        mirror.mode = mode
        mirrors.append(mirror)
        try persist()
        watch(mirror)
        scheduleSync(mirror.id, immediate: true)
    }
    func remove(_ id: UUID) {
        let transfer = mirrors.first(where: { $0.id == id })?.activeTransferID
        watchers.removeValue(forKey: id)?.stop()
        if let url = scopedURLs.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        scheduled.removeValue(forKey: id)?.cancel(); dirty.remove(id); pending.remove(id)
        pollers.removeValue(forKey: id)?.cancel(); running.remove(id); massDeletionAllowed.remove(id); matchers[id] = nil
        mirrors.removeAll { $0.id == id }
        if let transfer { queue?.cancel(transfer) }
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    func remap(_ change: RemoteIdentityChange, accountID: String) throws {
        for i in mirrors.indices where mirrors[i].accountID == accountID {
            mirrors[i].remoteFolderID = change.id(mirrors[i].remoteFolderID)
            mirrors[i].remoteEntries = mirrors[i].remoteEntries.mapValues(change.file)
        }
        try persist()
    }
    func removeAll(accountID: String) { for mirror in mirrors where mirror.accountID == accountID { remove(mirror.id) } }
    /// Pausing stops planning, puts a running upload on hold in the queue and lets a two-way run finish only the
    /// step it is on. Resuming runs at once: the run compares the whole folder, so it applies everything that
    /// changed meanwhile, including what changed while iCloudy was closed.
    func setPaused(_ paused: Bool, for id: UUID) {
        guard let index = mirrors.firstIndex(where: { $0.id == id }), mirrors[index].paused != paused else { return }
        mirrors[index].paused = paused
        if paused {
            scheduled.removeValue(forKey: id)?.cancel(); pending.remove(id); dirty.remove(id); massDeletionAllowed.remove(id)
            if let active = mirrors[index].activeTransferID, let item = queue?.items.first(where: { $0.id == active }), [.queued, .running].contains(item.state) {
                queue?.cancel(active, pause: true)
            }
        } else {
            mirrors[index].changesWhilePaused = []
        }
        do { try persist() } catch { persistenceError = error.localizedDescription }
        if !paused { scheduleSync(id, immediate: true) }
    }
    func isPaused(_ id: UUID) -> Bool { mirrors.first { $0.id == id }?.paused == true }
    /// What FSEvents reported for a mirror. While paused the paths are only noted down, relative to the folder and
    /// without what the rules exclude, so .DS_Store churn does not show up as pending work.
    func noteChanges(_ paths: [String], for id: UUID) {
        guard let index = mirrors.firstIndex(where: { $0.id == id }) else { return }
        guard mirrors[index].paused else { scheduleSync(id, immediate: false); return }
        let mirror = mirrors[index]
        // FSEvents reports real paths (/private/var/…), so the folder is tried both as stored and resolved. The
        // event paths themselves are not resolved: a deleted file has nothing left to resolve.
        let url = resolvedURL(mirror)
        let roots = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
        let rules = exclusions(of: mirror)
        var changes = mirror.changesWhilePaused
        for path in paths {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            guard !rules.excludes(relative, isFolder: false), changes.count < Self.pausedChangesLimit else { continue }
            changes.insert(relative)
        }
        guard changes != mirror.changesWhilePaused else { return }
        mirrors[index].changesWhilePaused = changes
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    func syncNow(_ id: UUID, applyingMassDeletion: Bool = false) {
        // A permission granted to a paused mirror would wait for the resume and apply to a run nobody asked for.
        guard !isPaused(id) else { return }
        if applyingMassDeletion { massDeletionAllowed.insert(id) }
        scheduleSync(id, immediate: true)
    }

    /// Replaces a mirror's rules and syncs again, so whatever a rule no longer covers goes up now. Nothing that a
    /// new rule covers is deleted on either side: it is simply no longer looked at.
    func setExclusions(_ rules: SyncExclusions, for id: UUID) throws {
        guard let index = mirrors.firstIndex(where: { $0.id == id }) else { return }
        guard mirrors[index].exclusions != rules else { return }
        mirrors[index].exclusions = rules
        matchers[id] = nil
        try persist()
        scheduleSync(id, immediate: true)
    }
    func exclusions(of mirror: FolderMirror) -> SyncExclusionMatcher {
        if let cached = matchers[mirror.id] { return cached }
        let matcher = mirror.exclusions.matcher(caseInsensitive: SyncExclusions.isCaseInsensitive(resolvedURL(mirror)))
        matchers[mirror.id] = matcher
        return matcher
    }
    private func exclusions(forTransfer transfer: UUID) -> SyncExclusionMatcher? {
        mirrors.first { $0.activeTransferID == transfer }.map(exclusions(of:))
    }

    /// What the sidebar shows next to a mirror.
    func status(of mirror: FolderMirror) -> String {
        if mirror.paused {
            if running.contains(mirror.id) { return L("Deteniéndose al acabar el paso en curso…") }
            let count = mirror.changesWhilePaused.count
            if count >= Self.pausedChangesLimit { return L("En pausa · más de \(Self.pausedChangesLimit) cambios esperando") }
            return count == 0 ? L("En pausa") : L("En pausa · \(count) cambios esperando")
        }
        if running.contains(mirror.id) { return L("Sincronizando en ambos sentidos…") }
        if let active = mirror.activeTransferID, let item = queue?.items.first(where: { $0.id == active }), [.queued, .running].contains(item.state) {
            return item.state == .running ? L("Sincronizando…") : L("En cola")
        }
        if pending.contains(mirror.id) { return L("Cambios detectados · sincronizando en breve") }
        if let error = mirror.lastError { return L("Error: \(error)") }
        guard let last = mirror.lastSync else { return L("Pendiente de la primera sincronización") }
        // The person's own locale: pinning es_ES here showed "hace 5 min" in the middle of an English interface.
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
        let when = L("Sincronizado \(formatter.localizedString(for: last, relativeTo: Date()))")
        if mirror.mode == .twoWay, let report = mirror.lastReport, !report.isEmpty { return when + " · " + report.summary }
        return when
    }

    private func persist() throws {
        do { try LocalStore.save(mirrors, to: storeURL); persistenceError = nil }
        catch { persistenceError = L("No se pudieron guardar los reflejos: \(error.localizedDescription)"); throw error }
    }
    private func resolvedURL(_ mirror: FolderMirror) -> URL {
        if let url = scopedURLs[mirror.id] { return url }
        var url = mirror.localURL
        var stale = false
        if let bookmark = mirror.bookmark {
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { url = resolved }
        }
        // Keep the scope open for as long as the folder is mirrored: the watcher and every sync read through it.
        if url.startAccessingSecurityScopedResource() { scopedURLs[mirror.id] = url }
        // A stale bookmark still resolves today and stops the day the folder moves, and the mirror then says the
        // folder no longer exists when it is sitting right there.
        if stale, let renewed = try? TransferQueue.bookmark(url), let index = mirrors.firstIndex(where: { $0.id == mirror.id }) {
            mirrors[index].bookmark = renewed
            try? persist()
        }
        return url
    }
    private func watch(_ mirror: FolderMirror) {
        guard watching, watchers[mirror.id] == nil else { return }
        let url = resolvedURL(mirror)
        let id = mirror.id
        watchers[id] = FolderWatcher(url: url) { [weak self] paths in Task { @MainActor in self?.noteChanges(paths, for: id) } }
        // The cloud sends no events: a two-way mirror asks it now and then for what changed elsewhere.
        if mirror.mode == .twoWay, pollers[id] == nil {
            let interval = remotePollInterval
            pollers[id] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.scheduleSync(id, immediate: true) }
                }
            }
        }
    }
    private func scheduleSync(_ id: UUID, immediate: Bool, resumeInterrupted: Bool = false) {
        // A paused mirror plans nothing: not on events, not on the remote poll and not on "sync now".
        guard let mirror = mirrors.first(where: { $0.id == id }), !mirror.paused else { return }
        pending.insert(id)
        scheduled[id]?.cancel()
        let delay = immediate ? Duration.zero : debounce
        scheduled[id] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            self.scheduled[id] = nil
            await self.sync(id, resumeInterrupted: resumeInterrupted)
        }
    }
    private func sync(_ id: UUID, resumeInterrupted: Bool = false) async {
        guard let index = mirrors.firstIndex(where: { $0.id == id }), let queue else { return }
        if mirrors[index].mode == .twoWay { await syncTwoWay(id); return }
        if let active = mirrors[index].activeTransferID, let item = queue.items.first(where: { $0.id == active }) {
            if [.queued, .running].contains(item.state) {
                // Let the running sync finish; its completion re-plans with whatever changed meanwhile.
                dirty.insert(id); return
            }
            // Closing the app pauses whatever was running. Planning a second sync left the first one orphaned in the
            // panel, with a plan made against a folder that had since moved on; the person had to notice and clear it.
            if item.state == .paused, item.mirrorEntries != nil {
                queue.retry(active)
                dirty.insert(id); pending.remove(id); return
            }
            if item.state == .paused, item.mirrorEntries == nil { queue.cancel(active) }
        }
        pending.remove(id)
        let mirror = mirrors[index]
        let url = resolvedURL(mirror)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw CloudError.message(L("La carpeta local ya no existe en \(url.path).")) }
            let rules = exclusions(of: mirror)
            let current = try await blockingIO { try MirrorPlanner.scan(url, exclusions: rules).stamps }
            guard let position = mirrors.firstIndex(where: { $0.id == id }) else { return }
            let (unchanged, nothingNew) = MirrorPlanner.oneWayPlan(current: current, mirror: mirrors[position])
            if nothingNew {
                // Nothing new since the last sync: no transfer, no network.
                mirrors[position].lastError = nil; try persist(); return
            }
            var job = Transfer(batchID: UUID(), name: L("Reflejo · \(url.lastPathComponent)"), destination: mirror.remoteName, accountID: mirror.accountID, direction: .upload, localURL: url, bookmark: mirror.bookmark, parent: mirror.remoteFolderID)
            // The root receives the contents. Only unchanged remote identities previously written by this mirror
            // may be replaced automatically; new collisions and remote edits still go through the conflict dialog.
            job.names["."] = url.lastPathComponent
            job.folders["."] = mirror.remoteFolderID
            job.mirrorEntries = mirrors[position].remoteEntries
            job.completedPaths = unchanged
            try queue.add([job])
            mirrors[position].activeTransferID = job.id
            mirrors[position].pendingStamps = current
            mirrors[position].lastError = nil
            try persist()
        } catch {
            if let position = mirrors.firstIndex(where: { $0.id == id }) { mirrors[position].lastError = error.localizedDescription; try? persist() }
        }
    }
    /// A two-way run: plan against the baseline, carry it out, write the baseline down after every step. One run
    /// per mirror at a time; a change that arrives meanwhile queues one more run.
    private func syncTwoWay(_ id: UUID) async {
        guard !running.contains(id) else { dirty.insert(id); return }
        guard let index = mirrors.firstIndex(where: { $0.id == id }), let account = accountLookup?(mirrors[index].accountID) else { return }
        pending.remove(id); running.insert(id)
        defer { running.remove(id) }
        let mirror = mirrors[index]
        let url = resolvedURL(mirror)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw CloudError.message(L("La carpeta local ya no existe en \(url.path).")) }
            let engine = try makeEngine(mirror, account: account, url: url)
            engine.shouldStop = { [weak self] in self?.isPaused(id) ?? true }
            engine.allowMassDeletion = massDeletionAllowed.remove(id) != nil
            engine.persist = { [weak self] baseline in
                guard let self, let position = self.mirrors.firstIndex(where: { $0.id == id }) else { return }
                self.mirrors[position].baseline = baseline
                try self.persist()
            }
            let report = try await engine.run()
            guard let position = mirrors.firstIndex(where: { $0.id == id }) else { return }
            mirrors[position].baseline = engine.baseline
            mirrors[position].lastReport = report
            mirrors[position].lastSync = Date()
            mirrors[position].lastError = nil
            try persist()
        } catch {
            if let position = mirrors.firstIndex(where: { $0.id == id }) {
                // Paused halfway: every finished step is in the baseline already, so that is not an error.
                if error is SyncPaused { mirrors[position].lastError = nil }
                else { mirrors[position].lastError = (error as? CancellationError) == nil ? error.localizedDescription : L("Sincronización cancelada") }
                try? persist()
            }
        }
        if dirty.remove(id) != nil { scheduleSync(id, immediate: true) }
    }
    private func makeEngine(_ mirror: FolderMirror, account: Account, url: URL) throws -> TwoWaySyncEngine {
        guard let api = try queue?.client?(account.id) else { throw CloudError.message(L("Vuelve a conectar la cuenta de este reflejo.")) }
        let engine = TwoWaySyncEngine(api: api, localRoot: url, remoteRoot: mirror.remoteFolderID, baseline: mirror.baseline)
        engine.exclusions = exclusions(of: mirror)
        return engine
    }
    /// A dry run of the next sync, paused or not: the same scan and the same planner as the real one, and nothing
    /// written anywhere. A two-way preview lists the cloud, which a one-way one never needs to.
    func preview(_ id: UUID) async throws -> MirrorPreview {
        guard let mirror = mirrors.first(where: { $0.id == id }) else { throw CloudError.message(L("Este reflejo ya no existe.")) }
        let url = resolvedURL(mirror)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CloudError.message(L("La carpeta local ya no existe en \(url.path).")) }
        let rules = exclusions(of: mirror)
        if mirror.mode == .twoWay {
            guard let account = accountLookup?(mirror.accountID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de este reflejo.")) }
            let engine = try makeEngine(mirror, account: account, url: url)
            engine.allowMassDeletion = massDeletionAllowed.contains(id)
            return try await engine.preview()
        }
        let scan = try await blockingIO { try MirrorPlanner.scan(url, exclusions: rules) }
        guard let current = mirrors.first(where: { $0.id == id }) else { throw CloudError.message(L("Este reflejo ya no existe.")) }
        let (completed, nothingNew) = MirrorPlanner.oneWayPlan(current: scan.stamps, mirror: current)
        var preview = MirrorPreview.oneWay(current: scan.stamps, completed: completed, nothingNew: nothingNew, remoteEntries: current.remoteEntries, excluded: scan.excluded)
        if let active = current.activeTransferID, let item = queue?.items.first(where: { $0.id == active }), item.mirrorEntries != nil, [.queued, .running, .paused].contains(item.state) {
            preview.resumesQueuedUpload = true
        }
        return preview
    }
    /// Hooked to the queue's `didFinish`: promotes the planned stamps and re-syncs if the folder changed meanwhile.
    func handleFinished(_ transfer: Transfer) {
        guard let index = mirrors.firstIndex(where: { $0.activeTransferID == transfer.id }) else { return }
        let entries = transfer.mirrorEntries ?? [:]
        mirrors[index].remoteEntries = entries
        mirrors[index].stamps = (mirrors[index].pendingStamps ?? mirrors[index].stamps).filter { entries["./" + $0.key] != nil }
        mirrors[index].pendingStamps = nil
        mirrors[index].lastSync = Date()
        mirrors[index].activeTransferID = nil
        mirrors[index].lastError = nil
        do { try persist() } catch { persistenceError = error.localizedDescription }
        let id = mirrors[index].id
        if dirty.remove(id) != nil { scheduleSync(id, immediate: true) }
    }
    private func noteFailures() {
        guard let queue else { return }
        var changed = false
        for index in mirrors.indices {
            guard let active = mirrors[index].activeTransferID, let item = queue.items.first(where: { $0.id == active }), [.failed, .cancelled].contains(item.state) else { continue }
            mirrors[index].lastError = item.state == .failed ? item.detail : L("Sincronización cancelada")
            mirrors[index].activeTransferID = nil; mirrors[index].pendingStamps = nil
            changed = true
        }
        if changed { try? persist(); objectWillChange.send() }
    }
}
