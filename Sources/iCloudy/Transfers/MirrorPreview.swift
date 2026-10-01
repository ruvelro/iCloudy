import Foundation

/// One line of the "pending changes" view: what the next sync would do to one path.
struct PendingChange: Identifiable, Hashable {
    enum Kind: Int, CaseIterable, Hashable {
        case upload, download, trashRemote, trashLocal, conflict, excluded
    }
    let kind: Kind
    let path: String
    let isFolder: Bool
    var id: String { "\(kind.rawValue)|\(path)" }
}

/// A dry run of a mirror: what its next sync would do, computed by the same planner the sync uses and without
/// touching either side.
struct MirrorPreview {
    var changes: [PendingChange] = []
    /// Two-way only: the plan exactly as the planner returned it, which is what the run would carry out.
    var actions: [SyncAction] = []
    /// Set when the run would stop rather than delete most of one side; `changes` then lists what it would delete.
    var massDeletion: String?
    /// One-way mirrors are previewed from the Mac alone; the cloud is only asked during the run itself.
    var oneWay = false
    /// One-way only: the run would resume an interrupted upload still in the queue instead of planning a new one.
    var resumesQueuedUpload = false

    func changes(_ kind: PendingChange.Kind) -> [PendingChange] { changes.filter { $0.kind == kind } }
    var isEmpty: Bool { !changes.contains { $0.kind != .excluded } }

    /// The two-way plan in the view's terms. Adopting a file and forgetting a path change nothing on either side,
    /// so they are not listed.
    static func twoWay(actions: [SyncAction], local: [String: FileStamp], excluded: [(path: String, isFolder: Bool)], massDeletion: String?) -> MirrorPreview {
        var preview = MirrorPreview(actions: actions, massDeletion: massDeletion)
        for action in actions {
            switch action {
            case .createRemoteFolder(let path): preview.changes.append(PendingChange(kind: .upload, path: path, isFolder: true))
            case .createLocalFolder(let path): preview.changes.append(PendingChange(kind: .download, path: path, isFolder: true))
            case .upload(let path, _): preview.changes.append(PendingChange(kind: .upload, path: path, isFolder: false))
            case .download(let path, _): preview.changes.append(PendingChange(kind: .download, path: path, isFolder: false))
            case .deleteRemote(let path, let file): preview.changes.append(PendingChange(kind: .trashRemote, path: path, isFolder: file.isFolder))
            case .deleteLocal(let path): preview.changes.append(PendingChange(kind: .trashLocal, path: path, isFolder: local[path]?.size == -1))
            case .conflict(let path, _): preview.changes.append(PendingChange(kind: .conflict, path: path, isFolder: false))
            case .adopt, .forget: continue
            }
        }
        preview.changes += excluded.map { PendingChange(kind: .excluded, path: $0.path, isFolder: $0.isFolder) }
        preview.changes.sort { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
        return preview
    }

    /// The one-way plan: every file not already marked completed goes up, and so does every folder this mirror has
    /// not created yet. Nothing is ever downloaded or deleted by a one-way mirror.
    static func oneWay(current: [String: FileStamp], completed: Set<String>, nothingNew: Bool, remoteEntries: [String: CloudFile],
                       excluded: [String: FileStamp]) -> MirrorPreview {
        var preview = MirrorPreview(oneWay: true)
        if !nothingNew {
            for (path, stamp) in current where !completed.contains("./" + path) {
                if stamp.size == -1, remoteEntries["./" + path] != nil { continue }
                preview.changes.append(PendingChange(kind: .upload, path: path, isFolder: stamp.size == -1))
            }
        }
        preview.changes += excluded.map { PendingChange(kind: .excluded, path: $0.key, isFolder: $0.value.size == -1) }
        preview.changes.sort { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
        return preview
    }
}

extension TwoWayPlanner {
    /// The outermost excluded items present on either side, which is what a dry run shows as left alone.
    static func excludedItems(local: [String: FileStamp], remote: [String: CloudFile], exclusions: SyncExclusionMatcher) -> [(path: String, isFolder: Bool)] {
        var found: [String: Bool] = [:]
        for (path, stamp) in local where exclusions.excludes(path, isFolder: stamp.size == -1) { found[path] = stamp.size == -1 }
        for (path, file) in remote where exclusions.excludes(path, isFolder: file.isFolder) { found[path] = found[path] ?? file.isFolder }
        let outermost = found.filter { entry in
            let parent = entry.key.split(separator: "/").dropLast().joined(separator: "/")
            return parent.isEmpty || !exclusions.excludes(parent, isFolder: true)
        }
        return outermost.map { (path: $0.key, isFolder: $0.value) }.sorted { $0.path < $1.path }
    }
}
