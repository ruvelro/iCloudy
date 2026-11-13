import Foundation
import Combine

/// One end of a saved job: a file or folder of this Mac, or an item of a connected account.
enum JobEndpoint: Codable, Equatable, Hashable, Sendable {
    case local(URL, bookmark: Data?)
    /// `location` is for people: "ana@example.com / Fotos / 2026".
    case remote(accountID: String, itemID: String, name: String, isFolder: Bool, location: String)

    var title: String {
        switch self {
        case .local(let url, _): return url.path
        case .remote(_, _, _, _, let location): return location
        }
    }
    var isLocal: Bool { if case .local = self { return true } else { return false } }
    var accountID: String? { if case .remote(let account, _, _, _, _) = self { return account } else { return nil } }
}

/// What a saved job does besides copying.
struct JobOptions: Codable, Equatable, Sendable {
    /// What a clash with the destination becomes; nil asks, as an ordinary transfer does. "This side" is the source.
    var conflictPolicy: ConflictPolicy?
    var exclusions = SyncExclusions()
    /// Checks every copied file against the destination when the run ends ("Verificar lo copiado").
    var verifyAfter = false
    /// Sends to the destination's trash what is in the copied folders there but not at the source.
    var deleteExtraneous = false
    var skipIdentical = false
    var schedule: SyncSchedule?

    init(conflictPolicy: ConflictPolicy? = nil, exclusions: SyncExclusions = SyncExclusions(), verifyAfter: Bool = false,
         deleteExtraneous: Bool = false, skipIdentical: Bool = false, schedule: SyncSchedule? = nil) {
        self.conflictPolicy = conflictPolicy; self.exclusions = exclusions; self.verifyAfter = verifyAfter
        self.deleteExtraneous = deleteExtraneous; self.skipIdentical = skipIdentical; self.schedule = schedule
    }
    enum CodingKeys: String, CodingKey { case conflictPolicy, exclusions, verifyAfter, deleteExtraneous, skipIdentical, schedule }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conflictPolicy = (try? values.decodeIfPresent(String.self, forKey: .conflictPolicy)).flatMap { $0.flatMap(ConflictPolicy.init(rawValue:)) }
        exclusions = (try? values.decodeIfPresent(SyncExclusions.self, forKey: .exclusions)) ?? SyncExclusions()
        verifyAfter = try values.decodeIfPresent(Bool.self, forKey: .verifyAfter) ?? false
        deleteExtraneous = try values.decodeIfPresent(Bool.self, forKey: .deleteExtraneous) ?? false
        skipIdentical = try values.decodeIfPresent(Bool.self, forKey: .skipIdentical) ?? false
        schedule = (try? values.decodeIfPresent(SyncSchedule.self, forKey: .schedule)) ?? nil
    }
}

/// A transfer kept with a name, to run again from the jobs window, the menu bar, Shortcuts or the command line.
/// Every run is an ordinary batch of the queue, with its report and its entries in the history.
struct SavedJob: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var sources: [JobEndpoint]
    /// A folder.
    var destination: JobEndpoint
    var options = JobOptions()
    var lastRun: Date?
    /// The batch of the last run, for its report.
    var lastBatchID: UUID?
    /// Set while the last run's batch has not finished.
    var running = false
    /// What the last run came to, in a sentence.
    var lastResult: String?
    var lastScheduledRun: Date?

    init(id: UUID = UUID(), name: String, sources: [JobEndpoint], destination: JobEndpoint, options: JobOptions = JobOptions()) {
        self.id = id; self.name = name; self.sources = sources; self.destination = destination; self.options = options
    }
    enum CodingKeys: String, CodingKey { case id, name, sources, destination, options, lastRun, lastBatchID, running, lastResult, lastScheduledRun }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? L("Trabajo")
        sources = try values.decode([JobEndpoint].self, forKey: .sources)
        destination = try values.decode(JobEndpoint.self, forKey: .destination)
        options = (try? values.decodeIfPresent(JobOptions.self, forKey: .options)) ?? JobOptions()
        lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
        lastBatchID = try values.decodeIfPresent(UUID.self, forKey: .lastBatchID)
        running = try values.decodeIfPresent(Bool.self, forKey: .running) ?? false
        lastResult = try values.decodeIfPresent(String.self, forKey: .lastResult)
        lastScheduledRun = try values.decodeIfPresent(Date.self, forKey: .lastScheduledRun)
    }

    enum Kind { case upload, download, transfer }
    /// What the queue makes of it, or why it cannot run.
    func kind() throws -> Kind {
        guard !sources.isEmpty else { throw CloudError.message(L("El trabajo no tiene nada que copiar.")) }
        let local = sources.filter(\.isLocal).count
        guard local == 0 || local == sources.count else { throw CloudError.message(L("Un trabajo copia desde el Mac o desde la nube, no desde los dos a la vez.")) }
        switch (local > 0, destination.isLocal) {
        case (true, true): throw CloudError.message(L("Para copiar de una carpeta del Mac a otra ya está el Finder: elige un destino en la nube."))
        case (true, false): return .upload
        case (false, true): return .download
        case (false, false): return .transfer
        }
    }
    var scheduleBase: Date? {
        switch (lastScheduledRun, lastRun) {
        case (let a?, let b?): return max(a, b)
        case (let a, let b): return a ?? b
        }
    }
}

