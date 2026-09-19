import Foundation
import CryptoKit

struct ServiceError: LocalizedError {
    let status: Int
    var detail: String? = nil
    /// Machine-readable code when the body carried one: RFC 6749 `error` (e.g. `invalid_grant`) or the Graph/Drive `error.code`.
    var code: String? = nil
    /// Seconds the provider asked us to wait, from its `Retry-After` header. Waiting less is what turns one refusal
    /// into a string of them.
    var retryAfter: Double? = nil
    var errorDescription: String? { detail ?? "El servicio devolvió HTTP \(status)." }
    var retryable: Bool { [408, 429, 500, 502, 503, 504].contains(status) }
}

extension CloudAPI {
    func rename(file: CloudFile, name: String) async throws {
        if let demo { try demo.rename(file.id, name: name); return }
        switch account.cloud {
        case .google:
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/" + Self.segment(file.id)), method: "PATCH", body: ["name": name])
        case .microsoft:
            _ = try await json(URL(string: "\(graphDrive)/items/" + Self.segment(file.id))!, method: "PATCH", body: ["name": name])
        case .dropbox: try await dropboxRename(file: file, name: name)
        case .ftp: try await ftpRename(file: file, name: name)
        case .volume: try await volumeRename(file: file, name: name)
        case .mega: try await megaRename(file: file, name: name)
        case .o2: try await o2Rename(file: file, name: name)
        case .box: _ = try await boxUpdate(file, body: ["name": name])
        case .webdav: try await webdavRename(file: file, name: name)
        }
    }

    func rootID() async throws -> String {
        if demo != nil { return "root" }
        // Dropbox, Box and WebDAV name their root directly; only Drive and Graph hide it behind an alias.
        if let drive = account.driveID, account.cloud == .google { return drive }
        guard [.google, .microsoft].contains(account.cloud) else { return account.cloud.rootAlias }
        if let rootIDCache { return rootIDCache }
        let endpoint = account.cloud == .google ? googleURL("https://www.googleapis.com/drive/v3/files/root?fields=id") : URL(string: "\(graphDrive)/root?$select=id")!
        guard let id = try await json(endpoint)["id"] as? String else { throw CloudError.message(L("No se pudo identificar la carpeta raíz.")) }
        rootIDCache = id
        return id
    }

