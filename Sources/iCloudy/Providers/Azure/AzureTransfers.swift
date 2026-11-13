import Foundation
import CryptoKit

/// A block upload in progress, kept in the checkpoint's `sessionID`: a marker, the block-id prefix of this attempt and
/// the item id of the blob it will become. The ids of the blocks Azure has accepted are the checkpoint's `parts`.
struct AzureBlockSession: Equatable {
    static let marker = "azure-blocks"
    let prefix: String
    let objectID: String
    init(prefix: String, objectID: String) { self.prefix = prefix; self.objectID = objectID }
    init?(_ raw: String) {
        let fields = raw.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, fields[0] == Self.marker, !fields[1].isEmpty, !fields[2].isEmpty else { return nil }
        prefix = fields[1]; objectID = fields[2]
    }
    var raw: String { Self.marker + "\n" + prefix + "\n" + objectID }
}

extension AzureProvider {
    // MARK: - Upload

    func azureUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                     save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let target: S3Path
        if let replacing { target = try object(replacing) }
        else {
            guard let folder = try path(parent) else { throw CloudError.message(L("Elige un contenedor antes de subir: Azure no guarda archivos fuera de ellos.")) }
            target = S3Path(bucket: folder.bucket, key: folder.key + name)
        }
        guard !target.isFolder else { throw CloudError.message(L("Introduce un nombre válido.")) }
        if cursor.total <= singleUploadLimit, cursor.sessionID == nil {
            return try await putBlob(local: local, to: target, name: name, replacing: replacing != nil, cursor: &cursor, save: save, progress: progress)
        }
        return try await blockUpload(local: local, to: target, name: name, replacing: replacing != nil, cursor: &cursor, save: save, progress: progress)
    }

    /// One Put Blob with Content-MD5: Azure refuses a body that changed on the way, and answers the MD5 it stored.
    private func putBlob(local: URL, to target: S3Path, name: String, replacing: Bool, cursor: inout UploadCheckpoint,
                         save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let (data, md5) = try await blockingIO { try S3Provider.readPart(local, offset: 0, length: total) }
        try cursor.sourceStamp?.validate(local)
        var call = AzureCall(method: "PUT", container: target.bucket, blob: target.key)
        call.body = data
        call.headers = ["x-ms-blob-type": "BlockBlob", "Content-MD5": md5.base64EncodedString(), "x-ms-blob-content-type": Self.mime(forName: name)]
        if !replacing { call.headers["If-None-Match"] = "*" }
        cursor.offset = 0; try save(cursor)
        let (_, response) = try await azure(call)
        cursor.offset = total; cursor.complete = true; try save(cursor); progress(total, total)
        guard let answered = response.value(forHTTPHeaderField: "Content-MD5") else { return UploadReceipt(remoteID: target.id, verification: .unavailable) }
        guard answered == md5.base64EncodedString() else {
            throw CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
        }
        return UploadReceipt(remoteID: target.id, verification: .verified)
    }

    /// Put Block for each piece, with its own Content-MD5 that Azure checks, and Put Block List to commit them in
    /// order. The checkpoint keeps the accepted block ids, so a retry carries on with the next block; the whole
    /// file's MD5 is stored on the blob (hashed again from the source for the part sent before a resume) so that a
    /// later download can be checked against it.
    private func blockUpload(local: URL, to target: S3Path, name: String, replacing: Bool, cursor: inout UploadCheckpoint,
                             save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        if let raw = cursor.sessionID, AzureBlockSession(raw)?.objectID != target.id {
            cursor.sessionID = nil
        }
        if cursor.sessionID == nil {
            let prefix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            cursor.sessionID = AzureBlockSession(prefix: prefix, objectID: target.id).raw
            cursor.chunkSize = blockOverride ?? Self.blockSize(for: total); cursor.parts = []; cursor.offset = 0
            try save(cursor)
        }
        guard let session = cursor.sessionID.flatMap(AzureBlockSession.init) else { throw CloudError.message(L("No hay sesión de subida.")) }
        let block = cursor.chunkSize ?? Self.blockSize(for: total)
        // The whole file's MD5: what was sent before a resume is read again here, from the same, unchanged source.
        let sent = cursor.offset
        var whole = try await blockingIO { () -> Insecure.MD5 in
            var hasher = Insecure.MD5()
            var offset: Int64 = 0
            while offset < sent {
                try Task.checkCancellation()
                let length = min(8 * 1024 * 1024, sent - offset)
                hasher.update(data: try S3Provider.readPart(local, offset: offset, length: length).data)
                offset += length
            }
            return hasher
        }
        progress(cursor.offset, total)
        while cursor.offset < total {
            try Task.checkCancellation()
            try cursor.sourceStamp?.validate(local)
            let offset = cursor.offset, length = min(block, total - offset)
            let (chunk, md5) = try await blockingIO { try S3Provider.readPart(local, offset: offset, length: length) }
            try cursor.sourceStamp?.validate(local)
            try await TransferThrottle.upload(chunk.count)
            let id = Self.blockID(session: session.prefix, index: cursor.parts.count + 1)
            var call = AzureCall(method: "PUT", container: target.bucket, blob: target.key, query: [("comp", "block"), ("blockid", id)])
            call.body = chunk
            call.headers["Content-MD5"] = md5.base64EncodedString()
            _ = try await azure(call)
            whole.update(data: chunk)
            cursor.parts.append(id)
            cursor.offset = offset + length
            try save(cursor)
            progress(cursor.offset, total)
        }
        var commit = AzureCall(method: "PUT", container: target.bucket, blob: target.key, query: [("comp", "blocklist")])
        commit.body = AzureXML.blockList(cursor.parts)
        commit.headers = ["Content-Type": "application/xml", "x-ms-blob-content-type": Self.mime(forName: name),
                          "x-ms-blob-content-md5": Data(whole.finalize()).base64EncodedString()]
        if !replacing { commit.headers["If-None-Match"] = "*" }
        do { _ = try await azure(commit) }
        catch let error as ServiceError where error.code == "InvalidBlockList" {
            // The blocks expired (a week after they were sent) or belong to another attempt: start again from zero.
            cursor.sessionID = nil; cursor.parts = []; cursor.offset = 0; try save(cursor)
            throw CloudError.message(L("Azure ya no tiene los bloques de esta subida. Vuelve a intentarlo: empezará desde el principio."))
        }
        cursor.sessionID = nil; cursor.offset = total; cursor.complete = true
        try save(cursor)
        progress(total, total)
        // Every block was checked by Azure against an MD5 computed here from the bytes that were sent.
        return UploadReceipt(remoteID: target.id, verification: .verified)
    }

    // MARK: - Download

    /// In ranges of `downloadPiece`, each repeated on its own if the connection drops. The whole file is then held
    /// to the blob's Content-MD5 by `CloudAPI`, when the listing carried one.
    func azureDownload(file: CloudFile, to destination: URL, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let path = try object(file.id)
        guard !path.isFolder else { throw CloudError.message(L("Esto es una carpeta, no un archivo.")) }
        if let maxBytes, let size = file.size, size > maxBytes { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
        let total = file.size ?? 0
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-azure-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw CloudError.message(L("No se pudo preparar la descarga.")) }
        defer { try? FileManager.default.removeItem(at: staging) }
        var written: Int64 = 0
        var pinned: String?
        repeat {
            let ranged = total > downloadPiece
            var call = AzureCall(container: path.bucket, blob: path.key)
            if ranged { call.headers["x-ms-range"] = "bytes=\(written)-\(min(written + downloadPiece, total) - 1)" }
            // Every piece must come from the same version of the blob: a change halfway would stitch two together.
            if let pinned { call.headers["If-Match"] = pinned }
            let base = written
            let (piece, response) = try await fetch(call, maxBytes: maxBytes.map { $0 - base }) { got, _ in progress(base + got, total) }
            defer { try? FileManager.default.removeItem(at: piece) }
            pinned = pinned ?? response.value(forHTTPHeaderField: "ETag")
            let target = staging
            let appended = try await blockingIO { try S3Provider.append(piece, to: target) }
            if response.statusCode == 200 { written = appended; break }
            guard appended > 0 else { throw CloudError.message(L("El servidor devolvió un avance no válido.")) }
            written += appended
            try Task.checkCancellation()
        } while written < total
        progress(written, max(total, written))
        let ready = staging
        try await blockingIO { try FileManager.default.moveItem(at: ready, to: destination) }
    }

    private func fetch(_ call: AzureCall, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        var attempt = 0, dropped = 0
        while true {
            try Task.checkCancellation()
            let request = try signedRequest(call)
            let delegate = DownloadProgress(maxBytes: maxBytes) { bytes, total in Task { @MainActor in progress(bytes, total) } }
            let temporary: URL, response: URLResponse
            do { (temporary, response) = try await session.download(for: request, delegate: delegate) }
            catch let error as URLError where [.networkConnectionLost, .timedOut].contains(error.code) && dropped < 3 {
                dropped += 1
                try await pause(pow(2, Double(dropped)))
                continue
            } catch {
                if delegate.exceededLimit { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
                throw error
            }
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporary)
                throw CloudError.message(L("Respuesta HTTP no válida."))
            }
            if (200..<300).contains(http.statusCode) { return (temporary, http) }
            let body = (try? FileHandle(forReadingFrom: temporary))?.readData(ofLength: 64 * 1024) ?? Data()
            try? FileManager.default.removeItem(at: temporary)
            if attempt < 3, let delay = Self.retryDelay(http, method: "GET", attempt: attempt) {
                attempt += 1
                try await pause(delay)
                continue
            }
            throw failure(http, data: body)
        }
    }

    // MARK: - Copy, move, delete

    /// Copy Blob within the account. Azure may finish it later (`x-ms-copy-status: pending`); the copy is followed
    /// until it ends, so a move never deletes a source whose copy is still on its way.
    func copyBlob(_ source: S3Path, to target: S3Path) async throws {
        let location = try location()
        var sourceURL = try location.url(container: source.bucket, blob: source.key)
        // A SAS account authorizes the source with its own token; Shared Key covers a source in the same account.
        if location.auth == .sas { sourceURL = try location.url(container: source.bucket, blob: source.key, sas: try secret()) }
        var call = AzureCall(method: "PUT", container: target.bucket, blob: target.key)
        call.headers["x-ms-copy-source"] = sourceURL.absoluteString
        var (_, response) = try await azure(call)
        var polls = 0
        while response.value(forHTTPHeaderField: "x-ms-copy-status") == "pending" {
            try Task.checkCancellation()
            polls += 1
            guard polls < 600 else { throw CloudError.message(L("Azure sigue copiando «\(target.name)». Comprueba el destino más tarde.")) }
            try await pause(min(5, 0.5 * Double(polls)))
            response = try await head(target).response
        }
        if let status = response.value(forHTTPHeaderField: "x-ms-copy-status"), status != "success" {
            throw CloudError.message(L("Azure no completó la copia de «\(target.name)»: \(response.value(forHTTPHeaderField: "x-ms-copy-status-description") ?? status)"))
        }
    }

    /// Rename, move and copy are a copy on the server followed by a delete unless it is a copy. A folder is every blob
    /// under its prefix, copied one by one and only then deleted, so a failure halfway leaves the original whole.
    func azureRelocate(_ file: CloudFile, from source: S3Path, to target: S3Path, keepSource: Bool) async throws {
        guard source != target else { throw CloudError.message(L("El elemento ya está en esa carpeta.")) }
        if source.isFolder, source.bucket == target.bucket, target.key.hasPrefix(source.key) {
            throw CloudError.message(L("Una carpeta no puede moverse ni copiarse dentro de sí misma."))
        }
        try await ensureFree(target)
        guard source.isFolder else {
            try await copyBlob(source, to: target)
            if !keepSource { _ = try await azure(AzureCall(method: "DELETE", container: source.bucket, blob: source.key)) }
            return
        }
        let blobs = try await listPages(container: source.bucket, prefix: source.key, delimiter: false).blobs
        for blob in blobs {
            try Task.checkCancellation()
            try await copyBlob(S3Path(bucket: source.bucket, key: blob.name), to: S3Path(bucket: target.bucket, key: target.key + blob.name.dropFirst(source.key.count)))
        }
        if blobs.isEmpty { _ = try await azureCreateFolder(name: target.name, parent: S3Path(bucket: target.bucket, key: target.parentKey).id) }
        if !keepSource {
            for blob in blobs { _ = try await azure(AzureCall(method: "DELETE", container: source.bucket, blob: blob.name)) }
        }
    }

    /// Deletes for good: a blob with its snapshots, or every blob under a folder's prefix.
    func azureDelete(_ path: S3Path) async throws {
        guard !path.key.isEmpty else { throw CloudError.message(L("iCloudy no borra contenedores enteros. Bórralo desde el portal de Azure.")) }
        let names = path.isFolder ? try await listPages(container: path.bucket, prefix: path.key, delimiter: false).blobs.map(\.name) : [path.key]
        for name in names {
            try Task.checkCancellation()
            var call = AzureCall(method: "DELETE", container: path.bucket, blob: name)
            call.headers["x-ms-delete-snapshots"] = "include"
            _ = try await azure(call)
        }
    }
}
