import Foundation

extension OneDriveProvider {
    func uploadFile(
        local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> UploadReceipt {
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let total = cursor.total
        if let url = cursor.url {
            guard case .next(let offset) = try await graphStanding(url) else { throw CloudError.message(L("No se pudo recuperar el avance de OneDrive.")) }
            cursor.offset = offset
            guard cursor.offset >= 0, cursor.offset <= total else { throw CloudError.message(L("El servidor devolvió un avance no válido.")) }
            try save(cursor)
        } else {
            if total == 0 {
                let route = replacing.map { "items/" + Self.segment($0) + "/content" } ?? (graphItem(parent) + ":/" + Self.segment(name) + ":/content?@microsoft.graph.conflictBehavior=fail")
                var empty = try await request(URL(string: "\(graphDrive)/" + route)!, method: "PUT")
                empty.httpBody = Data()
                empty.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await send(&empty)
                try HTTP.validate(response, data: data)
                cursor.complete = true
                try save(cursor)
                progress(0, 0)
                return UploadReceipt(remoteID: (try? HTTP.json(data))?["id"] as? String, verification: .unavailable)
            } else {
                let route = replacing.map { "items/" + Self.segment($0) } ?? (graphItem(parent) + ":/" + Self.segment(name) + ":")
                let result = try await json(
                    URL(string: "\(graphDrive)/\(route)/createUploadSession")!, method: "POST",
                    body: ["item": ["@microsoft.graph.conflictBehavior": replacing == nil ? "fail" : "replace", "name": name]])
                cursor.url = (result["uploadUrl"] as? String).flatMap(URL.init(string:))
            }
            guard cursor.url?.scheme == "https" else { throw CloudError.message(L("No se pudo iniciar la sesión de subida.")) }
            try save(cursor)
        }
        guard let url = cursor.url else { throw CloudError.message(L("No hay sesión de subida.")) }
        let wire = ResumableSessionUpload.Wire(inProgress: 202, offset: { body, _ in try Self.microsoftOffset(body) },
                                                standing: { [self] in try await graphStanding(url) })
        return try await ResumableSessionUpload(session: session, url: url, cloud: account.cloud, wire: wire, delay: blockRetryDelay)
            .run(local: local, name: name, total: total, fileSize: attributes.fileSize, cursor: &cursor, save: save, progress: progress)
    }

    /// Where a session stands: a GET on the upload URL lists the ranges Graph still expects.
    func graphStanding(_ url: URL) async throws -> ResumableSessionUpload.Standing {
        var probe = URLRequest(url: url)
        probe.httpMethod = "GET"
        let (data, response) = try await session.data(for: probe, delegate: RedirectGuard.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [404, 410].contains(status) {
            // Do not blindly recreate: a lost final response can look like an expired session.
            throw CloudError.message(L("La sesión de subida ha caducado o ya terminó. Comprueba el destino antes de iniciar otra subida; esta operación no se repetirá automáticamente."))
        }
        guard status == 200 else { throw ServiceError(status: status, retryAfter: RetryAfter.seconds(response)) }
        return .next(try Self.microsoftOffset(data))
    }

    static func microsoftOffset(_ data: Data) throws -> Int64 {
        let result = try HTTP.json(data)
        guard let ranges = result["nextExpectedRanges"] as? [String], let start = ranges.first?.split(separator: "-").first, let offset = Int64(start) else {
            throw CloudError.message(L("No se pudo recuperar el avance de OneDrive."))
        }
        return offset
    }
}
