import Foundation

extension GoogleDriveProvider {
    func uploadFile(
        local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> UploadReceipt {
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let total = cursor.total
        if let url = cursor.url {
            var probe = URLRequest(url: url)
            probe.httpMethod = "PUT"
            probe.httpBody = Data()
            probe.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
            let (data, response) = try await session.data(for: probe, delegate: RedirectGuard.shared)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [200, 201].contains(status) {
                cursor.complete = true
                cursor.offset = total
                try save(cursor)
                progress(total, total)
                return UploadReceipt(remoteID: (try? HTTP.json(data))?["id"] as? String, verification: .unavailable)
            }
            if [404, 410].contains(status) {
                // Do not blindly recreate: a lost final response can look like an expired session.
                throw CloudError.message(L("La sesión de subida ha caducado o ya terminó. Comprueba el destino antes de iniciar otra subida; esta operación no se repetirá automáticamente."))
            }
            if status == 308 {
                cursor.offset = Self.googleOffset(response)
            } else {
                throw ServiceError(status: status)
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
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        // Hash the bytes as they leave; a resumed session missed earlier blocks, so it cannot be verified.
        var hasher: UploadHasher? = cursor.offset == 0 ? UploadHasher(cloud: account.cloud) : nil
        var receipt = UploadReceipt(remoteID: nil, verification: .unavailable)
        // A server that keeps accepting a block without moving the offset on would otherwise be asked for ever. It is
        // the shape an empty file can take when the answer is a 308 with no range in it.
        var stalled = 0
        repeat {
            try Task.checkCancellation()
            try cursor.sourceStamp?.validate(local)
            let before = cursor.offset
            let current = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard current.fileSize == attributes.fileSize, current.contentModificationDate == cursor.modified else { throw CloudError.message(L("El archivo cambió durante la subida.")) }
            // Reading 5 MiB blocks on the main actor stalled the interface on slow volumes.
            let data = try await blockingIO { try handle.read(upToCount: 5 * 1024 * 1024) ?? Data() }
            try await TransferThrottle.upload(data.count)
            try cursor.sourceStamp?.validate(local)
            guard total == 0 || !data.isEmpty, cursor.offset + Int64(data.count) <= total else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            var upload = URLRequest(url: url)
            upload.httpMethod = "PUT"
            upload.timeoutInterval = 180
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.setValue(total == 0 ? "bytes */0" : "bytes \(cursor.offset)-\(cursor.offset + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            hasher?.update(data)
            let (body, response) = try await session.upload(for: upload, from: data, delegate: RedirectGuard.shared)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [200, 201].contains(status) {
                guard cursor.offset + Int64(data.count) == total else { throw CloudError.message(L("El servidor confirmó una subida incompleta.")) }
                cursor.offset = total
                cursor.complete = true
                let item = (try? HTTP.json(body)) ?? [:]
                let stamp = cursor.sourceStamp
                receipt = try cursor.finish(remoteID: item["id"] as? String, save: save) {
                    try stamp?.validate(local)
                    return try hasher?.verify(against: item, name: name) ?? .unavailable
                }
            } else if status == 308 {
                let received = Self.googleOffset(response)
                guard received == cursor.offset + Int64(data.count) else { throw URLError(.networkConnectionLost) }
                cursor.offset = received
            } else {
                throw ServiceError(status: status)
            }
            if !cursor.complete, cursor.offset == before {
                stalled += 1
                guard stalled < 3 else { throw CloudError.message(L("El servidor acepta los bloques pero no avanza con esta subida. Cancélala y vuelve a intentarlo.")) }
            } else {
                stalled = 0
            }
            try save(cursor)
            progress(cursor.offset, total)
        } while !cursor.complete
        return receipt
    }

    private static func googleOffset(_ response: URLResponse) -> Int64 {
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"), let end = range.split(separator: "-").last.flatMap({ Int64($0) }) else { return 0 }
        return end + 1
    }
}
