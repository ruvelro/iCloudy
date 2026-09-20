import Foundation
import CryptoKit

extension CloudAPI {
    /// The checkpoint is committed before sending bytes. Recovery asks the server for its authoritative offset.
    /// Returns whether the provider's checksum matched a hash computed from the very bytes that were sent.
    @discardableResult
    func resumableUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        if let demo {
            let id = try await demo.upload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: checkpoint, save: save, progress: progress)
            return UploadReceipt(remoteID: id, verification: .verified)
        }
        // Once Mega committed a new node, retry only its pending retirement step. The local source
        // (or a cross-cloud staging file) may no longer exist, and uploading again would duplicate it.
        if account.cloud == .mega, var committed = checkpoint, committed.remoteID != nil, !committed.complete {
            return try await megaUpload(local: local, parent: parent, name: name, replacing: replacing,
                                        cursor: &committed, save: save, progress: progress)
        }
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw CloudError.message(L("Solo se admiten archivos regulares, sin enlaces simbólicos.")) }
        let total = Int64(attributes.fileSize ?? 0)
        var cursor = checkpoint ?? UploadCheckpoint(total: total, modified: attributes.contentModificationDate)
        guard cursor.total == total, cursor.modified == attributes.contentModificationDate else { throw CloudError.message(L("El origen ha cambiado. Cancela esta operación y vuelve a subirlo.")) }
        let source = try UploadSourceStamp(local)
        if let original = cursor.sourceStamp { try original.validate(local) }
        cursor.sourceStamp = source
        if cursor.complete {
            guard cursor.integrity != .pending, cursor.integrity != .failed,
                  cursor.integrity != nil || ![.box, .dropbox].contains(account.cloud) else {
                throw CloudError.message(L("La integridad de esta subida falló o quedó sin confirmar. Revisa la copia remota y cancela esta operación antes de volver a subir el archivo."))
            }
            progress(total, total)
            return UploadReceipt(remoteID: cursor.remoteID, verification: cursor.integrity == .verified ? .verified : .unavailable)
        }
        try save(cursor)
        let persistCheckpoint: (UploadCheckpoint) throws -> Void = { checkpoint in
            var durable = checkpoint
            if durable.complete, durable.integrity == nil { durable.integrity = .pending }
            try save(durable)
        }
        let receipt: UploadReceipt
        switch account.cloud {
        case .google, .microsoft:
            receipt = try await rangeUpload(local: local, parent: parent, name: name, replacing: replacing, attributes: attributes, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .dropbox:
            receipt = try await dropboxUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .box:
            receipt = try await boxUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .webdav:
            receipt = try await webdavUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .ftp:
            receipt = try await ftpUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .volume:
            receipt = try await volumeUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .mega:
            receipt = try await megaUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        case .o2:
            receipt = try await o2Upload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        }
        do { try source.validate(local) }
        catch { cursor.complete = true; cursor.integrity = .failed; try save(cursor); throw error }
        cursor.remoteID = receipt.remoteID
        cursor.integrity = receipt.verification == .verified ? .verified : .unavailable
        try save(cursor)
        return receipt
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
            let (data, response) = try await session.data(for: probe, delegate: RedirectGuard.shared)
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
            try cursor.sourceStamp?.validate(local)
            guard total == 0 || !data.isEmpty, cursor.offset + Int64(data.count) <= total else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            var upload = URLRequest(url: url)
            upload.httpMethod = "PUT"; upload.timeoutInterval = 180
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.setValue(total == 0 ? "bytes */0" : "bytes \(cursor.offset)-\(cursor.offset + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            hasher?.update(data)
            let (body, response) = try await session.upload(for: upload, from: data, delegate: RedirectGuard.shared)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [200, 201].contains(status) {
                guard cursor.offset + Int64(data.count) == total else { throw CloudError.message(L("El servidor confirmó una subida incompleta.")) }
                cursor.offset = total; cursor.complete = true
                let item = (try? HTTP.json(body)) ?? [:]
                let stamp = cursor.sourceStamp
                receipt = try cursor.finish(remoteID: item["id"] as? String, save: save) {
                    try stamp?.validate(local)
                    return try hasher?.verify(against: item, name: name) ?? .unavailable
                }
            } else if account.cloud == .google && status == 308 {
                let received = Self.googleOffset(response)
                guard received == cursor.offset + Int64(data.count) else { throw URLError(.networkConnectionLost) }
                cursor.offset = received
            } else if account.cloud == .microsoft && status == 202 {
                let received = try Self.microsoftOffset(body)
                guard received == cursor.offset + Int64(data.count) else { throw URLError(.networkConnectionLost) }
                cursor.offset = received
            } else { throw ServiceError(status: status) }
            if !cursor.complete, cursor.offset == before {
                stalled += 1
                guard stalled < 3 else { throw CloudError.message(L("El servidor acepta los bloques pero no avanza con esta subida. Cancélala y vuelve a intentarlo.")) }
            } else { stalled = 0 }
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

