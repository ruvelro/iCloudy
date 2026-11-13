import Foundation

/// A two-way sync between two cloud folders, possibly of two accounts, against a baseline like a Mac-to-cloud sync.
/// The first folder plays the planner's "local" side: its items become stamps of size and date, and the same
/// `TwoWayPlanner` decides. Every file that moves is staged on this Mac, in the queue's scratch folder, one at a
/// time, and the stage is deleted at once. Experimental: copies are whole files, not resumed if cut short, and the
/// run is not a queue job, so it has no per-file report; it does reach the history.
@MainActor
final class CloudPairEngine {
    let first: CloudAPI, second: CloudAPI
    let firstRoot: String, secondRoot: String
    let scratch: URL
    private(set) var baseline: [String: SyncEntry]
    private(set) var report = SyncReport()
    var exclusions: SyncExclusionMatcher = .none
    var allowMassDeletion = false
    var conflictPolicy: ConflictPolicy = .keepBoth
    var decisions: [String: ConflictPolicy] = [:]
    private(set) var resolvedConflicts: Set<String> = []
    private(set) var unresolvedConflicts: [String] = []
    var persist: (([String: SyncEntry]) throws -> Void)?
    var shouldStop: (() -> Bool)?

    init(first: CloudAPI, firstRoot: String, second: CloudAPI, secondRoot: String, scratch: URL, baseline: [String: SyncEntry]) {
        self.first = first; self.firstRoot = firstRoot; self.second = second; self.secondRoot = secondRoot
        self.scratch = scratch; self.baseline = baseline
    }

    /// A first-folder item as the planner's local side sees it.
    nonisolated static func stamp(_ file: CloudFile) -> FileStamp {
        file.isFolder ? FileStamp(size: -1, modified: Date(timeIntervalSince1970: 0))
                      : FileStamp(size: file.size ?? 0, modified: file.modified ?? .distantPast)
    }

    private func snapshots() async throws -> (RemoteTree.Snapshot, RemoteTree.Snapshot) {
        (try await RemoteTree.snapshot(first, root: firstRoot, exclusions: exclusions),
         try await RemoteTree.snapshot(second, root: secondRoot, exclusions: exclusions))
    }
    /// Same bytes on both sides by the two listed checksums, where both list one in the same algorithm.
    private func contents(_ a: [String: CloudFile], _ b: [String: CloudFile]) -> ContentComparison.Result {
        var result = ContentComparison.Result()
        for (path, x) in a where !x.isFolder {
            guard let y = b[path], let cx = x.checksum, let cy = y.checksum, cx.algorithm == cy.algorithm else { continue }
            if cx.matches(cy.value) { result.identical.insert(path) } else { result.different.insert(path) }
        }
        return result
    }

    func preview() async throws -> MirrorPreview {
        let (a, b) = try await snapshots()
        let local = a.files.mapValues(Self.stamp)
        var refused: String?
        let actions: [SyncAction]
        do { actions = try TwoWayPlanner.plan(local: local, remote: b.files, baseline: baseline, allowMassDeletion: allowMassDeletion, exclusions: exclusions, contents: contents(a.files, b.files)) }
        catch let error as MassDeletionRefused {
            refused = error.localizedDescription
            actions = try TwoWayPlanner.plan(local: local, remote: b.files, baseline: baseline, allowMassDeletion: true, exclusions: exclusions, contents: contents(a.files, b.files))
        }
        return .twoWay(actions: actions, local: local, excluded: TwoWayPlanner.excludedItems(local: local, remote: b.files, exclusions: exclusions), massDeletion: refused)
    }

