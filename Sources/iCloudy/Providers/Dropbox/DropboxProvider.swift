import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Dropbox addresses everything by path, so iCloudy uses `path_lower` as the item id and the empty string as the root.
/// Ids therefore change when an item is renamed or moved, which is why every write is followed by a fresh listing.
@MainActor
final class DropboxProvider: CloudSession, CloudProvider {
    
}

extension DropboxProvider {
    func dropboxPath(_ id: String) -> String { id == "root" || id == Cloud.dropbox.rootAlias ? "" : id }
    static func dropboxJoin(_ parent: String, _ name: String) -> String {
        (parent == "/" ? "" : parent) + "/" + name
    }
    /// HTTP headers must be ASCII, and Dropbox carries its arguments in one. Non-ASCII characters are escaped as \\uXXXX.
    static func asciiJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.isASCII { result.unicodeScalars.append(scalar) }
            else { for unit in String(scalar).utf16 { result += String(format: "\\u%04x", unit) } }
        }
    }

    /// Every Dropbox call is a POST, reads included, so without `repeatable` none of them would ever be retried and
    /// a single 429 during a busy minute failed the whole operation. `repeatable` is set on the calls that only read,
    /// which can be repeated as often as needed; a create or a move is left alone unless Dropbox says it refused it.
    func dropboxRPC(_ endpoint: String, _ body: [String: Any]? = nil, repeatable: Bool = false) async throws -> [String: Any] {
        var request = try await request(URL(string: "https://api.dropboxapi.com/2/" + endpoint)!, method: "POST", body: body)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await send(&request)
            if attempt < 3, let delay = CloudSession.retryDelay(response, method: "POST", attempt: attempt, repeatable: repeatable) {
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            try HTTP.validate(response, data: data)
            return (try? HTTP.json(data)) ?? [:]
        }
        throw CloudError.message(L("El servicio no responde."))
    }

    static func dropboxFile(_ value: [String: Any]) -> CloudFile? {
        guard let name = value["name"] as? String, let path = value["path_lower"] as? String else { return nil }
        let folder = (value[".tag"] as? String) == "folder"
        return CloudFile(id: path, name: name,
                         mime: folder ? "application/vnd.google-apps.folder" : mime(forName: name),
                         size: (value["size"] as? NSNumber)?.int64Value,
                         modified: date(value["server_modified"] as? String),
                         webURL: nil, isFolder: folder,
                         checksum: (value["content_hash"] as? String).map { ContentHash(algorithm: .dropbox, value: $0) })
    }

    func dropboxList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        if parent == Collection.trash.rootID { return try await dropboxListDeleted(onPage: onPage) }
        var files: [CloudFile] = []
        var result = try await dropboxRPC("files/list_folder", ["path": dropboxPath(parent), "limit": 1000], repeatable: true)
        while true {
            files += (result["entries"] as? [[String: Any]] ?? []).compactMap(Self.dropboxFile)
            guard result["has_more"] as? Bool == true, let cursor = result["cursor"] as? String else { break }
            onPage?(Self.sorted(files))
            result = try await dropboxRPC("files/list_folder/continue", ["cursor": cursor], repeatable: true)
        }
        return Self.sorted(files)
    }

    /// A deleted entry as Dropbox describes it: a name and a path, nothing else. Whether it was a file or a folder is
    /// not said, so it is shown as a file and the restoration finds out.
    static func dropboxDeleted(_ value: [String: Any]) -> CloudFile? {
        guard (value[".tag"] as? String) == "deleted", let name = value["name"] as? String, let path = value["path_lower"] as? String else { return nil }
        return CloudFile(id: path, name: name, mime: mime(forName: name), size: nil, modified: nil, webURL: nil, isFolder: false)
    }
    /// Dropbox has no bin of its own to list: deleted entries are handed out among the live ones when asked for, and
    /// only for the whole account at once. Pages are shown as they arrive because a big account has many of them.
    func dropboxListDeleted(onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        var result = try await dropboxRPC("files/list_folder", ["path": "", "recursive": true, "include_deleted": true, "limit": 2000], repeatable: true)
        while true {
            files += (result["entries"] as? [[String: Any]] ?? []).compactMap(Self.dropboxDeleted)
            guard result["has_more"] as? Bool == true, let cursor = result["cursor"] as? String else { break }
            onPage?(Self.sorted(files))
            result = try await dropboxRPC("files/list_folder/continue", ["cursor": cursor], repeatable: true)
        }
        return Self.sorted(files)
    }
    /// A file comes back by restoring its last revision. Folders have no revisions and no restoration in the API.
    func dropboxRestore(file: CloudFile) async throws {
        let revisions: [String: Any]
        do { revisions = try await dropboxRPC("files/list_revisions", ["path": file.id, "mode": "path", "limit": 1], repeatable: true) }
        catch let error as ServiceError where error.status == 409 {
            throw CloudError.message(L("Dropbox solo restaura archivos desde otras aplicaciones. Una carpeta borrada se recupera desde dropbox.com, con todo su contenido."))
        }
        guard let rev = (revisions["entries"] as? [[String: Any]])?.first?["rev"] as? String else {
            throw CloudError.message(L("Dropbox no conserva ninguna versión de ese archivo."))
        }
        _ = try await dropboxRPC("files/restore", ["path": file.id, "rev": rev])
    }
    /// Purging is a Business feature; a personal account gets a refusal, which is passed on with the reason.
    func dropboxDeletePermanently(file: CloudFile) async throws {
        do { _ = try await dropboxRPC("files/permanently_delete", ["path": file.id]) }
        catch let error as ServiceError where [403, 409].contains(error.status) {
            throw CloudError.message(L("Dropbox solo permite el borrado definitivo en cuentas Business. En esta cuenta los archivos borrados caducan solos al cabo de 30 días, o se eliminan desde dropbox.com."))
        }
    }

    func dropboxCreateFolder(name: String, parent: String) async throws -> String {
        let result = try await dropboxRPC("files/create_folder_v2", ["path": Self.dropboxJoin(dropboxPath(parent), name), "autorename": false])
        guard let metadata = result["metadata"] as? [String: Any], let path = metadata["path_lower"] as? String else {
            throw CloudError.message(L("No se pudo crear la carpeta."))
        }
        return path
    }

    func dropboxRename(file: CloudFile, name: String) async throws {
        _ = try await dropboxRPC("files/move_v2", ["from_path": file.id, "to_path": Self.dropboxJoin(CloudSession.dropboxParent(file.id), name), "autorename": false])
    }
    func dropboxMove(file: CloudFile, to destination: String) async throws {
        _ = try await dropboxRPC("files/move_v2", ["from_path": file.id, "to_path": Self.dropboxJoin(dropboxPath(destination), file.name), "autorename": false])
    }
    func dropboxCopy(file: CloudFile, to destination: String) async throws {
        _ = try await dropboxRPC("files/copy_v2", ["from_path": file.id, "to_path": Self.dropboxJoin(dropboxPath(destination), file.name), "autorename": false])
    }
    /// Dropbox keeps deleted items recoverable from its website, so this matches the trash semantics of the other clouds.
    func dropboxTrash(file: CloudFile) async throws {
        _ = try await dropboxRPC("files/delete_v2", ["path": file.id])
    }

    func dropboxPublicLink(for file: CloudFile) async throws -> URL {
        do {
            let result = try await dropboxRPC("sharing/create_shared_link_with_settings", ["path": file.id, "settings": ["access": "viewer", "audience": "public"]])
            if let url = (result["url"] as? String).flatMap(URL.init(string:)) { return url }
        } catch let error as ServiceError where error.status == 409 {
            // Dropbox refuses to create a second link for the same item; reuse the one already there.
        }
        let existing = try await dropboxRPC("sharing/list_shared_links", ["path": file.id, "direct_only": true], repeatable: true)
        guard let link = (existing["links"] as? [[String: Any]])?.first, let url = (link["url"] as? String).flatMap(URL.init(string:)) else {
            throw CloudError.message(L("Dropbox no devolvió el enlace. La cuenta puede tener restringido compartir."))
        }
        return url
    }

    func dropboxQuota() async throws -> StorageQuota {
        let result = try await dropboxRPC("users/get_space_usage", nil, repeatable: true)
        guard let used = (result["used"] as? NSNumber)?.int64Value else { throw CloudError.message(L("El proveedor no ha informado del espacio utilizado.")) }
        let allocation = result["allocation"] as? [String: Any] ?? [:]
        // Team members report `user_within_team_space_allocated`, which is 0 when the team space is unlimited.
        let allocated = (allocation["allocated"] as? NSNumber)?.int64Value
        return StorageQuota(used: used, total: (allocated ?? 0) > 0 ? allocated : nil)
    }

    func dropboxSearch(term: String, cursor: String?) async throws -> SearchPage {
        let result: [String: Any]
        if let cursor { result = try await dropboxRPC("files/search/continue_v2", ["cursor": cursor], repeatable: true) }
        else { result = try await dropboxRPC("files/search_v2", ["query": term, "options": ["max_results": 100, "filename_only": false]], repeatable: true) }
        let hits = (result["matches"] as? [[String: Any]] ?? []).compactMap { match -> SearchHit? in
            guard let wrapper = match["metadata"] as? [String: Any],
                  let metadata = wrapper["metadata"] as? [String: Any],
                  let file = Self.dropboxFile(metadata) else { return nil }
            return SearchHit(accountID: account.id, file: file, parentID: CloudSession.dropboxParent(file.id))
        }
        return SearchPage(hits: hits, next: result["has_more"] as? Bool == true ? result["cursor"] as? String : nil)
    }

    /// The path already contains the whole ancestry, so the breadcrumbs need no requests at all.
    func dropboxTrail(id: String) -> [CloudFile] {
        let parts = dropboxPath(id).split(separator: "/").map(String.init)
        return parts.indices.map { index in
            let path = "/" + parts[0...index].joined(separator: "/")
            return CloudFile(id: path, name: parts[index], mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        }
    }

    /// Upload sessions take 4 MiB blocks, the same size Dropbox's content hash is defined over.
    nonisolated static let dropboxChunk: Int64 = 4 * 1024 * 1024

    /// The offset Dropbox says it is waiting for, when it refuses the one that was sent.
    ///
    /// Unlike Drive and Graph, Dropbox has no way to ask a session how far it got, and the local checkpoint is
    /// written in batches, so it can be seconds behind after a crash. Its 409 carries the answer: without reading it,
    /// every retry sent the same stale offset, was refused again, and the transfer stayed failed for good.
    static func dropboxCorrectOffset(_ response: URLResponse, _ data: Data) -> Int64? {
        guard (response as? HTTPURLResponse)?.statusCode == 409,
              let body = try? HTTP.json(data), let error = body["error"] as? [String: Any],
              error[".tag"] as? String == "incorrect_offset",
              let offset = (error["correct_offset"] as? NSNumber)?.int64Value, offset >= 0 else { return nil }
        return offset
    }

    func dropboxUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                       save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let destination = replacing ?? Self.dropboxJoin(dropboxPath(parent), name)
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        var hasher: DropboxContentHash? = cursor.offset == 0 ? DropboxContentHash() : nil

        if cursor.sessionID == nil {
            var start = try await request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!, method: "POST")
            start.setValue(Self.asciiJSON(["close": false]), forHTTPHeaderField: "Dropbox-API-Arg")
            start.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await upload(&start, from: Data())
            try HTTP.validate(response, data: data)
            guard let id = (try? HTTP.json(data))?["session_id"] as? String else { throw CloudError.message(L("No se pudo iniciar la sesión de subida.")) }
            cursor.sessionID = id
            try save(cursor)
        }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        // A server that keeps answering with the same offset would otherwise be asked for ever, which is worse than
        // the failure this recovery replaces.
        var corrections = 0
        while cursor.offset < total {
            try cursor.sourceStamp?.validate(local)
            try Task.checkCancellation()
            let chunk = try await blockingIO { try handle.read(upToCount: Int(Self.dropboxChunk)) ?? Data() }
            try cursor.sourceStamp?.validate(local)
            guard !chunk.isEmpty else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            hasher?.update(chunk)
            var append = try await request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/append_v2")!, method: "POST")
            append.timeoutInterval = 180
            append.setValue(Self.asciiJSON(["cursor": ["session_id": cursor.sessionID!, "offset": cursor.offset], "close": false]), forHTTPHeaderField: "Dropbox-API-Arg")
            append.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await upload(&append, from: chunk)
            if let corrected = Self.dropboxCorrectOffset(response, data) {
                corrections += 1
                guard corrected <= total, corrected != cursor.offset, corrections <= 3 else {
                    throw CloudError.message(L("Dropbox sigue rechazando el avance de esta subida. Cancélala y vuelve a subir el archivo."))
                }
                // Some of the file was sent by an attempt whose answer never arrived, so these bytes no longer
                // passed through the hasher in order. The upload continues; it just cannot be verified afterwards.
                hasher = nil
                cursor.offset = corrected
                try await blockingIO { try handle.seek(toOffset: UInt64(corrected)) }
                try save(cursor); progress(cursor.offset, total)
                continue
            }
            try HTTP.validate(response, data: data)
            cursor.offset += Int64(chunk.count)
            try save(cursor); progress(cursor.offset, total)
        }
        try cursor.sourceStamp?.validate(local)
        var finish = try await request(URL(string: "https://content.dropboxapi.com/2/files/upload_session/finish")!, method: "POST")
        finish.setValue(Self.asciiJSON(["cursor": ["session_id": cursor.sessionID!, "offset": cursor.offset],
                                        "commit": ["path": destination, "mode": replacing == nil ? "add" : "overwrite", "autorename": false, "mute": true]]),
                        forHTTPHeaderField: "Dropbox-API-Arg")
        finish.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await upload(&finish, from: Data())
        try HTTP.validate(response, data: data)
        progress(total, total)
        let metadata = (try? HTTP.json(data)) ?? [:]
        return try cursor.finish(remoteID: metadata["path_lower"] as? String, save: save) {
            var verification = UploadVerification.unavailable
            if let expected = metadata["content_hash"] as? String, let hasher {
                guard expected.lowercased() == hasher.finalize() else {
                    throw CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
                }
                verification = .verified
            }
            return verification
        }
    }
}

