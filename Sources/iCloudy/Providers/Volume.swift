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
        if let bookmark = account.bookmark {
            var stale = false
            if let fromBookmark = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                resolved = fromBookmark
            }
        }
        if resolved.startAccessingSecurityScopedResource() { volumeScopeOpen = true }
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
    private func volumeRelocate(from source: URL, to target: URL, copy: Bool) async throws {
        try await blockingIO {
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
    /// Walks the tree looking at names only. Bounded so a huge share cannot lock the search up.
    func volumeSearch(term: String) async throws -> SearchPage {
        try volumeCheckMounted()
        let root = try volumeRoot()
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SearchPage(hits: [], next: nil) }
        let accountID = account.id
        let limit = 500
        return try await blockingIO {
            var hits: [SearchHit] = []
            var truncated = false
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                if hits.count >= limit { truncated = true; break }
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
        if replacing != nil { try? FileManager.default.removeItem(at: target) }
        try await Self.volumeCopyContents(from: local, to: target, progress: progress)
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
        defer { try? output.close() }
        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await blockingIO { try input.read(upToCount: 4 * 1024 * 1024) ?? Data() }
            if chunk.isEmpty { break }
            try await blockingIO { try output.write(contentsOf: chunk) }
            written += Int64(chunk.count)
            let reported = written
            await MainActor.run { progress(reported, max(total, reported)) }
        }
    }
}