/// The saved jobs and their file, `jobs.json`, and what runs them.
@MainActor
@Observable
final class JobStore {
    private(set) var jobs: [SavedJob] = []
    var persistenceError: String?
    let storeURL: URL
    @ObservationIgnored weak var queue: TransferQueue?
    /// The account a job's remote end belongs to, for its client.
    @ObservationIgnored var accountLookup: ((String) -> Account?)?
    /// Sends a local item to the Trash after a run that carries deletions; tests bypass the Finder.
    @ObservationIgnored var trashLocally: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Runs allowed to delete most of a destination, for the next run only.
    @ObservationIgnored private var massDeletionAllowed: Set<UUID> = []
    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var finishing: Set<UUID> = []
    @ObservationIgnored private var scheduleTimer: Task<Void, Never>?

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("jobs.json")) {
        self.storeURL = storeURL
        do { jobs = try LocalStore.read(StoreEnvelope<[SavedJob]>.self, from: storeURL)?.items ?? [] }
        catch {
            // Never overwritten with an empty list: the file moves aside, where a later version may still read it.
            let kept = try? LocalStore.setAside(storeURL)
            persistenceError = L("No se pudieron leer los trabajos guardados: \(error.localizedDescription)")
                + (kept.map { " " + L("El archivo original se conserva en \($0.path).") } ?? "")
        }
    }

    private func persist() {
        persistenceError = nil
        StoreWriter.shared.later(StoreEnvelope(jobs), to: storeURL) { [weak self] error in
            self?.persistenceError = L("No se pudieron guardar los trabajos: \(error.localizedDescription)")
        }
    }

    func job(_ id: UUID) -> SavedJob? { jobs.first { $0.id == id } }
    /// By name, ignoring case and accents, for Shortcuts and the command line.
    func job(named name: String) -> SavedJob? {
        jobs.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    func add(_ job: SavedJob) throws {
        _ = try job.kind()
        jobs.append(job); persist(); armSchedule()
    }
    func update(_ job: SavedJob) throws {
        _ = try job.kind()
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job; persist(); armSchedule()
    }
    func remove(_ id: UUID) { jobs.removeAll { $0.id == id }; persist(); armSchedule() }
    private func edit(_ id: UUID, _ change: (inout SavedJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index]); persist()
    }

    // MARK: Running

    /// Follows the queue so each run is wrapped up when its batch ends, and keeps the schedule.
    func start() {
        subscription = queue?.stateChanges.sink { [weak self] _ in
            guard let self else { return }
            self.finishRuns()
            if self.queue?.currentHold == nil, let next = self.nextScheduled(), next <= Date() { self.tick() }
        }
        finishRuns()
        armSchedule()
    }

    /// Queues one run of the job as a batch and returns the batch's id. `allowingMassDeletion` lets this run delete
    /// most of what the destination holds, which the brake otherwise refuses.
    @discardableResult
    func run(_ id: UUID, allowingMassDeletion: Bool = false) async throws -> UUID {
        guard let job = job(id) else { throw CloudError.message(L("Ese trabajo ya no existe.")) }
        guard let queue, let client = queue.client else { throw CloudError.message(L("La cola de transferencias no está disponible.")) }
        if job.running, let batch = job.lastBatchID, queue.items.contains(where: { $0.batchID == batch && !$0.finished }) {
            throw CloudError.message(L("«\(job.name)» ya está en marcha."))
        }
        let kind = try job.kind()
        let batch = UUID()
        let options = TransferOptions(conflictPolicy: job.options.conflictPolicy, exclusions: job.options.exclusions,
                                      skipIdentical: job.options.skipIdentical)
        var transfers: [Transfer] = []
        for source in job.sources {
            var transfer: Transfer
            switch (kind, source, job.destination) {
            case (.upload, .local(let url, let bookmark), .remote(let account, let folder, _, _, let location)):
                transfer = Transfer(batchID: batch, name: url.lastPathComponent, destination: location, accountID: account, direction: .upload,
                                    localURL: url, bookmark: bookmark, parent: folder)
                // The local side is cheap to walk: the plan seeds the report, so a run that stops early still lists
                // every file it did not reach, and "Reintentar solo lo pendiente" knows them.
                // Files the rules leave out are taken out of it, or the end of the run would call them missing; with
                // an age filter the plan cannot tell, so there is none.
                if job.options.exclusions.maxAge == nil, job.options.exclusions.minAge == nil, let cloud = accountLookup?(account)?.cloud,
                   let plan = try? await TransferPlanner.uploads([url], to: cloud, existing: [], quota: nil), let seed = plan.seeds.first {
                    let rules = job.options.exclusions.matcher(caseInsensitive: SyncExclusions.isCaseInsensitive(url))
                    transfer.seed(seed.filter { key, record in
                        key == "." || !rules.excludesFile(String(key.dropFirst(2)), size: record.bytes, modified: nil, now: Date())
                    })
                }
            case (.download, .remote(let account, let item, let name, let isFolder, _), .local(let folder, let bookmark)):
                let file = try await currentItem(client(account), id: item, name: name, isFolder: isFolder)
                transfer = Transfer(batchID: batch, name: file.name, destination: folder.path, accountID: account, direction: .download,
                                    localURL: folder, bookmark: bookmark, file: file)
            case (.transfer, .remote(let account, let item, let name, let isFolder, _), .remote(let target, let folder, _, _, let location)):
                let file = try await currentItem(client(account), id: item, name: name, isFolder: isFolder)
                transfer = Transfer(batchID: batch, name: file.name, destination: location, accountID: account, direction: .transfer,
                                    localURL: URL(fileURLWithPath: "/"), parent: folder, file: file)
                transfer.localURL = queue.scratchDirectory(for: transfer.id)
                transfer.targetAccountID = target
            default:
                throw CloudError.message(L("El trabajo mezcla orígenes que no van a ese destino."))
            }
            transfer.options = options
            transfers.append(transfer)
        }
        try queue.add(transfers)
        if allowingMassDeletion { massDeletionAllowed.insert(id) } else { massDeletionAllowed.remove(id) }
        edit(id) { $0.lastRun = Date(); $0.lastBatchID = batch; $0.running = true; $0.lastResult = L("En marcha") }
        return batch
    }

    /// The source item as it is now, so a download is checked against its current size and checksum.
    private func currentItem(_ api: CloudAPI, id: String, name: String, isFolder: Bool) async throws -> CloudFile {
        let stored = CloudFile(id: id, name: name, mime: isFolder ? "application/vnd.google-apps.folder" : "application/octet-stream",
                               size: nil, modified: nil, webURL: nil, isFolder: isFolder)
        guard !isFolder else { return stored }
        return (try? await api.currentMetadata(of: stored)) ?? stored
    }

    /// Wraps up every run whose batch has ended: the check of what was copied, the deletions it carries, and the
    /// sentence the jobs window shows.
    private func finishRuns() {
        guard let queue else { return }
        for job in jobs where job.running && !finishing.contains(job.id) {
            guard let batch = job.lastBatchID else { continue }
            let items = queue.items.filter { $0.batchID == batch }
            guard items.allSatisfy(\.finished) else { continue }
            finishing.insert(job.id)
            Task { [weak self] in
                guard let self else { return }
                let result = await self.wrapUp(job, items: items)
                self.edit(job.id) { $0.running = false; $0.lastResult = result }
                self.finishing.remove(job.id)
            }
        }
    }

    private func wrapUp(_ job: SavedJob, items: [Transfer]) async -> String {
        guard let queue, !items.isEmpty else { return L("La transferencia se quitó de la cola antes de acabar.") }
        var parts: [String] = []
        let report = TransferReport(jobs: items)
        parts.append(L("\(report.copied) copiados"))
        if report.outstanding > 0 { parts.append(L("\(report.outstanding) pendientes o fallidos")) }
        let batch = items[0].batchID
        if job.options.verifyAfter, items.contains(where: { $0.state == .completed }) {
            do { parts.append(try await queue.verifyCopied(batch).text) }
            catch { parts.append(L("No se pudo verificar: \(error.localizedDescription)")) }
        }
        if job.options.deleteExtraneous, items.allSatisfy({ $0.state == .completed }) {
            do {
                let trashed = try await sweep(job, items: items, allowed: massDeletionAllowed.remove(job.id) != nil)
                if trashed > 0 { parts.append(L("\(trashed) enviados a la papelera del destino")) }
            } catch { parts.append(error.localizedDescription) }
        }
        return parts.joined(separator: " · ")
    }

    /// Sends to the destination's trash what the copied folders hold there and the sources do not. Only inside what
    /// the job copied, never beside it, and never what the job's rules exclude or what it wrote under another name.
    private func sweep(_ job: SavedJob, items: [Transfer], allowed: Bool) async throws -> Int {
        guard let client = queue?.client else { return 0 }
        var plans: [(ExtraneousSweep.Plan, ExtraneousSweep.Side)] = []
        for transfer in items where transfer.file?.isFolder ?? isDirectory(transfer.localURL) {
            let rules = job.options.exclusions.matcher(caseInsensitive: true)
            let written = Set(transfer.names.values)
            let source: ExtraneousSweep.Side, destination: ExtraneousSweep.Side, sourceRoot: String, destinationRoot: String
            switch transfer.direction {
            case .upload:
                guard let root = transfer.folders["."] ?? transfer.replacements["."] else { continue }
                source = .local(trash: trashLocally); sourceRoot = transfer.localURL.path
                destination = .remote(try client(transfer.accountID)); destinationRoot = root
            case .download:
                source = .remote(try client(transfer.accountID)); sourceRoot = transfer.file?.id ?? ""
                destination = .local(trash: trashLocally)
                destinationRoot = transfer.localURL.appendingPathComponent(transfer.names["."] ?? FileNames.safe(transfer.name)).path
            case .transfer:
                guard let target = transfer.targetAccountID, let root = transfer.folders["."] ?? transfer.replacements["."] else { continue }
                source = .remote(try client(transfer.accountID)); sourceRoot = transfer.file?.id ?? ""
                destination = .remote(try client(target)); destinationRoot = root
            }
            let plan = try await ExtraneousSweep.plan(source: source, sourceRoot: sourceRoot, destination: destination,
                                                      destinationRoot: destinationRoot, rules: rules, written: written)
            plans.append((plan, destination))
        }
        let extraneous = plans.reduce(0) { $0 + $1.0.files }, total = plans.reduce(0) { $0 + $1.0.destinationFiles }
        try ExactMirrorPlanner.checkMassDeletion(extraneous, of: total, side: L("el destino"), allowed: allowed)
        var trashed = 0
        for (plan, side) in plans { trashed += try await side.trash(plan.items) }
        return trashed
    }
    private func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    // MARK: Schedule

    /// Runs every job whose schedule is due, unless the queue is held; a run due while it is held starts when the
    /// hold lifts. A job still running is not started again.
    func tick(now: Date = Date()) {
        guard queue?.currentHold == nil else { return }
        for job in jobs where !job.running {
            guard let schedule = job.options.schedule, schedule.nextRun(after: job.scheduleBase, now: now) <= now else { continue }
            edit(job.id) { $0.lastScheduledRun = now }
            Task { [weak self] in
                do { try await self?.run(job.id) }
                catch { self?.edit(job.id) { $0.lastResult = error.localizedDescription } }
            }
        }
    }
    func nextScheduled(now: Date = Date()) -> Date? {
        jobs.compactMap { job in job.options.schedule.map { $0.nextRun(after: job.scheduleBase, now: now) } }.min()
    }
    private func armSchedule() {
        guard subscription != nil else { return }
        scheduleTimer?.cancel()
        guard let next = nextScheduled() else { scheduleTimer = nil; return }
        let delay = min(max(1, next.timeIntervalSinceNow), 15 * 60)
        scheduleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.tick()
            self.armSchedule()
        }
    }
}

