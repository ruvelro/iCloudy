import Foundation

/// What a download mirror's next run does: which files of the cloud folder come down, which local copies are replaced
/// without asking because this mirror wrote them and nobody touched them since, and which clash with a local change.
/// Pure, so the run and its dry run decide in the same place.
struct DownloadMirrorPlan {
    /// Tree keys ("./id/id") the queue's walk skips: unchanged files and folders with nothing new inside.
    var completed: Set<String> = []
    /// The local name of every planned key, so the report and "Verificar lo copiado" can find each file.
    var names: [String: String] = [:]
    /// Keys whose local copy is this mirror's own and unchanged: replaced without asking.
    var owned: Set<String> = []
    /// Relative paths that come down.
    var downloads: [String] = []
    /// Relative paths where both sides changed: settled by the policy, or asked.
    var conflicts: [String] = []
    /// Local copies that already match the cloud on a first sync: taken as this mirror's own.
    var adopt: [String: SyncEntry] = [:]
    /// Baseline entries whose remote file is gone; the local copy stays.
    var forget: [String] = []
    /// Relative path of every key the job may complete, and the remote side each one had when planned.
    var keys: [String: String] = [:]
    var remote: [String: SyncEntry] = [:]
    /// Exact mirrors only: local copies edited here that come back from the cloud. The edited version goes to the
    /// Trash first, so the download replaces nothing.
    var restore: [String] = []
    /// Exact mirrors only: what the cloud no longer has and this mirror put here, to the Trash.
    var trash: [String] = []
    var trashFolders: [String] = []
    /// Excluded or filtered items, outermost first, for the dry run.
    var excluded: [(path: String, isFolder: Bool)] = []
    var nothingToDo: Bool { downloads.isEmpty && conflicts.isEmpty }
}

enum DownloadMirrorPlanner {
    /// `local` is the scan of the mirror's folder (everything, excluded items included), `remote` the cloud folder by
    /// relative path and `keys` the queue's tree key of each remote path.
    static func plan(local: [String: FileStamp], remote: [String: CloudFile], keys: [String: String], baseline: [String: SyncEntry],
                     exclusions: SyncExclusionMatcher, exact: Bool = false, now: Date = Date()) -> DownloadMirrorPlan {
        var plan = DownloadMirrorPlan()
        let filtered = TwoWayPlanner.filteredFiles(local: local, remote: remote, exclusions: exclusions, now: now)
        func excluded(_ path: String, _ folder: Bool) -> Bool { exclusions.excludes(path, isFolder: folder) || filtered.contains(path) }
        var travelling: [String] = []
        for (path, file) in remote {
            guard let key = keys[path] else { continue }
            let name = FileNames.safe(file.name)
            plan.names[key] = name
            // Google documents have no bytes to mirror: a link would never match the cloud, and an export is another
            // document. They are left out, like an excluded file.
            if excluded(path, file.isFolder) || file.isGoogleDocument {
                plan.completed.insert(key)
                continue
            }
            if file.isFolder { continue }
            let l = local[path], b = baseline[path]
            let entry = SyncEntry(local: nil, remoteID: file.id, remoteSize: file.size, remoteModified: file.modified, isFolder: false)
            plan.remote[path] = entry
            let remoteChanged = SyncEntry.signature(file) != b?.remoteSignature
            if !remoteChanged {
                // Unchanged in the cloud. A local edit or deletion of a mirrored file is the Mac's business, unless the
                // mirror is exact: then the folder is put back as the cloud has it.
                if exact, let b, l != b.local {
                    plan.keys[key] = path; plan.downloads.append(path); travelling.append(path)
                    if l != nil { plan.restore.append(path) }
                } else {
                    plan.completed.insert(key)
                }
                continue
            }
            plan.keys[key] = path
            switch (l, b) {
            case (nil, _):
                plan.downloads.append(path); travelling.append(path)
            case (let l?, let b?) where l == b.local:
                plan.owned.insert(key); plan.downloads.append(path); travelling.append(path)
            case (let l?, nil) where l.size == file.size:
                // A first sync into a folder that already has the same file: taken as the same rather than doubled.
                var adopted = entry; adopted.local = l
                plan.adopt[path] = adopted
                plan.completed.insert(key)
                plan.keys[key] = nil
            default:
                plan.conflicts.append(path); travelling.append(path)
            }
        }
        // A folder is skipped as a whole only when it already exists here and nothing below it travels.
        for (path, file) in remote where file.isFolder {
            guard let key = keys[path], !plan.completed.contains(key) else { continue }
            if local[path]?.size == -1, !travelling.contains(where: { $0.hasPrefix(path + "/") }) { plan.completed.insert(key) }
        }
        for (path, entry) in baseline where remote[path] == nil && !entry.isFolder && !excluded(path, false) { plan.forget.append(path) }
        if exact {
            (plan.trash, plan.trashFolders) = ExactMirrorPlanner.localDeletions(local: local, remote: remote, baseline: baseline, exclusions: exclusions, now: now)
        }
        plan.excluded = TwoWayPlanner.excludedItems(local: [:], remote: remote, exclusions: exclusions, now: now)
        plan.downloads.sort(); plan.conflicts.sort(); plan.forget.sort()
        return plan
    }
}

