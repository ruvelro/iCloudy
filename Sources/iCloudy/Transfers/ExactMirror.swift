import Foundation

/// "Espejo exacto": a one-way mirror that also carries deletions from its source to its destination, into the
/// destination's trash. Only what this mirror itself put at the destination is ever deleted there; anything else
/// that lives beside it is left alone, and a file changed at the destination since the mirror wrote it is kept.
enum ExactMirrorPlanner {
    /// Remote items an upload mirror wrote that are gone from the Mac now, files first and then folders, deepest
    /// first. `entries` are the mirror's `remoteEntries`, keyed "./path".
    static func remoteDeletions(entries: [String: CloudFile], current: [String: FileStamp], excluded: [String: FileStamp],
                                exclusions: SyncExclusionMatcher) -> (files: [String], folders: [String]) {
        var files: [String] = [], folders: [String] = []
        for (key, file) in entries where key.hasPrefix("./") {
            let path = String(key.dropFirst(2))
            guard current[path] == nil, excluded[path] == nil, !exclusions.excludes(path, isFolder: file.isFolder) else { continue }
            // Below a folder that is excluded now: left alone like everything an exclusion covers.
            if excluded.keys.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            if file.isFolder { folders.append(path) } else { files.append(path) }
        }
        return (files.sorted(), folders.sorted { $0.count > $1.count })
    }

    /// Local copies a download mirror wrote whose cloud file is gone, unchanged since; and local folders the mirror
    /// had filled that the cloud no longer has.
    static func localDeletions(local: [String: FileStamp], remote: [String: CloudFile], baseline: [String: SyncEntry],
                               exclusions: SyncExclusionMatcher, now: Date) -> (files: [String], folders: [String]) {
        let filtered = TwoWayPlanner.filteredFiles(local: local, remote: remote, exclusions: exclusions, now: now)
        var files: [String] = []
        for (path, entry) in baseline where !entry.isFolder && remote[path] == nil && !exclusions.excludes(path, isFolder: false) && !filtered.contains(path) {
            guard let l = local[path], l == entry.local else { continue }
            files.append(path)
        }
        var folders: [String] = []
        for (path, stamp) in local where stamp.size == -1 && remote[path] == nil && !exclusions.excludes(path, isFolder: true) {
            if baseline.keys.contains(where: { $0.hasPrefix(path + "/") }) { folders.append(path) }
        }
        return (files.sorted(), folders.sorted { $0.count > $1.count })
    }

    /// The brake two-way syncs already had, for one side: deleting most of what is there stops and asks.
    static func checkMassDeletion(_ deletions: Int, of total: Int, side: String, allowed: Bool) throws {
        guard !allowed, deletions >= TwoWayPlanner.massDeletionMinimum, deletions * 2 > total else { return }
        throw MassDeletionRefused(count: deletions, side: side)
    }
}

extension MirrorManager {
    /// Carries an upload mirror's local deletions to the cloud's trash, before its upload is planned. A remote file
    /// that is no longer what the mirror uploaded (someone edited it there) is kept, and so is a folder that still
    /// holds anything. Returns how many items went to the trash.
    func applyRemoteDeletions(_ id: UUID, current: [String: FileStamp], excluded: [String: FileStamp], dryRun: Bool = false) async throws -> [String] {
        guard let mirror = mirrors.first(where: { $0.id == id }), mirror.options.exact, let queue else { return [] }
        let rules = exclusions(of: mirror)
        let (files, folders) = ExactMirrorPlanner.remoteDeletions(entries: mirror.remoteEntries, current: current, excluded: excluded, exclusions: rules)
        guard !files.isEmpty || !folders.isEmpty else { return [] }
        let previousFiles = mirror.remoteEntries.values.filter { !$0.isFolder }.count
        try ExactMirrorPlanner.checkMassDeletion(files.count, of: previousFiles, side: L("la nube"), allowed: massDeletionAllowed.contains(id))
        if dryRun { return files + folders }
        guard let api = try queue.client?(mirror.accountID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de este reflejo.")) }
        var listings: [String: [CloudFile]] = [:]
        func parentID(_ path: String) -> String {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            return parent.isEmpty ? mirror.remoteFolderID : (mirror.remoteEntries["./" + parent]?.id ?? mirror.remoteFolderID)
        }
        func listing(_ parent: String) async throws -> [CloudFile] {
            if let known = listings[parent] { return known }
            let items = try await api.list(parent: parent)
            listings[parent] = items
            return items
        }
        var gone: [String] = [], trashed: [String] = []
        for path in files {
            try Task.checkCancellation()
            guard let entry = mirror.remoteEntries["./" + path] else { continue }
            let parent = parentID(path)
            let found = try await listing(parent).first { $0.id == entry.id }
            gone.append(path)
            // Missing already, or changed there since: nothing to delete, or not ours to delete any more.
            guard let found, found.size == entry.size, found.modified == entry.modified else { continue }
            try await api.trash(file: found)
            listings[parent]?.removeAll { $0.id == found.id }
            trashed.append(path)
        }
        for path in folders {
            try Task.checkCancellation()
            guard let entry = mirror.remoteEntries["./" + path] else { continue }
            gone.append(path)
            listings[entry.id] = nil
            guard try await listing(entry.id).isEmpty else { continue }
            let parent = parentID(path)
            guard let found = try await listing(parent).first(where: { $0.id == entry.id }) else { continue }
            try await api.trash(file: found)
            trashed.append(path)
        }
        if let index = mirrors.firstIndex(where: { $0.id == id }) {
            for path in gone { mirrors[index].remoteEntries["./" + path] = nil; mirrors[index].stamps[path] = nil }
            persist(id)
        }
        return trashed
    }

    /// Trashes local items for an exact download mirror. Folders go only once nothing but folder metadata is left in
    /// them, so a file the person put there keeps its folder.
    func trashLocal(_ files: [String], folders: [String], in root: URL, rules: SyncExclusionMatcher) throws -> Int {
        var count = 0
        for path in files {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try trashLocally(url); count += 1
        }
        for path in folders {
            let url = root.appendingPathComponent(path)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            guard left.allSatisfy({ rules.isFolderMetadata(path + "/" + $0) }) else { continue }
            try trashLocally(url); count += 1
        }
        return count
    }
}
