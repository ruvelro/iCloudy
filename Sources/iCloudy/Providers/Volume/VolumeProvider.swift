import Foundation
import AppKit
import Darwin

/// A folder on this Mac or on a mounted volume, treated as a provider. macOS already speaks SMB, AFP and NFS, so
/// mounting is its job: the user connects the share in the Finder, picks the folder once, and iCloudy keeps a
/// security-scoped bookmark. Everything below is plain file-system work.
///
/// This is the only provider with a genuinely reversible trash, real free space and instant search, because all three
/// come from the file system rather than from a remote API.
@MainActor
final class VolumeProvider: CloudSession, CloudProvider {
    var volumeRootCache: URL?
    var volumeScopeOpen = false
    override func invalidate() {
        super.invalidate()
        if volumeScopeOpen, let volumeRootCache { volumeRootCache.stopAccessingSecurityScopedResource() }
        volumeScopeOpen = false; volumeRootCache = nil
    }
}

extension VolumeProvider {
    /// Root of the account, with its security scope open for as long as this client lives.
    func volumeRoot() throws -> URL {
        if let volumeRootCache { return volumeRootCache }
        guard let path = account.serverURL, let base = URL(string: path) ?? URL(fileURLWithPath: path) as URL? else {
            throw CloudError.message(L("Esta cuenta de volumen no tiene una carpeta válida. Vuelve a conectarla."))
        }
        var resolved = base.isFileURL ? base : URL(fileURLWithPath: path)
        var stale = false
        if let bookmark = account.bookmark {
            if let fromBookmark = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                resolved = fromBookmark
            }
        }
        if resolved.startAccessingSecurityScopedResource() { volumeScopeOpen = true }
        // A stale bookmark still resolves today but stops the day the folder moves, and the account then looks broken
        // for a reason nobody can see. Renewing it while the scope is open costs nothing and keeps it working.
        if stale, let renewed = try? TransferQueue.bookmark(resolved) { bookmarkDidRenew?(renewed) }
        volumeRootCache = resolved
        return resolved
    }
    /// Turns an item id into a URL, refusing anything that would escape the account's folder.
    func volumeURL(_ id: String) throws -> URL {
        let root = try volumeRoot()
        guard id != "root", id != root.path else { return root }
        let target = URL(fileURLWithPath: id).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard target.path == base || target.path.hasPrefix(base + "/") else {
            throw CloudError.message(L("Ese elemento está fuera de la carpeta conectada."))
        }
        _ = try VolumePath(root: root, url: target)
        return target
    }
    private func volumeCheckMounted() throws {
        let root = try volumeRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CloudError.message(L("El volumen no está montado. Conéctalo en el Finder y vuelve a intentarlo."))
        }
    }
    nonisolated static func volumeFile(_ url: URL) -> CloudFile? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // A symbolic link is listed under its own name but never browsed as a folder.
        let link = values.isSymbolicLink == true
        let folder = !link && values.isDirectory == true
        return CloudFile(id: url.standardizedFileURL.path, name: url.lastPathComponent,
                         mime: folder ? "application/vnd.google-apps.folder" : mime(forName: url.lastPathComponent),
                         size: folder ? nil : values.fileSize.map(Int64.init),
                         modified: values.contentModificationDate, webURL: nil, isFolder: folder)
    }

    func volumeList(parent: String) async throws -> [CloudFile] {
        try volumeCheckMounted()
        let directory = try volumeURL(parent)
        let path = try VolumePath(root: volumeRoot(), url: directory)
        let files = try await blockingIO {
            let fd = try path.directory(); defer { close(fd) }
            return try VolumePath.names(fd).map { name in
                try VolumePath.file(parent: fd, name: name, url: directory.appendingPathComponent(name))
            }
        }
        return Self.sorted(files)
    }
    func volumeCreateFolder(name: String, parent: String) async throws -> String {
        let target = try volumeURL(parent).appendingPathComponent(name)
        let path = try VolumePath(root: volumeRoot(), url: target)
        try await blockingIO { guard mkdirat(path.parent, path.name, 0o700) == 0 else { throw VolumePath.error() } }
        return target.standardizedFileURL.path
    }
    func volumeRename(file: CloudFile, name: String) async throws {
        let source = try volumeURL(file.id)
        try await volumeRelocate(from: source, to: source.deletingLastPathComponent().appendingPathComponent(name), copy: false)
    }
    func volumeMove(file: CloudFile, to destination: String) async throws {
        let source = try volumeURL(file.id)
        try await volumeRelocate(from: source, to: try volumeURL(destination).appendingPathComponent(file.name), copy: false)
    }
    func volumeCopy(file: CloudFile, to destination: String) async throws {
        let source = try volumeURL(file.id)
        try await volumeRelocate(from: source, to: try volumeURL(destination).appendingPathComponent(file.name), copy: true)
    }
    private func volumeRelocate(from source: URL, to target: URL, copy: Bool) async throws {
        guard !target.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else {
            throw CloudError.message(L("Una carpeta no puede moverse ni copiarse dentro de sí misma."))
        }
        let root = try volumeRoot()
        let from = try VolumePath(root: root, url: source)
        let to = try VolumePath(root: root, url: target)
        try await blockingIO {
            if copy {
                try VolumePath.copy(sourceParent: from.parent, source: from.name, targetParent: to.parent, target: to.name)
                return
            }
            var original = stat(), destination = stat()
            guard fstatat(from.parent, from.name, &original, AT_SYMLINK_NOFOLLOW) == 0 else { throw VolumePath.error() }
            let same = fstatat(to.parent, to.name, &destination, AT_SYMLINK_NOFOLLOW) == 0 &&
                original.st_dev == destination.st_dev && original.st_ino == destination.st_ino
            // The exclusive rename cannot clobber a destination created after the conflict check.
            let flags = same ? UInt32(0) : UInt32(RENAME_EXCL)
            guard renameatx_np(from.parent, from.name, to.parent, to.name, flags) == 0 else { throw VolumePath.error() }
        }
    }
    /// The only provider whose delete is undoable from the Finder: items go to the user's own Trash.
    func volumeTrash(file: CloudFile) async throws {
        let target = try volumeURL(file.id)
        let root = try volumeRoot()
        try await blockingIO {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var failure: Error?
            coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { coordinated in
                do {
                    // Recheck after acquiring coordination: Finder or another cooperating app may have moved an
                    // ancestor since the initial selection. Foundation owns the reversible Trash operation.
                    _ = try VolumePath(root: root, url: coordinated)
                    do { try FileManager.default.trashItem(at: coordinated, resultingItemURL: nil) }
                    catch { throw CloudError.message(L("Este volumen no admite papelera. Elimina el elemento desde el Finder si quieres borrarlo definitivamente.")) }
                } catch { failure = error }
            }
            if let coordinationError { throw coordinationError }
            if let failure { throw failure }
        }
    }
    func volumeQuota() async throws -> StorageQuota {
        try volumeCheckMounted()
        let root = try volumeRoot()
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        guard let total = values.volumeTotalCapacity.map(Int64.init), total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw CloudError.message(L("El sistema no informa del espacio de este volumen."))
        }
        return StorageQuota(used: max(0, total - free), total: total)
    }
    /// How many entries a search may look at before it gives up and says the answer is partial. The old limit only
    /// counted matches, so a term that matched nothing walked the entire share to the last file.
    static let volumeSearchScanLimit = 200_000
    /// Walks the tree looking at names only, bounded in both directions and stoppable.
    func volumeSearch(term: String) async throws -> SearchPage {
        try volumeCheckMounted()
        let root = try volumeRoot()
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SearchPage(hits: [], next: nil) }
        let accountID = account.id
        let limit = 500, scanLimit = Self.volumeSearchScanLimit
        // Closing the search stops the walk instead of leaving it grinding through a network share nobody is waiting
        // on any more. `blockingIO` passes the cancellation on to the work it runs off the main actor.
        return try await blockingIO {
            var hits: [SearchHit] = []
            var truncated = false
            var scanned = 0
            func walk(_ directory: URL, fd: Int32, depth: Int = 0) throws {
                guard depth < 128 else { truncated = true; return }
                for name in try VolumePath.names(fd, limit: scanLimit - scanned + 1) {
                    try Task.checkCancellation()
                    scanned += 1
                    if hits.count >= limit || scanned > scanLimit { truncated = true; return }
                    let url = directory.appendingPathComponent(name)
                    let file = try VolumePath.file(parent: fd, name: name, url: url)
                    if name.localizedCaseInsensitiveContains(needle) {
                        hits.append(SearchHit(accountID: accountID, file: file, parentID: directory.standardizedFileURL.path))
                    }
                    if file.isFolder, (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
                        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { throw VolumePath.error() }
                        do { try walk(url, fd: child, depth: depth + 1) } catch { close(child); throw error }
                        close(child)
                        if truncated { return }
                    }
                }
            }
            let path = try VolumePath(root: root, url: root)
            let fd = try path.directory(); defer { close(fd) }
            try walk(root, fd: fd)
            return SearchPage(hits: hits, next: nil, incomplete: truncated)
        }
    }
    func volumeTrail(id: String) throws -> [CloudFile] {
        let root = try volumeRoot().standardizedFileURL.path
        let target = try volumeURL(id).standardizedFileURL.path
        guard target != root else { return [] }
        let relative = target.hasPrefix(root + "/") ? String(target.dropFirst(root.count + 1)) : target
        let parts = relative.split(separator: "/").map(String.init)
        return parts.indices.map { index in
            let path = root + "/" + parts[0...index].joined(separator: "/")
            return CloudFile(id: path, name: parts[index], mime: "application/vnd.google-apps.folder",
                             size: nil, modified: nil, webURL: nil, isFolder: true)
        }
    }

    func volumeDownload(file: CloudFile, to destination: URL, maxBytes: Int64? = nil, progress: @escaping (Int64, Int64) -> Void) async throws {
        try volumeCheckMounted()
        let source = try volumeURL(file.id)
        let path = try VolumePath(root: volumeRoot(), url: source)
        try await Self.volumeCopyContents(from: source, to: destination, input: path.openFile(O_RDONLY), maxBytes: maxBytes, progress: progress)
    }
    func volumeUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                      save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try volumeCheckMounted()
        let target = try replacing.map { try volumeURL($0) } ?? volumeURL(parent).appendingPathComponent(name)
        let path = try VolumePath(root: volumeRoot(), url: target)
        cursor.offset = 0; try save(cursor)
        let staging = ".icloudy-" + UUID().uuidString + ".part"
        let fd = openat(path.parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VolumePath.error() }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); unlinkat(path.parent, staging, 0) }
        try await Self.volumeCopyContents(from: local, to: target, output: output, progress: progress)
        try cursor.sourceStamp?.validate(local)
        // rename replaces the directory entry itself and never follows a substituted final symlink.
        let flags = replacing == nil ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(path.parent, staging, path.parent, path.name, flags) == 0 else { throw VolumePath.error() }
        cursor.offset = cursor.total; cursor.complete = true; try save(cursor); progress(cursor.total, cursor.total)
        // A copy either completes or throws, so there is no checksum to compare against.
        return UploadReceipt(remoteID: target.standardizedFileURL.path, verification: .unavailable)
    }
    /// Copies in blocks so large files report progress and can be cancelled, unlike a single copyItem call.
    nonisolated static func volumeCopyContents(from source: URL, to destination: URL, input suppliedInput: FileHandle? = nil, output suppliedOutput: FileHandle? = nil, maxBytes: Int64? = nil, progress: @escaping (Int64, Int64) -> Void) async throws {
        let stamp = try UploadSourceStamp(source)
        let total = stamp.size
        try DownloadBudget.check(total, maximum: maxBytes)
        let input = try suppliedInput ?? FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output: FileHandle
        if let suppliedOutput { output = suppliedOutput }
        else {
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw VolumePath.error() }
            output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        var written: Int64 = 0
        do {
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                try stamp.validate(source)
                let chunk = try await blockingIO { try input.read(upToCount: 4 * 1024 * 1024) ?? Data() }
                try stamp.validate(source)
                if chunk.isEmpty { break }
                try DownloadBudget.check(written + Int64(chunk.count), maximum: maxBytes)
                try await blockingIO { try output.write(contentsOf: chunk) }
                written += Int64(chunk.count)
                let reported = written
                await MainActor.run { progress(reported, max(total, reported)) }
            }
        } catch {
            // Half a file is worse than none: it looks complete to anything that only checks whether it is there.
            if suppliedOutput == nil { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }
}

