import Foundation
import CryptoKit

/// Box uses numeric ids and keeps files and folders on separate routes, so every call needs to know which one it is.
extension CloudAPI {
    func boxID(_ id: String) -> String { id == "root" ? Cloud.box.rootAlias : id }
    static func boxRoute(_ file: CloudFile) -> String { file.isFolder ? "folders" : "files" }
    static let boxListFields = "id,name,size,modified_at,type,shared_link,sha1"

    static func boxFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        let type = value["type"] as? String
        // Web links are bookmarks, not content: expose them the same way shortcuts are elsewhere.
        if type == "web_link" {
            return CloudFile(id: id, name: name, mime: "application/vnd.google-apps.shortcut", size: nil, modified: date(value["modified_at"] as? String),
                             webURL: (value["url"] as? String).flatMap(URL.init(string:)), isFolder: false)
        }
        let folder = type == "folder"
        return CloudFile(id: id, name: name,
                         mime: folder ? "application/vnd.google-apps.folder" : mime(forName: name),
                         size: (value["size"] as? NSNumber)?.int64Value,
                         modified: date(value["modified_at"] as? String),
                         webURL: ((value["shared_link"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)),
                         isFolder: folder)
    }

    func boxList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        var offset = 0
        while true {
            var url = URLComponents(string: "https://api.box.com/2.0/folders/\(Self.segment(boxID(parent)))/items")!
            url.queryItems = [URLQueryItem(name: "fields", value: Self.boxListFields), URLQueryItem(name: "limit", value: "1000"), URLQueryItem(name: "offset", value: String(offset))]
            let result = try await json(url.url!)
            let entries = result["entries"] as? [[String: Any]] ?? []
            files += entries.compactMap(Self.boxFile)
            let total = (result["total_count"] as? NSNumber)?.intValue ?? files.count
            offset += entries.count
            guard !entries.isEmpty, offset < total else { break }
            onPage?(Self.sorted(files))
        }
        return Self.sorted(files)
    }

    func boxUpdate(_ file: CloudFile, body: [String: Any]) async throws -> [String: Any] {
        try await json(URL(string: "https://api.box.com/2.0/\(Self.boxRoute(file))/\(Self.segment(file.id))")!, method: "PUT", body: body)
    }
    func boxCopy(file: CloudFile, to destination: String) async throws {
        _ = try await json(URL(string: "https://api.box.com/2.0/\(Self.boxRoute(file))/\(Self.segment(file.id))/copy")!, method: "POST", body: ["parent": ["id": boxID(destination)]])
    }
    /// Box moves deleted items to its own trash, where they stay for the retention period set by the account.
    func boxTrash(file: CloudFile) async throws {
        let suffix = file.isFolder ? "?recursive=true" : ""
        var request = try await request(URL(string: "https://api.box.com/2.0/\(Self.boxRoute(file))/\(Self.segment(file.id))" + suffix)!, method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
    func boxPublicLink(for file: CloudFile) async throws -> URL {
        let result = try await boxUpdate(file, body: ["shared_link": ["access": "open", "permissions": ["can_download": true]]])
        guard let url = ((result["shared_link"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else {
            throw CloudError.message(L("Box no devolvió el enlace. La organización puede no permitir enlaces públicos."))
        }
        return url
    }
    func boxQuota() async throws -> StorageQuota {
        let result = try await json(URL(string: "https://api.box.com/2.0/users/me?fields=space_amount,space_used")!)
        guard let used = (result["space_used"] as? NSNumber)?.int64Value else { throw CloudError.message(L("El proveedor no ha informado del espacio utilizado.")) }
        let total = (result["space_amount"] as? NSNumber)?.int64Value
        // Box reports an enormous allocation for unlimited accounts; treat a non-positive value as unknown.
        return StorageQuota(used: used, total: (total ?? 0) > 0 ? total : nil)
    }
    func boxSearch(term: String, cursor: String?) async throws -> SearchPage {
        let offset = Int(cursor ?? "0") ?? 0
        var url = URLComponents(string: "https://api.box.com/2.0/search")!
        url.queryItems = [URLQueryItem(name: "query", value: term), URLQueryItem(name: "limit", value: "100"),
                          URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "fields", value: Self.boxListFields + ",parent")]
        let result = try await json(url.url!)
        let entries = result["entries"] as? [[String: Any]] ?? []
        let hits = entries.compactMap { value -> SearchHit? in
            guard let file = Self.boxFile(value) else { return nil }
            return SearchHit(accountID: account.id, file: file, parentID: (value["parent"] as? [String: Any])?["id"] as? String)
        }
        let total = (result["total_count"] as? NSNumber)?.intValue ?? entries.count
        return SearchPage(hits: hits, next: offset + entries.count < total && !entries.isEmpty ? String(offset + entries.count) : nil)
    }
    /// `path_collection` already carries every ancestor, so one request rebuilds the whole breadcrumb trail.
    func boxTrail(id: String) async throws -> [CloudFile] {
        let result = try await json(URL(string: "https://api.box.com/2.0/folders/\(Self.segment(boxID(id)))?fields=id,name,path_collection")!)
        let ancestors = ((result["path_collection"] as? [String: Any])?["entries"] as? [[String: Any]] ?? [])
            .filter { ($0["id"] as? String) != Cloud.box.rootAlias }
        var trail = ancestors.compactMap(Self.boxFile)
        if let id = result["id"] as? String, id != Cloud.box.rootAlias, let name = result["name"] as? String {
            trail.append(CloudFile(id: id, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true))
        }
        return trail
    }

    /// Box refuses upload sessions below 20 MB, so smaller files go through the single-shot multipart endpoint.
    static let boxSessionThreshold: Int64 = 20 * 1024 * 1024

    func boxUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                   save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        if total < Self.boxSessionThreshold {
            return try await boxSimpleUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        if cursor.sessionID == nil {
            let route = replacing.map { "files/\(Self.segment($0))/upload_sessions" } ?? "files/upload_sessions"
            var body: [String: Any] = ["file_size": total, "file_name": name]
            if replacing == nil { body["folder_id"] = boxID(parent) }
            let started = try await json(URL(string: "https://upload.box.com/api/2.0/" + route)!, method: "POST", body: body)
            guard let id = started["id"] as? String, let part = (started["part_size"] as? NSNumber)?.int64Value, part > 0 else {
                throw CloudError.message(L("No se pudo iniciar la sesión de subida."))
            }
            cursor.sessionID = id; cursor.chunkSize = part; cursor.parts = []
            try save(cursor)
        }
        guard let sessionID = cursor.sessionID, let partSize = cursor.chunkSize else { throw CloudError.message(L("No hay sesión de subida.")) }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        var whole = Insecure.SHA1()
        // A resumed session cannot recompute the digest of the whole file from the blocks it already sent.
        var wholeIsComplete = cursor.offset == 0
        while cursor.offset < total {
            try Task.checkCancellation()
            let chunk = try await blockingIO { try handle.read(upToCount: Int(partSize)) ?? Data() }
            guard !chunk.isEmpty else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            if wholeIsComplete { whole.update(data: chunk) }
            var upload = try await request(URL(string: "https://upload.box.com/api/2.0/files/upload_sessions/\(Self.segment(sessionID))")!, method: "PUT")
            upload.timeoutInterval = 180
            upload.setValue("bytes \(cursor.offset)-\(cursor.offset + Int64(chunk.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            upload.setValue("sha=" + Data(Insecure.SHA1.hash(data: chunk)).base64EncodedString(), forHTTPHeaderField: "Digest")
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: upload, from: chunk)
            try HTTP.validate(response, data: data)
            guard let part = (try? HTTP.json(data))?["part"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: part), let text = String(data: encoded, encoding: .utf8) else {
                throw CloudError.message(L("Box no confirmó el bloque enviado."))
            }
            cursor.parts.append(text)
            cursor.offset += Int64(chunk.count)
            try save(cursor); progress(cursor.offset, total)
        }
        let parts = cursor.parts.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        var commit = try await request(URL(string: "https://upload.box.com/api/2.0/files/upload_sessions/\(Self.segment(sessionID))/commit")!, method: "POST", body: ["parts": parts])
        if wholeIsComplete { commit.setValue("sha=" + Data(whole.finalize()).base64EncodedString(), forHTTPHeaderField: "Digest") }
        let (data, response) = try await send(&commit)
        try HTTP.validate(response, data: data)
        cursor.complete = true; try save(cursor); progress(total, total)
        let entry = ((try? HTTP.json(data))?["entries"] as? [[String: Any]])?.first ?? [:]
        wholeIsComplete = wholeIsComplete && entry["sha1"] != nil
        return UploadReceipt(remoteID: entry["id"] as? String, verification: wholeIsComplete ? .verified : .unavailable)
    }

    /// Single request with a multipart body. Bounded by `boxSessionThreshold`, so memory use stays modest.
    private func boxSimpleUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                                 save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let payload = try await blockingIO { try Data(contentsOf: local) }
        let boundary = "icloudy-" + UUID().uuidString
        var attributes: [String: Any] = ["name": name]
        if replacing == nil { attributes["parent"] = ["id": boxID(parent)] }
        let json = String(data: try JSONSerialization.data(withJSONObject: attributes), encoding: .utf8) ?? "{}"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n\(json)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let route = replacing.map { "files/\(Self.segment($0))/content" } ?? "files/content"
        var request = try await request(URL(string: "https://upload.box.com/api/2.0/" + route)!, method: "POST")
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("sha=" + Data(Insecure.SHA1.hash(data: payload)).base64EncodedString(), forHTTPHeaderField: "Digest")
        let (data, response) = try await session.upload(for: request, from: body)
        try HTTP.validate(response, data: data)
        cursor.offset = cursor.total; cursor.complete = true; try save(cursor); progress(cursor.total, cursor.total)
        let entry = ((try? HTTP.json(data))?["entries"] as? [[String: Any]])?.first ?? [:]
        // Box checks the Digest header itself and rejects a mismatch, so a stored sha1 means the bytes arrived intact.
        return UploadReceipt(remoteID: entry["id"] as? String, verification: entry["sha1"] != nil ? .verified : .unavailable)
    }
}