/// The remote side of a mirror: every item below its folder by relative path, with the queue's tree key of each.
enum RemoteTree {
    struct Snapshot {
        var files: [String: CloudFile] = [:]
        /// Relative path → tree key, as a download job keys its items ("./id/id").
        var keys: [String: String] = [:]
        /// Relative path → remote folder id, "" being the root.
        var folders: [String: String] = [:]
    }
    /// Lists the tree breadth first. An excluded folder is listed so the planners know it is there, but nobody needs
    /// what is inside it.
    @MainActor
    static func snapshot(_ api: CloudAPI, root: String, exclusions: SyncExclusionMatcher) async throws -> Snapshot {
        var snapshot = Snapshot()
        snapshot.folders[""] = root
        var queue: [(id: String, path: String, key: String)] = [(root, "", ".")]
        while !queue.isEmpty {
            let (id, prefix, parentKey) = queue.removeFirst()
            try Task.checkCancellation()
            for item in try await api.list(parent: id) {
                let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
                let key = parentKey + "/" + item.id
                snapshot.files[path] = item
                snapshot.keys[path] = key
                if item.isFolder, !exclusions.excludes(path, isFolder: true) {
                    snapshot.folders[path] = item.id
                    queue.append((item.id, path, key))
                }
            }
        }
        return snapshot
    }
}

