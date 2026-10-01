import Foundation
import Combine

/// Thrown to take a job out of its retry loop without failing it: the network went away, so it waits for it to come
/// back alongside the ones the monitor caught in time.
private struct NetworkGone: Error {}

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
    /// Rules a folder upload must leave out, by job; mirrors answer for their own uploads and everything else gets nil.
    /// Asked as the tree is walked, so a file that appears after the sync was planned is judged as well.
    var uploadExclusions: ((UUID) -> SyncExclusionMatcher?)?
    var retryDelay: Double = 1
    /// Minimum interval between two progress updates; URLSession can report dozens of times per second.
    var reportInterval: TimeInterval = 0.1
    /// Delay before coalesced checkpoint writes reach disk. State transitions and new upload sessions write at once.
    var flushDelay: Duration = .seconds(2)
    var isWorking: Bool { !tasks.isEmpty }
    /// While offline nothing starts; jobs interrupted by the network resume by themselves when it returns.
    private(set) var isOnline = true
    /// How many jobs run at once, the bandwidth limits and the schedule. Setting it re-evaluates the queue at once.
    var policy = TransferPolicy() {
        didSet {
            uploadLimiter.bytesPerSecond = policy.uploadLimit
            downloadLimiter.bytesPerSecond = policy.downloadLimit
            reevaluate()
        }
    }
    /// The provider of each account, for the providers that can only do one thing at a time.
    var cloud: ((String) -> Cloud?)?
    /// The clock the schedule is read against; a seam for tests.
    var now: () -> Date = Date.init
    /// Why nothing is starting right now, shown above the list and as each paused job's status.
    @Published private(set) var hold: TransferHold?
    /// The jobs whose task is alive, running or still unwinding from a pause.
    var runningIDs: Set<UUID> { Set(tasks.keys) }
    /// The bandwidth limits, one bucket per direction shared by every job of this queue.
    let uploadLimiter = BandwidthLimiter(), downloadLimiter = BandwidthLimiter()
    private var costlyNetwork = false
    private var windowTimer: Task<Void, Never>?
    let storeURL: URL
    private var writable = true
    private var dirty = false
    private var flushTask: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Several jobs can meet a name conflict at the same time; they wait in line and the sheet shows one at a time.
    private var conflictContinuations: [UUID: CheckedContinuation<ConflictChoice, Error>] = [:]
    private var pendingConflicts: [ConflictRequest] = []
    /// Per job: when it started this run, from how many bytes, and when it last reported.
    private var meters: [UUID: (started: Date, startBytes: Int64, lastReport: Date)] = [:]
    private var claims = NameClaims()
    /// The item each running job is working on, so a failure lands on the right line of its report.
    private var inFlight: [UUID: ReportCursor] = [:]

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("transfers.json")) {
        self.storeURL = storeURL
        do {
            items = try LocalStore.read([Transfer].self, from: storeURL) ?? []
            for index in items.indices where [.running, .queued].contains(items[index].state) { items[index].state = .paused; items[index].bytesPerSecond = 0; items[index].hold = nil }
            // The queue comes back paused for the person to decide, as it always has, except for jobs waiting for the
            // schedule or for a cheaper network: those were already decided, and the policy releases them.
            for index in items.indices where items[index].hold == .offline { items[index].hold = nil; items[index].detail = "" }
        } catch { writable = false; persistenceError = L("No se pudo recuperar la cola. Se conserva el archivo original: \(error.localizedDescription)") }
    }
    /// True when the saved queue could not be read: nothing can be added until the user sets that file aside.
    var canDiscardSavedQueue: Bool { !writable }
    /// Moves the unreadable store next to itself with a `.corrupt-<timestamp>` suffix and starts an empty, writable queue.
    /// The original bytes are preserved so nothing is lost if a future version can read them.
    func discardSavedQueue() {
        guard !writable else { return }
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) { try LocalStore.setAside(storeURL) }
            items = []; writable = true; persistenceError = nil
            stateChanges.send()
        } catch { persistenceError = L("No se pudo apartar la cola dañada: \(error.localizedDescription)") }
    }
    var hasActive: Bool { items.contains { [.queued, .running].contains($0.state) } }
    func hasActive(accountID: String) -> Bool {
        items.contains { ($0.accountID == accountID || $0.targetAccountID == accountID) && ([.queued, .running].contains($0.state) || tasks[$0.id] != nil) }
    }
    func remap(_ change: RemoteIdentityChange, accountID: String) throws {
        for i in items.indices where !items[i].finished {
            if items[i].accountID == accountID, let file = items[i].file {
                items[i].file = change.file(file)
                if items[i].direction != .upload {
                    items[i].completedPaths = Set(items[i].completedPaths.map(change.treeKey))
                    items[i].uncertainFolders = Set(items[i].uncertainFolders.map(change.treeKey))
                    items[i].names = Dictionary(items[i].names.map { (change.treeKey($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
                    items[i].folders = Dictionary(items[i].folders.map { (change.treeKey($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
                    items[i].replacements = Dictionary(items[i].replacements.map { (change.treeKey($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
                    items[i].uploads = Dictionary(items[i].uploads.map { (change.treeKey($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
                }
            }
            if (items[i].targetAccountID ?? items[i].accountID) == accountID {
                items[i].parent = change.id(items[i].parent)
                items[i].folders = items[i].folders.mapValues(change.id)
                items[i].replacements = items[i].replacements.mapValues(change.id)
                items[i].mirrorEntries = items[i].mirrorEntries?.mapValues(change.file)
                items[i].uploads = items[i].uploads.mapValues { checkpoint in
                    var updated = checkpoint
                    updated.remoteID = checkpoint.remoteID.map(change.id)
                    updated.pendingRetirementID = checkpoint.pendingRetirementID.map(change.id)
                    return updated
                }
            }
        }
        try persist()
    }
    var protectedLocalURLs: [URL] { items.filter { !$0.finished || tasks[$0.id] != nil }.map(\.localURL) }
    /// Where cross-cloud transfers stage their bytes. One folder per job, removed when the job completes or is cancelled.
    var scratchRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Transfers", isDirectory: true)
    func scratchDirectory(for id: UUID) -> URL { scratchRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// Drops staging folders that no unfinished transfer can still use, e.g. after a crash.
    func cleanScratch() {
        let live = Set(items.filter { $0.direction == .transfer && (!$0.finished || tasks[$0.id] != nil) }.map { $0.id.uuidString })
        for child in (try? FileManager.default.contentsOfDirectory(at: scratchRoot, includingPropertiesForKeys: nil)) ?? [] where !live.contains(child.lastPathComponent) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// Coalesced writes batch the per-block checkpoints into one file write every `flushDelay`. The server is the
    /// authority on resume anyway, so losing the last seconds of offsets only costs a probe request.
    private func persist(coalesce: Bool = false) throws {
        guard writable else { throw CloudError.message(persistenceError ?? L("La cola no se puede guardar.")) }
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
        reevaluate()
    }
    /// The network went to (or left) a hotspot, a cellular link or Low Data Mode. Only matters when the policy says so.
    func setCostlyNetwork(_ costly: Bool) {
        guard costly != costlyNetwork else { return }
        costlyNetwork = costly
        reevaluate()
    }
    /// The reason nothing may run right now, if any. No network comes first: it is the one nobody can wait out.
    var currentHold: TransferHold? {
        if !isOnline { return .offline }
        if policy.pauseOnCostlyNetwork, costlyNetwork { return .costlyNetwork }
        if let window = policy.window, !window.contains(now()) { return .schedule }
        return nil
    }
    /// Applies the current hold: everything running or waiting is paused with its reason, or, once the reason is
    /// gone, every job the queue paused by itself is queued again. Idempotent, so any change can simply call it.
    func reevaluate() {
        let current = currentHold
        hold = current
        if let current {
            let detail = current.detail(window: policy.window)
            for id in items.filter({ [.running, .queued].contains($0.state) }).map(\.id) {
                cancel(id, pause: true)
                if let index = index(id) { items[index].hold = current; items[index].detail = detail }
            }
            // Jobs held for another reason now wait for this one, and say so.
            for index in items.indices where items[index].state == .paused && items[index].hold != nil {
                items[index].hold = current; items[index].detail = detail
            }
            do { try persist() } catch { persistenceError = error.localizedDescription }
        } else {
            for id in items.filter({ $0.state == .paused && $0.hold != nil }).map(\.id) { retry(id) }
            kick()
        }
        scheduleWindowCheck()
        stateChanges.send()
    }
    /// Wakes the queue at the next edge of the schedule. Capped, so a clock or time zone change is noticed too.
    private func scheduleWindowCheck() {
        windowTimer?.cancel(); windowTimer = nil
        guard let window = policy.window, let next = window.nextChange(after: now()) else { return }
        let delay = min(max(1, next.timeIntervalSince(now())), 15 * 60)
        windowTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
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
        items[index].state = .queued; items[index].detail = ""; items[index].attempts = 0; items[index].hold = nil
        items[index].needsRestart = false
        do { try persist(); kick() } catch { items[index].state = .failed }
        stateChanges.send()
    }
    /// "Empezar de cero": forgets the uploads that were under way, sessions included, and runs the job again. What
    /// was completed stays completed; only the partly sent files go out whole, as they are now.
    func restartFromZero(_ id: UUID) {
        guard let index = index(id), [.failed, .paused].contains(items[index].state), tasks[id] == nil else { return }
        var partial = items[index]
        partial.uploads = partial.uploads.filter { !$0.value.complete }
        abandonSessions(partial)
        items[index].uploads = items[index].uploads.filter { $0.value.complete }
        retry(id)
    }
    /// Puts a completed job back in the queue, after a check of the destination found part of it missing. The walk
    /// skips whatever is still marked complete.
    func requeue(_ id: UUID) {
        guard let index = index(id), items[index].state == .completed else { return }
        items[index].state = .paused
        retry(id)
    }
    /// Updates one line of a job's report from outside a run. A file the destination no longer has goes back to
    /// pending, and so do the folders above it, so that the next run walks down to it again.
    func applyCheck(_ id: UUID, key: String, _ outcome: FileOutcome, reason: String?) {
        guard let index = index(id) else { return }
        items[index].record(key, outcome, reason: reason)
        if outcome == .pending {
            var current: String? = key
            while let path = current { items[index].completedPaths.remove(path); current = Transfer.parentKey(path) }
        }
        do { try persist(coalesce: true) } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    func cancel(_ id: UUID, pause: Bool = false) {
        guard let index = index(id), !items[index].finished else { return }
        items[index].state = pause ? .paused : .cancelled; items[index].bytesPerSecond = 0; items[index].detail = ""; items[index].hold = nil
        // Session URLs are pre-authenticated capabilities; a cancelled job will not resume them, so drop them from
        // disk, and tell the provider to forget them rather than leaving them to expire on their own.
        if !pause {
            abandonSessions(items[index])
            items[index].uploads = [:]
        }
        if !pause, items[index].direction == .transfer, tasks[id] == nil { try? FileManager.default.removeItem(at: items[index].localURL) }
        if let task = tasks[id] {
            task.cancel()
            dropConflict(of: id)
        }
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    /// Asks the provider to drop the upload sessions of a job that will never finish them. Best effort: they expire
    /// by themselves, but Box counts the open ones against the account and the others hold storage meanwhile.
    private func abandonSessions(_ transfer: Transfer) {
        let urls = transfer.uploads.values.compactMap(\.url)
        let boxSessions = transfer.uploads.values.compactMap(\.sessionID)
        guard !urls.isEmpty || !boxSessions.isEmpty, let lookup = client,
              let api = try? lookup(transfer.targetAccountID ?? transfer.accountID) else { return }
        Task { await api.abandonUploadSessions(urls: urls, boxSessions: boxSessions) }
    }
    /// True for jobs that can be re-prioritised: waiting or paused. Running jobs and finished ones keep their place.
    func isMovable(_ transfer: Transfer) -> Bool { [.queued, .paused].contains(transfer.state) && tasks[transfer.id] == nil }
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
    /// The opposite: behind every other waiting job, so whatever else is pending goes first.
    func deprioritize(_ id: UUID) {
        guard let from = index(id), isMovable(items[from]) else { return }
        let last = items.lastIndex { isMovable($0) } ?? from
        guard last > from else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: last + 1)
    }
    /// Other jobs of the same batch that would still run; drives the "cancel the rest" affordance.
    func pendingBatchMates(of id: UUID) -> Int {
        guard let job = items.first(where: { $0.id == id }) else { return 0 }
        return items.filter { $0.batchID == job.batchID && $0.id != id && [.queued, .running].contains($0.state) }.count
    }
    func cancelBatch(_ batchID: UUID) {
        for id in items.filter({ $0.batchID == batchID && [.running, .queued].contains($0.state) }).map(\.id) { cancel(id) }
    }
    /// Jobs another part of the app keeps paused on purpose: today, the upload of a mirror the person paused. The
    /// mirror resumes it when it is resumed itself; "Reanudar todas" restarting it behind the mirror's back left the
    /// sidebar saying "En pausa" while the folder uploaded.
    var isHeldPaused: ((Transfer) -> Bool)?
    private func resumable(_ transfer: Transfer) -> Bool {
        [.paused, .failed].contains(transfer.state) && isHeldPaused?(transfer) != true
    }
    /// How many jobs "Reanudar todas" would bring back.
    var resumableCount: Int { items.filter(resumable).count }
    /// Re-queues everything the user (or the network) left paused, plus what failed, except what a paused mirror
    /// holds. Returns how many were revived.
    @discardableResult func resumeAll() -> Int {
        let ids = items.filter(resumable).map(\.id)
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
        // Staging folders of cross-cloud transfers used to survive until the next launch, holding on to whole files
        // in the cache of a job the person had already swept away.
        for leaving in items where matches(leaving) && leaving.direction == .transfer {
            try? FileManager.default.removeItem(at: leaving.localURL)
        }
        items.removeAll(where: matches)
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    func resolve(_ choice: ConflictChoice, applyToBatch: Bool) {
        guard let request = conflict, let index = index(request.transferID) else { return }
        guard choice != .replace || request.canReplace else { return }
        var answered = [request]
        if applyToBatch {
            let batch = items[index].batchID
            for i in items.indices where items[i].batchID == batch { items[i].batchChoice = choice }
            // Mates of the batch already waiting in line take the same answer, as they would have had they asked
            // a moment later. One that cannot be replaced keeps waiting, exactly like `choose` would ask it again.
            answered += pendingConflicts.filter { pending in
                pending.id != request.id && (choice != .replace || pending.canReplace)
                    && items.first(where: { $0.id == pending.transferID })?.batchID == batch
            }
        }
        for request in answered {
            pendingConflicts.removeAll { $0.id == request.id }
            conflictContinuations.removeValue(forKey: request.transferID)?.resume(returning: choice)
        }
        conflict = pendingConflicts.first
    }
    /// Ends the wait of a job whose conflict will not be answered any more, and shows the next one in line.
    private func dropConflict(of id: UUID) {
        pendingConflicts.removeAll { $0.transferID == id }
        conflictContinuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if conflict?.transferID == id || (conflict == nil && !pendingConflicts.isEmpty) { conflict = pendingConflicts.first }
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
    /// Starts every waiting job the policy has room for. Called after anything that frees a slot or adds a job.
    private func kick() {
        // The schedule can close (or open) between two timer ticks; whoever notices first applies it.
        guard currentHold == hold else { reevaluate(); return }
        guard hold == nil else { return }
        let ids = TransferScheduler.startable(items, running: runningIDs, policy: policy, cloud: { [cloud] in cloud?($0) })
        for id in ids { start(id) }
    }
    private func start(_ id: UUID) {
        guard let next = items.first(where: { $0.id == id }) else { return }
        let throttle = TransferThrottle(upload: uploadLimiter, download: downloadLimiter)
        tasks[id] = Task {
            // A pause or cancel can land between scheduling and this first line; never overwrite what the user chose.
            guard (try? job(id))?.state == .queued else { finish(id); return }
            let diagnostics = Diagnostics.context(for: next) { try? self.client?($0).account }
            let started = Date()
            do {
                try edit(id) { $0.state = .running; $0.detail = L("Preparando…") }
                meters[id] = (started: Date(), startBytes: next.bytes, lastReport: .distantPast)
                while true {
                    // The buckets reach the providers through the task, and only for the bytes of this queue.
                    do {
                        try await Diagnostics.$context.withValue(diagnostics) {
                            try await TransferThrottle.$active.withValue(throttle) { try await run(id) }
                        }
                        break
                    }
                    catch {
                        try Task.checkCancellation()
                        let current = try job(id)
                        switch Self.outcome(for: error, attempts: current.attempts, online: isOnline) {
                        case .fail: throw error
                        case .waitForNetwork: throw NetworkGone()
                        case .retry:
                            try edit(id) { $0.attempts += 1; $0.detail = L("Conexión interrumpida. Reintento \($0.attempts)/3…") }
                            Diagnostics.transferRetrying(current, context: diagnostics, attempt: current.attempts + 1,
                                                         wait: Self.retryWait(after: error, attempt: current.attempts, base: retryDelay), error: error)
                            try await Task.sleep(for: .seconds(Self.retryWait(after: error, attempt: current.attempts, base: retryDelay)))
                        }
                    }
                }
                // If the user cancelled just after the server committed, preserve the completed checkpoint but keep their state.
                if try job(id).state == .running {
                    try edit(id) {
                        $0.state = .completed; $0.bytes = max($0.bytes, $0.total); $0.bytesPerSecond = 0; $0.uploads = [:]; $0.downloads = [:]
                        $0.settleReport()
                        $0.detail = Self.completionSummary(verified: $0.verifiedFiles, unverified: $0.unverifiedFiles,
                                                           exported: $0.exportedFiles, download: $0.direction == .download)
                    }
                }
                if let finished = items.first(where: { $0.id == id && $0.state == .completed }) { didFinish?(finished) }
                if let finished = items.first(where: { $0.id == id && $0.state == .completed }) { Diagnostics.transferFinished(finished, context: diagnostics, since: started) }
                didComplete?(next.accountID)
                if let target = next.targetAccountID, target != next.accountID { didComplete?(target) }
            } catch is NetworkGone {
                Diagnostics.transferWaitsForNetwork(next, context: diagnostics)
                if let index = index(id), !items[index].finished {
                    items[index].state = .paused; items[index].bytesPerSecond = 0
                    items[index].hold = .offline
                    items[index].detail = TransferHold.offline.detail(window: policy.window)
                    do { try persist() } catch { persistenceError = error.localizedDescription }
                }
            } catch {
                if let index = index(id), items[index].state == .running {
                    if Task.isCancelled { items[index].state = .paused; items[index].detail = "" }
                    else {
                        items[index].state = .failed; items[index].detail = error.localizedDescription + " " + L("Los elementos ya completados se conservan.")
                        items[index].needsRestart = error is UploadSourceChanged
                        if let cursor = inFlight[id] { items[index].recordFailure(at: cursor, error) }
                    }
                    if items[index].state == .failed { Diagnostics.transferFailed(items[index], context: diagnostics, error: error, since: started) }
                    items[index].bytesPerSecond = 0
                    do { try persist() } catch { persistenceError = error.localizedDescription }
                }
            }
            inFlight[id] = nil
            finish(id)
        }
    }
    /// The task of `id` is over, however it ended: its slot goes to the next job in line.
    private func finish(_ id: UUID) {
        tasks[id] = nil; meters[id] = nil
        dropConflict(of: id)
        if tasks.isEmpty { claims.removeAll() }
        cleanScratch()
        stateChanges.send()
        kick()
    }
    /// What becomes of a job that has just thrown.
    enum Outcome: Equatable { case retry, fail, waitForNetwork }
    /// With the network already gone this is not an error to spend attempts on: a job that fails here is not one
    /// that `setOnline(true)` brings back, so it sat in the error list until somebody pressed retry by hand. Only
    /// what the monitor already knows counts, because a job parked while the network looks fine would have nothing
    /// to wake it up again.
    static func outcome(for error: Error, attempts: Int, online: Bool) -> Outcome {
        guard online else { return .waitForNetwork }
        // A file that changed while it was downloading is fetched again with its new description.
        let transient = (error as? ServiceError)?.retryable == true || (error as? DownloadIntegrityError)?.retryable == true
            || [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains((error as? URLError)?.code)
        return transient && attempts < 3 ? .retry : .fail
    }
    /// How long to wait before trying a failed transfer again. A provider that answered 429 said how long it wants
    /// to be left alone; waiting less is what turns one refusal into a string of them and burns the three attempts in
    /// a few seconds. Anything else doubles the wait each time.
    static func retryWait(after error: Error, attempt: Int, base: Double) -> Double {
        if let announced = (error as? ServiceError)?.retryAfter { return min(max(1, announced), 60) }
        return base * pow(2, Double(attempt))
    }
    /// `download` words the unverified part for downloads, where nothing is resumed and only the size was compared.
    static func completionSummary(verified: Int, unverified: Int, exported: Int = 0, download: Bool = false) -> String {
        guard verified + unverified + exported > 0 else { return "" }
        var parts = [L("Completada")]
        if verified > 0 { parts.append(L("\(verified) \(verified == 1 ? L("archivo verificado") : L("archivos verificados")) con la suma del proveedor")) }
        if unverified > 0 {
            parts.append(download ? L("\(unverified) sin suma del proveedor (solo se comprobó el tamaño)")
                                  : L("\(unverified) sin verificar (reanudados o sin suma del proveedor)"))
        }
        if exported > 0 { parts.append(L("\(exported) exportados de Google, sin suma que comparar")) }
        return parts.joined(separator: " · ")
    }
    /// Keeps a failed check on the job. A file that changed remotely also leaves its new description behind when it
    /// is the job's own item, so the retry downloads, and checks, the version that exists now.
    private func recordFailedCheck(_ id: UUID, key: String, _ error: DownloadIntegrityError) throws {
        try edit(id) {
            $0.recordDownload(key, .failed)
            if key == ".", case .changedRemotely(_, let current?) = error {
                $0.file = current
                if !current.isFolder { $0.total = current.size ?? 0 }
            }
        }
    }
    private func choose(_ id: UUID, name: String, replace: Bool, folder: Bool) async throws -> ConflictChoice {
        try Task.checkCancellation()
        if let choice = try job(id).batchChoice, choice != .replace || replace { return choice }
        return try await withCheckedThrowingContinuation { continuation in
            conflictContinuations[id] = continuation
            pendingConflicts.append(ConflictRequest(transferID: id, name: name, canReplace: replace, folder: folder))
            if conflict == nil { conflict = pendingConflicts.first }
        }
    }
    private func report(_ id: UUID, base: Int64, bytes: Int64, total: Int64) {
        guard let index = index(id), items[index].state == .running, let meter = meters[id] else { return }
        let now = Date()
        // Throttle to `reportInterval`, but always deliver the final tick of an item. Each job keeps its own clock:
        // with one shared, the jobs running beside each other swallowed each other's ticks.
        guard now.timeIntervalSince(meter.lastReport) >= reportInterval || (total > 0 && bytes >= total) else { return }
        meters[id]?.lastReport = now
        items[index].bytes = base + bytes
        items[index].total = max(items[index].total, base + total)
        items[index].bytesPerSecond = Double(max(0, items[index].bytes - meter.startBytes)) / max(0.1, now.timeIntervalSince(meter.started))
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
        inFlight[id] = ReportCursor(key: key, leaf: file.name, folder: file.isFolder)
        var current = try job(id)
        let export = file.isGoogleDocument ? file.crossCloudExport : nil
        if file.isGoogleDocument && export == nil {
            // Forms, sites and shortcuts have nothing exportable; note it and move on instead of failing the whole tree.
            try edit(id, coalesce: true) {
                $0.completedPaths.insert(key); $0.unverifiedFiles += 1
                $0.record(key, .excluded, path: $0.reportPath(for: key, leaf: file.name), reason: L("Google no permite exportar formularios, sitios ni accesos directos."))
            }
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
            let room = NameClaims.remote(account: target.account.id, parent: parent)
            let existing = (siblings[parent] ?? []) + claimed(room, by: id, besides: siblings[parent] ?? [])
            let matches = existing.filter { $0.name.localizedCaseInsensitiveCompare(localName) == .orderedSame }
            var name = localName
            var replacing: String?
            if let match = matches.first {
                let choice = try await choose(id, name: name, replace: matches.count == 1 && match.isFolder == file.isFolder && !match.isGoogleDocument && !match.id.isEmpty, folder: file.isFolder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key); $0.recordSkip(key, leaf: name, folder: file.isFolder, bytes: file.size) }; done += file.size ?? 0; mark(id, done: done); return }
                // Claimed again after the wait: another job may have taken a name while this one was asking.
                if choice == .copy { name = Self.unique(name, existing: existing.map(\.name) + claims.others(in: room, excluding: id)) }
                if choice == .replace { replacing = match.id }
            }
            try edit(id, coalesce: true) { $0.names[key] = name; $0.replacements[key] = replacing }
            current = try job(id)
        }
        let name = current.names[key]!
        claims.claim(name, in: NameClaims.remote(account: target.account.id, parent: parent), by: id)
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
            if let checkpoint, checkpoint.complete {
                guard checkpoint.integrity == .verified || checkpoint.integrity == .unavailable else {
                    throw CloudError.message(L("La copia remota quedó sin verificar. Revisa el destino antes de reintentar."))
                }
                try edit(id) {
                    $0.completedPaths.insert(key)
                    $0.record(key, checkpoint.integrity == .verified ? .verified : .unverified, bytes: file.size)
                }
                try? FileManager.default.removeItem(at: staged)
                done += file.size ?? 0; mark(id, done: done)
                return
            }
            let canResumeWithoutSource = target.canResumeWithoutSource(checkpoint)
            if !FileManager.default.fileExists(atPath: staged.path), !canResumeWithoutSource {
                // No staged copy (first run, or scratch cleaned): the upload session, if any, is worthless now.
                checkpoint = nil
                try edit(id, coalesce: true) { $0.uploads[key] = nil; $0.detail = L("Descargando «\(file.name)» de \(source.account.cloud.title)…") }
                // Some providers write the destination as the bytes arrive, so a download cut short by the network
                // leaves a truncated file behind. Downloading beside the staged name and renaming only at the end
                // means a file at `staged` is always a complete one; a retry never uploads half a file as whole.
                let partial = staged.appendingPathExtension("part")
                try? FileManager.default.removeItem(at: partial)
                // Half the work of a cross-cloud transfer is this download, and the bar did not move for any of it.
                let downloaded = done
                // The download checks itself against the listed size and checksum, and deletes what fails, so only
                // a copy that passed is ever renamed into place.
                let verification: DownloadVerification
                do {
                    verification = try await source.download(file: file, to: partial, exportMime: export?.mime) { bytes, total in
                        self.report(id, base: downloaded, bytes: bytes, total: total)
                    }
                } catch let error as DownloadIntegrityError { try recordFailedCheck(id, key: key, error); throw error }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: partial, to: staged)
                try edit(id, coalesce: true) { $0.recordDownload(key, DownloadIntegrity(verification), path: $0.reportPath(for: key)) }
            }
            let base = done
            try edit(id, coalesce: true) { $0.detail = L("Subiendo «\(name)» a \(target.account.cloud.title)…") }
            let receipt = try await target.resumableUpload(local: staged, parent: parent, name: name, replacing: current.replacements[key], checkpoint: checkpoint, save: { checkpoint in
                try self.edit(id, coalesce: checkpoint.offset > 0 && !checkpoint.complete) { $0.uploads[key] = checkpoint }
            }, progress: { bytes, total in self.report(id, base: base, bytes: bytes, total: total) })
            // Persist the terminal state before deleting the only staged copy.
            try edit(id) {
                $0.completedPaths.insert(key)
                $0.record(key, receipt.verification == .verified ? .verified : .unverified, bytes: file.size,
                          reason: export.map { L("Exportado de Google como .\($0.ext)") })
            }
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
        let folder = values.isDirectory == true
        inFlight[id] = ReportCursor(key: key, leaf: local.lastPathComponent, folder: folder)
        guard values.isSymbolicLink != true else { throw CloudError.message(L("No se admiten enlaces simbólicos.")) }
        // Excluded: never uploaded, never listed, never counted. The root itself is the mirror and is never excluded.
        if key != ".", let rules = uploadExclusions?(id), rules.excludes(String(key.dropFirst(2)), isFolder: folder) { return }
        if try job(id).completedPaths.contains(key) { done += try await blockingIO { try Self.localSize(local) }; mark(id, done: done); return }
        // A mirror's own folder is never created remotely: its contents go into one that already exists, so its name
        // never reaches the provider. Judging it by the provider's rules stopped a mirror of "Fotos." from ever
        // syncing to OneDrive, over a name nobody was going to send.
        if key != ".", let problem = FileNames.problem(with: local.lastPathComponent, for: api.account.cloud) {
            throw CloudError.message(L("No se puede subir «\(local.lastPathComponent)»: \(problem)"))
        }
        var current = try job(id)
        if key == ".", current.folders[key] == nil, let problem = FileNames.problem(with: local.lastPathComponent, for: api.account.cloud) {
            throw CloudError.message(L("No se puede subir «\(local.lastPathComponent)»: \(problem)"))
        }
        if current.uncertainFolders.contains(key) {
            // An earlier POST may have committed even though its reply was lost. Recheck conflicts before creating again.
            try edit(id) { $0.names[key] = nil; $0.replacements[key] = nil; $0.uncertainFolders.remove(key) }
            siblings[parent] = nil
            current = try job(id)
        }
        if current.names[key] == nil {
            if siblings[parent] == nil { siblings[parent] = try await api.list(parent: parent) }
            let room = NameClaims.remote(account: api.account.id, parent: parent)
            let existing = (siblings[parent] ?? []) + claimed(room, by: id, besides: siblings[parent] ?? [])
            let remembered = current.mirrorEntries?[key]
            var name = remembered?.name ?? local.lastPathComponent
            let matches = existing.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.id == remembered?.id }
            var replacing: String?
            if let match = matches.first {
                let owned = remembered.map { old in
                    old.id == match.id && old.name == match.name && old.isFolder == match.isFolder &&
                    (folder || (old.size != nil && old.modified != nil && old.size == match.size && old.modified == match.modified))
                } ?? false
                let choice: ConflictChoice
                if owned, matches.count == 1 { choice = .replace }
                else { choice = try await choose(id, name: name, replace: matches.count == 1 && match.isFolder == folder && !match.isGoogleDocument && !match.id.isEmpty, folder: folder) }
                if choice == .skip { try edit(id) {
                    $0.completedPaths.insert(key)
                    $0.recordSkip(key, leaf: local.lastPathComponent, folder: folder, bytes: values.fileSize.map(Int64.init))
                    $0.mirrorEntries = $0.mirrorEntries?.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
                }; done += try await blockingIO { try Self.localSize(local) }; mark(id, done: done); return }
                if choice == .copy { name = Self.unique(name, existing: existing.map(\.name) + claims.others(in: room, excluding: id)) }
                if choice == .replace { replacing = match.id; if folder { name = match.name } }
            }
            try edit(id, coalesce: true) {
                $0.names[key] = name; $0.replacements[key] = replacing
                if folder, replacing == nil, $0.mirrorEntries != nil {
                    // A newly created/copied folder has none of the old destination's unchanged children.
                    $0.completedPaths = $0.completedPaths.filter { !$0.hasPrefix(key + "/") }
                    $0.mirrorEntries = $0.mirrorEntries?.filter { !$0.key.hasPrefix(key + "/") }
                }
            }
            current = try job(id)
        }
        let name = current.names[key]!
        claims.claim(name, in: NameClaims.remote(account: api.account.id, parent: parent), by: id)
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
            if current.mirrorEntries != nil {
                let entry = CloudFile(id: remote, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
                try edit(id) { $0.mirrorEntries?[key] = entry }
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
            try edit(id, coalesce: true) { $0.record(key, receipt.verification == .verified ? .verified : .unverified, bytes: values.fileSize.map(Int64.init)) }
            if current.mirrorEntries != nil {
                // Only an identity returned by this upload may become an automatically replaceable mirror target.
                let remote = try await api.list(parent: parent)
                let entry = receipt.remoteID.flatMap { id in remote.first { $0.id == id } }
                try edit(id) { $0.mirrorEntries?[key] = entry }
                siblings[parent] = remote
            }
            done += Int64(values.fileSize ?? 0)
            mark(id, done: done)
            if let remoteID = receipt.remoteID {
                // The file that was just uploaded is, by definition, also on this Mac.
                didStoreLocalCopy?(LocalCopy(accountID: try job(id).accountID, fileID: remoteID, name: name, path: local.path,
                                             bookmark: try job(id).bookmark, size: Int64(values.fileSize ?? 0),
                                             remoteModified: Date(), savedAt: Date(), origin: .upload))
            }
            if replacing == nil, current.mirrorEntries == nil {
                siblings[parent, default: []].append(CloudFile(id: "", name: name, mime: "application/octet-stream", size: values.fileSize.map(Int64.init), modified: nil, webURL: nil, isFolder: false))
            }
        }
        try edit(id, coalesce: true) { $0.completedPaths.insert(key) }
    }
    /// Stand-ins for the names other running jobs have chosen in `room` and not created yet. Their empty id means they
    /// can be avoided but never replaced.
    private func claimed(_ room: String, by id: UUID, besides listed: [CloudFile]) -> [CloudFile] {
        claims.others(in: room, excluding: id)
            .filter { name in !listed.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
            .map { CloudFile(id: "", name: $0, mime: "application/octet-stream", size: nil, modified: nil, webURL: nil, isFolder: false) }
    }
    /// `FileNames.available`, also stepping over the names other running jobs are downloading to.
    private func available(in folder: URL, name: String, room: String, for id: UUID) -> URL {
        var taken = claims.others(in: room, excluding: id)
        guard !taken.isEmpty else { return FileNames.available(in: folder, name: name) }
        while true {
            let candidate = folder.appendingPathComponent(Self.unique(FileNames.safe(name), existing: taken))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            taken.append(candidate.lastPathComponent)
        }
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
        inFlight[id] = ReportCursor(key: key, leaf: file.name, folder: file.isFolder)
        var current = try job(id)
        let exporting = key == "." && current.exportMime != nil
        let name = FileNames.safe(file.name + (exporting ? "." + (current.exportExtension ?? "pdf") : (file.isGoogleDocument ? ".webloc" : "")))
        var target = folder.appendingPathComponent(current.names[key] ?? name)
        var replace = current.replacements[key] != nil
        let room = NameClaims.local(folder)
        if current.names[key] == nil || (!file.isFolder && !replace && FileManager.default.fileExists(atPath: target.path)) {
            let exists = FileManager.default.fileExists(atPath: target.path)
            // A name another running job is downloading to is as taken as one already on disk, but there is nothing
            // there yet to replace.
            let claimed = claims.others(in: room, excluding: id).contains { $0.localizedCaseInsensitiveCompare(target.lastPathComponent) == .orderedSame }
            if exists || claimed {
                let values = exists ? try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) : nil
                let choice = try await choose(id, name: name, replace: !claimed && values?.isDirectory == file.isFolder && values?.isSymbolicLink != true, folder: file.isFolder)
                if choice == .skip { try edit(id) { $0.completedPaths.insert(key); $0.recordSkip(key, leaf: name, folder: file.isFolder, bytes: file.size) }; done += file.size ?? 0; mark(id, done: done); return }
                if choice == .copy { target = available(in: folder, name: name, room: room, for: id) }
                if choice == .replace { replace = true }
            }
            let selectedName = target.lastPathComponent
            try edit(id, coalesce: true) { $0.names[key] = selectedName; if replace { $0.replacements[key] = "local" } }
            current = try job(id)
        }
        claims.claim(target.lastPathComponent, in: room, by: id)
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
            var verification: DownloadVerification?
            if file.isGoogleDocument && !exporting {
                guard let url = file.webURL else { throw CloudError.message(L("No hay enlace web para este documento.")) }
                let link = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                try await blockingIO { try link.write(to: temporary) }
            } else {
                let base = done
                // A copy that fails its check is deleted inside `download`; the destination is never touched.
                do {
                    verification = try await api.download(file: file, to: temporary, exportMime: exporting ? current.exportMime : nil) { bytes, total in self.report(id, base: base, bytes: bytes, total: total) }
                } catch let error as DownloadIntegrityError { try recordFailedCheck(id, key: key, error); throw error }
            }
            try Task.checkCancellation()
            let destination = target, replacing = replace
            try await blockingIO {
                if replacing && FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
            if let verification { try edit(id, coalesce: true) { $0.recordDownload(key, DownloadIntegrity(verification), path: $0.reportPath(for: key)) } }
            else { try edit(id, coalesce: true) { $0.record(key, .exported, reason: L("Guardado como enlace .webloc al documento de Google"), counted: false) } }
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
