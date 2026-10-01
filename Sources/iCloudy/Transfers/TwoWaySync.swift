import Foundation

/// What both sides looked like the last time they agreed, per relative path. Every decision below is a three-way
/// comparison against this: a side that still matches its baseline entry has not changed, whatever the other did.
struct SyncEntry: Codable, Equatable {
    var local: FileStamp?
    var remoteID: String?
    var remoteSize: Int64?
    var remoteModified: Date?
    var isFolder: Bool
    /// The remote side as a comparable value. Ids are stable on the OAuth clouds and are the path on the rest;
    /// size and date catch a file replaced under the same id.
    var remoteSignature: String? {
        guard let remoteID else { return nil }
        return remoteID + "|" + String(remoteSize ?? -1) + "|" + String(remoteModified?.timeIntervalSince1970 ?? 0)
    }
    static func signature(_ file: CloudFile) -> String {
        file.id + "|" + String(file.isFolder ? -1 : (file.size ?? -1)) + "|" + String(file.isFolder ? 0 : (file.modified?.timeIntervalSince1970 ?? 0))
    }
}

enum SyncAction: Hashable {
    case createRemoteFolder(String)
    case createLocalFolder(String)
    case upload(String, replacing: String?)
    case download(String, CloudFile)
    /// Same size on both sides with no baseline to say otherwise: both are taken as the same file.
    case adopt(String, CloudFile)
    case deleteRemote(String, CloudFile)
    case deleteLocal(String)
    case conflict(String, CloudFile)
    case forget(String)
    var path: String {
        switch self {
        case .createRemoteFolder(let p), .createLocalFolder(let p), .upload(let p, _), .download(let p, _), .adopt(let p, _),
             .deleteRemote(let p, _), .deleteLocal(let p), .conflict(let p, _), .forget(let p): return p
        }
    }
}

struct SyncReport: Codable, Equatable {
    var uploaded = 0, downloaded = 0, deletedRemote = 0, deletedLocal = 0, conflicts = 0
    var isEmpty: Bool { uploaded + downloaded + deletedRemote + deletedLocal + conflicts == 0 }
    var summary: String {
        var parts: [String] = []
        if uploaded > 0 { parts.append(L("\(uploaded) subidos")) }
        if downloaded > 0 { parts.append(L("\(downloaded) bajados")) }
        if deletedRemote > 0 { parts.append(L("\(deletedRemote) borrados en la nube")) }
        if deletedLocal > 0 { parts.append(L("\(deletedLocal) enviados a la papelera del Mac")) }
        if conflicts > 0 { parts.append(L("\(conflicts) conflictos")) }
        return parts.isEmpty ? L("sin cambios") : parts.joined(separator: ", ")
    }
}

/// Refuses to carry out a sweep that would wipe most of one side. Deleting is what a person who moved a folder or
/// unmounted a volume never meant, and it is the one step a sync cannot take back.
struct MassDeletionRefused: LocalizedError {
    let count: Int
    let side: String
    var errorDescription: String? {
        L("La sincronización borraría \(count) elementos de \(side), la mayor parte de lo que hay. No se ha tocado nada. Si es lo que quieres, elige «Sincronizar aplicando los borrados» en el menú del reflejo.")
    }
}

/// Pure planning. Given both trees and the baseline, decides what has to happen to make them agree again.
enum TwoWayPlanner {
    static let massDeletionMinimum = 10

