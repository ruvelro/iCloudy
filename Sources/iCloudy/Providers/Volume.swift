import Foundation
import AppKit

/// A folder on this Mac or on a mounted volume, treated as a provider. macOS already speaks SMB, AFP and NFS, so
/// mounting is its job: the user connects the share in the Finder, picks the folder once, and iCloudy keeps a
/// security-scoped bookmark. Everything below is plain file-system work.
///
/// This is the only provider with a genuinely reversible trash, real free space and instant search, because all three
/// come from the file system rather than from a remote API.
extension CloudAPI {
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
        let files = try await blockingIO {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
                .compactMap(Self.volumeFile)
        }
        return Self.sorted(files)
    }
    func volumeCreateFolder(name: String, parent: String) async throws -> String {
        let target = try volumeURL(parent).appendingPathComponent(name)
        try await blockingIO { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
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
    /// True when both paths name the very same file on disk, which is how a case-insensitive volume answers to
    /// "Foto" and "foto" at once.
    nonisolated static func volumeSameFile(_ first: URL, _ second: URL) -> Bool {
        guard let a = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let b = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return (a as? NSObject)?.isEqual(b) ?? false
    }
    private func volumeRelocate(from source: URL, to target: URL, copy: Bool) async throws {
        try await blockingIO {
            // Renaming only the capitalisation used to be refused as a name clash: on APFS and HFS+ the file being
            // renamed already answers to the new name. Comparing the files themselves tells the two cases apart.
            if !copy, source.path != target.path, Self.volumeSameFile(source, target) {
                let intermediate = source.deletingLastPathComponent().appendingPathComponent(".icloudy-" + UUID().uuidString)
                try FileManager.default.moveItem(at: source, to: intermediate)
                do { try FileManager.default.moveItem(at: intermediate, to: target) }
                catch {
                    guard (try? FileManager.default.moveItem(at: intermediate, to: source)) != nil else {
                        // Both moves failed, so the file is sitting under a hidden name. Saying which one is the
                        // difference between recovering it and believing it was lost.
                        throw CloudError.message(L("No se pudo renombrar y el archivo quedó como «\(intermediate.lastPathComponent)» en la misma carpeta. Renómbralo desde el Finder. (\(error.localizedDescription))"))
                    }
                    throw error
                }
                return
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw CloudError.message(L("Ya existe un elemento con ese nombre en el destino."))
            }
            if copy { try FileManager.default.copyItem(at: source, to: target) }
            else { try FileManager.default.moveItem(at: source, to: target) }
        }
    }
    /// The only provider whose delete is undoable from the Finder: items go to the user's own Trash.
    func volumeTrash(file: CloudFile) async throws {
        let target = try volumeURL(file.id)
        try await blockingIO {
            do { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
            catch {
                // Network volumes often have no Trash of their own; say so instead of deleting behind the user's back.
                throw CloudError.message(L("Este volumen no admite papelera. Elimina el elemento desde el Finder si quieres borrarlo definitivamente."))
            }
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
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                scanned += 1
                try Task.checkCancellation()
                if hits.count >= limit || scanned > scanLimit { truncated = true; break }
                guard url.lastPathComponent.localizedCaseInsensitiveContains(needle), let file = Self.volumeFile(url) else { continue }
                hits.append(SearchHit(accountID: accountID, file: file,
                                      parentID: url.deletingLastPathComponent().standardizedFileURL.path))
            }
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

    func volumeDownload(file: CloudFile, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        try volumeCheckMounted()
        try await Self.volumeCopyContents(from: try volumeURL(file.id), to: destination, progress: progress)
    }
    func volumeUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                      save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try volumeCheckMounted()
        let target = try replacing.map { try volumeURL($0) } ?? volumeURL(parent).appendingPathComponent(name)
        cursor.offset = 0; try save(cursor)
        if replacing != nil {
            // Replacing used to delete the old file and then copy over it, so cancelling or losing the volume halfway
            // left neither the original nor a whole replacement. The new bytes land beside it under a temporary name
            // and only take its place once they are all there.
            let staging = target.deletingLastPathComponent().appendingPathComponent(".icloudy-" + UUID().uuidString + ".part")
            do {
                try await Self.volumeCopyContents(from: local, to: staging, progress: progress)
                try await blockingIO {
                    if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
                    else { try FileManager.default.moveItem(at: staging, to: target) }
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        } else {
            try await Self.volumeCopyContents(from: local, to: target, progress: progress)
        }
        cursor.offset = cursor.total; cursor.complete = true; try save(cursor); progress(cursor.total, cursor.total)
        // A copy either completes or throws, so there is no checksum to compare against.
        return UploadReceipt(remoteID: target.standardizedFileURL.path, verification: .unavailable)
    }
    /// Copies in blocks so large files report progress and can be cancelled, unlike a single copyItem call.
    nonisolated static func volumeCopyContents(from source: URL, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        let total = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CloudError.message(L("No se pudo crear el archivo de destino."))
        }
        let output = try FileHandle(forWritingTo: destination)
        var written: Int64 = 0
        do {
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try await blockingIO { try input.read(upToCount: 4 * 1024 * 1024) ?? Data() }
                if chunk.isEmpty { break }
                try await blockingIO { try output.write(contentsOf: chunk) }
                written += Int64(chunk.count)
                let reported = written
                await MainActor.run { progress(reported, max(total, reported)) }
            }
        } catch {
            // Half a file is worse than none: it looks complete to anything that only checks whether it is there.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
