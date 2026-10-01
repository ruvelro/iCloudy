import Foundation

/// Something the plan found that will not travel as it is.
struct PlanIssue: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A Google document that leaves Drive converted, with this extension.
        case exported(String)
        /// A Google document inside a downloaded folder: saved as a `.webloc` link to it.
        case linked
        /// Forms, sites and shortcuts: nothing to export, left out.
        case omitted
        /// Never uploaded; the whole job fails on it.
        case symlink
        /// The destination provider refuses the name; the job stops there.
        case invalidName(String)
    }
    let path: String
    let kind: Kind
    var id: String { path + "|" + String(describing: kind) }
    /// Issues that stop the job they are in, as opposed to items that are converted or left out on purpose.
    var blocking: Bool {
        switch kind {
        case .symlink, .invalidName: return true
        default: return false
        }
    }
    var explanation: String {
        switch kind {
        case .exported(let ext): return L("Se exporta como .\(ext)")
        case .linked: return L("Se guarda como enlace .webloc al documento")
        case .omitted: return L("Se omite: Google no permite exportarlo")
        case .symlink: return L("Los enlaces simbólicos no se suben y hacen fallar su transferencia")
        case .invalidName(let reason): return reason
        }
    }
}

/// How far an enumeration has got, for the sheet that waits for it.
struct PlanProgress: Equatable {
    var files = 0
    var folders = 0
    var bytes: Int64 = 0
}

/// What a transfer is about to do, computed before it starts: how much, where it needs room, what is already at the
/// destination and what will not travel as it is.
struct TransferPlan {
    enum Kind { case upload, download, transfer }
    /// Beyond either of these the plan is shown before starting; below them it only seeds the report.
    static let fileThreshold = 20
    static let byteThreshold: Int64 = 500_000_000

    let kind: Kind
    var files = 0
    var folders = 0
    var bytes: Int64 = 0
    /// Files without a listed size, Google documents mostly: their bytes are not in `bytes`.
    var unknownSizes = 0
    var largestFile: Int64 = 0
    /// Paths that already exist at the destination; each will ask what to do when the job reaches it.
    var conflicts: [String] = []
    var issues: [PlanIssue] = []
    var localFree: Int64?
    /// Quota left at the destination, when the provider reports a total.
    var destinationFree: Int64?
    /// One report per top-level item, in order, with every file pending: the jobs start from these.
    var seeds: [[String: FileRecord]] = []

    init(kind: Kind) { self.kind = kind }

    /// Room needed on this Mac. A cross-cloud copy stages one file at a time, so it needs the largest of them; a
    /// download needs everything; an upload needs nothing.
    var localNeed: Int64 {
        switch kind {
        case .upload: return 0
        case .download: return bytes
        case .transfer: return largestFile
        }
    }
    var destinationNeed: Int64 { kind == .download ? 0 : bytes }
    var localShort: Bool { localNeed > 0 && (localFree.map { $0 < localNeed } ?? false) }
    var destinationShort: Bool { destinationNeed > 0 && (destinationFree.map { $0 < destinationNeed } ?? false) }
    var isLarge: Bool { files > Self.fileThreshold || bytes > Self.byteThreshold }
    /// Large, or not going to fit: either is worth a look before starting.
    var needsReview: Bool { isLarge || localShort || destinationShort }
    var blockingIssues: Int { issues.filter(\.blocking).count }
}