extension MirrorManager {
    /// One run of a download mirror: list the cloud folder, plan against the baseline, and hand the queue one
    /// download job with everything unchanged marked done. The baseline follows the job as it completes.
    func syncDownload(_ id: UUID) async {
        guard let index = mirrors.firstIndex(where: { $0.id == id }), let queue else { return }
        if let active = mirrors[index].activeTransferID, let item = queue.items.first(where: { $0.id == active }) {
            if [.queued, .running].contains(item.state) { dirty.insert(id); return }
            // Closed halfway: carry on with the job already planned rather than plan a second one beside it.
            if item.state == .paused, mirrors[index].pendingKeys != nil { queue.retry(active); dirty.insert(id); pending.remove(id); return }
            if item.state == .paused { queue.cancel(active) }
        }
        pending.remove(id)
        let mirror = mirrors[index]
        let url = resolvedURL(mirror)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw CloudError.message(L("La carpeta local ya no existe en \(url.path).")) }
            let (plan, snapshot, scan) = try await downloadPlan(mirror, url: url)
            if mirror.options.exact {
                let localFiles = scan.stamps.values.filter { $0.size != -1 }.count
                try ExactMirrorPlanner.checkMassDeletion(plan.trash.count, of: localFiles, side: L("la carpeta del Mac"), allowed: massDeletionAllowed.remove(id) != nil)
            }
            let rules = exclusions(of: mirror)
            _ = try trashLocal(plan.restore, folders: [], in: url, rules: rules)
            let deleted = try trashLocal(plan.trash, folders: plan.trashFolders, in: url, rules: rules)
            guard let position = mirrors.firstIndex(where: { $0.id == id }) else { return }
            var report = SyncReport(); report.deletedLocal = deleted
            mirrors[position].lastReport = report
            for (path, entry) in plan.adopt { mirrors[position].baseline[path] = entry }
            for path in plan.forget { mirrors[position].baseline[path] = nil }
            if plan.nothingToDo {
                mirrors[position].lastSync = Date(); mirrors[position].lastError = nil
                persist(id); return
            }
            let root = CloudFile(id: mirror.remoteFolderID, name: url.lastPathComponent, mime: "application/vnd.google-apps.folder",
                                 size: nil, modified: nil, webURL: nil, isFolder: true)
            var job = Transfer(batchID: UUID(), name: L("Reflejo · \(url.lastPathComponent)"), destination: url.path, accountID: mirror.accountID,
                               direction: .download, localURL: url, bookmark: mirror.bookmark, file: root)
            job.options = TransferOptions(conflictPolicy: mirror.transferPolicy, exclusions: mirror.exclusions, contentsOnly: true)
            job.names = plan.names
            job.names["."] = url.lastPathComponent
            for key in plan.owned { job.replacements[key] = "local" }
            job.completedPaths = plan.completed
            // The report lists every file that travels, reached or not, under the folder's own name like a download.
            var seed: [String: FileRecord] = [:]
            for (key, path) in plan.keys { seed[key] = FileRecord(path: url.lastPathComponent + "/" + path, outcome: .pending, bytes: snapshot.files[path]?.size) }
            job.seed(seed)
            try queue.add([job])
            mirrors[position].activeTransferID = job.id
            mirrors[position].pendingKeys = plan.keys
            mirrors[position].pendingRemote = plan.remote
            mirrors[position].lastError = nil
            persist(id)
        } catch {
            if let position = mirrors.firstIndex(where: { $0.id == id }) { mirrors[position].lastError = error.localizedDescription; persist(id) }
        }
    }

    /// The scan, the listing and the plan, shared by the run and its dry run.
    func downloadPlan(_ mirror: FolderMirror, url: URL) async throws -> (DownloadMirrorPlan, RemoteTree.Snapshot, MirrorPlanner.LocalScan) {
        guard let api = try queue?.client?(mirror.accountID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de este reflejo.")) }
        let rules = exclusions(of: mirror)
        let scan = try await blockingIO { try MirrorPlanner.scan(url, exclusions: rules) }
        let snapshot = try await RemoteTree.snapshot(api, root: mirror.remoteFolderID, exclusions: rules)
        let plan = DownloadMirrorPlanner.plan(local: scan.all, remote: snapshot.files, keys: snapshot.keys, baseline: mirror.baseline,
                                              exclusions: rules, exact: mirror.options.exact)
        return (plan, snapshot, scan)
    }

    /// What a download job completed becomes this mirror's own: its baseline entry says what the cloud had and what
    /// the copy here looks like now. Called when the job ends, however it ends, so a failed run keeps what it did.
    func absorbDownload(_ transfer: Transfer, at index: Int) {
        guard let keys = mirrors[index].pendingKeys, let planned = mirrors[index].pendingRemote else { return }
        let url = resolvedURL(mirrors[index])
        let stamps = (try? MirrorPlanner.scan(url, exclusions: exclusions(of: mirrors[index])).all) ?? [:]
        var report = mirrors[index].lastReport ?? SyncReport()
        for (key, path) in keys where transfer.completedPaths.contains(key) {
            guard var entry = planned[path] else { continue }
            entry.local = stamps[path]
            mirrors[index].baseline[path] = entry
            if transfer.report[key]?.outcome.isCopied == true { report.downloaded += 1; report.bytes += entry.remoteSize ?? 0 }
        }
        mirrors[index].lastReport = report
        mirrors[index].pendingKeys = nil
        mirrors[index].pendingRemote = nil
    }

    /// The dry run of a download mirror.
    func previewDownload(_ mirror: FolderMirror) async throws -> MirrorPreview {
        let url = resolvedURL(mirror)
        let (plan, _, scan) = try await downloadPlan(mirror, url: url)
        var preview = MirrorPreview(oneWay: true)
        if mirror.options.exact {
            let localFiles = scan.stamps.values.filter { $0.size != -1 }.count
            do { try ExactMirrorPlanner.checkMassDeletion(plan.trash.count, of: localFiles, side: L("la carpeta del Mac"), allowed: massDeletionAllowed.contains(mirror.id)) }
            catch { preview.massDeletion = error.localizedDescription }
        }
        preview.changes = plan.downloads.map { PendingChange(kind: .download, path: $0, isFolder: false) }
            + (plan.restore + plan.trash).map { PendingChange(kind: .trashLocal, path: $0, isFolder: false) }
            + plan.trashFolders.map { PendingChange(kind: .trashLocal, path: $0, isFolder: true) }
            + plan.conflicts.map { PendingChange(kind: .conflict, path: $0, isFolder: false) }
            + plan.excluded.map { PendingChange(kind: .excluded, path: $0.path, isFolder: $0.isFolder) }
        preview.changes.sort { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
        if let active = mirror.activeTransferID, let item = queue?.items.first(where: { $0.id == active }), mirror.pendingKeys != nil,
           [.queued, .running, .paused].contains(item.state) {
            preview.resumesQueuedUpload = true
        }
        return preview
    }
}
