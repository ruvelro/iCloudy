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
}

extension FolderMirror {
    enum CodingKeys: String, CodingKey { case id, mode, baseline, lastReport, accountID, remoteFolderID, remoteName, localURL, bookmark, stamps, pendingStamps, lastSync, activeTransferID, lastError, remoteEntries }
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
    }
}

/// Pure planning: which upload-tree keys can be marked completed because nothing under them changed.
enum MirrorPlanner {
    /// Relative path → stamp for every regular file under `root`. Symlinks are skipped, hidden files are included.
    nonisolated static func stamps(of root: URL) throws -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        let base = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: []) else { return result }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true || values.isDirectory == true else { continue }
            let modified = values.isDirectory == true ? Date(timeIntervalSince1970: 0) : (values.contentModificationDate ?? .distantPast)
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            result[String(path.dropFirst(base.count + 1))] = FileStamp(size: values.isDirectory == true ? -1 : Int64(values.fileSize ?? 0), modified: modified)
        }
        return result
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

/// Recursive FSEvents watcher for one folder; fires on the given queue after the system's own coalescing latency.
final class FolderWatcher {
    /// What the FSEvents callback is handed. The stream keeps this alive and this keeps nothing alive, so an event
    /// already on its way when the watcher goes finds an empty box instead of freed memory.
    private final class Callback {
        var onChange: (() -> Void)?
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }
    private var stream: FSEventStreamRef?
    private let callback: Callback
    init(url: URL, latency: TimeInterval = 2, onChange: @escaping () -> Void) {
        callback = Callback(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callback).toOpaque(), retain: nil,
                                           release: { info in Unmanaged<Callback>.fromOpaque(info!).release() },
                                           copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange?()
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
    weak var queue: TransferQueue?
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
        pollers.removeValue(forKey: id)?.cancel(); running.remove(id); massDeletionAllowed.remove(id)
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
    func syncNow(_ id: UUID, applyingMassDeletion: Bool = false) {
        if applyingMassDeletion { massDeletionAllowed.insert(id) }
        scheduleSync(id, immediate: true)
    }

    /// What the sidebar shows next to a mirror.
    func status(of mirror: FolderMirror) -> String {
        if running.contains(mirror.id) { return L("Sincronizando en ambos sentidos…") }
        if let active = mirror.activeTransferID, let item = queue?.items.first(where: { $0.id == active }), [.queued, .running].contains(item.state) {
            return item.state == .running ? L("Sincronizando…") : L("En cola")
        }
        if pending.contains(mirror.id) { return L("Cambios detectados · sincronizando en breve") }
        if let error = mirror.lastError { return L("Error: ") + error }
        guard let last = mirror.lastSync else { return L("Pendiente de la primera sincronización") }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "es_ES"); formatter.unitsStyle = .short
        let when = L("Sincronizado ") + formatter.localizedString(for: last, relativeTo: Date())
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
        watchers[id] = FolderWatcher(url: url) { [weak self] in Task { @MainActor in self?.scheduleSync(id, immediate: false) } }
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
        guard mirrors.contains(where: { $0.id == id }) else { return }
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
            let current = try await blockingIO { try MirrorPlanner.stamps(of: url) }
            guard let position = mirrors.firstIndex(where: { $0.id == id }) else { return }
            let unchanged = MirrorPlanner.completedKeys(current: current, previous: mirrors[position].stamps.filter { mirrors[position].remoteEntries["./" + $0.key] != nil })
            if unchanged.count == current.count + unchanged.filter({ !current.keys.contains(String($0.dropFirst(2))) }).count, current.allSatisfy({ mirrors[position].stamps[$0.key] == $0.value && mirrors[position].remoteEntries["./" + $0.key] != nil }), mirrors[position].lastSync != nil {
                // Nothing new since the last sync: no transfer, no network.
                mirrors[position].lastError = nil; try persist(); return
            }
            var job = Transfer(batchID: UUID(), name: "Reflejo · " + url.lastPathComponent, destination: mirror.remoteName, accountID: mirror.accountID, direction: .upload, localURL: url, bookmark: mirror.bookmark, parent: mirror.remoteFolderID)
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
            guard let api = try queue?.client?(account.id) else { throw CloudError.message(L("Vuelve a conectar la cuenta de este reflejo.")) }
            let engine = TwoWaySyncEngine(api: api, localRoot: url, remoteRoot: mirror.remoteFolderID, baseline: mirror.baseline)
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
                mirrors[position].lastError = (error as? CancellationError) == nil ? error.localizedDescription : L("Sincronización cancelada")
                try? persist()
            }
        }
        if dirty.remove(id) != nil { scheduleSync(id, immediate: true) }
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
            mirrors[index].lastError = item.state == .failed ? item.detail : "Sincronización cancelada"
            mirrors[index].activeTransferID = nil; mirrors[index].pendingStamps = nil
            changed = true
        }
        if changed { try? persist(); objectWillChange.send() }
    }
}