extension VolumeProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        return try await volumeList(parent: parent)
    }

    func createFolder(name: String, parent: String) async throws -> String {
        return try await volumeCreateFolder(name: name, parent: parent)
    }

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        // None of them fetches with a plain request; `download` branches before reaching here.
                    throw CloudError.message(L("Este proveedor no usa peticiones HTTP."))
    }

    func rename(file: CloudFile, name: String) async throws {
        try await volumeRename(file: file, name: name)
    }

    func move(file: CloudFile, to destination: String) async throws {
        try await volumeMove(file: file, to: destination); return
    }

    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        try await volumeCopy(file: file, to: destination); return
    }

    func trash(file: CloudFile) async throws {
        try await volumeTrash(file: file); return
    }

    func publicLink(for file: CloudFile) async throws -> URL {
        throw CloudError.message(L("Un volumen no tiene enlaces públicos. Compártelo desde el Finder."))
    }

    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        return try await volumeSearch(term: term)
    }

    func folderTrail(id: String) async throws -> [CloudFile] {
        return try volumeTrail(id: id)
    }

    func storageQuota() async throws -> StorageQuota {
        return try await volumeQuota()
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        return try await volumeUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await volumeDownload(file: file, to: destination, maxBytes: maxBytes, progress: progress)
    }
}

extension VolumeProvider {
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        let newID: String

                newID = try (destination.map(volumeURL) ?? volumeURL(file.id).deletingLastPathComponent()).appendingPathComponent(name).standardizedFileURL.path
        return RemoteIdentityChange(oldID: file.id, newID: newID, name: name, descendants: file.isFolder)
    }
}
