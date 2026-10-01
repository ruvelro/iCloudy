import Foundation
import CryptoKit

/// A multipart upload in progress, kept in the checkpoint's `sessionID` so a cancelled transfer can abort it: the
/// upload id, a line break, and the item id of the object it will become. Upload ids never contain line breaks.
struct S3UploadSession: Equatable {
    let uploadID: String
    let objectID: String
    init(uploadID: String, objectID: String) { self.uploadID = uploadID; self.objectID = objectID }
    init?(_ raw: String) {
        guard let separator = raw.firstIndex(of: "\n") else { return nil }
        uploadID = String(raw[..<separator]); objectID = String(raw[raw.index(after: separator)...])
        guard !uploadID.isEmpty, !objectID.isEmpty else { return nil }
    }
    var raw: String { uploadID + "\n" + objectID }
}

/// One part already accepted by the server: the ETag it gave back and the MD5 computed here over the same bytes.
/// Stored in the checkpoint's `parts`, one per line pair, in part order.
struct S3PartRecord: Equatable {
    let etag: String
    let md5: String
    init(etag: String, md5: String) { self.etag = etag; self.md5 = md5 }
    init?(_ raw: String) {
        let fields = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2, !fields[0].isEmpty else { return nil }
        etag = fields[0]; md5 = fields[1]
    }
    var raw: String { etag + "\n" + md5 }
    /// The server's part ETag is the MD5 of the part, as S3 does for parts that are not encrypted with KMS.
    var verified: Bool { !md5.isEmpty && etag.lowercased() == md5 }
}

extension S3Provider {
    /// Below this a file goes up in one PUT, hashed in memory; above it, in parts that can resume.
    nonisolated static let singleUploadLimit: Int64 = 16 * 1024 * 1024
    /// S3 allows 5 MiB; 8 MiB is what the AWS tools use, and halves the requests.
    nonisolated static let minimumPartSize: Int64 = 8 * 1024 * 1024
    nonisolated static let maximumParts: Int64 = 10_000
    nonisolated static let maximumObjectSize: Int64 = 5 * 1024 * 1024 * 1024 * 1024
    /// CopyObject copies up to 5 GiB in one request; beyond that it has to be done part by part.
    nonisolated static let singleCopyLimit: Int64 = 5 * 1024 * 1024 * 1024

    /// Parts of at least 8 MiB, in whole MiB, and never more than the 10,000 parts S3 accepts.
    nonisolated static func partSize(for total: Int64) -> Int64 {
        let mebibyte: Int64 = 1024 * 1024
        let needed = (total + maximumParts - 1) / maximumParts
        return max(minimumPartSize, (needed + mebibyte - 1) / mebibyte * mebibyte)
    }

    /// The ETag S3 gives a multipart object: the MD5 of the parts' binary MD5s, a dash and how many parts there are.
    nonisolated static func compositeETag(_ partMD5s: [String]) -> String? {
        var joined = Data()
        for hex in partMD5s {
            guard let bytes = bytes(hex: hex), bytes.count == 16 else { return nil }
            joined.append(bytes)
        }
        guard !partMD5s.isEmpty else { return nil }
        return S3Signer.hex(Insecure.MD5.hash(data: joined)) + "-" + String(partMD5s.count)
    }

    /// Bytes from an even-length hexadecimal string, or nil for anything else.
    nonisolated static func bytes(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Reads `length` bytes at `offset` and hashes them, off the main actor.
    nonisolated static func readPart(_ local: URL, offset: Int64, length: Int64) throws -> (data: Data, md5: Data) {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard Int64(data.count) == length else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
        return (data, Data(Insecure.MD5.hash(data: data)))
    }

    private func mismatch(_ name: String) -> CloudError {
        CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
    }

    // MARK: - Upload

    func s3Upload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                  save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let target: S3Path
        if let replacing {
            target = try object(replacing)
        } else {
            guard let folder = try path(parent) else {
                throw CloudError.message(L("Elige un bucket antes de subir: S3 no guarda archivos fuera de ellos."))
            }
            target = S3Path(bucket: folder.bucket, key: folder.key + name)
        }
        guard !target.isFolder else { throw CloudError.message(L("Introduce un nombre válido.")) }
        guard cursor.total <= Self.maximumObjectSize else { throw CloudError.message(L("El archivo supera el tamaño máximo que admite el servicio.")) }
        if cursor.total <= Self.singleUploadLimit, cursor.sessionID == nil {
            return try await singleUpload(local: local, to: target, name: name, cursor: &cursor, save: save, progress: progress)
        }
        return try await multipartUpload(local: local, to: target, name: name, cursor: &cursor, save: save, progress: progress)
    }

