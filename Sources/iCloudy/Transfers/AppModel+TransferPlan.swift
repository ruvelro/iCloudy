import Foundation
import Combine

/// Drives the plan sheet: counts in the background, shows itself only when counting takes a moment or the result
/// deserves a look, and starts the transfer with the plan's seeds once the person agrees.
@MainActor
final class TransferPlanCoordinator: ObservableObject {
    struct Session: Identifiable {
        let id = UUID()
        let title: String
        var progress = PlanProgress()
        var plan: TransferPlan?
        var error: String?
        /// False while a small enumeration may still finish unseen.
        var shown = false
    }
    @Published private(set) var session: Session?
    /// A plan that is still counting after this long shows its progress, so a slow listing is never silent.
    var revealDelay: Duration = .milliseconds(400)
    private var task: Task<Void, Never>?
    private var start: ((TransferPlan?) -> Void)?

    static var enabled: Bool { Prefs.bool(Prefs.transferPlan, default: true) }

    /// `compute` receives a progress callback; `start` receives the plan, or nil when the person chose to go ahead
    /// without one after the enumeration failed.
    func begin(title: String, compute: @escaping (@escaping (PlanProgress) -> Void) async throws -> TransferPlan,
               start: @escaping (TransferPlan?) -> Void) {
        cancel()
        let session = Session(title: title)
        let id = session.id
        self.session = session
        self.start = start
        let delay = revealDelay
        task = Task { [weak self] in
            let reveal = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.session?.id == id else { return }
                self.session?.shown = true
            }
            defer { reveal.cancel() }
            do {
                let plan = try await compute { progress in
                    guard let self, self.session?.id == id else { return }
                    self.session?.progress = progress
                }
                guard let self, !Task.isCancelled, self.session?.id == id else { return }
                if plan.needsReview { self.session?.plan = plan; self.session?.shown = true }
                else { self.finish(with: plan) }
            } catch {
                guard let self, !Task.isCancelled, self.session?.id == id else { return }
                self.session?.error = error.localizedDescription
                self.session?.shown = true
            }
        }
    }
    func confirm(dontAskAgain: Bool) {
        if dontAskAgain { UserDefaults.standard.set(false, forKey: Prefs.transferPlan) }
        finish(with: session?.plan)
    }
    /// After a failed enumeration: the transfer is still possible, just without a plan to seed its report.
    func startWithoutPlan() { finish(with: nil) }
    /// Stops the enumeration; nothing is queued.
    func cancel() {
        task?.cancel(); task = nil
        session = nil; start = nil
    }
    private func finish(with plan: TransferPlan?) {
        let start = self.start
        task = nil; session = nil; self.start = nil
        start?(plan)
    }
}

extension Transfer {
    /// Starts a job from its plan: every file pending, so a report of a job that stops early still lists them all.
    mutating func seed(_ records: [String: FileRecord]?) {
        guard let records else { return }
        report = records
        planned = true
    }
}

extension AppModel {
    /// Uploads started by the person in the window go through the plan; Services, Shortcuts and the Dock keep
    /// `enqueueUploads`, because nobody is looking at the window to answer a sheet.
    @discardableResult func planUploads(_ urls: [URL], target: (Account, String, String)? = nil) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard let account = target?.0 ?? account, target != nil || canWrite else { return enqueueUploads(urls, target: target) }
        let parent = target?.1 ?? folderID, destination = target?.2 ?? location
        guard TransferPlanCoordinator.enabled, !TransferPlanner.trivial(urls), let api = try? client(account) else {
            return enqueueUploads(urls, target: (account, parent, destination))
        }
        planner.begin(title: urls.count == 1 ? L("Subir «\(urls[0].lastPathComponent)»") : L("Subir \(urls.count) elementos"), compute: { [weak self] progress in
            let existing = try await api.list(parent: parent)
            let quota = await self?.destinationQuota(account, api: api)
            return try await TransferPlanner.uploads(urls, to: account.cloud, existing: existing, quota: quota, progress: progress)
        }, start: { [weak self] plan in
            self?.enqueueUploads(urls, target: (account, parent, destination), seeds: plan?.seeds)
        })
        return true
    }

    /// Downloads chosen in the window, once the destination folder is known.
    func planDownloads(_ files: [CloudFile], account: Account, folder: URL, export: (mime: String, ext: String)?, start: @escaping ([[String: FileRecord]]?) -> Void) {
        guard TransferPlanCoordinator.enabled, !TransferPlanner.trivial(files), let api = try? client(account) else { return start(nil) }
        planner.begin(title: files.count == 1 ? L("Descargar «\(files[0].name)»") : L("Descargar \(files.count) elementos"), compute: { progress in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            return try await TransferPlanner.downloads(files, into: folder, exporting: export != nil, list: { try await api.list(parent: $0) },
                                                       localFree: TransferPlanner.freeSpace(at: folder), progress: progress)
        }, start: { plan in start(plan?.seeds) })
    }

    /// Cross-cloud copies, once the destination folder is chosen.
    func planCrossCloud(_ files: [CloudFile], from source: Account, to target: Account, parent: String, start: @escaping ([[String: FileRecord]]?) -> Void) {
        guard TransferPlanCoordinator.enabled, !TransferPlanner.trivial(files), let from = try? client(source), let to = try? client(target) else { return start(nil) }
        let scratch = queue.scratchRoot
        planner.begin(title: files.count == 1 ? L("Enviar «\(files[0].name)» a \(accountTitle(target))") : L("Enviar \(files.count) elementos a \(accountTitle(target))"), compute: { [weak self] progress in
            let existing = try await to.list(parent: parent)
            let quota = await self?.destinationQuota(target, api: to)
            return try await TransferPlanner.crossCloud(files, to: target.cloud, existing: existing, list: { try await from.list(parent: $0) },
                                                        quota: quota, localFree: TransferPlanner.freeSpace(at: scratch), progress: progress)
        }, start: { plan in start(plan?.seeds) })
    }

    /// The last known quota when there is one, asked for otherwise. A provider without quotas has no answer.
    func destinationQuota(_ account: Account, api: CloudAPI) async -> StorageQuota? {
        if case .available(let quota) = quotas.states[account.id] { return quota }
        guard account.capabilities.quota else { return nil }
        return try? await api.storageQuota()
    }
}
