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
    @Published var conflict: ConflictRequest?
    @Published var persistenceError: String?
    var client: ((String) throws -> CloudAPI)?
    var didComplete: ((String) -> Void)?
    var retryDelay: Double = 1
    var isWorking: Bool { task != nil }
    let storeURL: URL
    private var writable = true
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    private var conflictContinuation: CheckedContinuation<ConflictChoice, Error>?
    private var started = Date()
    private var startBytes: Int64 = 0

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
        } catch { persistenceError = "No se pudo apartar la cola dañada: \(error.localizedDescription)" }
    }
    var hasActive: Bool { items.contains { [.queued, .running].contains($0.state) } }
    func hasActive(accountID: String) -> Bool {
        items.contains { $0.accountID == accountID && ([.queued, .running].contains($0.state) || $0.id == activeID) }
    }
    private func persist() throws {
        guard writable else { throw CloudError.message(persistenceError ?? "La cola no se puede guardar.") }
        do { try LocalStore.save(items, to: storeURL) }
        catch { persistenceError = "No se pudo guardar la cola: \(error.localizedDescription)"; throw error }
    }
    func add(_ jobs: [Transfer]) throws {
        items += jobs
        do { try persist() } catch { items.removeAll { item in jobs.contains { $0.id == item.id } }; throw error }
        kick()
    }
    static func bookmark(_ url: URL) throws -> Data { try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
    func retry(_ id: UUID) {
        guard let index = index(id), [.failed, .paused, .cancelled].contains(items[index].state) else { return }
        items[index].state = .queued; items[index].detail = ""; items[index].attempts = 0
        do { try persist(); kick() } catch { items[index].state = .failed }
    }
    func cancel(_ id: UUID, pause: Bool = false) {
        guard let index = index(id), !items[index].finished else { return }
        items[index].state = pause ? .paused : .cancelled; items[index].bytesPerSecond = 0
        if activeID == id {
            task?.cancel()
            conflictContinuation?.resume(throwing: CancellationError()); conflictContinuation = nil; conflict = nil
        }
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    func pauseAll() {
        for id in items.filter({ [.running, .queued].contains($0.state) }).map(\.id) { cancel(id, pause: true) }
    }
    func clearCompleted() {
        items.removeAll { $0.state == .completed }
        do { try persist() } catch { persistenceError = error.localizedDescription }
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
    private func edit(_ id: UUID, _ change: (inout Transfer) -> Void) throws {
        guard let index = index(id) else { throw CancellationError() }
        change(&items[index]); try persist()
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
            activeID = nil; task = nil; kick()
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
        if current.direction == .upload {
            let total = try Self.localSize(url)
            try edit(id) { $0.total = total; $0.bytes = 0 }
            var done: Int64 = 0
            try await uploadTree(id, api: api, local: url, parent: current.parent, key: ".", done: &done)
        } else if let file = current.file {
            try edit(id) { $0.bytes = 0 }
            var done: Int64 = 0
            try await downloadTree(id, api: api, file: file, folder: url, key: ".", done: &done)
        }
    }
    private static func localSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message("No se admiten enlaces simbólicos: \(url.lastPathComponent)") }
        if values.isDirectory == true { return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).reduce(0) { try $0 + localSize($1) } }
        return Int64(values.fileSize ?? 0)
    }
    private func uploadTree(_ id: UUID, api: CloudAPI, local: URL, parent: String, key: String, done: inout Int64) async throws {
        try Task.checkCancellation()
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message("No se admiten enlaces simbólicos.") }
        let folder = values.isDirectory == true
        if try job(id).completedPaths.contains(key) { done += try Self.localSize(local); return }
        var current = try job(id)
        if current.uncertainFolders.contains(key) {
            // An earlier POST may have committed even though its reply was lost. Recheck conflicts before creating again.
            try edit(id) { $0.names[key] = nil; $0.replacements[key] = nil; $0.uncertainFolders.remove(key) }
            current = try job(id)
        }
        if current.names[key] == nil {
            let siblings = try await api.list(parent: parent)
            let matches = siblings.filter { $0.name.localizedCaseInsensitiveCompare(local.lastPathComponent) == .orderedSame }
            var name = local.lastPathComponent
            var replacing: String?
            if let existing = matches.first {
                let choice = try await choose(id, name: name, replace: matches.count == 1 && existing.isFolder == folder && !existing.isGoogleDocument, folder: folder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key) }; done += try Self.localSize(local); return }
                if choice == .copy { name = Self.unique(name, existing: siblings.map(\.name)) }
                if choice == .replace { replacing = existing.id }
            }
            try edit(id) { $0.names[key] = name; $0.replacements[key] = replacing }
            current = try job(id)
        }
        let name = current.names[key]!
        if folder {
            let remote: String
            if let known = current.folders[key] ?? current.replacements[key] { remote = known }
            else {
                try edit(id) { $0.uncertainFolders.insert(key) }
                do { remote = try await api.createFolder(name: name, parent: parent) }
                catch { throw CloudError.message("No se confirmó la creación de \(name). Revisa el destino antes de reintentar. \(error.localizedDescription)") }
                try edit(id) { $0.folders[key] = remote; $0.uncertainFolders.remove(key) }
            }
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try await uploadTree(id, api: api, local: child, parent: remote, key: key + "/" + child.lastPathComponent, done: &done)
            }
        } else {
            let base = done
            try await api.resumableUpload(local: local, parent: parent, name: name, replacing: current.replacements[key], checkpoint: current.uploads[key], save: { checkpoint in try self.edit(id) { $0.uploads[key] = checkpoint } }, progress: { bytes, total in self.report(id, base: base, bytes: bytes, total: total) })
            done += Int64(values.fileSize ?? 0)
        }
        try edit(id) { $0.completedPaths.insert(key) }
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
            try edit(id) { $0.names[key] = selectedName; if replace { $0.replacements[key] = "local" } }
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
                try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0).write(to: temporary)
            } else {
                let base = done
                try await api.download(file: file, to: temporary, exportMime: exporting ? current.exportMime : nil) { bytes, total in self.report(id, base: base, bytes: bytes, total: total) }
            }
            try Task.checkCancellation()
            if replace && FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: target) }
            done += file.size ?? 0
        }
        try edit(id) { $0.completedPaths.insert(key) }
    }
}