    /// One PUT with the real payload hash and Content-MD5, so the server refuses a body that changed on the way. The
    /// ETag it answers is the MD5 of what it stored, unless KMS encrypted it.
    private func singleUpload(local: URL, to target: S3Path, name: String, cursor: inout UploadCheckpoint,
                              save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let (data, md5) = try await blockingIO { try Self.readPart(local, offset: 0, length: total) }
        try cursor.sourceStamp?.validate(local)
        var call = S3Call(method: "PUT", bucket: target.bucket, key: target.key)
        call.body = data
        call.headers["Content-MD5"] = md5.base64EncodedString()
        call.headers["Content-Type"] = Self.mime(forName: name)
        cursor.offset = 0; try save(cursor)
        let (_, response) = try await s3(call) { sent in progress(min(sent, total), total) }
        cursor.offset = total; cursor.complete = true; try save(cursor); progress(total, total)
        let expected = S3Signer.hex(md5)
        guard let etag = S3XML.etag(response.value(forHTTPHeaderField: "ETag")), Self.isPlainMD5(etag), !Self.encrypted(response) else {
            return UploadReceipt(remoteID: target.id, verification: .unavailable)
        }
        guard etag.lowercased() == expected else { throw mismatch(name) }
        return UploadReceipt(remoteID: target.id, verification: .verified)
    }

    private func multipartUpload(local: URL, to target: S3Path, name: String, cursor: inout UploadCheckpoint,
                                 save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let partSize = cursor.chunkSize ?? Self.partSize(for: total)
        if let raw = cursor.sessionID {
            let upload = S3UploadSession(raw)
            if let upload, upload.objectID == target.id {
                do { try await resumeParts(upload, local: local, partSize: partSize, cursor: &cursor, save: save) }
                catch let error as ServiceError where error.code == "NoSuchUpload" || error.status == 404 {
                    // Either the upload expired, or it finished and only its answer was lost. The object tells which.
                    if let receipt = try await committedUpload(target, cursor: &cursor, save: save, progress: progress) { return receipt }
                    cursor.sessionID = nil
                }
            } else {
                // A session for another object: abandon it rather than mix two uploads.
                await abandonUploadSessions(urls: [], boxSessions: [raw])
                cursor.sessionID = nil
            }
        }
        if cursor.sessionID == nil {
            var create = S3Call(method: "POST", bucket: target.bucket, key: target.key, query: [("uploads", nil)])
            create.headers["Content-Type"] = Self.mime(forName: name)
            let (data, _) = try await s3(create)
            let id = try S3XML.uploadID(data)
            cursor.sessionID = S3UploadSession(uploadID: id, objectID: target.id).raw
            cursor.chunkSize = partSize; cursor.parts = []; cursor.offset = 0
            try save(cursor)
        }
        guard let upload = cursor.sessionID.flatMap(S3UploadSession.init) else { throw CloudError.message(L("No hay sesión de subida.")) }
        let secure = try location().isSecure
        var opaque = false
        progress(cursor.offset, total)
        while cursor.offset < total {
            try cursor.sourceStamp?.validate(local)
            try Task.checkCancellation()
            let number = cursor.parts.count + 1
            let offset = cursor.offset, length = min(partSize, total - offset)
            let (chunk, md5) = try await blockingIO { try Self.readPart(local, offset: offset, length: length) }
            try cursor.sourceStamp?.validate(local)
            var call = S3Call(method: "PUT", bucket: target.bucket, key: target.key,
                              query: [("partNumber", String(number)), ("uploadId", upload.uploadID)])
            call.body = chunk
            call.headers["Content-MD5"] = md5.base64EncodedString()
            // Over TLS the channel protects the body and Content-MD5 checks it; hashing 8 MiB twice buys nothing.
            // Over plain HTTP the signature is all there is, so it covers the bytes.
            if secure { call.payloadHash = S3Signer.unsignedPayload }
            let (_, response) = try await s3(call) { sent in progress(offset + min(sent, length), total) }
            guard let etag = S3XML.etag(response.value(forHTTPHeaderField: "ETag")) else {
                throw CloudError.message(L("El servidor no confirmó una de las partes de la subida."))
            }
            let record = S3PartRecord(etag: etag, md5: S3Signer.hex(md5))
            if Self.encrypted(response) || !Self.isPlainMD5(etag) { opaque = true }
            else if !record.verified { throw mismatch(name) }
            cursor.parts.append(record.raw)
            cursor.offset += length
            try save(cursor)
            progress(cursor.offset, total)
        }
        let records = cursor.parts.compactMap(S3PartRecord.init)
        var complete = S3Call(method: "POST", bucket: target.bucket, key: target.key, query: [("uploadId", upload.uploadID)])
        complete.body = S3XML.completeBody(records.map(\.etag))
        complete.headers["Content-Type"] = "application/xml"
        complete.errorsInBody = true
        let (data, response) = try await s3(complete)
        let etag = S3XML.resultETag(data) ?? S3XML.etag(response.value(forHTTPHeaderField: "ETag"))
        cursor.sessionID = nil; cursor.offset = total; cursor.complete = true
        try save(cursor)
        progress(total, total)
        // Every part's ETag was checked against its own MD5 as it went; the object's ETag now proves the server put
        // together exactly those parts, in that order.
        guard !opaque, !Self.encrypted(response), records.allSatisfy(\.verified),
              let expected = Self.compositeETag(records.map(\.md5)), let etag else {
            return UploadReceipt(remoteID: target.id, verification: .unavailable)
        }
        guard etag.lowercased() == expected else { throw mismatch(name) }
        return UploadReceipt(remoteID: target.id, verification: .verified)
    }