    /// Excluded paths are taken out of all three inputs before anything is decided, so they are never transferred,
    /// deleted or reported as conflicts. Their baseline entries are not forgotten either: a rule added after a file
    /// was synced leaves that file alone on both sides, and removing the rule picks it up again from where it was.
    static func plan(local fullLocal: [String: FileStamp], remote fullRemote: [String: CloudFile], baseline fullBaseline: [String: SyncEntry],
                     allowMassDeletion: Bool = false, exclusions: SyncExclusionMatcher = .none) throws -> [SyncAction] {
        let excludedLocal = fullLocal.filter { exclusions.excludes($0.key, isFolder: $0.value.size == -1) }
        let excludedRemote = fullRemote.filter { exclusions.excludes($0.key, isFolder: $0.value.isFolder) }
        let local = fullLocal.filter { excludedLocal[$0.key] == nil }
        let remote = fullRemote.filter { excludedRemote[$0.key] == nil }
        let baseline = fullBaseline.filter { !exclusions.excludes($0.key, isFolder: $0.value.isFolder) }
        // A folder holding something excluded is not removed as a whole, which would take the excluded item along;
        // its synced contents go one by one and the folder stays. Folder metadata such as .DS_Store does not count.
        func keeps(_ folder: String, _ excluded: [String]) -> Bool {
            excluded.contains { $0.hasPrefix(folder + "/") && !exclusions.isFolderMetadata($0) }
        }
        var creates: [SyncAction] = [], transfers: [SyncAction] = [], deletes: [SyncAction] = []
        let paths = Set(local.keys).union(remote.keys).union(baseline.keys)
        // Folders whose deletion on one side is carried to the other take everything below them along.
        var localFolderDeletes: Set<String> = [], remoteFolderDeletes: Set<String> = []
        let folders = paths.filter { isFolder($0, local: local, remote: remote, baseline: baseline) }.sorted { $0.count < $1.count }
        for path in folders {
            let here = local[path] != nil, there = remote[path] != nil, before = baseline[path] != nil
            switch (here, there, before) {
            case (true, true, _): continue
            case (true, false, false): creates.append(.createRemoteFolder(path))
            case (false, true, false): creates.append(.createLocalFolder(path))
            case (true, false, true):
                if changedBelow(path, local: local, baseline: baseline) { creates.append(.createRemoteFolder(path)) }
                else if keeps(path, Array(excludedLocal.keys)) { continue }
                else if !isUnder(path, any: localFolderDeletes) { localFolderDeletes.insert(path); deletes.append(.deleteLocal(path)) }
            case (false, true, true):
                if remoteChangedBelow(path, remote: remote, baseline: baseline), let folder = remote[path] { _ = folder; creates.append(.createLocalFolder(path)) }
                else if keeps(path, Array(excludedRemote.keys)) { continue }
                else if !isUnder(path, any: remoteFolderDeletes), let folder = remote[path] { remoteFolderDeletes.insert(path); deletes.append(.deleteRemote(path, folder)) }
            case (false, false, true): deletes.append(.forget(path))
            case (false, false, false): continue
            }
        }
        for path in paths where !isFolder(path, local: local, remote: remote, baseline: baseline) {
            if isUnder(path, any: localFolderDeletes) || isUnder(path, any: remoteFolderDeletes) { continue }
            let l = local[path], r = remote[path], b = baseline[path]
            let localChanged = l != b?.local
            let remoteChanged = r.map(SyncEntry.signature) != b?.remoteSignature
            switch (localChanged, remoteChanged) {
            case (false, false): continue
            case (true, false):
                if l != nil { transfers.append(.upload(path, replacing: r?.id)) }
                else if let r { deletes.append(.deleteRemote(path, r)) }
                else { deletes.append(.forget(path)) }
            case (false, true):
                if let r { transfers.append(.download(path, r)) }
                else if l != nil { deletes.append(.deleteLocal(path)) }
                else { deletes.append(.forget(path)) }
            case (true, true):
                switch (l, r) {
                case (nil, nil): deletes.append(.forget(path))
                case (nil, let r?): transfers.append(.download(path, r))
                case (_, nil): transfers.append(.upload(path, replacing: nil))
                case (let l?, let r?):
                    // The first sync of two copies of the same folder: same size is taken as the same file rather
                    // than doubling every one of them. With a baseline behind them, a disagreement is a conflict.
                    if b == nil, l.size == r.size ?? -2 { transfers.append(.adopt(path, r)) } else { transfers.append(.conflict(path, r)) }
                }
            }
        }
        // Children before parents when deleting, parents before children when creating.
        creates.sort { $0.path.count < $1.path.count }
        deletes.sort { $0.path.count > $1.path.count }
        let localFiles = local.filter { $0.value.size != -1 }.count, remoteFiles = remote.filter { !$0.value.isFolder }.count
        let localDeletions = deletes.filter { if case .deleteLocal = $0 { return true } else { return false } }
            .reduce(0) { $0 + filesBelow($1.path, in: local) }
        let remoteDeletions = deletes.filter { if case .deleteRemote = $0 { return true } else { return false } }
            .reduce(0) { $0 + filesBelow($1.path, in: remote) }
        if !allowMassDeletion {
            if localDeletions >= massDeletionMinimum, localDeletions * 2 > localFiles { throw MassDeletionRefused(count: localDeletions, side: L("la carpeta del Mac")) }
            if remoteDeletions >= massDeletionMinimum, remoteDeletions * 2 > remoteFiles { throw MassDeletionRefused(count: remoteDeletions, side: L("la nube")) }
        }
        return creates + transfers + deletes
    }
    private static func isFolder(_ path: String, local: [String: FileStamp], remote: [String: CloudFile], baseline: [String: SyncEntry]) -> Bool {
        if let l = local[path] { return l.size == -1 }
        if let r = remote[path] { return r.isFolder }
        return baseline[path]?.isFolder ?? false
    }
    private static func isUnder(_ path: String, any prefixes: Set<String>) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    private static func changedBelow(_ folder: String, local: [String: FileStamp], baseline: [String: SyncEntry]) -> Bool {
        local.contains { $0.key.hasPrefix(folder + "/") && $0.value.size != -1 && baseline[$0.key]?.local != $0.value }
    }
    private static func remoteChangedBelow(_ folder: String, remote: [String: CloudFile], baseline: [String: SyncEntry]) -> Bool {
        remote.contains { $0.key.hasPrefix(folder + "/") && !$0.value.isFolder && baseline[$0.key]?.remoteSignature != SyncEntry.signature($0.value) }
    }
    private static func filesBelow<T>(_ path: String, in tree: [String: T]) -> Int {
        if tree[path] != nil, !(tree[path] is FileStamp && (tree[path] as? FileStamp)?.size == -1), !((tree[path] as? CloudFile)?.isFolder ?? false) { return 1 }
        return tree.keys.filter { $0.hasPrefix(path + "/") }.count
    }
}

