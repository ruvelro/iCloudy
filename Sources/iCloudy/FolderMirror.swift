import Foundation
import Combine
import CoreServices

/// Size and modification date of a local file the last time it was uploaded by a mirror.
struct FileStamp: Codable, Equatable {
    let size: Int64
    let modified: Date
}

/// A local folder whose contents are pushed, one way, into a remote folder. Deletions and renames are not mirrored:
/// a removed local file stays in the cloud, a renamed one is uploaded under its new name.
struct FolderMirror: Identifiable, Codable {
    var id = UUID()
    let accountID: String
    let remoteFolderID: String
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
}

extension FolderMirror {
    enum CodingKeys: String, CodingKey { case id, accountID, remoteFolderID, remoteName, localURL, bookmark, stamps, pendingStamps, lastSync, activeTransferID, lastError }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
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
    }
}

/// Pure planning: which upload-tree keys can be marked completed because nothing under them changed.
enum MirrorPlanner {
    /// Relative path → stamp for every regular file under `root`. Symlinks are skipped, hidden files are included.
    nonisolated static func stamps(of root: URL) throws -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        let base = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: []) else { return result }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            result[String(path.dropFirst(base.count + 1))] = FileStamp(size: Int64(values.fileSize ?? 0), modified: modified)
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
            if unchanged { keys.insert("./" + path) }
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
    func add(local: URL, account: Account, folder: CloudFile, path: [CloudFile]) throws {
        let standardized = local.standardizedFileURL
        guard !mirrors.contains(where: { $0.localURL.standardizedFileURL == standardized && $0.remoteFolderID == folder.id }) else {
            throw CloudError.message(L("Esa carpeta ya se refleja en ese destino."))
        }
        guard !mirrors.contains(where: { $0.localURL.standardizedFileURL == standardized }) else {
            throw CloudError.message(L("Esa carpeta ya se refleja en otro destino. Deja de reflejarla antes de elegir uno nuevo."))
        }
        let mirror = FolderMirror(accountID: account.id, remoteFolderID: folder.id, remoteName: ([account.email] + path.map(\.name) + [folder.name]).joined(separator: " / "), localURL: standardized, bookmark: try? TransferQueue.bookmark(local))
        mirrors.append(mirror)
        try persist()
        watch(mirror)
        scheduleSync(mirror.id, immediate: true)
    }
    func remove(_ id: UUID) {
        watchers.removeValue(forKey: id)?.stop()
        if let url = scopedURLs.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        scheduled.removeValue(forKey: id)?.cancel(); dirty.remove(id); pending.remove(id)
        mirrors.removeAll { $0.id == id }
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    func removeAll(accountID: String) { for mirror in mirrors where mirror.accountID == accountID { remove(mirror.id) } }
    func syncNow(_ id: UUID) { scheduleSync(id, immediate: true) }

    /// What the sidebar shows next to a mirror.
    func status(of mirror: FolderMirror) -> String {
        if let active = mirror.activeTransferID, let item = queue?.items.first(where: { $0.id == active }), [.queued, .running].contains(item.state) {
            return item.state == .running ? L("Sincronizando…") : L("En cola")
        }
        if pending.contains(mirror.id) { return L("Cambios detectados · sincronizando en breve") }
        if let error = mirror.lastError { return L("Error: ") + error }
        guard let last = mirror.lastSync else { return L("Pendiente de la primera sincronización") }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "es_ES"); formatter.unitsStyle = .short
        return L("Sincronizado ") + formatter.localizedString(for: last, relativeTo: Date())
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
        if let active = mirrors[index].activeTransferID, let item = queue.items.first(where: { $0.id == active }) {
            if [.queued, .running].contains(item.state) {
                // Let the running sync finish; its completion re-plans with whatever changed meanwhile.
                dirty.insert(id); return
            }
            // Closing the app pauses whatever was running. Planning a second sync left the first one orphaned in the
            // panel, with a plan made against a folder that had since moved on; the person had to notice and clear it.
            if resumeInterrupted, item.state == .paused {
                queue.retry(active)
                dirty.insert(id); pending.remove(id); return
            }
        }
        pending.remove(id)
        let mirror = mirrors[index]
        let url = resolvedURL(mirror)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw CloudError.message(L("La carpeta local ya no existe en \(url.path).")) }
            let current = try await blockingIO { try MirrorPlanner.stamps(of: url) }
            guard let position = mirrors.firstIndex(where: { $0.id == id }) else { return }
            let unchanged = MirrorPlanner.completedKeys(current: current, previous: mirrors[position].stamps)
            if unchanged.count == current.count + unchanged.filter({ !current.keys.contains(String($0.dropFirst(2))) }).count, current.allSatisfy({ mirrors[position].stamps[$0.key] == $0.value }), mirrors[position].lastSync != nil {
                // Nothing new since the last sync: no transfer, no network.
                mirrors[position].lastError = nil; try persist(); return
            }
            var job = Transfer(batchID: UUID(), name: "Reflejo · " + url.lastPathComponent, destination: mirror.remoteName, accountID: mirror.accountID, direction: .upload, localURL: url, bookmark: mirror.bookmark, parent: mirror.remoteFolderID)
            // The remote folder already exists and receives the *contents*: the root level is pre-resolved, and files
            // that changed replace their remote counterpart instead of prompting.
            job.names["."] = url.lastPathComponent
            job.folders["."] = mirror.remoteFolderID
            // Only what this mirror has uploaded before is replaced without asking. On the very first sync there is
            // nothing to compare against, so anything already in the destination is a stranger's file and the usual
            // conflict dialog decides what happens to it.
            if mirrors[position].lastSync != nil { job.batchChoice = .replace }
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
    /// Hooked to the queue's `didFinish`: promotes the planned stamps and re-syncs if the folder changed meanwhile.
    func handleFinished(_ transfer: Transfer) {
        guard let index = mirrors.firstIndex(where: { $0.activeTransferID == transfer.id }) else { return }
        mirrors[index].stamps = mirrors[index].pendingStamps ?? mirrors[index].stamps
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
