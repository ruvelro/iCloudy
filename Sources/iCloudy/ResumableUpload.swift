import Foundation

struct ServiceError: LocalizedError {
    let status: Int
    var detail: String? = nil
    /// Machine-readable code when the body carried one: RFC 6749 `error` (e.g. `invalid_grant`) or the Graph/Drive `error.code`.
    var code: String? = nil
    var errorDescription: String? { detail ?? "El servicio devolvió HTTP \(status)." }
    var retryable: Bool { [408, 429, 500, 502, 503, 504].contains(status) }
}

extension CloudAPI {
    func rename(file: CloudFile, name: String) async throws {
        if let demo { try demo.rename(file.id, name: name); return }
        let base = account.cloud == .google ? "https://www.googleapis.com/drive/v3/files/" : "https://graph.microsoft.com/v1.0/me/drive/items/"
        _ = try await json(URL(string: base + Self.segment(file.id))!, method: "PATCH", body: ["name": name])
    }

    func rootID() async throws -> String {
        if demo != nil { return "root" }
        if let rootIDCache { return rootIDCache }
        let endpoint = account.cloud == .google ? "https://www.googleapis.com/drive/v3/files/root?fields=id" : "https://graph.microsoft.com/v1.0/me/drive/root?$select=id"
        guard let id = try await json(URL(string: endpoint)!)["id"] as? String else { throw CloudError.message("No se pudo identificar la carpeta raíz.") }
        rootIDCache = id
        return id
    }

    /// Moves an item to another folder of the same account. The caller checks name clashes and cycles beforehand.
    func move(file: CloudFile, to destination: String) async throws {
        if let demo { try demo.move(file.id, to: destination); return }
        let target = destination == "root" ? try await rootID() : destination
        if account.cloud == .google {
            // Drive items can have several parents; moving means replacing all of them with the destination.
            let current = try await json(URL(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=parents")!)
            let parents = (current["parents"] as? [String] ?? []).filter { $0 != target }
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))")!
            url.queryItems = [URLQueryItem(name: "addParents", value: target), URLQueryItem(name: "removeParents", value: parents.joined(separator: ",")), URLQueryItem(name: "fields", value: "id,parents")]
            _ = try await json(url.url!, method: "PATCH", body: [:])
        } else {
            _ = try await json(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.segment(file.id))")!, method: "PATCH", body: ["parentReference": ["id": target]])
        }
    }

