import Foundation

extension MirrorManager {
    /// An upload mirror comparing by checksum: a file whose date changed but whose bytes are still what the cloud
    /// lists is taken as unchanged, so it is not sent again.
    func adoptUnchangedContents(_ id: UUID, current: [String: FileStamp], root: URL) async throws {
        guard let mirror = mirrors.first(where: { $0.id == id }) else { return }
        var remote: [String: CloudFile] = [:]
        for (path, stamp) in current where stamp.size != -1 && mirror.stamps[path] != stamp {
            if let entry = mirror.remoteEntries["./" + path], entry.checksum != nil { remote[path] = entry }
        }
        guard !remote.isEmpty else { return }
        let result = try await ContentComparison.compare(Array(remote.keys), root: root, local: current, remote: remote)
        guard !result.identical.isEmpty, let index = mirrors.firstIndex(where: { $0.id == id }) else { return }
        for path in result.identical { mirrors[index].stamps[path] = current[path] }
        persist(id)
    }

    /// Looks at every file the mirror keeps on both sides and compares size and, where the provider lists one,
    /// checksum. One-way mirrors repair what they find: a copy that is missing or different is sent again by the next
    /// run. A two-way sync only reports it, because which side is right is the person's call.
    @discardableResult
    func verify(_ id: UUID, now: Date = Date()) async throws -> VerificationSummary {
        guard let mirror = mirrors.first(where: { $0.id == id }) else { throw CloudError.message(L("Este reflejo ya no existe.")) }
        guard let api = try queue?.client?(mirror.accountID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de este reflejo.")) }
        let url = resolvedURL(mirror)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CloudError.message(L("La carpeta local ya no existe en \(url.path).")) }
        let rules = exclusions(of: mirror)
        let scan = try await blockingIO { try MirrorPlanner.scan(url, exclusions: rules) }
        let snapshot = try await RemoteTree.snapshot(api, root: mirror.remoteFolderID, exclusions: rules)
        // What the mirror says is the same on both sides: for an upload mirror its stamps, for the rest the baseline.
        var agreed: [String] = []
        switch mirror.mode {
        case .upload: agreed = mirror.stamps.filter { $0.value.size != -1 && scan.stamps[$0.key] == $0.value }.map(\.key)
        case .download, .twoWay: agreed = mirror.baseline.filter { !$0.value.isFolder && $0.value.local != nil && scan.stamps[$0.key] == $0.value.local }.map(\.key)
        }
        var summary = VerificationSummary()
        var wrong: [String] = []
        let present = agreed.filter { snapshot.files[$0] != nil }
        let missing = mirror.mode == .download ? [] : agreed.filter { snapshot.files[$0] == nil }
        let sized = present.filter { path in snapshot.files[path]?.size.map { $0 == scan.stamps[path]?.size } ?? true }
        wrong += missing + present.filter { !sized.contains($0) }
        let hashed = try await ContentComparison.compare(sized, root: url, local: scan.stamps, remote: snapshot.files)
        wrong += hashed.different
        summary.checked = present.count + missing.count
        summary.verified = hashed.identical.count
        summary.sizeOnly = sized.count - hashed.identical.count - hashed.different.count
        summary.missing = wrong.count
        guard let index = mirrors.firstIndex(where: { $0.id == id }) else { return summary }
        if mirror.mode != .twoWay {
            for path in wrong {
                switch mirror.mode {
                case .upload: mirrors[index].stamps[path] = nil
                // The copy here is still what the mirror wrote, so forgetting the cloud's side makes the next run
                // replace it without asking.
                case .download: mirrors[index].baseline[path]?.remoteID = nil
                case .twoWay: break
                }
            }
        }
        mirrors[index].lastVerified = now
        mirrors[index].lastVerification = summary.text
        persist(id)
        if !wrong.isEmpty, mirror.mode != .twoWay { scheduleSync(id, immediate: true) }
        return summary
    }
}