/// The enumerations behind a plan. Listings come in as closures, so they can be replaced in tests, and every step
/// checks for cancellation: a plan of a huge tree must be something the person can walk away from.
@MainActor
enum TransferPlanner {
    /// A selection that cannot be large: no folders, few items, known sizes under the threshold. Not worth a listing.
    static func trivial(_ files: [CloudFile]) -> Bool {
        !files.contains(where: \.isFolder) && files.count <= TransferPlan.fileThreshold
            && files.reduce(Int64(0)) { $0 + ($1.size ?? 0) } <= TransferPlan.byteThreshold
    }
    static func trivial(_ urls: [URL]) -> Bool {
        guard urls.count <= TransferPlan.fileThreshold else { return false }
        var total: Int64 = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory != true else { return false }
            total += Int64(values.fileSize ?? 0)
        }
        return total <= TransferPlan.byteThreshold
    }
    /// Free space for important data on the volume holding `url`, or its nearest existing ancestor.
    nonisolated static func freeSpace(at url: URL) -> Int64? {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.pathComponents.count > 1 { current.deleteLastPathComponent() }
        return (try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    static func remaining(_ quota: StorageQuota?) -> Int64? {
        guard let quota, let total = quota.total else { return nil }
        return max(0, total - quota.used)
    }

    // MARK: - Uploads

    /// Local items about to go to `cloud`. `existing` is the destination folder's listing.
    static func uploads(_ urls: [URL], to cloud: Cloud, existing: [CloudFile], quota: StorageQuota?,
                        progress: @escaping (PlanProgress) -> Void = { _ in }) async throws -> TransferPlan {
        var plan = TransferPlan(kind: .upload)
        plan.destinationFree = remaining(quota)
        plan.conflicts = urls.map(\.lastPathComponent).filter { name in existing.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        var tally = PlanProgress()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var seed: [String: FileRecord] = [:]
            let root = try await blockingIO { try LocalEntry(url) }
            try await walk(root, key: ".", path: root.name, cloud: cloud, plan: &plan, seed: &seed, tally: &tally, progress: progress)
            plan.seeds.append(seed)
        }
        progress(tally)
        return plan
    }
    /// One local item with what the walk needs to know, read off the main thread.
    struct LocalEntry: Sendable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: Int64
        nonisolated init(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            self.url = url; name = url.lastPathComponent
            isSymlink = values.isSymbolicLink == true
            isDirectory = !isSymlink && values.isDirectory == true
            size = Int64(values.fileSize ?? 0)
        }
        nonisolated func children() throws -> [LocalEntry] {
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                .sorted { $0.path < $1.path }.map(LocalEntry.init)
        }
    }
    private static func walk(_ entry: LocalEntry, key: String, path: String, cloud: Cloud, plan: inout TransferPlan, seed: inout [String: FileRecord],
                             tally: inout PlanProgress, progress: (PlanProgress) -> Void) async throws {
        try Task.checkCancellation()
        if entry.isSymlink { plan.issues.append(PlanIssue(path: path, kind: .symlink)); return }
        if let problem = FileNames.problem(with: entry.name, for: cloud) { plan.issues.append(PlanIssue(path: path, kind: .invalidName(problem))) }
        if entry.isDirectory {
            plan.folders += 1; tally.folders += 1
            progress(tally)
            let children = try await blockingIO { try entry.children() }
            for child in children {
                try await walk(child, key: key + "/" + child.name, path: path + "/" + child.name, cloud: cloud, plan: &plan, seed: &seed, tally: &tally, progress: progress)
            }
        } else {
            plan.files += 1; plan.bytes += entry.size; plan.largestFile = max(plan.largestFile, entry.size)
            tally.files += 1; tally.bytes += entry.size
            if tally.files % 50 == 0 { progress(tally) }
            seed[key] = FileRecord(path: path, outcome: .pending, bytes: entry.size)
        }
    }

    // MARK: - Remote sources

    /// Remote items about to be saved into `folder` on this Mac. `exporting` is the single-document export.
    static func downloads(_ files: [CloudFile], into folder: URL, exporting: Bool, list: @escaping (String) async throws -> [CloudFile],
                          localFree: Int64?, progress: @escaping (PlanProgress) -> Void = { _ in }) async throws -> TransferPlan {
        var plan = TransferPlan(kind: .download)
        plan.localFree = localFree
        var tally = PlanProgress()
        for file in files {
            var seed: [String: FileRecord] = [:]
            let local = folder.appendingPathComponent(FileNames.safe(file.name))
            try await walkRemote(file, key: ".", path: file.name, target: nil, exportsTopLevel: exporting, local: local,
                                 list: list, plan: &plan, seed: &seed, tally: &tally, progress: progress)
            plan.seeds.append(seed)
        }
        progress(tally)
        return plan
    }
    /// Remote items about to be copied to another account. `existing` is the destination folder's listing.
    static func crossCloud(_ files: [CloudFile], to cloud: Cloud, existing: [CloudFile], list: @escaping (String) async throws -> [CloudFile],
                           quota: StorageQuota?, localFree: Int64?, progress: @escaping (PlanProgress) -> Void = { _ in }) async throws -> TransferPlan {
        var plan = TransferPlan(kind: .transfer)
        plan.localFree = localFree
        plan.destinationFree = remaining(quota)
        var tally = PlanProgress()
        for file in files {
            var seed: [String: FileRecord] = [:]
            let name = file.crossCloudExport.map { file.name + "." + $0.ext } ?? file.name
            if existing.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) { plan.conflicts.append(name) }
            try await walkRemote(file, key: ".", path: file.name, target: cloud, exportsTopLevel: false, local: nil,
                                 list: list, plan: &plan, seed: &seed, tally: &tally, progress: progress)
            plan.seeds.append(seed)
        }
        progress(tally)
        return plan
    }
    /// `target` is the destination cloud of a cross-cloud copy, nil for a download. `local` is where a download puts
    /// this item, looked at to find what is already there.
    private static func walkRemote(_ file: CloudFile, key: String, path: String, target: Cloud?, exportsTopLevel: Bool, local: URL?,
                                   list: (String) async throws -> [CloudFile], plan: inout TransferPlan, seed: inout [String: FileRecord],
                                   tally: inout PlanProgress, progress: (PlanProgress) -> Void) async throws {
        try Task.checkCancellation()
        var localName = file.name
        if file.isGoogleDocument {
            if target != nil {
                guard let export = file.crossCloudExport else {
                    plan.issues.append(PlanIssue(path: path, kind: .omitted))
                    seed[key] = FileRecord(path: path, outcome: .pending)
                    return
                }
                localName = file.name + "." + export.ext
                plan.issues.append(PlanIssue(path: path, kind: .exported(export.ext)))
            } else if key == "." && exportsTopLevel {
                // Exporting is what was asked for; nothing to warn about.
            } else {
                localName = file.name + ".webloc"
                plan.issues.append(PlanIssue(path: path, kind: .linked))
            }
        }
        if let target, let problem = FileNames.problem(with: localName, for: target) {
            plan.issues.append(PlanIssue(path: path, kind: .invalidName(problem)))
        }
        // A download merges into what is already on the Mac; every clash below the top asks too.
        var here = local
        if file.isGoogleDocument, let local, !(key == "." && exportsTopLevel) { here = local.deletingLastPathComponent().appendingPathComponent(FileNames.safe(localName)) }
        if let here, (key != "." || !exportsTopLevel), FileManager.default.fileExists(atPath: here.path) {
            plan.conflicts.append(path)
        }
        if file.isFolder {
            plan.folders += 1; tally.folders += 1
            progress(tally)
            let children = try await list(file.id)
            for child in children {
                try await walkRemote(child, key: key + "/" + child.id, path: path + "/" + child.name, target: target, exportsTopLevel: false,
                                     local: here.map { $0.appendingPathComponent(FileNames.safe(child.name)) },
                                     list: list, plan: &plan, seed: &seed, tally: &tally, progress: progress)
            }
        } else {
            plan.files += 1; tally.files += 1
            if let size = file.size, !file.isGoogleDocument {
                plan.bytes += size; tally.bytes += size; plan.largestFile = max(plan.largestFile, size)
            } else { plan.unknownSizes += 1 }
            if tally.files % 50 == 0 { progress(tally) }
            seed[key] = FileRecord(path: path, outcome: .pending, bytes: file.isGoogleDocument ? nil : file.size)
        }
    }
}
