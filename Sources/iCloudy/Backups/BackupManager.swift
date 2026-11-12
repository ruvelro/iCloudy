import Foundation
import Combine

/// Runs the scheduled copies between accounts: lists both sides, plans, moves aside what is about to be replaced
/// and hands the copy itself to the transfer queue as one job.
@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var plans: [BackupPlan] = []
    @Published var persistenceError: String?
    /// Plans being listed and planned right now; the copy itself shows in the transfer panel.
    @Published private(set) var preparing: Set<UUID> = []
    let storeURL: URL
    weak var queue: TransferQueue? {
        didSet { subscription = queue?.stateChanges.sink { [weak self] _ in self?.noteFailures() } }
    }
    var accountLookup: ((String) -> Account?)?
    /// The clock the schedules are read against; a seam for tests.
    var now: () -> Date = Date.init
    /// How often the schedules are looked at.
    var tick: Duration = .seconds(60)
    private var subscription: AnyCancellable?
    private var timer: Task<Void, Never>?
    /// When each plan was last tried, so one that keeps failing is not tried again every minute.
    private var attempted: [UUID: Date] = [:]
    private var removalAllowed: Set<UUID> = []
    /// Dated folders of earlier versions made by the running job, to be pruned by age when it completes.
    static let stampFormat = "yyyy-MM-dd HH.mm"

    static var defaultStore: URL {
        guard Diagnostics.underTest else { return LocalStore.directory.appendingPathComponent("backups.json") }
        return FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-tests-\(ProcessInfo.processInfo.processIdentifier)/backups-\(UUID().uuidString).json")
    }
    init(storeURL: URL = BackupManager.defaultStore) {
        self.storeURL = storeURL
        do { plans = try LocalStore.read([BackupPlan].self, from: storeURL) ?? [] }
        catch { persistenceError = L("No se pudieron leer las copias programadas: \(error.localizedDescription)") }
    }

    /// Called once the queue and the accounts exist. A run that was copying when the app closed is resumed rather
    /// than planned again; after that the schedules are looked at every minute.
    func start() {
        for plan in plans {
            guard let active = plan.activeTransferID else { continue }
            if let job = queue?.items.first(where: { $0.id == active }) { if job.state == .paused, !plan.paused { queue?.retry(active) } }
            else { update(plan.id) { $0.activeTransferID = nil; $0.pending = nil } }
        }
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.runDue()
                guard let interval = self?.tick else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func add(_ plan: BackupPlan) throws {
        guard !(plan.sourceAccountID == plan.targetAccountID && plan.sourceFolderID == plan.targetFolderID) else {
            throw CloudError.message(L("El origen y el destino son la misma carpeta."))
        }
        guard !plans.contains(where: { $0.sourceAccountID == plan.sourceAccountID && $0.sourceFolderID == plan.sourceFolderID
                                       && $0.targetAccountID == plan.targetAccountID && $0.targetFolderID == plan.targetFolderID }) else {
            throw CloudError.message(L("Esa carpeta ya se copia a ese destino."))
        }
        plans.append(plan)
        try persist()
    }
    func remove(_ id: UUID) {
        if let active = plans.first(where: { $0.id == id })?.activeTransferID { queue?.cancel(active) }
        plans.removeAll { $0.id == id }
        attempted[id] = nil; removalAllowed.remove(id)
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    func removeAll(accountID: String) {
        for plan in plans where plan.sourceAccountID == accountID || plan.targetAccountID == accountID { remove(plan.id) }
    }
    func setPaused(_ paused: Bool, for id: UUID) {
        update(id) { $0.paused = paused }
        guard let plan = plans.first(where: { $0.id == id }), let active = plan.activeTransferID else { return }
        if paused { queue?.cancel(active, pause: true) } else { queue?.retry(active) }
    }
    func setSchedule(_ schedule: BackupSchedule, for id: UUID) { update(id) { $0.schedule = schedule } }
    func setOptions(keepsVersions: Bool, removesDeleted: Bool, retentionDays: Int?, for id: UUID) {
        update(id) { $0.keepsVersions = keepsVersions; $0.removesDeleted = removesDeleted; $0.retentionDays = retentionDays }
    }
    /// Renames and moves made from iCloudy carry the plans along, like mirrors and favourites.
    func remap(_ change: RemoteIdentityChange, accountID: String) {
        var changed = false
        for index in plans.indices {
            if plans[index].sourceAccountID == accountID, change.id(plans[index].sourceFolderID) != plans[index].sourceFolderID {
                plans[index].sourceFolderID = change.id(plans[index].sourceFolderID); changed = true
            }
            if plans[index].targetAccountID == accountID, change.id(plans[index].targetFolderID) != plans[index].targetFolderID {
                plans[index].targetFolderID = change.id(plans[index].targetFolderID); changed = true
            }
        }
        if changed { try? persist() }
    }
    /// Whether `transfer` is the copy of a plan that is paused: it waits for the plan, not for "Reanudar todas".
    func holdsPaused(_ transfer: Transfer) -> Bool { plans.contains { $0.paused && $0.activeTransferID == transfer.id } }

    func status(of plan: BackupPlan) -> String {
        if plan.paused { return L("En pausa") }
        if preparing.contains(plan.id) { return L("Comparando origen y destino…") }
        if let active = plan.activeTransferID, let job = queue?.items.first(where: { $0.id == active }), !job.finished {
            return job.state == .running ? L("Copiando…") : (job.state == .paused ? job.status : L("En cola"))
        }
        if let error = plan.lastError { return L("Error: \(error)") }
        guard let last = plan.lastRun else { return L("Todavía no se ha ejecutado") + " · " + plan.schedule.summary }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
        return L("Última copia \(formatter.localizedString(for: last, relativeTo: now()))") + (plan.lastSummary.map { " · " + $0 } ?? "")
    }

    private func runDue() {
        for plan in plans where !plan.paused && plan.activeTransferID == nil && !preparing.contains(plan.id) {
            let last = [plan.lastRun, attempted[plan.id]].compactMap { $0 }.max()
            if plan.schedule.isDue(lastRun: last, now: now()) { Task { await run(plan.id) } }
        }
    }

    func runNow(_ id: UUID, applyingRemovals: Bool = false) {
        guard let plan = plans.first(where: { $0.id == id }), !plan.paused else { return }
        if applyingRemovals { removalAllowed.insert(id) }
        Task { await run(id) }
    }

    // MARK: - A run

    /// Both trees below the plan's folders. The destination is only read where the source has a folder of the same
    /// name: what else is there was not put there by this plan, and is none of its business.
    func snapshot(_ plan: BackupPlan, source: CloudAPI, target: CloudAPI) async throws -> (source: [BackupNode], target: [BackupNode]) {
        var sourceNodes: [BackupNode] = [], targetNodes: [BackupNode] = []
        let sourcePacer = ListingPacer.shared(for: source.account.id, interval: source.demo != nil ? .zero : .milliseconds(100))
        let targetPacer = ListingPacer.shared(for: target.account.id, interval: target.demo != nil ? .zero : .milliseconds(100))
        var pending: [(source: String, target: String?, path: String, key: String)] = [(plan.sourceFolderID, plan.targetFolderID, "", ".")]
        while !pending.isEmpty {
            try Task.checkCancellation()
            let folder = pending.removeFirst()
            let here = try await ListingRetry.run { try await sourcePacer.wait(); return try await source.list(parent: folder.source) }
            var there: [CloudFile] = []
            if let targetID = folder.target {
                there = try await ListingRetry.run { try await targetPacer.wait(); return try await target.list(parent: targetID) }
                // The folder of earlier versions lives inside the destination and is never part of the copy.
                if folder.path.isEmpty { there.removeAll { $0.name == BackupPlan.versionsFolder } }
            }
            for item in there { targetNodes.append(BackupNode(path: folder.path.isEmpty ? item.name : folder.path + "/" + item.name, file: item)) }
            for item in here {
                let path = folder.path.isEmpty ? item.name : folder.path + "/" + item.name
                let key = folder.key + "/" + item.id
                sourceNodes.append(BackupNode(path: path, file: item, key: key))
                guard item.isFolder else { continue }
                let match = there.first { $0.isFolder && $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame }
                pending.append((item.id, match?.id, path, key))
            }
        }
        return (sourceNodes, targetNodes)
    }

    func run(_ id: UUID) async {
        guard let plan = plans.first(where: { $0.id == id }), !preparing.contains(id), let queue, let client = queue.client else { return }
        if let active = plan.activeTransferID, let job = queue.items.first(where: { $0.id == active }), !job.finished {
            // Already copying: a paused job is resumed, a running one is left alone.
            if job.state == .paused { queue.retry(active) }
            return
        }
        attempted[id] = now()
        preparing.insert(id)
        defer { preparing.remove(id) }
        do {
            let source = try client(plan.sourceAccountID), target = try client(plan.targetAccountID)
            let (here, there) = try await snapshot(plan, source: source, target: target)
            guard let current = plans.first(where: { $0.id == id }), !current.paused else { return }
            let capabilities = target.account.capabilities
            let outcome = try BackupPlanner.plan(source: here, target: there, plan: current, targetCloud: target.account.cloud,
                                                 canMove: capabilities.move, allowMassRemoval: removalAllowed.remove(id) != nil)
            guard !outcome.nothingToDo else {
                update(id) { $0.lastRun = self.now(); $0.lastError = nil; $0.lastSummary = outcome.summary; $0.baseline = $0.baseline.merging(outcome.signatures) { _, new in new } }
                return
            }
            try await retire(outcome.retire, plan: current, api: target)
            guard outcome.copies + outcome.replaces > 0 else {
                // Only removals: there is nothing to copy, so the run ends here.
                update(id) {
                    $0.lastRun = self.now(); $0.lastError = nil; $0.lastSummary = outcome.summary
                    $0.baseline = $0.baseline.filter { path, _ in here.contains { $0.path == path } }
                }
                return
            }
            let root = CloudFile(id: current.sourceFolderID, name: current.title, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
            var job = Transfer(name: L("Copia · \(current.title)"), destination: current.targetName, accountID: current.sourceAccountID, direction: .transfer,
                               localURL: URL(fileURLWithPath: "/"), parent: current.targetFolderID, file: root)
            job.localURL = queue.scratchDirectory(for: job.id)
            job.targetAccountID = current.targetAccountID
            job.names = outcome.names
            job.folders = outcome.folders
            job.replacements = outcome.replacements
            job.completedPaths = outcome.completed
            try queue.add([job])
            update(id) { $0.activeTransferID = job.id; $0.pending = outcome.signatures; $0.lastError = nil; $0.lastSummary = outcome.summary }
        } catch is CancellationError {
        } catch {
            update(id) { $0.lastError = error.localizedDescription }
        }
    }

    /// Takes destination items out of the way: into the dated folder of earlier versions, under the same path they
    /// had, or to the provider's bin when versions are not kept.
    private func retire(_ nodes: [BackupNode], plan: BackupPlan, api: CloudAPI) async throws {
        guard !nodes.isEmpty else { return }
        guard plan.keepsVersions, api.account.capabilities.move else {
            for node in nodes { try await api.trash(file: node.file) }
            return
        }
        let formatter = DateFormatter(); formatter.dateFormat = Self.stampFormat
        var folders: [String: String] = [:]
        // One listing per folder that has to exist, so a second run in the same minute reuses what the first made.
        func folder(_ path: [String], under parent: String, trail: String) async throws -> String {
            guard let name = path.first else { return parent }
            let key = trail + "/" + name
            let id: String
            if let known = folders[key] { id = known }
            else if let existing = try await api.list(parent: parent).first(where: { $0.isFolder && $0.name == name }) { id = existing.id }
            else { id = try await api.createFolder(name: name, parent: parent) }
            folders[key] = id
            return try await folder(Array(path.dropFirst()), under: id, trail: key)
        }
        let stamp = formatter.string(from: now())
        for node in nodes {
            try Task.checkCancellation()
            let parents = node.path.split(separator: "/").dropLast().map(String.init)
            let destination = try await folder([BackupPlan.versionsFolder, stamp] + parents, under: plan.targetFolderID, trail: "")
            try await api.move(file: node.file, to: destination)
        }
    }

    /// Sends to the bin the dated folders of earlier versions that are older than the plan keeps them.
    func prune(_ plan: BackupPlan, api: CloudAPI) async {
        guard plan.keepsVersions, let days = plan.retentionDays, days > 0 else { return }
        let formatter = DateFormatter(); formatter.dateFormat = Self.stampFormat
        let limit = now().addingTimeInterval(-Double(days) * 86_400)
        guard let top = try? await api.list(parent: plan.targetFolderID),
              let versions = top.first(where: { $0.isFolder && $0.name == BackupPlan.versionsFolder }),
              let dated = try? await api.list(parent: versions.id) else { return }
        // Only folders named the way this app names them: anything else in there was put by a person.
        for folder in dated where folder.isFolder {
            guard let date = formatter.date(from: folder.name), date < limit else { continue }
            try? await api.trash(file: folder)
        }
    }

    /// Hooked to the queue's `didFinish`: the copy completed, so the baseline says so and old versions are pruned.
    func handleFinished(_ transfer: Transfer) {
        guard let index = plans.firstIndex(where: { $0.activeTransferID == transfer.id }) else { return }
        let failedKeys = transfer.report.filter { [.failed, .pending].contains($0.value.outcome) }
        plans[index].baseline = failedKeys.isEmpty ? plans[index].baseline.merging(plans[index].pending ?? [:]) { _, new in new } : plans[index].baseline
        plans[index].pending = nil
        plans[index].activeTransferID = nil
        plans[index].lastRun = now()
        plans[index].lastError = nil
        do { try persist() } catch { persistenceError = error.localizedDescription }
        let plan = plans[index]
        Task { [weak self] in
            guard let self, let api = try? self.queue?.client?(plan.targetAccountID) else { return }
            await self.prune(plan, api: api)
        }
    }
    private func noteFailures() {
        guard let queue else { return }
        for plan in plans {
            guard let active = plan.activeTransferID, let job = queue.items.first(where: { $0.id == active }), [.failed, .cancelled].contains(job.state) else { continue }
            update(plan.id) { $0.activeTransferID = nil; $0.pending = nil; $0.lastError = job.state == .failed ? job.detail : L("Copia cancelada") }
        }
    }

    private func update(_ id: UUID, _ change: (inout BackupPlan) -> Void) {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
        change(&plans[index])
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    private func persist() throws {
        do { try LocalStore.save(plans, to: storeURL); persistenceError = nil }
        catch { persistenceError = L("No se pudieron guardar las copias programadas: \(error.localizedDescription)"); throw error }
    }
}
