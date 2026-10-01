import Foundation
import CryptoKit

/// SHA-1 and SHA-256 over the same bytes. Which of the two pCloud reports depends on the region the account lives
/// in, so both are kept until its answer says which one to compare.
struct PCloudDigest {
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    mutating func update(_ data: Data) { sha1.update(data: data); sha256.update(data: data) }
    var hex: (sha1: String, sha256: String) { (UploadHasher.hex(sha1.finalize()), UploadHasher.hex(sha256.finalize())) }

    /// Compares against what pCloud stored: SHA-256 when it reports one, SHA-1 otherwise. Only an answer that matches
    /// the bytes sent counts as verified; no answer at all leaves the upload unverified rather than failed.
    func verify(against listed: [String: Any]?, name: String) throws -> UploadVerification {
        let (sha1, sha256) = hex
        let expected: String, actual: String
        if let value = listed?["sha256"] as? String, !value.isEmpty { expected = value; actual = sha256 }
        else if let value = listed?["sha1"] as? String, !value.isEmpty { expected = value; actual = sha1 }
        else { return .unavailable }
        guard expected.lowercased() == actual else {
            throw CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
        }
        return .verified
    }
}

extension PCloudProvider {
    /// Below this size a file goes up in a single `uploadfile`, read whole into memory.
    static let pcloudSessionThreshold: Int64 = 8 * 1024 * 1024
    /// Block size of an upload session. pCloud imposes none; this keeps a lost block cheap to send again.
    static let pcloudChunk: Int64 = 4 * 1024 * 1024

    /// `renameifexists` keeps a name taken since the conflict check from being overwritten: without it pCloud
    /// replaces a file of the same name, which is exactly what `replacing` asks for and nothing else should do.
    private static func destination(parent: String, name: String, replacing: String?) -> [String: String] {
        var parameters = ["folderid": folderID(parent)]
        if replacing == nil { parameters["renameifexists"] = "1" }
        parameters["name"] = name
        return parameters
    }

    func pcloudUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                      save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        if cursor.sessionID == nil, cursor.total < Self.pcloudSessionThreshold {
            return try await pcloudSimpleUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        }
        let total = cursor.total
        // A session pCloud no longer knows (it expired, or was saved before the checkpoint said so) starts again
        // from the first byte. What it does know is the authority on how far the upload got: a block can arrive
        // after the checkpoint that should have recorded it was lost.
        if let id = cursor.sessionID {
            do {
                let info = try await pcloud("upload_info", ["uploadid": id])
                let size = (info["size"] as? NSNumber)?.int64Value ?? 0
                if size > total { cursor.sessionID = nil } else { cursor.offset = size }
            } catch let error as ServiceError where !error.retryable {
                cursor.sessionID = nil
            }
        }
        if cursor.sessionID == nil {
            let created = try await pcloud("upload_create", [:], write: true)
            guard let id = (created["uploadid"] as? NSNumber)?.stringValue else { throw CloudError.message(L("No se pudo iniciar la sesión de subida.")) }
            cursor.sessionID = id; cursor.offset = 0; cursor.chunkSize = Self.pcloudChunk
            try save(cursor)
        }
        guard let uploadID = cursor.sessionID else { throw CloudError.message(L("No hay sesión de subida.")) }
        let chunkSize = cursor.chunkSize ?? Self.pcloudChunk

        // The digest covers the whole file. A resumed session did not see its first blocks leave, so they are read
        // again from the local file, which is still here; it is what lets a resumed upload be verified too.
        var digest = PCloudDigest()
        if cursor.offset > 0 {
            let prefix = cursor.offset, step = Self.pcloudChunk
            digest = try await blockingIO {
                var hasher = PCloudDigest()
                let reader = try FileHandle(forReadingFrom: local)
                defer { try? reader.close() }
                var remaining = prefix
                while remaining > 0 {
                    let piece = try reader.read(upToCount: Int(min(remaining, step))) ?? Data()
                    guard !piece.isEmpty else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
                    hasher.update(piece); remaining -= Int64(piece.count)
                }
                return hasher
            }
        }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        while cursor.offset < total {
            try Task.checkCancellation()
            try cursor.sourceStamp?.validate(local)
            let chunk = try await blockingIO { try handle.read(upToCount: Int(chunkSize)) ?? Data() }
            try cursor.sourceStamp?.validate(local)
            guard !chunk.isEmpty else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            var write = try await request(pcloudURL("upload_write", ["uploadid": uploadID, "uploadoffset": String(cursor.offset)]), method: "PUT")
            write.timeoutInterval = 180
            write.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await upload(&write, from: chunk)
            _ = try pcloudCheck(data, response)
            digest.update(chunk)
            cursor.offset += Int64(chunk.count)
            try save(cursor); progress(cursor.offset, total)
        }
        try cursor.sourceStamp?.validate(local)
        var parameters = Self.destination(parent: parent, name: name, replacing: replacing)
        parameters["uploadid"] = uploadID
        let saved = try await pcloud("upload_save", parameters, write: true)
        progress(total, total)
        let entry = Self.uploadedEntry(saved)
        return try await pcloudFinish(entry: entry, listed: nil, digest: digest, name: name, cursor: &cursor, save: save)
    }

    /// One `PUT` with the file as the body and the name as a parameter, which spares a multipart body and a
    /// non-ASCII name inside a header.
    private func pcloudSimpleUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let payload = try await blockingIO { try Data(contentsOf: local) }
        try cursor.sourceStamp?.validate(local)
        var parameters = Self.destination(parent: parent, name: name, replacing: replacing)
        parameters["filename"] = parameters.removeValue(forKey: "name")
        parameters["nopartial"] = "1"
        var request = try await request(pcloudURL("uploadfile", parameters), method: "PUT")
        request.timeoutInterval = 180
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await upload(&request, from: payload)
        let body = try pcloudCheck(data, response)
        progress(cursor.total, cursor.total)
        var digest = PCloudDigest()
        digest.update(payload)
        return try await pcloudFinish(entry: Self.uploadedEntry(body), listed: (body["checksums"] as? [[String: Any]])?.first,
                                      digest: digest, name: name, cursor: &cursor, save: save)
    }

    /// `uploadfile` answers a list of metadata, one per file sent; `upload_save` a single one.
    private static func uploadedEntry(_ body: [String: Any]) -> [String: Any] {
        (body["metadata"] as? [[String: Any]])?.first ?? body["metadata"] as? [String: Any] ?? [:]
    }

    /// Records the commit before anything else can fail, then asks for the stored digest when the answer did not
    /// carry it. Failing to ask leaves the upload unverified: the file is there, and sending it again would only make
    /// a second copy next to it.
    private func pcloudFinish(entry: [String: Any], listed: [String: Any]?, digest: PCloudDigest, name: String,
                              cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void) async throws -> UploadReceipt {
        let remoteID = entry["id"] as? String
        cursor.complete = true; cursor.offset = cursor.total; cursor.remoteID = remoteID
        try save(cursor)
        var stored = listed
        if stored == nil, let remoteID, remoteID.hasPrefix("f") {
            stored = try? await pcloud("checksumfile", ["fileid": Self.numericID(remoteID)])
        }
        return try cursor.finish(remoteID: remoteID, save: save) { try digest.verify(against: stored, name: name) }
    }
}
