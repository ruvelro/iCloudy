import Foundation

/// Keeps the offline copies current. Each account is refreshed by one task at a time, pin by pin; a request that
/// arrives while one runs is merged into the next round instead of starting a second walk of the same tree.
///
/// Every byte goes through `CloudAPI.download`, so a copy is checked against the listed size and the provider's
/// checksum before it replaces the previous one, exactly like any other download. Nothing is uploaded from here.
@MainActor
final class OfflineRefresher {
    enum Scope: Equatable {
        case all
        case pins(Set<String>)
        func merged(with other: Scope) -> Scope {
            switch (self, other) {
            case (.pins(let a), .pins(let b)): return .pins(a.union(b))
            default: return .all
            }
        }
        func includes(_ pin: OfflinePin) -> Bool {
            if case .pins(let folders) = self { return folders.contains(pin.folder) }
            return true
        }
    }

    let store: OfflineStore
    /// The client of an account, or a throw when it is not connected.
    var client: ((String) throws -> CloudAPI)?
    var isOnline: () -> Bool = { true }
    /// When the last refresh of everything was asked for, so the periodic timer knows when the next one is due.
    private(set) var lastFullRefresh = Date.distantPast
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pending: [String: Scope] = [:]
    /// The periodic timer, owned here so the model does not need a property of its own for it.
    var timer: Task<Void, Never>?

    init(store: OfflineStore) { self.store = store }

    var isRunning: Bool { !tasks.isEmpty }

    /// Refreshes the given pins, or all of them. Does nothing offline: the copies stay as they are until the network
    /// comes back, which asks for a refresh of its own.
    func refresh(accountID: String? = nil, scope: Scope = .all) {
        guard isOnline() else { return }
        if accountID == nil, scope == .all { lastFullRefresh = Date() }
        let accounts = accountID.map { [$0] } ?? Array(Set(store.pins.map(\.accountID)))
        for account in accounts where store.pins.contains(where: { $0.accountID == account && scope.includes($0) }) {
            schedule(account, scope)
        }
    }

    func cancel(accountID: String) {
        pending[accountID] = nil
        tasks.removeValue(forKey: accountID)?.cancel()
    }

    /// Waits until nothing is running or queued. For tests and for callers that need the result.
    func wait() async {
        while let task = tasks.values.first { await task.value }
    }

    private func schedule(_ account: String, _ scope: Scope) {
        guard tasks[account] == nil else {
            pending[account] = pending[account].map { $0.merged(with: scope) } ?? scope
            return
        }
        tasks[account] = Task { [weak self] in
            await self?.run(account, scope)
            guard let self else { return }
            self.tasks[account] = nil
            if let next = self.pending.removeValue(forKey: account) { self.schedule(account, next) }
        }
    }

    private func run(_ account: String, _ scope: Scope) async {
        guard let api = try? client?(account) else { return }
        var listings: [String: [CloudFile]] = [:]
        for pin in store.pins where pin.accountID == account && scope.includes(pin) {
            guard !Task.isCancelled, isOnline() else { return }
            // The pin may have been removed while an earlier one was refreshing.
            guard let current = store.pin(folder: pin.folder) else { continue }
            await refresh(current, api: api, listings: &listings)
        }
    }

    /// Refreshes one pin: confirms it still exists, then brings every file it covers up to date.
    func refresh(_ pin: OfflinePin, api: CloudAPI) async {
        var listings: [String: [CloudFile]] = [:]
        await refresh(pin, api: api, listings: &listings)
    }

    private func refresh(_ pin: OfflinePin, api: CloudAPI, listings: inout [String: [CloudFile]]) async {
        store.beginRefresh(pin.folder)
        do {
            // Only the answer about the pinned item itself can unpin it. A child that vanishes halfway through the
            // walk of a folder is that child's business, and the folder stays pinned.
            let found: CloudFile?
            do { found = try await describe(pin, api: api, listings: &listings) }
            catch let error where Self.isNotFound(error) { found = nil }
            guard let remote = found else { return gone(pin) }
            try Task.checkCancellation()
            store.updatePin(pin.folder) { $0.file = remote }
            var current = pin; current.file = remote
            let top = FileNames.safe(remote.name)
            if remote.isFolder {
                var seen: Set<String> = []
                try await walk(remote, relative: top, pin: current, api: api, seen: &seen)
                // Only after a complete walk: a walk cut short has not seen everything that is still there.
                store.dropEntries(of: pin.folder, except: seen)
            } else {
                try await sync(remote, relative: top, pin: current, api: api)
                store.dropEntries(of: pin.folder, except: [remote.id])
            }
            store.endRefresh(pin.folder, error: nil)
        } catch is CancellationError {
            store.endRefresh(pin.folder, error: store.pin(folder: pin.folder)?.lastError)
        } catch {
            store.endRefresh(pin.folder, error: error.localizedDescription)
            if let error = error as? OfflineError { store.notices.append(OfflineNotice(text: error.localizedDescription)) }
        }
    }

    private func gone(_ pin: OfflinePin) {
        store.unpin(pin.folder, notice: L("«\(pin.file.name)» ya no está en la nube y se ha quitado de Sin conexión."))
    }

    /// The item as the provider describes it now, or nil when it is gone. The parent's listing answers for every
    /// provider, and serves every pin in the same folder; asking for the item itself covers one moved elsewhere.
    private func describe(_ pin: OfflinePin, api: CloudAPI, listings: inout [String: [CloudFile]]) async throws -> CloudFile? {
        if let parent = pin.parentID {
            let siblings: [CloudFile]
            if let cached = listings[parent] { siblings = cached } else { siblings = try await api.list(parent: parent); listings[parent] = siblings }
            if let match = siblings.first(where: { $0.id == pin.file.id }) { return match }
        }
        if let current = try await api.currentMetadata(of: pin.file) { return current }
        // Pinned from a list that is not a folder, on a provider that cannot describe one item: nothing says it is
        // gone, so what was known is kept.
        return pin.parentID == nil ? pin.file : nil
    }