/// Carries out a plan against one account, updating the baseline after every step so an interruption leaves a
/// state the next run can continue from rather than redo.
@MainActor
final class TwoWaySyncEngine {
    let api: CloudAPI
    let localRoot: URL
    let remoteRoot: String
    private(set) var baseline: [String: SyncEntry]
    private(set) var report = SyncReport()
    /// Called after every change to the baseline, so it can be written down at once.
    var persist: (([String: SyncEntry]) throws -> Void)?
    var allowMassDeletion = false
    /// What this sync leaves alone on both sides; see `TwoWayPlanner.plan`.
    var exclusions: SyncExclusionMatcher = .none
    /// Tests bypass the Finder Trash, which a temporary folder on some volumes does not have.
    var trashLocally: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    init(api: CloudAPI, localRoot: URL, remoteRoot: String, baseline: [String: SyncEntry]) {
        self.api = api; self.localRoot = localRoot; self.remoteRoot = remoteRoot; self.baseline = baseline
    }

    /// Relative path → item for the whole remote tree, plus the id of every remote folder by path.
    func remoteSnapshot() async throws -> (files: [String: CloudFile], folders: [String: String]) {
        var files: [String: CloudFile] = [:]
        var folders: [String: String] = ["": remoteRoot]
        var queue: [(id: String, path: String)] = [(remoteRoot, "")]
        while !queue.isEmpty {
            let (id, prefix) = queue.removeFirst()
            try Task.checkCancellation()
            for item in try await api.list(parent: id) {
                let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
                files[path] = item
                // An excluded folder is listed so the planner knows it is there, but nobody needs what is inside.
                if item.isFolder, !exclusions.excludes(path, isFolder: true) { folders[path] = item.id; queue.append((item.id, path)) }
            }
        }
        return (files, folders)
    }