    /// Asks the server which parts it already holds and keeps the run of them that still matches the file: the
    /// right size and, where the ETag is an MD5, the MD5 of the same bytes read again from disk. Everything after
    /// the first gap or difference is sent again.
    private func resumeParts(_ upload: S3UploadSession, local: URL, partSize: Int64, cursor: inout UploadCheckpoint,
                             save: (UploadCheckpoint) throws -> Void) async throws {
        let path = try object(upload.objectID)
        var server: [Int: S3Part] = [:]
        var marker: String?
        repeat {
            var query: [(String, String?)] = [("uploadId", upload.uploadID)]
            if let marker { query.append(("part-number-marker", marker)) }
            let (data, _) = try await s3(S3Call(bucket: path.bucket, key: path.key, query: query))
            let page = try S3XML.parts(data)
            for part in page.parts { server[part.number] = part }
            marker = page.next
        } while marker != nil
        let remembered = cursor.parts.compactMap(S3PartRecord.init)
        var kept: [String] = []
        var offset: Int64 = 0
        let total = cursor.total
        while offset < total, let part = server[kept.count + 1] {
            let length = min(partSize, total - offset)
            guard part.size == length else { break }
            let start = offset
            let md5 = S3Signer.hex(try await blockingIO { try Self.readPart(local, offset: start, length: length).md5 })
            let record = S3PartRecord(etag: part.etag, md5: md5)
            // An ETag that is not an MD5 (KMS) is trusted only if this client saw the server give it to these bytes.
            let earlier = remembered.indices.contains(kept.count) ? remembered[kept.count] : nil
            guard record.verified || (earlier?.etag == part.etag && earlier?.md5 == md5) else { break }
            kept.append(record.raw)
            offset += length
        }
        cursor.parts = kept
        cursor.offset = offset
        cursor.chunkSize = partSize
        try save(cursor)
    }

