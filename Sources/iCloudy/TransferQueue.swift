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
    /// Receives the completed job itself, for the persistent history.
    var didFinish: ((Transfer) -> Void)?
    /// Fires for every single file that ends up on this Mac, or whose local original was just uploaded.
    var didStoreLocalCopy: ((LocalCopy) -> Void)?
    var retryDelay: Double = 1
    /// Minimum interval between two progress updates; URLSession can report dozens of times per second.
    var reportInterval: TimeInterval = 0.1
    /// Delay before coalesced checkpoint writes reach disk. State transitions and new upload sessions write at once.
    var flushDelay: Duration = .seconds(2)
    var isWorking: Bool { task != nil }
    /// While offline nothing starts; jobs interrupted by the network resume by themselves when it returns.
    private(set) var isOnline = true
    private var pausedByNetwork: Set<UUID> = []
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
        } catch { writable = false; persistenceError = L("No se pudo recuperar la cola. Se conserva el archivo original: \(error.localizedDescription)") }
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
        } catch { persistenceError = L("No se pudo apartar la cola dañada: \(error.localizedDescription)") }
    }
    var hasActive: Bool { items.contains { [.queued, .running].contains($0.state) } }
    func hasActive(accountID: String) -> Bool {
        items.contains { ($0.accountID == accountID || $0.targetAccountID == accountID) && ([.queued, .running].contains($0.state) || $0.id == activeID) }
    }
    /// Where cross-cloud transfers stage their bytes. One folder per job, removed when the job completes or is cancelled.
    var scratchRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Transfers", isDirectory: true)
    func scratchDirectory(for id: UUID) -> URL { scratchRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// Drops staging folders that no unfinished transfer can still use, e.g. after a crash.
    func cleanScratch() {
        let live = Set(items.filter { $0.direction == .transfer && !$0.finished }.map { $0.id.uuidString })
        for child in (try? FileManager.default.contentsOfDirectory(at: scratchRoot, includingPropertiesForKeys: nil)) ?? [] where !live.contains(child.lastPathComponent) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// Coalesced writes batch the per-block checkpoints into one file write every `flushDelay`. The server is the
    /// authority on resume anyway, so losing the last seconds of offsets only costs a probe request.
    private func persist(coalesce: Bool = false) throws {
        guard writable else { throw CloudError.message(persistenceError ?? "La cola no se puede guardar.") }
        if coalesce { dirty = true; scheduleFlush(); return }
        flushTask?.cancel(); flushTask = nil; dirty = false
        do { try LocalStore.save(items, to: storeURL) }
        catch { persistenceError = L("No se pudo guardar la cola: \(error.localizedDescription)"); throw error }
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

    func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online {
            let resume = pausedByNetwork; pausedByNetwork = []
            for id in resume where index(id).map({ items[$0].state == .paused }) == true { retry(id) }
            kick()
        } else {
            for id in items.filter({ [.running, .queued].contains($0.state) }).map(\.id) {
                pausedByNetwork.insert(id)
                cancel(id, pause: true)
                if let index = index(id) { items[index].detail = L("Sin conexión · se reanudará automáticamente al volver la red") }
            }
        }
        stateChanges.send()
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
        items[index].state = pause ? .paused : .cancelled; items[index].bytesPerSecond = 0; items[index].detail = ""
        // Session URLs are pre-authenticated capabilities; a cancelled job will not resume them, so drop them from disk.
        if !pause { items[index].uploads = [:] }
        if !pause, items[index].direction == .transfer { try? FileManager.default.removeItem(at: items[index].localURL) }
        if activeID == id {
            task?.cancel()
            conflictContinuation?.resume(throwing: CancellationError()); conflictContinuation = nil; conflict = nil
        }
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    /// True for jobs that can be re-prioritised: waiting or paused. The running job and finished ones keep their place.
    func isMovable(_ transfer: Transfer) -> Bool { [.queued, .paused].contains(transfer.state) && transfer.id != activeID }
    /// Same semantics as SwiftUI's `onMove`: `destination` is an index in the list before removal.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty, source.allSatisfy({ items.indices.contains($0) && isMovable(items[$0]) }), (0...items.count).contains(destination) else { return }
        let moving = source.map { items[$0] }
        var remaining = items
        for index in source.reversed() { remaining.remove(at: index) }
        remaining.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        items = remaining
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    /// The same drag, but with offsets that count only the unfinished jobs, which is all the in-progress tab shows.
    /// Without the translation, dropping the third waiting job would reorder the third job of the whole queue — a
    /// different one as soon as anything above it has finished.
    func moveActive(fromOffsets source: IndexSet, toOffset destination: Int) {
        let active = items.indices.filter { !items[$0].finished }
        guard source.allSatisfy({ active.indices.contains($0) }), (0...active.count).contains(destination) else { return }
        let last = active.last.map { $0 + 1 } ?? items.count
        move(fromOffsets: IndexSet(source.map { active[$0] }),
             toOffset: destination < active.count ? active[destination] : last)
    }
    /// Puts a waiting job in front of every other waiting job, right after whatever is running or already finished.
    func prioritize(_ id: UUID) {
        guard let from = index(id), isMovable(items[from]) else { return }
        let to = items.firstIndex { isMovable($0) } ?? from
        guard to < from else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: to)
    }
    /// Other jobs of the same batch that would still run; drives the "cancel the rest" affordance.
    func pendingBatchMates(of id: UUID) -> Int {
        guard let job = items.first(where: { $0.id == id }) else { return 0 }
        return items.filter { $0.batchID == job.batchID && $0.id != id && [.queued, .running].contains($0.state) }.count
    }
    func cancelBatch(_ batchID: UUID) {
        for id in items.filter({ $0.batchID == batchID && [.running, .queued].contains($0.state) }).map(\.id) { cancel(id) }
    }
    /// Re-queues everything the user (or the network) left paused, plus what failed. Returns how many were revived.
    @discardableResult func resumeAll() -> Int {
        let ids = items.filter { [.paused, .failed].contains($0.state) }.map(\.id)
        for id in ids { retry(id) }
        return ids.count
    }
    func pauseAll() {
        for id in items.filter({ [.running, .queued].contains($0.state) }).map(\.id) { cancel(id, pause: true) }
    }
    func clearCompleted() { clear { $0.state == .completed } }
    /// Failed transfers are never retried on their own, so without a way to clear them they pile up in the panel and
    /// bury whatever is actually running.
    func clearFailed() { clear { $0.state == .failed } }
    /// What the user stopped by hand. It sits beside the failures in the panel, and it is cleared the same way.
    func clearCancelled() { clear { $0.state == .cancelled } }
    /// Both halves of the error tab at once.
    func clearErrored() { clear { [.failed, .cancelled].contains($0.state) } }
    /// Everything that is over, however it ended. The history keeps its own record either way.
    func clearFinished() { clear(\.finished) }
    /// Empties the in-progress tab: everything waiting, running or paused is cancelled and then dropped outright.
    /// Leaving the cancellations behind would move them to the error tab, so "limpiar" would have to be pressed
    /// twice to make one list go away. Returns how many were stopped.
    @discardableResult func cancelActive() -> Int {
        let ids = Set(items.filter { !$0.finished }.map(\.id))
        for id in ids { cancel(id) }
        clear { ids.contains($0.id) && $0.state == .cancelled }
        return ids.count
    }
    private func clear(_ matches: (Transfer) -> Bool) {
        items.removeAll(where: matches)
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
        guard isOnline, task == nil, let next = items.first(where: { $0.state == .queued }) else { return }
        activeID = next.id
        task = Task {
            let id = next.id
            // A pause or cancel can land between scheduling and this first line; never overwrite what the user chose.
            guard (try? job(id))?.state == .queued else { activeID = nil; task = nil; kick(); return }
            do {
                try edit(id) { $0.state = .running; $0.detail = L("Preparando…") }
                started = Date(); startBytes = next.bytes
                while true {
                    do { try await run(id); break }
                    catch {
                        try Task.checkCancellation()
                        let current = try job(id)
                        let transient = (error as? ServiceError)?.retryable == true || [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains((error as? URLError)?.code)
                        guard transient, current.attempts < 3 else { throw error }
                        try edit(id) { $0.attempts += 1; $0.detail = L("Conexión interrumpida. Reintento \($0.attempts)/3…") }
                        try await Task.sleep(for: .seconds(Self.retryWait(after: error, attempt: current.attempts, base: retryDelay)))
                    }
                }
                // If the user cancelled just after the server committed, preserve the completed checkpoint but keep their state.
                if try job(id).state == .running {
                    try edit(id) {
                        $0.state = .completed; $0.bytes = max($0.bytes, $0.total); $0.bytesPerSecond = 0; $0.uploads = [:]
                        $0.detail = Self.completionSummary(verified: $0.verifiedFiles, unverified: $0.unverifiedFiles)
                    }
                }
                if let finished = items.first(where: { $0.id == id && $0.state == .completed }) { didFinish?(finished) }
                didComplete?(next.accountID)
            } catch {
                if let index = index(id), items[index].state == .running {
                    if Task.isCancelled { items[index].state = .paused; items[index].detail = "" }
                    else { items[index].state = .failed; items[index].detail = error.localizedDescription + " Los elementos ya completados se conservan." }
                    items[index].bytesPerSecond = 0
                    do { try persist() } catch { persistenceError = error.localizedDescription }
                }
            }
            activeID = nil; task = nil
            stateChanges.send()
            kick()
        }
    }
    /// How long to wait before trying a failed transfer again. A provider that answered 429 said how long it wants
    /// to be left alone; waiting less is what turns one refusal into a string of them and burns the three attempts in
    /// a few seconds. Anything else doubles the wait each time.
    static func retryWait(after error: Error, attempt: Int, base: Double) -> Double {
        if let announced = (error as? ServiceError)?.retryAfter { return min(max(1, announced), 60) }
        return base * pow(2, Double(attempt))
    }
    static func completionSummary(verified: Int, unverified: Int) -> String {
        guard verified + unverified > 0 else { return "" }
        var parts = ["Completada"]
        if verified > 0 { parts.append(L("\(verified) \(verified == 1 ? L("archivo verificado") : L("archivos verificados")) con la suma del proveedor")) }
        if unverified > 0 { parts.append(L("\(unverified) sin verificar (reanudados o sin suma del proveedor)")) }
        return parts.joined(separator: " · ")
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
        items[index].detail = L("Transfiriendo…")
    }
    /// Advances the byte count when an already completed item is skipped, so a retry does not show progress falling to zero.
    private func mark(_ id: UUID, done: Int64) {
        guard let index = index(id), items[index].state == .running, items[index].bytes < done else { return }
        items[index].bytes = done
    }
    private func run(_ id: UUID) async throws {
        let current = try job(id)
        guard let client else { throw CloudError.message(L("Conecta la cuenta de esta transferencia.")) }
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
        } else if current.direction == .transfer, let file = current.file {
            guard let targetID = current.targetAccountID else { throw CloudError.message(L("Falta la cuenta de destino de esta transferencia.")) }
            let target = try client(targetID)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try edit(id) { $0.bytes = 0; $0.total = file.isFolder ? 0 : (file.size ?? 0) }
            var done: Int64 = 0
            var siblings: [String: [CloudFile]] = [:]
            try await transferTree(id, source: api, target: target, file: file, parent: current.parent, scratch: source, key: ".", done: &done, siblings: &siblings)
            try? FileManager.default.removeItem(at: source)
        } else if let file = current.file {
            // Folder totals grow as each remote folder is listed; a single file's size is known up front.
            try edit(id) { $0.bytes = 0; $0.total = file.isFolder ? 0 : (file.size ?? 0) }
            var done: Int64 = 0
            try await downloadTree(id, api: api, file: file, folder: source, key: ".", done: &done)
        }
    }
    /// Copies a remote tree from one account into a folder of another. Each file is staged in `scratch`, uploaded with
    /// the usual checkpoints, then deleted. Google documents leave Drive as Office files or PDF.
    private func transferTree(_ id: UUID, source: CloudAPI, target: CloudAPI, file: CloudFile, parent: String, scratch: URL, key: String, done: inout Int64, siblings: inout [String: [CloudFile]]) async throws {
        try Task.checkCancellation()
        if try job(id).completedPaths.contains(key) { done += file.size ?? 0; mark(id, done: done); return }
        var current = try job(id)
        let export = file.isGoogleDocument ? file.crossCloudExport : nil
        if file.isGoogleDocument && export == nil {
            // Forms, sites and shortcuts have nothing exportable; note it and move on instead of failing the whole tree.
            try edit(id, coalesce: true) { $0.completedPaths.insert(key); $0.unverifiedFiles += 1 }
            return
        }
        let localName = export.map { file.name + "." + $0.ext } ?? file.name
        if let problem = FileNames.problem(with: localName, for: target.account.cloud) { throw CloudError.message(L("No se puede enviar «\(localName)»: \(problem)")) }
        if current.uncertainFolders.contains(key) {
            try edit(id) { $0.names[key] = nil; $0.replacements[key] = nil; $0.uncertainFolders.remove(key) }
            siblings[parent] = nil
            current = try job(id)
        }
        if current.names[key] == nil {
            if siblings[parent] == nil { siblings[parent] = try await target.list(parent: parent) }
            let existing = siblings[parent] ?? []
            let matches = existing.filter { $0.name.localizedCaseInsensitiveCompare(localName) == .orderedSame }
            var name = localName
            var replacing: String?
            if let match = matches.first {
                let choice = try await choose(id, name: name, replace: matches.count == 1 && match.isFolder == file.isFolder && !match.isGoogleDocument, folder: file.isFolder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key) }; done += file.size ?? 0; mark(id, done: done); return }
                if choice == .copy { name = Self.unique(name, existing: existing.map(\.name)) }
                if choice == .replace { replacing = match.id }
            }
            try edit(id, coalesce: true) { $0.names[key] = name; $0.replacements[key] = replacing }
            current = try job(id)
        }
        let name = current.names[key]!
        if file.isFolder {
            let remote: String
            if let known = current.folders[key] ?? current.replacements[key] { remote = known }
            else {
                try edit(id) { $0.uncertainFolders.insert(key) }
                do { remote = try await target.createFolder(name: name, parent: parent) }
                catch { throw CloudError.message(L("No se confirmó la creación de \(name) en el destino. Revisa antes de reintentar. \(error.localizedDescription)")) }
                try edit(id) { $0.folders[key] = remote; $0.uncertainFolders.remove(key) }
                siblings[parent, default: []].append(CloudFile(id: remote, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true))
                siblings[remote] = []
            }
            let children = try await source.list(parent: file.id)
            let known = children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            if known > 0 { try edit(id, coalesce: true) { $0.total += known } }
            for child in children {
                try await transferTree(id, source: source, target: target, file: child, parent: remote, scratch: scratch, key: key + "/" + child.id, done: &done, siblings: &siblings)
            }
        } else {
            let staged = scratch.appendingPathComponent(Self.stagedName(key, name))
            var checkpoint = current.uploads[key]
            if !FileManager.default.fileExists(atPath: staged.path) {
                // No staged copy (first run, or scratch cleaned): the upload session, if any, is worthless now.
                checkpoint = nil
                try edit(id, coalesce: true) { $0.uploads[key] = nil; $0.detail = L("Descargando «\(file.name)» de \(source.account.cloud.title)…") }
                // Some providers write the destination as the bytes arrive, so a download cut short by the network
                // leaves a truncated file behind. Downloading beside the staged name and renaming only at the end
                // means a file at `staged` is always a complete one; a retry never uploads half a file as whole.
                let partial = staged.appendingPathExtension("part")
                try? FileManager.default.removeItem(at: partial)
                try await source.download(file: file, to: partial, exportMime: export?.mime)
                try Task.checkCancellation()
                if let expected = file.size, export == nil {
                    let actual = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: partial)
                        throw CloudError.message(L("«\(file.name)» llegó incompleto de \(source.account.cloud.title): \(actual) de \(expected) bytes."))
                    }
                }
                try FileManager.default.moveItem(at: partial, to: staged)
            }
            let base = done
            try edit(id, coalesce: true) { $0.detail = L("Subiendo «\(name)» a \(target.account.cloud.title)…") }
            let receipt = try await target.resumableUpload(local: staged, parent: parent, name: name, replacing: current.replacements[key], checkpoint: checkpoint, save: { checkpoint in
                try self.edit(id, coalesce: checkpoint.offset > 0 && !checkpoint.complete) { $0.uploads[key] = checkpoint }
            }, progress: { bytes, total in self.report(id, base: base, bytes: bytes, total: total) })
            try edit(id, coalesce: true) { if receipt.verification == .verified { $0.verifiedFiles += 1 } else { $0.unverifiedFiles += 1 } }
            try? FileManager.default.removeItem(at: staged)
            done += file.size ?? 0
            mark(id, done: done)
            if current.replacements[key] == nil {
                siblings[parent, default: []].append(CloudFile(id: "", name: name, mime: "application/octet-stream", size: file.size, modified: nil, webURL: nil, isFolder: false))
            }
        }
        try edit(id, coalesce: true) { $0.completedPaths.insert(key) }
    }
    /// Flat, collision-free staging name: keys are paths, and the digest keeps them out of nested directories.
    nonisolated private static func stagedName(_ key: String, _ name: String) -> String {
        String(key.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16) + "-" + FileNames.safe(name)
    }
    /// Walks the tree synchronously; callers run it through `blockingIO` because large folders take a while.
    nonisolated private static func localSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message(L("No se admiten enlaces simbólicos: \(url.lastPathComponent)")) }
        if values.isDirectory == true { return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).reduce(0) { try $0 + localSize($1) } }
        return Int64(values.fileSize ?? 0)
    }
    /// `siblings` caches one remote listing per destination folder for the whole run. Before, every uploaded item listed
    /// its parent again, which made a folder of N files cost N listings of N items.
    private func uploadTree(_ id: UUID, api: CloudAPI, local: URL, parent: String, key: String, done: inout Int64, siblings: inout [String: [CloudFile]]) async throws {
        try Task.checkCancellation()
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message(L("No se admiten enlaces simbólicos.")) }
        let folder = values.isDirectory == true
        if try job(id).completedPaths.contains(key) { done += try await blockingIO { try Self.localSize(local) }; mark(id, done: done); return }
        if let problem = FileNames.problem(with: local.lastPathComponent, for: api.account.cloud) {
            throw CloudError.message(L("No se puede subir «\(local.lastPathComponent)»: \(problem)"))
        }
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
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key) }; done += try await blockingIO { try Self.localSize(local) }; mark(id, done: done); return }
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
                catch { throw CloudError.message(L("No se confirmó la creación de \(name). Revisa el destino antes de reintentar. \(error.localizedDescription)")) }
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
            let receipt = try await api.resumableUpload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: current.uploads[key], save: { checkpoint in
                // A new session URL and the completion are durable at once; intermediate offsets are coalesced.
                try self.edit(id, coalesce: checkpoint.offset > 0 && !checkpoint.complete) { $0.uploads[key] = checkpoint }
            }, progress: { bytes, total in self.report(id, base: base, bytes: bytes, total: total) })
            try edit(id, coalesce: true) { if receipt.verification == .verified { $0.verifiedFiles += 1 } else { $0.unverifiedFiles += 1 } }
            done += Int64(values.fileSize ?? 0)
            mark(id, done: done)
            if let remoteID = receipt.remoteID {
                // The file that was just uploaded is, by definition, also on this Mac.
                didStoreLocalCopy?(LocalCopy(accountID: try job(id).accountID, fileID: remoteID, name: name, path: local.path,
                                             bookmark: try job(id).bookmark, size: Int64(values.fileSize ?? 0),
                                             remoteModified: Date(), savedAt: Date(), origin: .upload))
            }
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
        if try job(id).completedPaths.contains(key) { done += file.size ?? 0; mark(id, done: done); return }
        var current = try job(id)
        let exporting = key == "." && current.exportMime != nil
        let name = FileNames.safe(file.name + (exporting ? "." + (current.exportExtension ?? "pdf") : (file.isGoogleDocument ? ".webloc" : "")))
        var target = folder.appendingPathComponent(current.names[key] ?? name)
        var replace = current.replacements[key] != nil
        if current.names[key] == nil || (!file.isFolder && !replace && FileManager.default.fileExists(atPath: target.path)) {
            if FileManager.default.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let choice = try await choose(id, name: name, replace: values.isDirectory == file.isFolder && values.isSymbolicLink != true, folder: file.isFolder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key) }; done += file.size ?? 0; mark(id, done: done); return }
                if choice == .copy { target = FileNames.available(in: folder, name: name) }
                if choice == .replace { replace = true }
            }
            let selectedName = target.lastPathComponent
            try edit(id, coalesce: true) { $0.names[key] = selectedName; if replace { $0.replacements[key] = "local" } }
            current = try job(id)
        }
        // Never follow an externally substituted symlink, including on recovery.
        if FileManager.default.fileExists(atPath: target.path), try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CloudError.message(L("El destino es un enlace simbólico. Elige otra carpeta.")) }
        if file.isFolder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let children = try await api.list(parent: file.id)
            let known = children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            if known > 0 { try edit(id, coalesce: true) { $0.total += known } }
            for child in children { try await downloadTree(id, api: api, file: child, folder: target, key: key + "/" + child.id, done: &done) }
        } else {
            let temporary = folder.appendingPathComponent(".icloudy-" + UUID().uuidString + ".part")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if file.isGoogleDocument && !exporting {
                guard let url = file.webURL else { throw CloudError.message(L("No hay enlace web para este documento.")) }
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
            mark(id, done: done)
            // Only real content counts as a local copy: a .webloc is a link and an export is a different document.
            if !file.isGoogleDocument, !exporting {
                didStoreLocalCopy?(LocalCopy(accountID: current.accountID, fileID: file.id, name: file.name, path: target.path,
                                             bookmark: current.bookmark, size: file.size ?? 0,
                                             remoteModified: file.modified, savedAt: Date(), origin: .download))
            }
        }
        try edit(id, coalesce: true) { $0.completedPaths.insert(key) }
    }
}