    private func walk(_ folder: CloudFile, relative: String, pin: OfflinePin, api: CloudAPI, seen: inout Set<String>) async throws {
        try Task.checkCancellation()
        let children = try await api.list(parent: folder.id)
        var used: Set<String> = []
        for child in children.sorted(by: { $0.id < $1.id }) {
            // Two names that differ only in case, or that sanitise alike, would share a file on this Mac.
            var name = FileNames.safe(child.name)
            if !used.insert(name.lowercased()).inserted {
                let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
                let tag = String(child.id.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }, radix: 16)
                name = stem + " (" + tag + ")" + (ext.isEmpty ? "" : "." + ext)
                used.insert(name.lowercased())
            }
            if child.isFolder {
                try await walk(child, relative: relative + "/" + name, pin: pin, api: api, seen: &seen)
            } else {
                seen.insert(child.id)
                try await sync(child, relative: relative + "/" + name, pin: pin, api: api)
            }
        }
    }

    /// Brings one file up to date: nothing when the copy matches the listing, a move when only its place changed
    /// (a rename, or a cached preview adopted by a pin), a verified download otherwise.
    private func sync(_ file: CloudFile, relative: String, pin: OfflinePin, api: CloudAPI) async throws {
        try Task.checkCancellation()
        // A Google document has no bytes of its own to keep; an export is a different document.
        guard !file.isGoogleDocument else { return }
        let id = OfflineStore.key(accountID: pin.accountID, fileID: file.id)
        let existing = store.entries[id]
        // Another pin already keeps this file (a folder pinned inside a pinned folder): one copy is enough.
        if let owner = existing?.pinFolder, owner != pin.folder, store.pin(folder: owner) != nil { return }
        let path = OfflineStore.accountFolder(pin.accountID) + "/" + pin.folder + "/" + relative
        let target = store.root.appendingPathComponent(path)
        if let existing {
            let source = store.url(of: existing)
            let present = FileManager.default.fileExists(atPath: source.path)
            if !OfflinePolicy.needsDownload(existing, remote: file, localExists: present) {
                var updated = existing
                if existing.relativePath != path {
                    try await blockingIO {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                        try FileManager.default.moveItem(at: source, to: target)
                    }
                    updated.relativePath = path
                }
                updated.pinFolder = pin.folder; updated.name = file.name
                // Fill in what the listing knows and the copy did not record, so the next comparison has it.
                updated.remoteModified = updated.remoteModified ?? file.modified
                updated.checksum = updated.checksum ?? file.checksum
                if updated != existing { store.record(updated) }
                return
            }
        }
        try store.reserve(file.size ?? 0, for: file, accountID: pin.accountID)
        let downloaded: CloudFile
        do { downloaded = try await download(file, to: target, api: api) }
        catch let error where Self.isNotFound(error) {
            // Gone between the listing and the download: nothing to keep, and the next walk will not list it.
            if let existing { store.removeEntry(existing.id) }
            return
        }
        // The pin may have gone while the bytes travelled; its folder has been deleted and so must this copy.
        guard store.pin(folder: pin.folder) != nil else { try? FileManager.default.removeItem(at: target); return }
        if let existing, existing.relativePath != path { store.removeEntry(existing.id) }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? downloaded.size ?? 0
        store.record(OfflineEntry(accountID: pin.accountID, fileID: file.id, name: downloaded.name, relativePath: path, size: size,
                                  remoteModified: downloaded.modified, checksum: downloaded.checksum, pinFolder: pin.folder,
                                  savedAt: Date(), lastAccess: existing?.lastAccess ?? Date()))
    }

    /// Downloads to a hidden file beside the target and puts it in place only after it passed the check, so an open
    /// copy is never seen half written. A file changed while it travelled is fetched once more as it is now.
    private func download(_ file: CloudFile, to target: URL, api: CloudAPI) async throws -> CloudFile {
        let folder = target.deletingLastPathComponent()
        try await blockingIO { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var description = file
        for attempt in 0..<2 {
            let temporary = folder.appendingPathComponent(".icloudy-" + UUID().uuidString + ".part")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try await api.download(file: description, to: temporary)
            } catch let error as DownloadIntegrityError {
                if attempt == 0, case .changedRemotely(_, let current?) = error { description = current; continue }
                throw error
            }
            try Task.checkCancellation()
            let modified = description.modified
            try await blockingIO {
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o444]
                if let modified { attributes[.modificationDate] = modified }
                try FileManager.default.setAttributes(attributes, ofItemAtPath: temporary.path)
                if FileManager.default.fileExists(atPath: target.path) {
                    do { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
                    catch { try FileManager.default.removeItem(at: target); try FileManager.default.moveItem(at: temporary, to: target) }
                } else { try FileManager.default.moveItem(at: temporary, to: target) }
            }
            return description
        }
        throw CloudError.message(L("«\(file.name)» cambió en la nube mientras se descargaba. Se volverá a descargar la versión nueva."))
    }

    /// A refusal that means the item is not there, as opposed to a failure to ask.
    nonisolated static func isNotFound(_ error: Error) -> Bool {
        if let error = error as? ServiceError { return error.status == 404 || error.status == 410 || (error.status == 409 && error.code?.contains("not_found") == true) }
        if let error = error as? DownloadIntegrityError, case .changedRemotely(_, nil) = error { return true }
        return false
    }
}