    func run() async throws -> SyncReport {
        report = SyncReport()
        let root = localRoot, exclusions = exclusions
        let local = try await blockingIO { try MirrorPlanner.scan(root, exclusions: exclusions).all }
        var (remote, folders) = try await remoteSnapshot()
        let plan = try TwoWayPlanner.plan(local: local, remote: remote, baseline: baseline, allowMassDeletion: allowMassDeletion, exclusions: exclusions)
        var touchedRemote: Set<String> = []
        for action in plan {
            try Task.checkCancellation()
            switch action {
            case .createRemoteFolder(let path):
                let parent = try remoteParent(of: path, folders: folders)
                let id = try await api.createFolder(name: name(of: path), parent: parent)
                folders[path] = id
                baseline[path] = SyncEntry(local: FileStamp(size: -1, modified: Date(timeIntervalSince1970: 0)), remoteID: id, isFolder: true)
            case .createLocalFolder(let path):
                try FileManager.default.createDirectory(at: localRoot.appendingPathComponent(path), withIntermediateDirectories: true)
                baseline[path] = SyncEntry(local: FileStamp(size: -1, modified: Date(timeIntervalSince1970: 0)), remoteID: folders[path] ?? remote[path]?.id, isFolder: true)
            case .upload(let path, let replacing):
                let parent = try remoteParent(of: path, folders: folders)
                let source = localRoot.appendingPathComponent(path)
                let receipt = try await api.resumableUpload(local: source, parent: parent, name: name(of: path), replacing: replacing, checkpoint: nil, save: { _ in }, progress: { _, _ in })
                baseline[path] = SyncEntry(local: local[path], remoteID: receipt.remoteID, remoteSize: local[path]?.size, remoteModified: nil, isFolder: false)
                touchedRemote.insert(path); report.uploaded += 1
            case .download(let path, let file):
                try await download(file, to: path)
                report.downloaded += 1
            case .adopt(let path, let file):
                baseline[path] = SyncEntry(local: local[path], remoteID: file.id, remoteSize: file.size, remoteModified: file.modified, isFolder: false)
            case .deleteRemote(let path, let file):
                try await api.trash(file: file)
                forgetBelow(path); report.deletedRemote += 1
            case .deleteLocal(let path):
                let target = localRoot.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: target.path) { try trashLocally(target) }
                forgetBelow(path); report.deletedLocal += 1
            case .conflict(let path, let file):
                // Both copies survive: the local one under a name that says where it came from, the remote one in
                // its place. The renamed copy goes up too, so both sides end with both versions.
                let original = localRoot.appendingPathComponent(path)
                let copyPath = Self.conflictName(for: path, host: Host.current().localizedName ?? "Mac")
                try FileManager.default.moveItem(at: original, to: localRoot.appendingPathComponent(copyPath))
                try await download(file, to: path)
                let parent = try remoteParent(of: copyPath, folders: folders)
                let copy = localRoot.appendingPathComponent(copyPath)
                let receipt = try await api.resumableUpload(local: copy, parent: parent, name: name(of: copyPath), replacing: nil, checkpoint: nil, save: { _ in }, progress: { _, _ in })
                baseline[copyPath] = SyncEntry(local: try stamp(of: copy), remoteID: receipt.remoteID, remoteSize: local[path]?.size, remoteModified: nil, isFolder: false)
                touchedRemote.insert(copyPath); report.conflicts += 1
            case .forget(let path):
                baseline[path] = nil
            }
            try persist?(baseline)
        }
        // Uploads leave the remote date unknown; one more listing fills it in so the next run sees them unchanged.
        if !touchedRemote.isEmpty {
            (remote, _) = try await remoteSnapshot()
            for path in touchedRemote {
                guard var entry = baseline[path], let file = remote[path] else { continue }
                entry.remoteID = file.id; entry.remoteSize = file.size; entry.remoteModified = file.modified
                baseline[path] = entry
            }
            try persist?(baseline)
        }
        return report
    }

    private func download(_ file: CloudFile, to path: String) async throws {
        let target = localRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".icloudy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await api.download(file: file, to: temporary)
        if let modified = file.modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path) }
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: target) }
        baseline[path] = SyncEntry(local: try stamp(of: target), remoteID: file.id, remoteSize: file.size, remoteModified: file.modified, isFolder: false)
    }
    private func stamp(of url: URL) throws -> FileStamp {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileStamp(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
    }
    private func forgetBelow(_ path: String) {
        baseline = baseline.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }
    private func name(of path: String) -> String { String(path.split(separator: "/").last ?? Substring(path)) }
    private func remoteParent(of path: String, folders: [String: String]) throws -> String {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        guard let id = folders[parent] else { throw CloudError.message(L("Falta la carpeta remota «\(parent)»; vuelve a sincronizar.")) }
        return id
    }
    static func conflictName(for path: String, host: String, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let renamed = stem + " (conflicto " + host + " " + formatter.string(from: date) + ")" + (ext.isEmpty ? "" : "." + ext)
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? renamed : parent + "/" + renamed
    }
}