/// What a run that carries deletions finds at its destination and the source no longer has.
enum ExtraneousSweep {
    struct Node: Sendable { let name: String; let isFolder: Bool; let handle: String }
    /// One side of the comparison: the local file system (handles are paths) or an account (handles are ids).
    enum Side {
        case local(trash: (URL) throws -> Void)
        case remote(CloudAPI)

        @MainActor func children(_ handle: String) async throws -> [Node] {
            switch self {
            case .local:
                let url = URL(fileURLWithPath: handle)
                return try await blockingIO {
                    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).map {
                        Node(name: $0.lastPathComponent, isFolder: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, handle: $0.path)
                    }
                }
            case .remote(let api):
                return try await api.list(parent: handle).map { Node(name: $0.name, isFolder: $0.isFolder, handle: $0.id) }
            }
        }
        @MainActor func trash(_ items: [(node: Node, file: CloudFile?)]) async throws -> Int {
            var count = 0
            for item in items {
                switch self {
                case .local(let trash): try trash(URL(fileURLWithPath: item.node.handle))
                case .remote(let api): if let file = item.file { try await api.trash(file: file) }
                }
                count += 1
            }
            return count
        }
    }
    struct Plan {
        var items: [(node: Node, file: CloudFile?)] = []
        /// Files among `items`, and files found at the destination, for the brake.
        var files = 0
        var destinationFiles = 0
    }

    @MainActor
    static func plan(source: Side, sourceRoot: String, destination: Side, destinationRoot: String,
                     rules: SyncExclusionMatcher, written: Set<String>) async throws -> Plan {
        var plan = Plan()
        var queue: [(source: String, destination: String, path: String)] = [(sourceRoot, destinationRoot, "")]
        while !queue.isEmpty {
            let (sourceHandle, destinationHandle, prefix) = queue.removeFirst()
            try Task.checkCancellation()
            let theirs = try await source.children(sourceHandle)
            let mine: [Node]
            var files: [String: CloudFile] = [:]
            if case .remote(let api) = destination {
                let listed = try await api.list(parent: destinationHandle)
                for file in listed { files[file.id] = file }
                mine = listed.map { Node(name: $0.name, isFolder: $0.isFolder, handle: $0.id) }
            } else {
                mine = try await destination.children(destinationHandle)
            }
            for node in mine {
                let path = prefix.isEmpty ? node.name : prefix + "/" + node.name
                if !node.isFolder { plan.destinationFiles += 1 }
                if rules.excludes(path, isFolder: node.isFolder) || rules.isFolderMetadata(path) { continue }
                if let match = theirs.first(where: { $0.name.localizedCaseInsensitiveCompare(node.name) == .orderedSame }) {
                    if node.isFolder, match.isFolder { queue.append((match.handle, node.handle, path)) }
                    continue
                }
                // A name the job chose itself, a copy kept beside a clash, belongs to the run.
                if written.contains(node.name) { continue }
                plan.items.append((node, files[node.handle]))
                if !node.isFolder { plan.files += 1 }
            }
        }
        return plan
    }
}