/// Dropbox's documented content hash: SHA-256 of every 4 MiB block, concatenated, then hashed again.
struct DropboxContentHash {
    private var digests = Data()
    private var pending = Data()
    mutating func update(_ data: Data) {
        pending.append(data)
        while pending.count >= Int(DropboxProvider.dropboxChunk) {
            let block = pending.prefix(Int(DropboxProvider.dropboxChunk))
            digests.append(contentsOf: SHA256.hash(data: block))
            pending.removeFirst(Int(DropboxProvider.dropboxChunk))
        }
    }
    /// Not mutating, so the result can be read from a captured copy after the last block was fed in.
    func finalize() -> String {
        var all = digests
        if !pending.isEmpty { all.append(contentsOf: SHA256.hash(data: pending)) }
        return UploadHasher.hex(SHA256.hash(data: all))
    }
}

extension DropboxProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        return try await dropboxList(parent: parent, onPage: onPage)
    }

    func createFolder(name: String, parent: String) async throws -> String {
        return try await dropboxCreateFolder(name: name, parent: parent)
    }

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        var request = try await request(URL(string: "https://content.dropboxapi.com/2/files/download")!, method: "POST")
                    request.setValue(Self.asciiJSON(["path": dropboxPath(file.id)]), forHTTPHeaderField: "Dropbox-API-Arg")
                    return request
    }

    func rename(file: CloudFile, name: String) async throws {
        try await dropboxRename(file: file, name: name)
    }

    func move(file: CloudFile, to destination: String) async throws {
        try await dropboxMove(file: file, to: destination); return
    }

    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        try await dropboxCopy(file: file, to: destination); return
    }

    func trash(file: CloudFile) async throws {
        try await dropboxTrash(file: file); return
    }
    func restore(file: CloudFile) async throws { try await dropboxRestore(file: file) }
    func deletePermanently(file: CloudFile) async throws { try await dropboxDeletePermanently(file: file) }

    func publicLink(for file: CloudFile) async throws -> URL {
        return try await dropboxPublicLink(for: file)
    }

    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        return try await dropboxSearch(term: term, cursor: cursor)
    }

    func folderTrail(id: String) async throws -> [CloudFile] {
        return dropboxTrail(id: id)
    }

    func storageQuota() async throws -> StorageQuota {
        return try await dropboxQuota()
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        return try await dropboxUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
}

extension DropboxProvider {
    var requiresVerifiedLegacyCheckpoint: Bool { true }
}

extension DropboxProvider {
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        let newID: String

                newID = Self.dropboxJoin(destination.map(dropboxPath) ?? CloudSession.dropboxParent(file.id), name).lowercased()
        return RemoteIdentityChange(oldID: file.id, newID: newID, name: name, descendants: file.isFolder)
    }
}