    func run() async throws -> SyncReport {
        report = SyncReport(); resolvedConflicts = []; unresolvedConflicts = []
        var (a, b) = try await snapshots()
        let local = a.files.mapValues(Self.stamp)
        let plan = try TwoWayPlanner.plan(local: local, remote: b.files, baseline: baseline, allowMassDeletion: allowMassDeletion,
                                          exclusions: exclusions, contents: contents(a.files, b.files))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var touched: Set<String> = []
        var stopped = false
        for action in plan {
            try Task.checkCancellation()
            if shouldStop?() == true { stopped = true; break }
            switch action {
            case .createRemoteFolder(let path):
                let id = try await second.createFolder(name: name(path), parent: try parent(path, b.folders))
                b.folders[path] = id
                baseline[path] = SyncEntry(local: Self.stamp(a.files[path]!), remoteID: id, isFolder: true)
            case .createLocalFolder(let path):
                let id = try await first.createFolder(name: name(path), parent: try parent(path, a.folders))
                a.folders[path] = id
                baseline[path] = SyncEntry(local: FileStamp(size: -1, modified: Date(timeIntervalSince1970: 0)), remoteID: b.files[path]?.id, isFolder: true)
            case .upload(let path, let replacing):
                guard let file = a.files[path] else { continue }
                try await copy(file, from: first, to: second, parent: try parent(path, b.folders), name: name(path), replacing: replacing)
                touched.insert(path); report.uploaded += 1; report.bytes += file.size ?? 0
            case .download(let path, let file):
                try await copy(file, from: second, to: first, parent: try parent(path, a.folders), name: name(path), replacing: a.files[path]?.id)
                touched.insert(path); report.downloaded += 1; report.bytes += file.size ?? 0
            case .adopt(let path, let file):
                baseline[path] = SyncEntry(local: local[path], remoteID: file.id, remoteSize: file.size, remoteModified: file.modified, isFolder: false)
            case .deleteRemote(let path, let file):
                try await second.trash(file: file)
                forgetBelow(path); report.deletedRemote += 1
            case .deleteLocal(let path):
                if let file = a.files[path] { try await first.trash(file: file) }
                forgetBelow(path); report.deletedLocal += 1
            case .conflict(let path, let file):
                guard let mine = a.files[path] else { continue }
                switch TwoWaySyncEngine.resolution(of: decisions[path] ?? conflictPolicy, local: local[path], remote: file) {
                case .undecided:
                    unresolvedConflicts.append(path); report.unresolved += 1
                    continue
                case .local:
                    try await copy(mine, from: first, to: second, parent: try parent(path, b.folders), name: name(path), replacing: file.id)
                case .remote:
                    try await copy(file, from: second, to: first, parent: try parent(path, a.folders), name: name(path), replacing: mine.id)
                case .both:
                    // The first folder's version moves aside under a conflict name, the second's takes its place, and
                    // the renamed one is copied over, so both folders end with both versions.
                    let renamed = TwoWaySyncEngine.conflictName(for: path, host: first.account.cloud.title)
                    try await first.rename(file: mine, name: name(renamed))
                    try await copy(file, from: second, to: first, parent: try parent(path, a.folders), name: name(path), replacing: nil)
                    let moved = CloudFile(id: mine.id, name: name(renamed), mime: mine.mime, size: mine.size, modified: mine.modified, webURL: nil, isFolder: false)
                    try await copy(moved, from: first, to: second, parent: try parent(renamed, b.folders), name: name(renamed), replacing: nil)
                    touched.insert(renamed)
                }
                touched.insert(path); resolvedConflicts.insert(path); report.conflicts += 1
            case .forget(let path):
                baseline[path] = nil
            }
            try persist?(baseline)
        }
        // Copies leave dates unknown on the side they landed on; a fresh listing of both fills them in, so the next
        // run sees them unchanged.
        if !touched.isEmpty {
            (a, b) = try await snapshots()
            for path in touched {
                guard let x = a.files[path], let y = b.files[path] else { continue }
                baseline[path] = SyncEntry(local: Self.stamp(x), remoteID: y.id, remoteSize: y.size, remoteModified: y.modified, isFolder: false)
            }
            try persist?(baseline)
        }
        if stopped { throw SyncPaused() }
        return report
    }