    /// Moves an item to another folder of the same account. The caller checks name clashes and cycles beforehand.
    func move(file: CloudFile, to destination: String) async throws {
        if let demo { try demo.move(file.id, to: destination); return }
        switch account.cloud {
        case .dropbox: try await dropboxMove(file: file, to: destination); return
        case .ftp: try await ftpMove(file: file, to: destination); return
        case .volume: try await volumeMove(file: file, to: destination); return
        case .mega: try await megaMove(file: file, to: destination); return
        case .o2: try await o2Move(file: file, to: destination); return
        case .webdav: try await webdavMove(file: file, to: destination); return
        case .box: _ = try await boxUpdate(file, body: ["parent": ["id": boxID(destination)]]); return
        case .google, .microsoft: break
        }
        let target = destination == "root" ? try await rootID() : destination
        if account.cloud == .google {
            // Drive items can have several parents; moving means replacing all of them with the destination.
            let current = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=parents"))
            let parents = (current["parents"] as? [String] ?? []).filter { $0 != target }
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))")!
            url.queryItems = [URLQueryItem(name: "addParents", value: target), URLQueryItem(name: "removeParents", value: parents.joined(separator: ",")), URLQueryItem(name: "fields", value: "id,parents")] + googleAllDrives
            _ = try await json(url.url!, method: "PATCH", body: [:])
        } else {
            _ = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))")!, method: "PATCH", body: ["parentReference": ["id": target]])
        }
    }

    /// Copies an item into another folder. Drive cannot copy folders; Graph copies asynchronously and answers 202.
    func copy(file: CloudFile, to destination: String) async throws {
        if let demo { _ = try demo.copy(file.id, to: destination); return }
        switch account.cloud {
        case .dropbox: try await dropboxCopy(file: file, to: destination); return
        case .ftp: throw CloudError.message(L("FTP no puede copiar en el servidor. Descarga el archivo y vuelve a subirlo."))
        case .volume: try await volumeCopy(file: file, to: destination); return
        case .mega: try await megaCopy(file: file, to: destination); return
        case .o2: throw CloudError.message(L("O2 Cloud no copia archivos en el servidor. Descárgalo y vuelve a subirlo."))
        case .webdav: try await webdavCopy(file: file, to: destination); return
        case .box: try await boxCopy(file: file, to: destination); return
        case .google, .microsoft: break
        }
        let target = destination == "root" ? try await rootID() : destination
        if account.cloud == .google {
            guard !file.isFolder else { throw CloudError.message(L("Google Drive no permite copiar carpetas. Copia los archivos que contiene.")) }
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/copy"), method: "POST", body: ["parents": [target], "name": file.name])
        } else {
            var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/copy")!, method: "POST", body: ["parentReference": ["id": target]])
            let (data, response) = try await send(&request)
            try HTTP.validate(response, data: data)
        }
    }

    /// Moves the item to the provider's trash or recycle bin, which the user can undo on the web. Never a hard delete.
    func trash(file: CloudFile) async throws {
        if let demo { try demo.trash(file.id); return }
        switch account.cloud {
        case .dropbox: try await dropboxTrash(file: file); return
        case .box: try await boxTrash(file: file); return
        case .webdav: try await webdavDelete(file: file); return
        case .ftp: try await ftpDelete(file: file); return
        case .volume: try await volumeTrash(file: file); return
        case .mega: try await megaTrash(file: file); return
        case .o2: try await o2Trash(file: file); return
        case .google, .microsoft: break
        }
        if account.cloud == .google {
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))"), method: "PATCH", body: ["trashed": true])
        } else {
            // Graph's DELETE on a driveItem is a recycle-bin move and answers 204 without a body.
            var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))")!, method: "DELETE")
            let (data, response) = try await send(&request)
            try HTTP.validate(response, data: data)
        }
    }

    /// Grants read-only access to anyone holding the link and returns it. Both providers keep the permission until the
    /// owner removes it on the web, so the caller must confirm with the user first.
    func publicLink(for file: CloudFile) async throws -> URL {
        if let demo { return try demo.publicLink(file.id) }
        switch account.cloud {
        case .dropbox: return try await dropboxPublicLink(for: file)
        case .box: return try await boxPublicLink(for: file)
        case .webdav:
            guard account.flavor == "nextcloud" else {
                throw CloudError.message(L("Este servidor WebDAV no admite enlaces públicos desde iCloudy. Créalos en su interfaz web."))
            }
            return try await nextcloudPublicLink(for: file)
        case .ftp: throw CloudError.message(L("FTP no tiene enlaces públicos."))
        case .volume: throw CloudError.message(L("Un volumen no tiene enlaces públicos. Compártelo desde el Finder."))
        case .mega: return try await megaPublicLink(for: file)
        case .o2: return try await o2PublicLink(for: file)
        case .google, .microsoft: break
        }
        if account.cloud == .google {
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions"), method: "POST", body: ["role": "reader", "type": "anyone"])
            let metadata = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=webViewLink"))
            guard let link = (metadata["webViewLink"] as? String).flatMap(URL.init(string:)) ?? file.webURL else { throw CloudError.message(L("Google no devolvió un enlace para este elemento.")) }
            return link
        }
        let result = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/createLink")!, method: "POST", body: ["type": "view", "scope": "anonymous"])
        guard let link = ((result["link"] as? [String: Any])?["webUrl"] as? String).flatMap(URL.init(string:)) else { throw CloudError.message(L("OneDrive no devolvió el enlace. La organización puede no permitir enlaces anónimos.")) }
        return link
    }

    /// The checkpoint is committed before sending bytes. Recovery asks the server for its authoritative offset.
    /// Returns whether the provider's checksum matched a hash computed from the very bytes that were sent.
    @discardableResult
    func resumableUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        if let demo {
            try await demo.upload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: checkpoint, save: save, progress: progress)
            return UploadReceipt(remoteID: nil, verification: .verified)
        }
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw CloudError.message(L("Solo se admiten archivos regulares, sin enlaces simbólicos.")) }
        let total = Int64(attributes.fileSize ?? 0)
        var cursor = checkpoint ?? UploadCheckpoint(total: total, modified: attributes.contentModificationDate)
        guard cursor.total == total, cursor.modified == attributes.contentModificationDate else { throw CloudError.message(L("El origen ha cambiado. Cancela esta operación y vuelve a subirlo.")) }
        if cursor.complete { progress(total, total); return UploadReceipt(remoteID: nil, verification: .unavailable) }
        switch account.cloud {
        case .google, .microsoft:
            return try await rangeUpload(local: local, parent: parent, name: name, replacing: replacing, attributes: attributes, cursor: &cursor, save: save, progress: progress)
        case .dropbox:
            return try await dropboxUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        case .box:
            return try await boxUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        case .webdav:
            return try await webdavUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        case .ftp:
            return try await ftpUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        case .volume:
            return try await volumeUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        case .mega:
            return try await megaUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        case .o2:
            return try await o2Upload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        }
    }

    /// Google Drive and Microsoft Graph both resume with `Content-Range` against a session URL the server hands out.
    private func rangeUpload(local: URL, parent: String, name: String, replacing: String?, attributes: URLResourceValues,
                             cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void,
                             progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        if let url = cursor.url {
            var probe = URLRequest(url: url)
            probe.httpMethod = account.cloud == .google ? "PUT" : "GET"
            if account.cloud == .google { probe.httpBody = Data(); probe.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range") }
            let (data, response) = try await session.data(for: probe)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if account.cloud == .google, [200, 201].contains(status) {
                cursor.complete = true; cursor.offset = total; try save(cursor); progress(total, total)
                return UploadReceipt(remoteID: (try? HTTP.json(data))?["id"] as? String, verification: .unavailable)
            }
            if [404, 410].contains(status) {
                // Do not blindly recreate: a lost final response can look like an expired session.
                throw CloudError.message(L("La sesión de subida ha caducado o ya terminó. Comprueba el destino antes de iniciar otra subida; esta operación no se repetirá automáticamente."))
            }
            if account.cloud == .google, status == 308 {
                cursor.offset = Self.googleOffset(response)
            } else if account.cloud == .microsoft, status == 200 {
                cursor.offset = try Self.microsoftOffset(data)
            } else { throw ServiceError(status: status) }
            guard cursor.offset >= 0, cursor.offset <= total else { throw CloudError.message(L("El servidor devolvió un avance no válido.")) }
            try save(cursor)
        } else {
            if account.cloud == .google {
                let suffix = replacing.map { "/" + Self.segment($0) } ?? ""
                var metadata: [String: Any] = ["name": name]
                // The top of a shared drive is the drive's own id; sending the alias would file it under "Mi unidad".
                if replacing == nil { metadata["parents"] = [googleParent(parent)] }
                // `fields` on the session request shapes the final response, which is where the checksum comes back.
                var initial = try await request(googleURL("https://www.googleapis.com/upload/drive/v3/files\(suffix)?uploadType=resumable&fields=id,md5Checksum,size"), method: replacing == nil ? "POST" : "PATCH", body: metadata)
                initial.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
                initial.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
                let (data, response) = try await send(&initial)
                try HTTP.validate(response, data: data)
                cursor.url = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
            } else if total == 0 {
                let route = replacing.map { "items/" + Self.segment($0) + "/content" } ?? (graphItem(parent) + ":/" + Self.segment(name) + ":/content?@microsoft.graph.conflictBehavior=fail")
                var empty = try await request(URL(string: "\(graphDrive)/" + route)!, method: "PUT")
                empty.httpBody = Data(); empty.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await send(&empty)
                try HTTP.validate(response, data: data)
                cursor.complete = true; try save(cursor); progress(0, 0)
                return UploadReceipt(remoteID: (try? HTTP.json(data))?["id"] as? String, verification: .unavailable)
            } else {
                let route = replacing.map { "items/" + Self.segment($0) } ?? (graphItem(parent) + ":/" + Self.segment(name) + ":")
                let result = try await json(URL(string: "\(graphDrive)/\(route)/createUploadSession")!, method: "POST", body: ["item": ["@microsoft.graph.conflictBehavior": replacing == nil ? "fail" : "replace", "name": name]])
                cursor.url = (result["uploadUrl"] as? String).flatMap(URL.init(string:))
            }
            guard cursor.url?.scheme == "https" else { throw CloudError.message(L("No se pudo iniciar la sesión de subida.")) }
            try save(cursor)
        }
        guard let url = cursor.url else { throw CloudError.message(L("No hay sesión de subida.")) }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        // Hash the bytes as they leave; a resumed session missed earlier blocks, so it cannot be verified.
        var hasher: UploadHasher? = cursor.offset == 0 ? UploadHasher(cloud: account.cloud) : nil
        var receipt = UploadReceipt(remoteID: nil, verification: .unavailable)
        repeat {
            try Task.checkCancellation()
            let current = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard current.fileSize == attributes.fileSize, current.contentModificationDate == cursor.modified else { throw CloudError.message(L("El archivo cambió durante la subida.")) }
            // Reading 5 MiB blocks on the main actor stalled the interface on slow volumes.
            let data = try await blockingIO { try handle.read(upToCount: 5 * 1024 * 1024) ?? Data() }
            guard total == 0 || !data.isEmpty, cursor.offset + Int64(data.count) <= total else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            var upload = URLRequest(url: url)
            upload.httpMethod = "PUT"; upload.timeoutInterval = 180
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.setValue(total == 0 ? "bytes */0" : "bytes \(cursor.offset)-\(cursor.offset + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            hasher?.update(data)
            let (body, response) = try await session.upload(for: upload, from: data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [200, 201].contains(status) {
                guard cursor.offset + Int64(data.count) == total else { throw CloudError.message(L("El servidor confirmó una subida incompleta.")) }
                cursor.offset = total; cursor.complete = true
                let item = (try? HTTP.json(body)) ?? [:]
                receipt = UploadReceipt(remoteID: item["id"] as? String, verification: try hasher?.verify(against: item, name: name) ?? .unavailable)
            } else if account.cloud == .google && status == 308 {
                let received = Self.googleOffset(response)
                guard received == cursor.offset + Int64(data.count) else { throw URLError(.networkConnectionLost) }
                cursor.offset = received
            } else if account.cloud == .microsoft && status == 202 {
                let received = try Self.microsoftOffset(body)
                guard received == cursor.offset + Int64(data.count) else { throw URLError(.networkConnectionLost) }
                cursor.offset = received
            } else { throw ServiceError(status: status) }
            try save(cursor); progress(cursor.offset, total)
        } while !cursor.complete
        return receipt
    }
    private static func googleOffset(_ response: URLResponse) -> Int64 {
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"), let end = range.split(separator: "-").last.flatMap({ Int64($0) }) else { return 0 }
        return end + 1
    }
    private static func microsoftOffset(_ data: Data) throws -> Int64 {
        let result = try HTTP.json(data)
        guard let ranges = result["nextExpectedRanges"] as? [String], let start = ranges.first?.split(separator: "-").first, let offset = Int64(start) else { throw CloudError.message(L("No se pudo recuperar el avance de OneDrive.")) }
        return offset
    }
}

enum UploadVerification: String, Codable { case verified, unavailable }
struct UploadReceipt {
    let remoteID: String?
    let verification: UploadVerification
}

/// Incremental digests over the uploaded blocks. Drive reports `md5Checksum`; Graph reports `sha256Hash` or `sha1Hash`
/// (personal accounts) and `quickXorHash` (business). QuickXorHash is not implemented, so business uploads stay
/// "unavailable" rather than risking a false mismatch.
struct UploadHasher {
    private var md5 = Insecure.MD5()
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    private let cloud: Cloud
    init(cloud: Cloud) { self.cloud = cloud }
    mutating func update(_ data: Data) {
        if cloud == .google { md5.update(data: data) } else { sha1.update(data: data); sha256.update(data: data) }
    }
    /// Throws when the provider's checksum disagrees: the bytes stored are not the bytes sent.
    func verify(against item: [String: Any], name: String) throws -> UploadVerification {
        let expected: String?, actual: String
        if cloud == .google {
            expected = item["md5Checksum"] as? String
            actual = Self.hex(md5.finalize())
        } else {
            let hashes = (item["file"] as? [String: Any])?["hashes"] as? [String: Any]
            if let sha = hashes?["sha256Hash"] as? String { expected = sha; actual = Self.hex(sha256.finalize()) }
            else { expected = hashes?["sha1Hash"] as? String; actual = Self.hex(sha1.finalize()) }
        }
        guard let expected else { return .unavailable }
        guard expected.lowercased() == actual.lowercased() else {
            throw CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
        }
        return .verified
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}
