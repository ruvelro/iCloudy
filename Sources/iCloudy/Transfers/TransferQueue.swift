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
@Observable
final class TransferQueue {
    private(set) var items: [Transfer] = []
    var conflict: ConflictRequest? { didSet { stateChanges.send() } }
    var persistenceError: String? { didSet { stateChanges.send() } }
    /// Fires on structural changes only: jobs added or removed, state transitions, conflicts and persistence errors.
    /// Progress ticks mutate `items` without touching it, so views observing the whole app do not re-render per block.
    let stateChanges = PassthroughSubject<Void, Never>()
    /// Moves with every structural change, so what reads `structuralItems` redraws with those and not per block.
    private(set) var revision = 0
    @ObservationIgnored private var revisionSubscription: AnyCancellable?
    /// The jobs, observed only through `revision`. The explorer's badges and menus read this: they care that a job
    /// started or ended, and redrawing every row of every listing on each progress tick was a visible stutter.
    var structuralItems: [Transfer] {
        _ = revision
        return _items
    }
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
            // An account's buckets outlive a change of its limit, so the lanes of its running jobs keep working.
            for (account, buckets) in accountLimiters where policy.accountLimits[account] == nil {
                buckets.upload.bytesPerSecond = nil; buckets.download.bytesPerSecond = nil
            }
            for (account, limit) in policy.accountLimits {
                let buckets = limiters(for: account)
                buckets.upload.bytesPerSecond = limit.upload
                buckets.download.bytesPerSecond = limit.download
            }
            reevaluate()
        }
    }
    /// The provider of each account, for the providers that can only do one thing at a time.
    var cloud: ((String) -> Cloud?)?
    /// The clock the schedule is read against; a seam for tests.
    var now: () -> Date = Date.init
    /// Why nothing is starting right now, shown above the list and as each paused job's status.
    private(set) var hold: TransferHold?
    /// The jobs whose task is alive, running or still unwinding from a pause.
    var runningIDs: Set<UUID> { Set(tasks.keys) }
    /// The bandwidth limits, one bucket per direction shared by every job of this queue.
    let uploadLimiter = BandwidthLimiter(), downloadLimiter = BandwidthLimiter()
    /// The combined speed of the last two minutes, for the panel's chart.
    let speed = SpeedHistory()
    @ObservationIgnored var samplingTask: Task<Void, Never>?
    var speedSampleInterval: Duration = .seconds(1)
    /// Each account's own buckets, made the first time the account has a limit or a job.
    @ObservationIgnored private var accountLimiters: [String: (upload: BandwidthLimiter, download: BandwidthLimiter)] = [:]
    private func limiters(for account: String) -> (upload: BandwidthLimiter, download: BandwidthLimiter) {
        if let known = accountLimiters[account] { return known }
        let made = (upload: BandwidthLimiter(), download: BandwidthLimiter())
        accountLimiters[account] = made
        return made
    }
    /// The lanes for work that sends to `upload` and reads from `download`: the queue's buckets and those accounts'.
    /// Mirrors that run outside the queue go through the same ones.
    func throttle(upload: String?, download: String?) -> TransferThrottle {
        TransferThrottle(upload: [uploadLimiter] + (upload.map { [limiters(for: $0).upload] } ?? []),
                         download: [downloadLimiter] + (download.map { [limiters(for: $0).download] } ?? []))
    }
    private var costlyNetwork = false
    @ObservationIgnored private var windowTimer: Task<Void, Never>?
    let storeURL: URL
    private var writable = true
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Several jobs can meet a name conflict at the same time; they wait in line and the sheet shows one at a time.
    @ObservationIgnored private var conflictContinuations: [UUID: CheckedContinuation<ConflictChoice, Error>] = [:]
    private var pendingConflicts: [ConflictRequest] = []
    /// Per job: when it started this run, from how many bytes, and when it last reported.
    @ObservationIgnored private var meters: [UUID: (started: Date, startBytes: Int64, lastReport: Date)] = [:]
    /// Shared with the walkers of the running jobs.
    @ObservationIgnored var claims = NameClaims()
    /// The item each running job is working on, so a failure lands on the right line of its report.
    @ObservationIgnored var inFlight: [UUID: ReportCursor] = [:]

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("transfers.json")) {
        self.storeURL = storeURL
        revisionSubscription = stateChanges.sink { [weak self] in self?.revision &+= 1 }
        do {
            items = try LocalStore.read(StoreEnvelope<[Transfer]>.self, from: storeURL)?.items ?? []
            for index in items.indices where [.running, .queued].contains(items[index].state) { items[index].state = .paused; items[index].bytesPerSecond = 0; items[index].hold = nil }
            // The queue comes back paused for the person to decide, as it always has, except for jobs waiting for the
            // schedule or for a cheaper network: those were already decided, and the policy releases them.
            for index in items.indices where items[index].hold == .offline { items[index].hold = nil; items[index].detail = "" }
            trimFinished()
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

    /// Finished jobs the panel keeps. Each mirror pass leaves one, and every one of them used to stay in the file the
    /// queue rewrites, with its whole per-file report, until somebody pressed «Limpiar». The history keeps its own
    /// record of all of them; the panel keeps the newest.
    static let finishedLimit = 300

    /// Drops the oldest finished jobs beyond the limit. Only called where no index into `items` is held: when the
    /// queue is read and before jobs are added.
    func trimFinished() {
        let finished = items.filter { $0.finished && tasks[$0.id] == nil }
        guard finished.count > Self.finishedLimit else { return }
        let leaving = Set(finished.prefix(finished.count - Self.finishedLimit).map(\.id))
        for job in items where leaving.contains(job.id) && job.direction == .transfer { try? FileManager.default.removeItem(at: job.localURL) }
        items.removeAll { leaving.contains($0.id) }
    }

    /// Coalesced writes batch the per-block checkpoints into one file write every `flushDelay`. Every other change is
    /// handed to the writer at once and written in the background, in order; a burst of them costs one write. The
    /// queue used to wait for each of those writes on the main thread, and for every other store's before it, so a
    /// tree of F folders cost at least 2F blocking writes. `now` waits, for `add` and for the flush on quit.
    private func persist(coalesce: Bool = false, now: Bool = false) throws {
        guard writable else { throw CloudError.message(persistenceError ?? L("La cola no se puede guardar.")) }
        if coalesce { dirty = true; scheduleFlush(); return }
        flushTask?.cancel(); flushTask = nil; dirty = false
        guard now else {
            StoreWriter.shared.later(StoreEnvelope(items), to: storeURL) { [weak self] error in
                self?.persistenceError = L("No se pudo guardar la cola: \(error.localizedDescription)")
            }
            return
        }
        do { try StoreWriter.shared.now(StoreEnvelope(items), to: storeURL) }
        catch { persistenceError = L("No se pudo guardar la cola: \(error.localizedDescription)"); throw error }
    }
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let delay = self?.flushDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush(waiting: false)
        }
    }
    /// Writes pending coalesced changes. Before the process exits it waits for the write; the periodic flush does not.
    func flush(waiting: Bool = true) {
        guard dirty, writable else { return }
        guard !waiting else {
            do { try persist(now: true) } catch { persistenceError = error.localizedDescription }
            return
        }
        dirty = false
        StoreWriter.shared.later(StoreEnvelope(items), to: storeURL) { [weak self] error in
            self?.persistenceError = L("No se pudo guardar la cola: \(error.localizedDescription)")
        }
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
        trimFinished()
        items += jobs
        // Written before returning: whoever adds a job may quit right after, and the job must still be there.
        do { try persist(now: true) } catch { items.removeAll { item in jobs.contains { $0.id == item.id } }; throw error }
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
        // A download that resumes by offset may have left a partial behind from an earlier attempt.
        if !pause, items[index].direction == .download, tasks[id] == nil { Self.removeResumablePartials(of: items[index]) }
        if let task = tasks[id] {
            task.cancel()
            dropConflict(of: id)
        }
        do { try persist() } catch { persistenceError = error.localizedDescription }
        stateChanges.send()
    }
    /// Removes the partials of a cancelled download job, in its destination folder and below, off the main thread.
    nonisolated static func removeResumablePartials(of transfer: Transfer) {
        let id = transfer.id, bookmark = transfer.bookmark, folder = transfer.localURL
        Task.detached(priority: .utility) {
            var url = folder, stale = false
            if let bookmark, let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { url = resolved }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            ResumableDownload.removePartials(job: id, under: url)
        }
    }
    /// Asks the provider to drop the upload sessions of a job that will never finish them. Best effort: they expire
    /// by themselves, but Box counts the open ones against the account and the others hold storage meanwhile.
    private func abandonSessions(_ transfer: Transfer) {
        let urls = transfer.uploads.values.compactMap(\.url)
        let sessionIDs = transfer.uploads.values.compactMap(\.sessionID)
        guard !urls.isEmpty || !sessionIDs.isEmpty, let lookup = client,
              let api = try? lookup(transfer.targetAccountID ?? transfer.accountID) else { return }
        Task { await api.abandonUploadSessions(urls: urls, sessionIDs: sessionIDs) }
    }
    /// The original of a cross-cloud move has been dealt with: removed, or left where it was with an explanation.
    /// Either way the job stops being a move, so the next launch does not act on it again.
    func settleMove(_ id: UUID) {
        guard let index = index(id), items[index].removesSource else { return }
        items[index].removesSource = false
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    /// The archive step of a job has run: it stops carrying it.
    func settleArchive(_ id: UUID) {
        guard let index = index(id), items[index].archive != nil else { return }
        items[index].archive = nil
        do { try persist() } catch { persistenceError = error.localizedDescription }
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
    func job(_ id: UUID) throws -> Transfer {
        guard let index = index(id) else { throw CancellationError() }
        return items[index]
    }
    /// `coalesce` defers the disk write; a state transition is handed to the writer at once and notifies observers.
    func edit(_ id: UUID, coalesce: Bool = false, _ change: (inout Transfer) -> Void) throws {
        guard let index = index(id) else { throw CancellationError() }
        let before = items[index].state
        change(&items[index])
        let transition = items[index].state != before
        try persist(coalesce: coalesce && !transition)
        if transition { stateChanges.send() }
    }
    /// The same, returning once the change is on disk: for a marker that has to exist before a request is sent.
    /// It waits without holding the main thread.
    func commit(_ id: UUID, _ change: (inout Transfer) -> Void) async throws {
        guard let index = index(id) else { throw CancellationError() }
        let before = items[index].state
        change(&items[index])
        guard writable else { throw CloudError.message(persistenceError ?? L("La cola no se puede guardar.")) }
        flushTask?.cancel(); flushTask = nil; dirty = false
        do { try await StoreWriter.shared.write(StoreEnvelope(items), to: storeURL) }
        catch { persistenceError = L("No se pudo guardar la cola: \(error.localizedDescription)"); throw error }
        if items.first(where: { $0.id == id })?.state != before { stateChanges.send() }
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
        defer { startSampling() }
        // An upload sends to its account, a download reads from it, and a copy between clouds does both.
        let throttle = throttle(upload: next.direction == .upload ? next.accountID : next.targetAccountID,
                                download: next.direction == .upload ? nil : next.accountID)
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
        if let announced = (error as? ServiceError)?.retryAfter { return RetryAfter.delay(announced: announced, attempt: attempt) }
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
    func recordFailedCheck(_ id: UUID, key: String, _ error: DownloadIntegrityError) throws {
        try edit(id) {
            $0.recordDownload(key, .failed)
            if key == ".", case .changedRemotely(_, let current?) = error {
                $0.file = current
                if !current.isFolder { $0.total = current.size ?? 0 }
            }
        }
    }
    func choose(_ id: UUID, name: String, replace: Bool, folder: Bool) async throws -> ConflictChoice {
        try Task.checkCancellation()
        if let choice = try job(id).batchChoice, choice != .replace || replace { return choice }
        return try await withCheckedThrowingContinuation { continuation in
            conflictContinuations[id] = continuation
            pendingConflicts.append(ConflictRequest(transferID: id, name: name, canReplace: replace, folder: folder))
            if conflict == nil { conflict = pendingConflicts.first }
        }
    }
    func report(_ id: UUID, base: Int64, bytes: Int64, total: Int64) {
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
    func mark(_ id: UUID, done: Int64) {
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
            try await TransferWalker(queue: self, id: id, width: TransferScheduler.filesAtOnce(policy, accounts: [api.account], uploading: true)).upload(api: api, local: source, parent: current.parent)
        } else if current.direction == .transfer, let file = current.file {
            guard let targetID = current.targetAccountID else { throw CloudError.message(L("Falta la cuenta de destino de esta transferencia.")) }
            let target = try client(targetID)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try edit(id) { $0.bytes = 0; $0.total = file.isFolder ? 0 : (file.size ?? 0) }
            try await TransferWalker(queue: self, id: id, width: TransferScheduler.filesAtOnce(policy, accounts: [api.account, target.account], uploading: true)).copy(from: api, to: target, file: file, parent: current.parent, scratch: source)
            try? FileManager.default.removeItem(at: source)
        } else if let file = current.file {
            // Folder totals grow as each remote folder is listed; a single file's size is known up front.
            try edit(id) { $0.bytes = 0; $0.total = file.isFolder ? 0 : (file.size ?? 0) }
            try await TransferWalker(queue: self, id: id, width: TransferScheduler.filesAtOnce(policy, accounts: [api.account], uploading: false)).download(api: api, file: file, into: source)
        }
    }
    /// Flat, collision-free staging name: keys are paths, and the digest keeps them out of nested directories.
    nonisolated static func stagedName(_ key: String, _ name: String) -> String {
        String(key.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16) + "-" + FileNames.safe(name)
    }
    /// Walks the tree synchronously; callers run it through `blockingIO` because large folders take a while.
    nonisolated static func localSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CloudError.message(L("No se admiten enlaces simbólicos: \(url.lastPathComponent)")) }
        if values.isDirectory == true { return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).reduce(0) { try $0 + localSize($1) } }
        return Int64(values.fileSize ?? 0)
    }
    /// Stand-ins for the names other running jobs have chosen in `room` and not created yet. Their empty id means they
    /// can be avoided but never replaced.
    func claimed(_ room: String, by id: UUID, besides listed: [CloudFile]) -> [CloudFile] {
        claims.others(in: room, excluding: id)
            .filter { name in !listed.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
            .map { CloudFile(id: "", name: $0, mime: "application/octet-stream", size: nil, modified: nil, webURL: nil, isFolder: false) }
    }
    /// `FileNames.available`, also stepping over the names other running jobs are downloading to.
    func available(in folder: URL, name: String, room: String, for id: UUID) -> URL {
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
}
