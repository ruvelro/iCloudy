import Foundation

/// Walks the tree of one job: an upload from this Mac, a download to it, or a copy from one account to another.
///
/// The three walks used to be three copies of the same steps, about 340 lines that had to be fixed three times:
/// skip what an earlier run completed, forget a folder whose creation was never confirmed, pick a name that clashes
/// with nothing (asking the person when it does), claim it against the other running jobs, and create the folder
/// with a marker on disk before the request. Those steps live here once; each walk only says what is particular to it.
@MainActor
final class TransferWalker {
    private let queue: TransferQueue
    let id: UUID
    /// Bytes accounted for so far, for the progress bar.
    private var done: Int64 = 0
    /// One remote listing per destination folder for the whole run. Before, every item listed its parent again,
    /// which made a folder of N files cost N listings of N items.
    private var siblings: [String: [CloudFile]] = [:]
    /// The job's own rules, compiled once per run. A mirror's come from the queue instead, asked for every item.
    private var ownRules: SyncExclusionMatcher??

    init(queue: TransferQueue, id: UUID) { self.queue = queue; self.id = id }

    private func job() throws -> Transfer { try queue.job(id) }
    private func edit(coalesce: Bool = false, _ change: (inout Transfer) -> Void) throws { try queue.edit(id, coalesce: coalesce, change) }
    /// The same, written to disk before returning, for a marker that must exist before a request is sent.
    private func commit(_ change: (inout Transfer) -> Void) async throws { try await queue.commit(id, change) }
    private func advance(_ bytes: Int64) { done += bytes; queue.mark(id, done: done) }

    /// What an upload leaves out: the mirror's current rules, or the ones the job was saved with.
    private func uploadRules() throws -> SyncExclusionMatcher? {
        if let rules = queue.uploadExclusions?(id) { return rules }
        if let ownRules { return ownRules }
        let job = try job()
        let compiled = job.options?.exclusions.map { $0.matcher(caseInsensitive: SyncExclusions.isCaseInsensitive(job.localURL)) }
        ownRules = .some(compiled)
        return compiled
    }

    // MARK: Shared steps

    /// True when an earlier run already finished this item, whose bytes then count as done.
    private func alreadyCompleted(_ key: String, bytes: () async throws -> Int64) async throws -> Bool {
        guard try job().completedPaths.contains(key) else { return false }
        advance(try await bytes())
        return true
    }

    /// An earlier creation may have committed even though its reply was lost: the folder is looked for again, by
    /// name, before anything is created a second time.
    private func forgetUncertainFolder(_ key: String, parent: String) throws -> Transfer {
        if try job().uncertainFolders.contains(key) {
            try edit { $0.names[key] = nil; $0.replacements[key] = nil; $0.uncertainFolders.remove(key) }
            siblings[parent] = nil
        }
        return try job()
    }

    /// What became of a name that clashed: left alone, or written under this name, replacing that item if any.
    enum NameDecision { case skip, use(String, replacing: String?) }

