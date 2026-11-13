import Foundation

extension GoogleDriveProvider {
    func uploadFile(
        local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> UploadReceipt {
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let total = cursor.total
        if let url = cursor.url {
            switch try await googleStanding(url, total: total) {
            case .finished(let item):
                cursor.complete = true
                cursor.offset = total
                try save(cursor)
                progress(total, total)
                return UploadReceipt(remoteID: item["id"] as? String, verification: .unavailable)
            case .next(let offset):
                cursor.offset = offset
            }
            guard cursor.offset >= 0, cursor.offset <= total else { throw CloudError.message(L("El servidor devolvió un avance no válido.")) }
            try save(cursor)
        } else {
            let suffix = replacing.map { "/" + Self.segment($0) } ?? ""
            var metadata: [String: Any] = ["name": name]
            // The top of a shared drive is the drive's own id; sending the alias would file it under "Mi unidad".
            if replacing == nil { metadata["parents"] = [googleParent(parent)] }
            // `fields` on the session request shapes the final response, which is where the checksum comes back.
            var initial = try await request(
                googleURL("https://www.googleapis.com/upload/drive/v3/files\(suffix)?uploadType=resumable&fields=id,md5Checksum,size"), method: replacing == nil ? "POST" : "PATCH", body: metadata)
            initial.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            initial.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
            let (data, response) = try await send(&initial)
            try HTTP.validate(response, data: data)
            cursor.url = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))

            guard cursor.url?.scheme == "https" else { throw CloudError.message(L("No se pudo iniciar la sesión de subida.")) }
            try save(cursor)
        }
        guard let url = cursor.url else { throw CloudError.message(L("No hay sesión de subida.")) }
        let wire = ResumableSessionUpload.Wire(inProgress: 308, offset: { _, response in Self.googleOffset(response) },
                                                standing: { [self] in try await googleStanding(url, total: total) })
        return try await ResumableSessionUpload(session: session, url: url, cloud: account.cloud, wire: wire, delay: blockRetryDelay)
            .run(local: local, name: name, total: total, fileSize: attributes.fileSize, cursor: &cursor, save: save, progress: progress)
    }

    /// Where a session stands: an empty PUT with `bytes */total` answers 308 with the range received so far, or
    /// 200/201 with the file when the last block got there but its answer did not.
    func googleStanding(_ url: URL, total: Int64) async throws -> ResumableSessionUpload.Standing {
        var probe = URLRequest(url: url)
        probe.httpMethod = "PUT"
        probe.httpBody = Data()
        probe.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (data, response) = try await session.data(for: probe, delegate: RedirectGuard.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [200, 201].contains(status) { return .finished((try? HTTP.json(data)) ?? [:]) }
        if [404, 410].contains(status) {
            // Do not blindly recreate: a lost final response can look like an expired session.
            throw CloudError.message(L("La sesión de subida ha caducado o ya terminó. Comprueba el destino antes de iniciar otra subida; esta operación no se repetirá automáticamente."))
        }
        guard status == 308 else { throw ServiceError(status: status, retryAfter: RetryAfter.seconds(response)) }
        return .next(Self.googleOffset(response))
    }

    static func googleOffset(_ response: URLResponse) -> Int64 {
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"), let end = range.split(separator: "-").last.flatMap({ Int64($0) }) else { return 0 }
        return end + 1
    }
}