    /// After a NoSuchUpload on resume: if every part had been sent and the object now carries the ETag those parts
    /// make, the upload finished and only its answer was lost.
    private func committedUpload(_ target: S3Path, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void,
                                 progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt? {
        let records = cursor.parts.compactMap(S3PartRecord.init)
        guard cursor.offset == cursor.total, !records.isEmpty, let expected = Self.compositeETag(records.map(\.md5)) else { return nil }
        guard let current = try? await head(target), current.etag?.lowercased() == expected else { return nil }
        cursor.sessionID = nil; cursor.complete = true
        try save(cursor)
        progress(cursor.total, cursor.total)
        return UploadReceipt(remoteID: target.id, verification: records.allSatisfy(\.verified) ? .verified : .unavailable)
    }

    // MARK: - Download

    /// GET with Range: large objects come down in pieces, pinned to the first piece's ETag with If-Match so that an
    /// object replaced halfway cannot produce a file made of two versions. A dropped connection repeats only its piece.
    func s3Download(file: CloudFile, to destination: URL, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let path = try object(file.id)
        guard !path.isFolder else { throw CloudError.message(L("Esto es una carpeta, no un archivo.")) }
        if let maxBytes, let size = file.size, size > maxBytes {
            throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
        }
        let total = file.size ?? 0
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-s3-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw CloudError.message(L("No se pudo preparar la descarga."))
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        var written: Int64 = 0
        var pinned: String?
        repeat {
            let range: ClosedRange<Int64>? = total > downloadPiece ? written...(min(written + downloadPiece, total) - 1) : nil
            let base = written
            let (piece, response) = try await fetch(path, range: range, ifMatch: pinned, maxBytes: maxBytes.map { $0 - base }) { got, _ in
                progress(base + got, total)
            }
            defer { try? FileManager.default.removeItem(at: piece) }
            if Self.encrypted(response) { opaqueChecksums.insert(file.id) } else { opaqueChecksums.remove(file.id) }
            pinned = pinned ?? S3XML.etag(response.value(forHTTPHeaderField: "ETag"))
            let target = staging
            let appended = try await blockingIO { try Self.append(piece, to: target) }
            // A server that ignores Range answers 200 with the whole object, which is then all there is to it.
            if response.statusCode == 200 { written = appended; break }
            guard appended > 0 else { throw CloudError.message(L("El servidor devolvió un avance no válido.")) }
            written += appended
            try Task.checkCancellation()
        } while written < total
        progress(written, max(total, written))
        let ready = staging
        try await blockingIO { try FileManager.default.moveItem(at: ready, to: destination) }
    }

    nonisolated static func append(_ piece: URL, to target: URL) throws -> Int64 {
        let reader = try FileHandle(forReadingFrom: piece)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        try writer.seekToEnd()
        var count: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try reader.read(upToCount: 4 * 1024 * 1024) ?? Data() }
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
            count += Int64(chunk.count)
        }
        return count
    }

    /// One GET into a temporary file, repeated for the refusals S3 asks to repeat and for a connection that drops.
    private func fetch(_ path: S3Path, range: ClosedRange<Int64>?, ifMatch: String?, maxBytes: Int64?,
                       progress: @escaping (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        var call = S3Call(bucket: path.bucket, key: path.key)
        if let range { call.headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)" }
        if let ifMatch { call.headers["If-Match"] = "\"\(ifMatch)\"" }
        var state = RetryState()
        var dropped = 0
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
            switch judge(http, data: body, call: call, state: &state) {
            case .again(let delay): if delay > 0 { try await pause(delay) }
            case .fail(let error): throw error
            }
        }
    }

    // MARK: - Copy, move, delete

    /// Copies one object on the server. Above 5 GiB CopyObject refuses, and the copy is assembled from ranges of the
    /// source with UploadPartCopy.
    func copyObject(_ source: S3Path, size: Int64, to target: S3Path) async throws {
        let copySource = "/" + S3Signer.encode(source.bucket) + "/" + S3Signer.encode(source.key, slash: true)
        guard size > Self.singleCopyLimit else {
            var call = S3Call(method: "PUT", bucket: target.bucket, key: target.key)
            call.headers["x-amz-copy-source"] = copySource
            call.errorsInBody = true
            _ = try await s3(call)
            return
        }
        var create = S3Call(method: "POST", bucket: target.bucket, key: target.key, query: [("uploads", nil)])
        create.headers["Content-Type"] = Self.mime(forName: target.name)
        let uploadID = try S3XML.uploadID(try await s3(create).0)
        do {
            let part = max(512 * 1024 * 1024, Self.partSize(for: size))
            var etags: [String] = []
            var offset: Int64 = 0
            while offset < size {
                try Task.checkCancellation()
                let end = min(offset + part, size) - 1
                var call = S3Call(method: "PUT", bucket: target.bucket, key: target.key,
                                  query: [("partNumber", String(etags.count + 1)), ("uploadId", uploadID)])
                call.headers["x-amz-copy-source"] = copySource
                call.headers["x-amz-copy-source-range"] = "bytes=\(offset)-\(end)"
                call.errorsInBody = true
                guard let etag = S3XML.resultETag(try await s3(call).0) else {
                    throw CloudError.message(L("El servidor no confirmó una de las partes de la subida."))
                }
                etags.append(etag)
                offset = end + 1
            }
            var complete = S3Call(method: "POST", bucket: target.bucket, key: target.key, query: [("uploadId", uploadID)])
            complete.body = S3XML.completeBody(etags)
            complete.headers["Content-Type"] = "application/xml"
            complete.errorsInBody = true
            _ = try await s3(complete)
        } catch {
            await abandonUploadSessions(urls: [], boxSessions: [S3UploadSession(uploadID: uploadID, objectID: target.id).raw])
            throw error
        }
    }

    /// Rename, move and copy are all a copy on the server, followed by a delete unless it is a copy. A folder is every
    /// key under its prefix, copied one by one with progress and only then deleted, so a failure halfway leaves the
    /// original whole.
    func s3Relocate(_ file: CloudFile, from source: S3Path, to target: S3Path, keepSource: Bool) async throws {
        guard source != target else { throw CloudError.message(L("El elemento ya está en esa carpeta.")) }
        if source.isFolder, source.bucket == target.bucket, target.key.hasPrefix(source.key) {
            throw CloudError.message(L("Una carpeta no puede moverse ni copiarse dentro de sí misma."))
        }
        try await ensureFree(target)
        guard source.isFolder else {
            let size: Int64
            if let known = file.size { size = known } else { size = try await head(source).file.size ?? 0 }
            try await copyObject(source, size: size, to: target)
            if !keepSource { try await deleteKeys([source.key], in: source.bucket) }
            return
        }
        let objects = try await listPages(bucket: source.bucket, prefix: source.key, delimiter: false).objects
        relocationProgress?(0, objects.count)
        for (index, item) in objects.enumerated() {
            try Task.checkCancellation()
            let key = target.key + item.key.dropFirst(source.key.count)
            try await copyObject(S3Path(bucket: source.bucket, key: item.key), size: item.size, to: S3Path(bucket: target.bucket, key: key))
            relocationProgress?(index + 1, objects.count)
        }
        // A folder that only existed through its children still exists after the copy; one with nothing at all
        // under it (the listing raced a delete) gets a marker so the operation leaves what it promised.
        if objects.isEmpty { _ = try await s3CreateFolder(name: target.name, parent: S3Path(bucket: target.bucket, key: target.parentKey).id) }
        if !keepSource { try await deleteKeys(objects.map(\.key), in: source.bucket) }
    }

    /// Deletes for good: an object, or every key under a folder's prefix.
    func s3Delete(_ path: S3Path) async throws {
        guard !path.key.isEmpty else { throw CloudError.message(L("iCloudy no borra buckets enteros. Vacía y borra el bucket desde la consola de tu proveedor.")) }
        guard path.isFolder else {
            _ = try await s3(S3Call(method: "DELETE", bucket: path.bucket, key: path.key))
            return
        }
        let keys = try await listPages(bucket: path.bucket, prefix: path.key, delimiter: false).objects.map(\.key)
        try await deleteKeys(keys, in: path.bucket)
    }

    /// DeleteObjects, a thousand keys at a time. A service without it gets one DELETE per key.
    func deleteKeys(_ keys: [String], in bucket: String) async throws {
        var start = 0
        while start < keys.count {
            try Task.checkCancellation()
            let batch = Array(keys[start..<min(start + 1000, keys.count)])
            start += batch.count
            guard batch.count > 1 else {
                _ = try await s3(S3Call(method: "DELETE", bucket: bucket, key: batch[0]))
                continue
            }
            var call = S3Call(method: "POST", bucket: bucket, query: [("delete", nil)])
            call.body = S3XML.deleteBody(batch)
            call.headers["Content-MD5"] = Data(Insecure.MD5.hash(data: call.body!)).base64EncodedString()
            call.headers["Content-Type"] = "application/xml"
            call.repeatable = true
            do {
                let (data, _) = try await s3(call)
                if let failure = S3XML.deleteFailures(data).first {
                    throw ServiceError(status: 500, detail: S3Failure.message(status: 500, body: failure, bucket: bucket) + " " + (failure.message ?? ""), code: failure.code)
                }
            } catch let error as ServiceError where error.status == 501 || error.code == "NotImplemented" {
                for key in batch { _ = try await s3(S3Call(method: "DELETE", bucket: bucket, key: key)) }
            }
        }
    }
}