    /// Picks the remote name of an item. `remembered` is what a mirror last uploaded there, which it may replace
    /// without asking when `owns` says the item is still exactly that; `keepsMatchName` replaces a folder under the
    /// spelling it already has.
    private func resolveName(_ desired: String, key: String, parent: String, in api: CloudAPI, folder: Bool,
                             remembered: CloudFile? = nil, owns: ((CloudFile) -> Bool)? = nil,
                             keepsMatchName: Bool = false, incoming: Date? = nil) async throws -> NameDecision {
        if siblings[parent] == nil { siblings[parent] = try await api.list(parent: parent) }
        let room = NameClaims.remote(account: api.account.id, parent: parent)
        let existing = (siblings[parent] ?? []) + queue.claimed(room, by: id, besides: siblings[parent] ?? [])
        let name = remembered?.name ?? desired
        let matches = existing.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.id == remembered?.id }
        guard let match = matches.first else { return .use(name, replacing: nil) }
        let choice: ConflictChoice
        let canReplace = matches.count == 1 && match.isFolder == folder && !match.isGoogleDocument && !match.id.isEmpty
        if let owns, owns(match), matches.count == 1 { choice = .replace }
        else if let decided = try policyChoice(incoming: incoming, existing: match.modified, canReplace: canReplace, folder: folder) { choice = decided }
        else { choice = try await askConflict(name, replace: canReplace, folder: folder) }
        switch choice {
        case .skip: return .skip
        // Claimed again after the wait: another job may have taken a name while this one was asking.
        case .copy: return .use(TransferQueue.unique(name, existing: existing.map(\.name) + queue.claims.others(in: room, excluding: id)), replacing: nil)
        case .replace: return .use(folder && keepsMatchName ? match.name : name, replacing: match.id)
        }
    }

    /// Picks the local name of a downloaded item, against what is on disk and what other jobs are downloading.
    private func resolveLocalName(_ name: String, in folder: URL, target: URL, room: String, isFolder: Bool,
                                  incoming: Date? = nil) async throws -> (decision: NameDecision, target: URL) {
        let exists = FileManager.default.fileExists(atPath: target.path)
        // A name another running job is downloading to is as taken as one already on disk, but there is nothing
        // there yet to replace.
        let claimed = queue.claims.others(in: room, excluding: id).contains { $0.localizedCaseInsensitiveCompare(target.lastPathComponent) == .orderedSame }
        guard exists || claimed else { return (.use(target.lastPathComponent, replacing: nil), target) }
        let values = exists ? try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) : nil
        let canReplace = !claimed && values?.isDirectory == isFolder && values?.isSymbolicLink != true
        let choice: ConflictChoice
        if let decided = try policyChoice(incoming: incoming, existing: values?.contentModificationDate, canReplace: canReplace, folder: isFolder) { choice = decided }
        else { choice = try await askConflict(name, replace: canReplace, folder: isFolder) }
        switch choice {
        case .skip: return (.skip, target)
        case .copy:
            let available = queue.available(in: folder, name: name, room: room, for: id)
            return (.use(available.lastPathComponent, replacing: nil), available)
        case .replace: return (.use(target.lastPathComponent, replacing: "local"), target)
        }
    }

    /// The answer of the job's conflict policy, nil when there is none or it says to ask. A folder that meets a
    /// folder is merged into, whatever the policy: two copies of a folder tree is never what a sync meant.
    private func policyChoice(incoming: Date?, existing: Date?, canReplace: Bool, folder: Bool) throws -> ConflictChoice? {
        guard let policy = try job().options?.conflictPolicy else { return nil }
        if folder, canReplace, policy != .ask { return .replace }
        return policy.choice(incoming: incoming, existing: existing, canReplace: canReplace)
    }

    /// Waits for the person (or the batch's standing answer) when a name is taken.
    private func askConflict(_ name: String, replace: Bool, folder: Bool) async throws -> ConflictChoice {
        try await queue.choose(id, name: name, replace: replace, folder: folder)
    }

    /// Takes the name in its folder, so no other running job picks it before this one has created it.
    private func claim(_ name: String, in room: String) { queue.claims.claim(name, in: room, by: id) }

    /// The remote folder for `key`: the one already created or chosen, or a new one. The marker reaches the disk
    /// before the request, so a creation whose reply was lost is looked for, not repeated, by the next run.
    private func ensureFolder(_ key: String, name: String, parent: String, in api: CloudAPI, current: Transfer,
                              unconfirmed: (String) -> String) async throws -> String {
        if let known = current.folders[key] ?? current.replacements[key] { return known }
        try await commit { $0.uncertainFolders.insert(key) }
        let remote: String
        do { remote = try await api.createFolder(name: name, parent: parent) }
        catch { throw CloudError.message(unconfirmed(error.localizedDescription)) }
        try edit { $0.folders[key] = remote; $0.uncertainFolders.remove(key) }
        siblings[parent, default: []].append(Self.folderEntry(remote, name))
        // A folder created a moment ago is empty: its children need no listing at all.
        siblings[remote] = []
        return remote
    }

    private static func folderEntry(_ id: String, _ name: String) -> CloudFile {
        CloudFile(id: id, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    private static func fileEntry(_ name: String, size: Int64?) -> CloudFile {
        CloudFile(id: "", name: name, mime: "application/octet-stream", size: size, modified: nil, webURL: nil, isFolder: false)
    }

    // MARK: Upload

    func upload(api: CloudAPI, local: URL, parent: String, key: String = ".") async throws {
        try Task.checkCancellation()
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let folder = values.isDirectory == true
        queue.inFlight[id] = ReportCursor(key: key, leaf: local.lastPathComponent, folder: folder)
        guard values.isSymbolicLink != true else { throw CloudError.message(L("No se admiten enlaces simbólicos.")) }
        // Excluded: never uploaded, never listed, never counted. The root itself is the mirror and is never excluded.
        if key != ".", let rules = try uploadRules() {
            let path = String(key.dropFirst(2))
            if rules.excludes(path, isFolder: folder) { return }
            if !folder, rules.filtersOut(size: values.fileSize.map(Int64.init), modified: values.contentModificationDate, now: Date()) { return }
        }
        if try await alreadyCompleted(key, bytes: { try await blockingIO { try TransferQueue.localSize(local) } }) { return }
        // A mirror's own folder is never created remotely: its contents go into one that already exists, so its name
        // never reaches the provider. Judging it by the provider's rules stopped a mirror of "Fotos." from ever
        // syncing to OneDrive, over a name nobody was going to send.
        if key != ".", let problem = FileNames.problem(with: local.lastPathComponent, for: api.account.cloud) {
            throw CloudError.message(L("No se puede subir «\(local.lastPathComponent)»: \(problem)"))
        }
        if key == ".", try job().folders[key] == nil, let problem = FileNames.problem(with: local.lastPathComponent, for: api.account.cloud) {
            throw CloudError.message(L("No se puede subir «\(local.lastPathComponent)»: \(problem)"))
        }
        var current = try forgetUncertainFolder(key, parent: parent)
        if current.names[key] == nil {
            let remembered = current.mirrorEntries?[key]
            let decision = try await resolveName(local.lastPathComponent, key: key, parent: parent, in: api, folder: folder,
                                                 remembered: remembered, owns: { match in
                remembered.map { old in
                    old.id == match.id && old.name == match.name && old.isFolder == match.isFolder &&
                    (folder || (old.size != nil && old.modified != nil && old.size == match.size && old.modified == match.modified))
                } ?? false
            }, keepsMatchName: true, incoming: values.contentModificationDate)
            guard case .use(let name, let replacing) = decision else {
                try edit {
                    $0.completedPaths.insert(key)
                    $0.recordSkip(key, leaf: local.lastPathComponent, folder: folder, bytes: values.fileSize.map(Int64.init))
                    $0.mirrorEntries = $0.mirrorEntries?.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
                }
                advance(try await blockingIO { try TransferQueue.localSize(local) })
                return
            }
            try edit(coalesce: true) {
                $0.names[key] = name; $0.replacements[key] = replacing
                if folder, replacing == nil, $0.mirrorEntries != nil {
                    // A newly created/copied folder has none of the old destination's unchanged children.
                    $0.completedPaths = $0.completedPaths.filter { !$0.hasPrefix(key + "/") }
                    $0.mirrorEntries = $0.mirrorEntries?.filter { !$0.key.hasPrefix(key + "/") }
                }
            }
            current = try job()
        }
        let name = current.names[key]!
        claim(name, in: NameClaims.remote(account: api.account.id, parent: parent))
        if folder {
            let remote = try await ensureFolder(key, name: name, parent: parent, in: api, current: current) {
                L("No se confirmó la creación de \(name). Revisa el destino antes de reintentar. \($0)")
            }
            if current.mirrorEntries != nil {
                let entry = Self.folderEntry(remote, name)
                try edit { $0.mirrorEntries?[key] = entry }
            }
            let children = try await blockingIO { try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) }
            for child in children {
                try await upload(api: api, local: child, parent: remote, key: key + "/" + child.lastPathComponent)
            }
        } else {
            let base = done
            let replacing = current.replacements[key]
            let receipt = try await api.resumableUpload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: current.uploads[key], save: { [queue, id] checkpoint in
                // A new session URL and the completion are written at once; intermediate offsets are coalesced.
                try queue.edit(id, coalesce: checkpoint.offset > 0 && !checkpoint.complete) { $0.uploads[key] = checkpoint }
            }, progress: { [queue, id] bytes, total in queue.report(id, base: base, bytes: bytes, total: total) })
            try edit(coalesce: true) { $0.record(key, receipt.verification == .verified ? .verified : .unverified, bytes: values.fileSize.map(Int64.init)) }
            if current.mirrorEntries != nil {
                // Only an identity returned by this upload may become an automatically replaceable mirror target.
                let remote = try await api.list(parent: parent)
                let entry = receipt.remoteID.flatMap { id in remote.first { $0.id == id } }
                try edit { $0.mirrorEntries?[key] = entry }
                siblings[parent] = remote
            }
            advance(Int64(values.fileSize ?? 0))
            if let remoteID = receipt.remoteID {
                // The file that was just uploaded is, by definition, also on this Mac.
                queue.didStoreLocalCopy?(LocalCopy(accountID: try job().accountID, fileID: remoteID, name: name, path: local.path,
                                                   bookmark: try job().bookmark, size: Int64(values.fileSize ?? 0),
                                                   remoteModified: Date(), savedAt: Date(), origin: .upload))
            }
            if replacing == nil, current.mirrorEntries == nil {
                siblings[parent, default: []].append(Self.fileEntry(name, size: values.fileSize.map(Int64.init)))
            }
        }
        try edit(coalesce: true) { $0.completedPaths.insert(key) }
    }

    // MARK: Copy between accounts

    /// Copies a remote tree from one account into a folder of another. Each file is staged in `scratch`, uploaded with
    /// the usual checkpoints, then deleted. Google documents leave Drive as Office files or PDF.
    func copy(from source: CloudAPI, to target: CloudAPI, file: CloudFile, parent: String, scratch: URL, key: String = ".") async throws {
        try Task.checkCancellation()
        if try await alreadyCompleted(key, bytes: { file.size ?? 0 }) { return }
        queue.inFlight[id] = ReportCursor(key: key, leaf: file.name, folder: file.isFolder)
        let export = file.isGoogleDocument ? file.crossCloudExport : nil
        if file.isGoogleDocument && export == nil {
            // Forms, sites and shortcuts have nothing exportable; note it and move on instead of failing the whole tree.
            try edit(coalesce: true) {
                $0.completedPaths.insert(key); $0.unverifiedFiles += 1
                $0.record(key, .excluded, path: $0.reportPath(for: key, leaf: file.name), reason: L("Google no permite exportar formularios, sitios ni accesos directos."))
            }
            return
        }
        let localName = export.map { file.name + "." + $0.ext } ?? file.name
        if let problem = FileNames.problem(with: localName, for: target.account.cloud) { throw CloudError.message(L("No se puede enviar «\(localName)»: \(problem)")) }
        var current = try forgetUncertainFolder(key, parent: parent)
        if current.names[key] == nil {
            guard case .use(let name, let replacing) = try await resolveName(localName, key: key, parent: parent, in: target, folder: file.isFolder, incoming: file.modified) else {
                try edit { $0.completedPaths.insert(key); $0.recordSkip(key, leaf: localName, folder: file.isFolder, bytes: file.size) }
                advance(file.size ?? 0)
                return
            }
            try edit(coalesce: true) { $0.names[key] = name; $0.replacements[key] = replacing }
            current = try job()
        }
        let name = current.names[key]!
        claim(name, in: NameClaims.remote(account: target.account.id, parent: parent))
        if file.isFolder {
            let remote = try await ensureFolder(key, name: name, parent: parent, in: target, current: current) {
                L("No se confirmó la creación de \(name) en el destino. Revisa antes de reintentar. \($0)")
            }
            let children = try await source.list(parent: file.id)
            let known = children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            if known > 0 { try edit(coalesce: true) { $0.total += known } }
            for child in children {
                try await copy(from: source, to: target, file: child, parent: remote, scratch: scratch, key: key + "/" + child.id)
            }
        } else {
            let staged = scratch.appendingPathComponent(TransferQueue.stagedName(key, name))
            var checkpoint = current.uploads[key]
            if let checkpoint, checkpoint.complete {
                guard checkpoint.integrity == .verified || checkpoint.integrity == .unavailable else {
                    throw CloudError.message(L("La copia remota quedó sin verificar. Revisa el destino antes de reintentar."))
                }
                try edit {
                    $0.completedPaths.insert(key)
                    $0.record(key, checkpoint.integrity == .verified ? .verified : .unverified, bytes: file.size)
                }
                try? FileManager.default.removeItem(at: staged)
                advance(file.size ?? 0)
                return
            }
            let canResumeWithoutSource = target.canResumeWithoutSource(checkpoint)
            if !FileManager.default.fileExists(atPath: staged.path), !canResumeWithoutSource {
                // No staged copy (first run, or scratch cleaned): the upload session, if any, is worthless now.
                checkpoint = nil
                try edit(coalesce: true) { $0.uploads[key] = nil; $0.detail = L("Descargando «\(file.name)» de \(source.account.cloud.title)…") }
                // Some providers write the destination as the bytes arrive, so a download cut short by the network
                // leaves a truncated file behind. Downloading beside the staged name and renaming only at the end
                // means a file at `staged` is always a complete one; a retry never uploads half a file as whole.
                let partial = staged.appendingPathExtension("part")
                try? FileManager.default.removeItem(at: partial)
                // Half the work of a cross-cloud transfer is this download, and the bar did not move for any of it.
                let downloaded = done
                // The download checks itself against the listed size and checksum, and deletes what fails, so only
                // a copy that passed is ever renamed into place.
                let verification: DownloadVerification
                do {
                    verification = try await source.download(file: file, to: partial, exportMime: export?.mime) { [queue, id] bytes, total in
                        queue.report(id, base: downloaded, bytes: bytes, total: total)
                    }
                } catch let error as DownloadIntegrityError { try queue.recordFailedCheck(id, key: key, error); throw error }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: partial, to: staged)
                try edit(coalesce: true) { $0.recordDownload(key, DownloadIntegrity(verification), path: $0.reportPath(for: key)) }
            }
            let base = done
            try edit(coalesce: true) { $0.detail = L("Subiendo «\(name)» a \(target.account.cloud.title)…") }
            let receipt = try await target.resumableUpload(local: staged, parent: parent, name: name, replacing: current.replacements[key], checkpoint: checkpoint, save: { [queue, id] checkpoint in
                try queue.edit(id, coalesce: checkpoint.offset > 0 && !checkpoint.complete) { $0.uploads[key] = checkpoint }
            }, progress: { [queue, id] bytes, total in queue.report(id, base: base, bytes: bytes, total: total) })
            // On disk before deleting the only staged copy.
            try await commit {
                $0.completedPaths.insert(key)
                $0.record(key, receipt.verification == .verified ? .verified : .unverified, bytes: file.size,
                          reason: export.map { L("Exportado de Google como .\($0.ext)") })
            }
            try? FileManager.default.removeItem(at: staged)
            advance(file.size ?? 0)
            if current.replacements[key] == nil {
                siblings[parent, default: []].append(Self.fileEntry(name, size: file.size))
            }
        }
        try edit(coalesce: true) { $0.completedPaths.insert(key) }
    }

    // MARK: Download

    func download(api: CloudAPI, file: CloudFile, into folder: URL, key: String = ".") async throws {
        try Task.checkCancellation()
        if try await alreadyCompleted(key, bytes: { file.size ?? 0 }) { return }
        queue.inFlight[id] = ReportCursor(key: key, leaf: file.name, folder: file.isFolder)
        var current = try job()
        let exporting = key == "." && current.exportMime != nil
        let name = FileNames.safe(file.name + (exporting ? "." + (current.exportExtension ?? "pdf") : (file.isGoogleDocument ? ".webloc" : "")))
        var target = folder.appendingPathComponent(current.names[key] ?? name)
        var replace = current.replacements[key] != nil
        let room = NameClaims.local(folder)
        if current.names[key] == nil || (!file.isFolder && !replace && FileManager.default.fileExists(atPath: target.path)) {
            let resolved = try await resolveLocalName(name, in: folder, target: target, room: room, isFolder: file.isFolder, incoming: file.modified)
            guard case .use(let selectedName, let replacing) = resolved.decision else {
                try edit { $0.completedPaths.insert(key); $0.recordSkip(key, leaf: name, folder: file.isFolder, bytes: file.size) }
                advance(file.size ?? 0)
                return
            }
            target = resolved.target
            if replacing != nil { replace = true }
            let replacingNow = replace
            try edit(coalesce: true) { $0.names[key] = selectedName; if replacingNow { $0.replacements[key] = "local" } }
            current = try job()
        }
        claim(target.lastPathComponent, in: room)
        // Never follow an externally substituted symlink, including on recovery.
        if FileManager.default.fileExists(atPath: target.path), try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CloudError.message(L("El destino es un enlace simbólico. Elige otra carpeta.")) }
        if file.isFolder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let children = try await api.list(parent: file.id)
            let known = children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            if known > 0 { try edit(coalesce: true) { $0.total += known } }
            for child in children { try await download(api: api, file: child, into: target, key: key + "/" + child.id) }
        } else {
            let temporary = folder.appendingPathComponent(".icloudy-" + UUID().uuidString + ".part")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var verification: DownloadVerification?
            if file.isGoogleDocument && !exporting {
                guard let url = file.webURL else { throw CloudError.message(L("No hay enlace web para este documento.")) }
                let link = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                try await blockingIO { try link.write(to: temporary) }
            } else {
                let base = done
                // A copy that fails its check is deleted inside `download`; the destination is never touched.
                do {
                    verification = try await api.download(file: file, to: temporary, exportMime: exporting ? current.exportMime : nil) { [queue, id] bytes, total in
                        queue.report(id, base: base, bytes: bytes, total: total)
                    }
                } catch let error as DownloadIntegrityError { try queue.recordFailedCheck(id, key: key, error); throw error }
            }
            try Task.checkCancellation()
            let destination = target, replacing = replace
            try await blockingIO {
                if replacing && FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
            if let verification { try edit(coalesce: true) { $0.recordDownload(key, DownloadIntegrity(verification), path: $0.reportPath(for: key)) } }
            else { try edit(coalesce: true) { $0.record(key, .exported, reason: L("Guardado como enlace .webloc al documento de Google"), counted: false) } }
            advance(file.size ?? 0)
            // Only real content counts as a local copy: a .webloc is a link and an export is a different document.
            if !file.isGoogleDocument, !exporting {
                queue.didStoreLocalCopy?(LocalCopy(accountID: current.accountID, fileID: file.id, name: file.name, path: target.path,
                                                   bookmark: current.bookmark, size: file.size ?? 0,
                                                   remoteModified: file.modified, savedAt: Date(), origin: .download))
            }
        }
        try edit(coalesce: true) { $0.completedPaths.insert(key) }
    }
}
