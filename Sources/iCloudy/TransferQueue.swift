import Foundation
import Combine

struct ConflictRequest: Identifiable {
    let id = UUID()
    let transferID: UUID
    let name: String
    let canReplace: Bool
    let folder: Bool
}

@MainActor
final class TransferQueue: ObservableObject {
    @Published private(set) var items: [Transfer] = []
    @Published var conflict: ConflictRequest? { didSet { stateChanges.send() } }
    @Published var persistenceError: String? { didSet { stateChanges.send() } }
    /// Fires on structural changes only: jobs added or removed, state transitions, conflicts and persistence errors.
    /// Progress ticks mutate `items` without touching it, so views observing the whole app do not re-render per block.
    let stateChanges = PassthroughSubject<Void, Never>()
    var client: ((String) throws -> CloudAPI)?
    var didComplete: ((String) -> Void)?
    var retryDelay: Double = 1
    /// Minimum interval between two progress updates; URLSession can report dozens of times per second.
    var reportInterval: TimeInterval = 0.1
    /// Delay before coalesced checkpoint writes reach disk. State transitions and new upload sessions write at once.
    var flushDelay: Duration = .seconds(2)
    var isWorking: Bool { task != nil }
    let storeURL: URL
    private var writable = true
    private var dirty = false
    private var flushTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private var conflictContinuation: CheckedContinuation<ConflictChoice, Error>?
    private var started = Date()
    private var startBytes: Int64 = 0
    private var lastReport = Date.distantPast

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("transfers.json")) {
        self.storeURL = storeURL
        do {
            items = try LocalStore.read([Transfer].self, from: storeURL) ?? []
            for index in items.indices where [.running, .queued].contains(items[index].state) { items[index].state = .paused; items[index].bytesPerSecond = 0 }
        } catch { writable = false; persistenceError = "No se pudo recuperar la cola. Se conserva el archivo original: \(error.localizedDescription)" }
    }
    /// True when the saved queue could not be read: nothing can be added until the user sets that file aside.
    var canDiscardSavedQueue: Bool { !writable }
    /// Moves the unreadable store next to itself with a `.corrupt-<timestamp>` suffix and starts an empty, writable queue.
    /// The original bytes are preserved so nothing is lost if a future version can read them.
    func discardSavedQueue() {
        guard !writable else { return }
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                let backup = storeURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try FileManager.default.moveItem(at: storeURL, to: backup)
            }
            items = []; writable = true; persistenceError = nil
            stateChanges.send()
        } catch { persistenceError = "No se pudo apartar la cola dañada: \(error.localizedDescription)" }
    }
    var hasActive: Bool { items.contains { [.queued, .running].contains($0.state) } }
    func hasActive(accountID: String) -> Bool {
        items.contains { $0.accountID == accountID && ([.queued, .running].contains($0.state) || $0.id == activeID) }
    }

    /// Coalesced writes batch the per-block checkpoints into one file write every `flushDelay`. The server is the
    /// authority on resume anyway, so losing the last seconds of offsets only costs a probe request.
    private func persist(coalesce: Bool = false) throws {
        guard writable else { throw CloudError.message(persistenceError ?? "La cola no se puede guardar.") }
        if coalesce { dirty = true; scheduleFlush(); return }
        flushTask?.cancel(); flushTask = nil; dirty = false
        do { try LocalStore.save(items, to: storeURL) }
        catch { persistenceError = "No se pudo guardar la cola: \(error.localizedDescription)"; throw error }
    }
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let delay = self?.flushDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }
    /// Writes pending coalesced changes now. Called before the process exits.
    func flush() {
        guard dirty, writable else { return }
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }

    func add(_ jobs: [Transfer]) throws {
        items += jobs
        do { try persist() } catch { items.removeAll { item in jobs.contains { $0.id == item.id } }; throw error }
        stateChanges.send()
        kick()
    }
    static func bookmark(_ url: URL) throws -> Data { try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
    func retry(_ id: UUID) {
        guard let index = index(id), [.failed, .paused, .cancelled].contains(items[index].state) else { return }
        items[index].state = .queued; items[index].detail = ""; items[index].attempts = 0
        do { try persist(); kick() } catch { items[index].state = .failed }
        stateChanges.send()
    }
    func cancel(_ id: UUID, pause: Bool = false) {
        guard let index = index(id), !items[index].finished else { return }
        items[index].state = pause ? .paused : .cancelled; items[index].bytesPerSecond = 0
        if activeID == id {
            task?.cancel()
            conflictContinuation?.resume(throwing: CancellationError()); conflictContinuation = nil; conflict = nil
        }
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    func pauseAll() {
        for id in items.filter({ [.running, .queued].contains($0.state) }).map(\.id) { cancel(id, pause: true) }
    }
    func clearCompleted() {
        items.removeAll { $0.state == .completed }
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    func resolve(_ choice: ConflictChoice, applyToBatch: Bool) {
        guard let request = conflict, let index = index(request.transferID) else { return }
        guard choice != .replace || request.canReplace else { return }
        if applyToBatch {
            let batch = items[index].batchID
            for i in items.indices where items[i].batchID == batch { items[i].batchChoice = choice }
        }
        conflict = nil
        conflictContinuation?.resume(returning: choice); conflictContinuation = nil
    }
    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private func job(_ id: UUID) throws -> Transfer {
        guard let index = index(id) else { throw CancellationError() }
        return items[index]
    }
    /// `coalesce` defers the disk write; a state transition always writes immediately and notifies observers.
    private func edit(_ id: UUID, coalesce: Bool = false, _ change: (inout Transfer) -> Void) throws {
        guard let index = index(id) else { throw CancellationError() }
        let before = items[index].state
        change(&items[index])
        let transition = items[index].state != before
        try persist(coalesce: coalesce && !transition)
        if transition { stateChanges.send() }
    }
    private func kick() {
        guard task == nil, let next = items.first(where: { $0.state == .queued }) else { return }
        activeID = next.id
        task = Task {
            let id = next.id
            do {
                try edit(id) { $0.state = .running; $0.detail = "Preparando…" }
                started = Date(); startBytes = next.bytes
                while true {
                    do { try await run(id); break }
                    catch {
                        try Task.checkCancellation()
                        let current = try job(id)
                        let transient = (error as? ServiceError)?.retryable == true || [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains((error as? URLError)?.code)
                        guard transient, current.attempts < 3 else { throw error }
                        try edit(id) { $0.attempts += 1; $0.detail = "Conexión interrumpida. Reintento \($0.attempts)/3…" }
                        try await Task.sleep(for: .seconds(retryDelay * pow(2, Double(current.attempts))))
                    }
                }
                // If the user cancelled just after the server committed, preserve the completed checkpoint but keep their state.
                if try job(id).state == .running { try edit(id) { $0.state = .completed; $0.bytes = max($0.bytes, $0.total); $0.bytesPerSecond = 0; $0.detail = ""; $0.uploads = [:] } }
                didComplete?(next.accountID)
            } catch {
                if let index = index(id), items[index].state == .running {
                    items[index].state = Task.isCancelled ? .paused : .failed
                    items[index].detail = error.localizedDescription + " Los elementos ya completados se conservan."
                    items[index].bytesPerSecond = 0
                    do { try persist() } catch { persistenceError = error.localizedDescription }
                }
            }
            activeID = nil; task = nil
            stateChanges.send()
            kick()
        }
    }
    private func choose(_ id: UUID, name: String, replace: Bool, folder: Bool) async throws -> ConflictChoice {
        try Task.checkCancellation()
        if let choice = try job(id).batchChoice, choice != .replace || replace { return choice }
        return try await withCheckedThrowingContinuation { continuation in
            conflictContinuation = continuation
            conflict = ConflictRequest(transferID: id, name: name, canReplace: replace, folder: folder)
        }
    }
    private func report(_ id: UUID, base: Int64, bytes: Int64, total: Int64) {
        guard let index = index(id), items[index].state == .running else { return }
        let now = Date()
        // Throttle to `reportInterval`, but always deliver the final tick of an item.
        guard now.timeIntervalSince(lastReport) >= reportInterval || (total > 0 && bytes >= total) else { return }
        lastReport = now
        items[index].bytes = base + bytes
        items[index].total = max(items[index].total, base + total)
        items[index].bytesPerSecond = Double(max(0, items[index].bytes - startBytes)) / max(0.1, Date().timeIntervalSince(started))
        items[index].detail = "Transfiriendo…"
    }
    private func run(_ id: UUID) async throws {
        let current = try job(id)
        guard let client else { throw CloudError.message("Conecta la cuenta de esta transferencia.") }
        let api = try client(current.accountID)
        var url = current.localURL
        if let bookmark = current.bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let renewed = try Self.bookmark(url)
                try edit(id) { $0.bookmark = renewed }
            }
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = url
        if current.direction == .upload {
            let total = try await blockingIO { try Self.localSize(source) }
            try edit(id) { $0.total = total; $0.bytes = 0 }
            var done: Int64 = 0
            var siblings: [String: [CloudFile]] = [:]
            try await uploadTree(id, api: api, local: source, parent: current.parent, key: ".", done: &done, siblings: &siblings)
        } else if let file = current.file {
            try edit(id) { $0.bytes = 0 }
            var done: Int64 = 0
            try await downloadTree(id, api: api, file: file, folder: source, key: ".", done: &done)
        }
    }
    /// Walks the tree synchronously; callers run it through `blockingIO` because large folders take a while.
    nonisolated private static func localSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message("No se admiten enlaces simbólicos: \(url.lastPathComponent)") }
        if values.isDirectory == true { return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).reduce(0) { try $0 + localSize($1) } }
        return Int64(values.fileSize ?? 0)
    }
    /// `siblings` caches one remote listing per destination folder for the whole run. Before, every uploaded item listed
    /// its parent again, which made a folder of N files cost N listings of N items.
    private func uploadTree(_ id: UUID, api: CloudAPI, local: URL, parent: String, key: String, done: inout Int64, siblings: inout [String: [CloudFile]]) async throws {
        try Task.checkCancellation()
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message("No se admiten enlaces simbólicos.") }
        let folder = values.isDirectory == true
        if try job(id).completedPaths.contains(key) { done += try await blockingIO { try Self.localSize(local) }; return }
        var current = try job(id)
        if current.uncertainFolders.contains(key) {
            // An earlier POST may have committed even though its reply was lost. Recheck conflicts before creating again.
            try edit(id) { $0.names[key] = nil; $0.replacements[key] = nil; $0.uncertainFolders.remove(key) }
            siblings[parent] = nil
            current = try job(id)
        }
        if current.names[key] == nil {
            if siblings[parent] == nil { siblings[parent] = try await api.list(parent: parent) }
            let existing = siblings[parent] ?? []
            let matches = existing.filter { $0.name.localizedCaseInsensitiveCompare(local.lastPathComponent) == .orderedSame }
            var name = local.lastPathComponent
            var replacing: String?
            if let match = matches.first {
                let choice = try await choose(id, name: name, replace: matches.count == 1 && match.isFolder == folder && !match.isGoogleDocument, folder: folder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key) }; done += try await blockingIO { try Self.localSize(local) }; return }
                if choice == .copy { name = Self.unique(name, existing: existing.map(\.name)) }
                if choice == .replace { replacing = match.id }
            }
            try edit(id, coalesce: true) { $0.names[key] = name; $0.replacements[key] = replacing }
            current = try job(id)
        }
        let name = current.names[key]!
        if folder {
            let remote: String
            if let known = current.folders[key] ?? current.replacements[key] { remote = known }
            else {
                // The marker must be on disk before the POST, so it is never coalesced.
                try edit(id) { $0.uncertainFolders.insert(key) }
                do { remote = try await api.createFolder(name: name, parent: parent) }
                catch { throw CloudError.message("No se confirmó la creación de \(name). Revisa el destino antes de reintentar. \(error.localizedDescription)") }
                try edit(id) { $0.folders[key] = remote; $0.uncertainFolders.remove(key) }
                siblings[parent, default: []].append(CloudFile(id: remote, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true))
                // A folder created a moment ago is empty: its children need no listing at all.
                siblings[remote] = []
            }
            let children = try await blockingIO { try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) }
            for child in children {
                try await uploadTree(id, api: api, local: child, parent: remote, key: key + "/" + child.lastPathComponent, done: &done, siblings: &siblings)
            }
        } else {
            let base = done
            let replacing = current.replacements[key]
            try await api.resumableUpload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: current.uploads[key], save: { checkpoint in
                // A new session URL and the completion are durable at once; intermediate offsets are coalesced.
                try self.edit(id, coalesce: checkpoint.offset > 0 && !checkpoint.complete) { $0.uploads[key] = checkpoint }
            }, progress: { bytes, total in self.report(id, base: base, bytes: bytes, total: total) })
            done += Int64(values.fileSize ?? 0)
            if replacing == nil {
                siblings[parent, default: []].append(CloudFile(id: "", name: name, mime: "application/octet-stream", size: values.fileSize.map(Int64.init), modified: nil, webURL: nil, isFolder: false))
            }
        }
        try edit(id, coalesce: true) { $0.completedPaths.insert(key) }
    }
    static func unique(_ name: String, existing: [String]) -> String {
        let url = URL(fileURLWithPath: name)
        var candidate = name; var number = 2
        while existing.contains(where: { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = url.deletingPathExtension().lastPathComponent + " (\(number))" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
            number += 1
        }
        return candidate
    }
    private func downloadTree(_ id: UUID, api: CloudAPI, file: CloudFile, folder: URL, key: String, done: inout Int64) async throws {
        try Task.checkCancellation()
        if try job(id).completedPaths.contains(key) { done += file.size ?? 0; return }
        var current = try job(id)
        let exporting = key == "." && current.exportMime != nil
        let name = FileNames.safe(file.name + (exporting ? "." + (current.exportExtension ?? "pdf") : (file.isGoogleDocument ? ".webloc" : "")))
        var target = folder.appendingPathComponent(current.names[key] ?? name)
        var replace = current.replacements[key] != nil
        if current.names[key] == nil || (!file.isFolder && !replace && FileManager.default.fileExists(atPath: target.path)) {
            if FileManager.default.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let choice = try await choose(id, name: name, replace: values.isDirectory == file.isFolder && values.isSymbolicLink != true, folder: file.isFolder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key) }; done += file.size ?? 0; return }
                if choice == .copy { target = FileNames.available(in: folder, name: name) }
                if choice == .replace { replace = true }
            }
            let selectedName = target.lastPathComponent
            try edit(id, coalesce: true) { $0.names[key] = selectedName; if replace { $0.replacements[key] = "local" } }
            current = try job(id)
        }
        // Never follow an externally substituted symlink, including on recovery.
        if FileManager.default.fileExists(atPath: target.path), try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CloudError.message("El destino es un enlace simbólico. Elige otra carpeta.") }
        if file.isFolder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let children = try await api.list(parent: file.id)
            for child in children { try await downloadTree(id, api: api, file: child, folder: target, key: key + "/" + child.id, done: &done) }
        } else {
            let temporary = folder.appendingPathComponent(".icloudy-" + UUID().uuidString + ".part")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if file.isGoogleDocument && !exporting {
                guard let url = file.webURL else { throw CloudError.message("No hay enlace web para este documento.") }
                let link = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                try await blockingIO { try link.write(to: temporary) }
            } else {
                let base = done
                try await api.download(file: file, to: temporary, exportMime: exporting ? current.exportMime : nil) { bytes, total in self.report(id, base: base, bytes: bytes, total: total) }
            }
            try Task.checkCancellation()
            let destination = target, replacing = replace
            try await blockingIO {
                if replacing && FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
            done += file.size ?? 0
        }
        try edit(id, coalesce: true) { $0.completedPaths.insert(key) }
    }
}