    /// Downloads one file to the scratch folder, checked as every download is, and uploads it.
    private func copy(_ file: CloudFile, from source: CloudAPI, to target: CloudAPI, parent: String, name: String, replacing: String?) async throws {
        let staged = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await source.download(file: file, to: staged)
        _ = try await target.resumableUpload(local: staged, parent: parent, name: name, replacing: replacing, checkpoint: nil, save: { _ in }, progress: { _, _ in })
    }
    private func forgetBelow(_ path: String) { baseline = baseline.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
    private func name(_ path: String) -> String { String(path.split(separator: "/").last ?? Substring(path)) }
    private func parent(_ path: String, _ folders: [String: String]) throws -> String {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        guard let id = folders[parent] else { throw CloudError.message(L("Falta la carpeta remota «\(parent)»; vuelve a sincronizar.")) }
        return id
    }
}

extension MirrorManager {
    /// Pairs two cloud folders in a two-way sync. Experimental; see `CloudPairEngine`.
    func addPair(first: Account, firstFolder: String, firstName: String, second: Account, secondFolder: String, secondName: String) throws {
        guard !(first.id == second.id && firstFolder == secondFolder) else { throw CloudError.message(L("Elige dos carpetas distintas.")) }
        guard !mirrors.contains(where: { $0.mode == .cloudPair && $0.accountID == first.id && $0.remoteFolderID == firstFolder && $0.peerFolderID == secondFolder }) else {
            throw CloudError.message(L("Esas dos carpetas ya se sincronizan."))
        }
        let id = UUID()
        let scratch = (queue?.scratchRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent("pair-" + id.uuidString, isDirectory: true)
        var mirror = FolderMirror(id: id, accountID: first.id, remoteFolderID: firstFolder, remoteName: secondName, localURL: scratch)
        mirror.mode = .cloudPair
        mirror.peerAccountID = second.id; mirror.peerFolderID = secondFolder; mirror.peerName = firstName
        mirrors.append(mirror)
        persist(id)
        scheduleSync(id, immediate: true)
    }

    func makePairEngine(_ mirror: FolderMirror) throws -> CloudPairEngine {
        guard let lookup = queue?.client, let peer = mirror.peerAccountID, let peerFolder = mirror.peerFolderID else {
            throw CloudError.message(L("Vuelve a conectar las cuentas de esta sincronización."))
        }
        let engine = CloudPairEngine(first: try lookup(mirror.accountID), firstRoot: mirror.remoteFolderID, second: try lookup(peer),
                                     secondRoot: peerFolder, scratch: mirror.localURL, baseline: mirror.baseline)
        engine.exclusions = exclusions(of: mirror)
        engine.conflictPolicy = mirror.conflictPolicy
        engine.decisions = mirror.conflictDecisions
        return engine
    }

    /// One run of a pair, like a two-way run: one at a time, the baseline written as it goes, through the queue's
    /// bandwidth buckets, and recorded in the history when something moved.
    func syncPair(_ id: UUID) async {
        guard !running.contains(id) else { dirty.insert(id); return }
        guard let mirror = mirrors.first(where: { $0.id == id }) else { return }
        pending.remove(id); running.insert(id)
        defer { running.remove(id) }
        do {
            let engine = try makePairEngine(mirror)
            engine.shouldStop = { [weak self] in self?.isPaused(id) ?? true }
            engine.allowMassDeletion = massDeletionAllowed.remove(id) != nil
            engine.persist = { [weak self] baseline in
                guard let self, let position = self.mirrors.firstIndex(where: { $0.id == id }) else { return }
                self.mirrors[position].baseline = baseline
                self.persistSoon(id)
            }
            let throttle = queue?.throttle(upload: mirror.peerAccountID, download: mirror.accountID)
            let report = try await TransferThrottle.$active.withValue(throttle) { try await engine.run() }
            guard let position = mirrors.firstIndex(where: { $0.id == id }) else { return }
            mirrors[position].baseline = engine.baseline
            mirrors[position].lastReport = report
            for path in engine.resolvedConflicts { mirrors[position].conflictDecisions[path] = nil }
            mirrors[position].unresolvedConflicts = engine.unresolvedConflicts
            mirrors[position].lastSync = Date(); mirrors[position].lastError = nil
            persist(id)
            if report.bytes > 0 || !report.isEmpty { didRecordRun?(mirrors[position].historyRecord(report)) }
        } catch {
            if let position = mirrors.firstIndex(where: { $0.id == id }) {
                if error is SyncPaused { mirrors[position].lastError = nil }
                else { mirrors[position].lastError = (error as? CancellationError) == nil ? error.localizedDescription : L("Sincronización cancelada") }
                persist(id)
            }
        }
        if dirty.remove(id) != nil { scheduleSync(id, immediate: true) }
    }
}

extension FolderMirror {
    /// A finished run that is not a queue job, as the history keeps one.
    func historyRecord(_ report: SyncReport) -> Transfer {
        var transfer = Transfer(name: L("Sincronización · \(mode == .cloudPair ? (peerName ?? remoteName) : localURL.lastPathComponent)"),
                                destination: remoteName, accountID: accountID, direction: mode == .cloudPair ? .transfer : .upload,
                                localURL: localURL, parent: mode == .cloudPair ? (peerFolderID ?? remoteFolderID) : remoteFolderID)
        transfer.targetAccountID = mode == .cloudPair ? peerAccountID : nil
        transfer.state = .completed
        transfer.bytes = report.bytes
        transfer.detail = report.summary
        return transfer
    }
}