    /// Copies an item into another folder. Drive cannot copy folders; Graph copies asynchronously and answers 202.
    func copy(file: CloudFile, to destination: String) async throws {
        if let demo { _ = try demo.copy(file.id, to: destination); return }
        let target = destination == "root" ? try await rootID() : destination
        if account.cloud == .google {
            guard !file.isFolder else { throw CloudError.message("Google Drive no permite copiar carpetas. Copia los archivos que contiene.") }
            _ = try await json(URL(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/copy")!, method: "POST", body: ["parents": [target], "name": file.name])
        } else {
            var request = try await request(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.segment(file.id))/copy")!, method: "POST", body: ["parentReference": ["id": target]])
            let (data, response) = try await send(&request)
            try HTTP.validate(response, data: data)
        }
    }

    /// Moves the item to the provider's trash or recycle bin, which the user can undo on the web. Never a hard delete.
    func trash(file: CloudFile) async throws {
        if let demo { try demo.trash(file.id); return }
        if account.cloud == .google {
            _ = try await json(URL(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))")!, method: "PATCH", body: ["trashed": true])
        } else {
            // Graph's DELETE on a driveItem is a recycle-bin move and answers 204 without a body.
            var request = try await request(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.segment(file.id))")!, method: "DELETE")
            let (data, response) = try await send(&request)
            try HTTP.validate(response, data: data)
        }
    }

    /// Grants read-only access to anyone holding the link and returns it. Both providers keep the permission until the
    /// owner removes it on the web, so the caller must confirm with the user first.
    func publicLink(for file: CloudFile) async throws -> URL {
        if let demo { return try demo.publicLink(file.id) }
        if account.cloud == .google {
            _ = try await json(URL(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions")!, method: "POST", body: ["role": "reader", "type": "anyone"])
            let metadata = try await json(URL(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=webViewLink")!)
            guard let link = (metadata["webViewLink"] as? String).flatMap(URL.init(string:)) ?? file.webURL else { throw CloudError.message("Google no devolvió un enlace para este elemento.") }
            return link
        }
        let result = try await json(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.segment(file.id))/createLink")!, method: "POST", body: ["type": "view", "scope": "anonymous"])
        guard let link = ((result["link"] as? [String: Any])?["webUrl"] as? String).flatMap(URL.init(string:)) else { throw CloudError.message("OneDrive no devolvió el enlace. La organización puede no permitir enlaces anónimos.") }
        return link
    }

    /// The checkpoint is committed before sending bytes. Recovery asks the server for its authoritative offset.
    func resumableUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws {
        if let demo { try await demo.upload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: checkpoint, save: save, progress: progress); return }
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw CloudError.message("Solo se admiten archivos regulares, sin enlaces simbólicos.") }
        let total = Int64(attributes.fileSize ?? 0)
        var cursor = checkpoint ?? UploadCheckpoint(total: total, modified: attributes.contentModificationDate)
        guard cursor.total == total, cursor.modified == attributes.contentModificationDate else { throw CloudError.message("El origen ha cambiado. Cancela esta operación y vuelve a subirlo.") }
        if cursor.complete { progress(total, total); return }
        if let url = cursor.url {
            var probe = URLRequest(url: url)
            probe.httpMethod = account.cloud == .google ? "PUT" : "GET"
            if account.cloud == .google { probe.httpBody = Data(); probe.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range") }
            let (data, response) = try await session.data(for: probe)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if account.cloud == .google, [200, 201].contains(status) {
                cursor.complete = true; cursor.offset = total; try save(cursor); progress(total, total); return
            }
            if [404, 410].contains(status) {
                // Do not blindly recreate: a lost final response can look like an expired session.
                throw CloudError.message("La sesión de subida ha caducado o ya terminó. Comprueba el destino antes de iniciar otra subida; esta operación no se repetirá automáticamente.")
            }
            if account.cloud == .google, status == 308 {
                cursor.offset = Self.googleOffset(response)
            } else if account.cloud == .microsoft, status == 200 {
                cursor.offset = try Self.microsoftOffset(data)
            } else { throw ServiceError(status: status) }
            guard cursor.offset >= 0, cursor.offset <= total else { throw CloudError.message("El servidor devolvió un avance no válido.") }
            try save(cursor)
        } else {
            if account.cloud == .google {
                let suffix = replacing.map { "/" + Self.segment($0) } ?? ""
                var metadata: [String: Any] = ["name": name]
                if replacing == nil { metadata["parents"] = [parent] }
                var initial = try await request(URL(string: "https://www.googleapis.com/upload/drive/v3/files\(suffix)?uploadType=resumable")!, method: replacing == nil ? "POST" : "PATCH", body: metadata)
                initial.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
                initial.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
                let (data, response) = try await send(&initial)
                try HTTP.validate(response, data: data)
                cursor.url = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
            } else if total == 0 {
                let route = replacing.map { "items/" + Self.segment($0) + "/content" } ?? (graphItem(parent) + ":/" + Self.segment(name) + ":/content?@microsoft.graph.conflictBehavior=fail")
                var empty = try await request(URL(string: "https://graph.microsoft.com/v1.0/me/drive/" + route)!, method: "PUT")
                empty.httpBody = Data(); empty.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await send(&empty)
                try HTTP.validate(response, data: data)
                cursor.complete = true; try save(cursor); progress(0, 0); return
            } else {
                let route = replacing.map { "items/" + Self.segment($0) } ?? (graphItem(parent) + ":/" + Self.segment(name) + ":")
                let result = try await json(URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(route)/createUploadSession")!, method: "POST", body: ["item": ["@microsoft.graph.conflictBehavior": replacing == nil ? "fail" : "replace", "name": name]])
                cursor.url = (result["uploadUrl"] as? String).flatMap(URL.init(string:))
            }
            guard cursor.url?.scheme == "https" else { throw CloudError.message("No se pudo iniciar la sesión de subida.") }
            try save(cursor)
        }
        guard let url = cursor.url else { throw CloudError.message("No hay sesión de subida.") }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        repeat {
            try Task.checkCancellation()
            let current = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard current.fileSize == attributes.fileSize, current.contentModificationDate == cursor.modified else { throw CloudError.message("El archivo cambió durante la subida.") }
            // Reading 5 MiB blocks on the main actor stalled the interface on slow volumes.
            let data = try await blockingIO { try handle.read(upToCount: 5 * 1024 * 1024) ?? Data() }
            guard total == 0 || !data.isEmpty, cursor.offset + Int64(data.count) <= total else { throw CloudError.message("El tamaño del origen ha cambiado.") }
            var upload = URLRequest(url: url)
            upload.httpMethod = "PUT"; upload.timeoutInterval = 180
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.setValue(total == 0 ? "bytes */0" : "bytes \(cursor.offset)-\(cursor.offset + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            let (body, response) = try await session.upload(for: upload, from: data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [200, 201].contains(status) {
                guard cursor.offset + Int64(data.count) == total else { throw CloudError.message("El servidor confirmó una subida incompleta.") }
                cursor.offset = total; cursor.complete = true
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
    }
    private static func googleOffset(_ response: URLResponse) -> Int64 {
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"), let end = range.split(separator: "-").last.flatMap({ Int64($0) }) else { return 0 }
        return end + 1
    }
    private static func microsoftOffset(_ data: Data) throws -> Int64 {
        let result = try HTTP.json(data)
        guard let ranges = result["nextExpectedRanges"] as? [String], let start = ranges.first?.split(separator: "-").first, let offset = Int64(start) else { throw CloudError.message("No se pudo recuperar el avance de OneDrive.") }
        return offset
    }
}
