import Foundation

/// Nextcloud's chunked upload, version 2. A large file is not one PUT that has to start over whenever the connection
/// drops: it goes up in numbered chunks into a collection of its own under `/remote.php/dav/uploads/{user}/`, and a
/// MOVE of that collection's `.file` onto the target puts the assembled file in place in one step.
///
/// The collection is the upload session: its URL is kept in the checkpoint's `url`, the chunk size in `chunkSize`, and
/// `offset` counts the bytes of the chunks the server has confirmed. A resumed transfer asks whether the collection is
/// still there (the server drops abandoned ones after a day or so) and carries on from the next chunk; cancelling the
/// transfer deletes it. Every request names the final file in `Destination`, which v2 requires so that the server can
/// check quota and permissions before taking the bytes.
/// https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/chunking.html
extension WebDAVProvider {
    /// Files at least this large go up in chunks; smaller ones are a single PUT, which is quicker for them.
    nonisolated static let chunkedUploadThreshold: Int64 = 32 * 1024 * 1024
    /// Nextcloud accepts chunks from 5 MiB to 5 GiB (the last one may be smaller) and at most 10,000 of them.
    nonisolated static let minimumChunk: Int64 = 10 * 1024 * 1024
    nonisolated static let maximumChunks: Int64 = 10_000

    nonisolated static func chunkSize(for total: Int64) -> Int64 {
        let mebibyte: Int64 = 1024 * 1024
        let needed = (total + maximumChunks - 1) / maximumChunks
        return max(minimumChunk, (needed + mebibyte - 1) / mebibyte * mebibyte)
    }
    /// Chunk names are the numbers 1 to 10,000; the padding keeps them in order for servers that list them.
    nonisolated static func chunkName(_ number: Int) -> String { String(format: "%05d", number) }

    /// Whether this upload goes in chunks: on a Nextcloud, above the threshold, or resuming a session already open.
    func usesChunkedUpload(_ cursor: UploadCheckpoint) -> Bool {
        account.capabilities.chunkedUploads && (cursor.url != nil || cursor.total >= chunkedThreshold)
    }

    private func uploadsCollection(_ id: String) async throws -> URL {
        let user = try await nextcloudUser()
        return try nextcloudURL("/remote.php/dav/uploads/\(Self.segment(user))/\(Self.segment(id))")
    }
    /// True for a URL that is an upload collection of this account's server, the only kind this code deletes.
    func isNextcloudUploadCollection(_ url: URL) -> Bool {
        guard let base = try? webdavBase(), url.host?.lowercased() == base.host?.lowercased(), url.scheme == base.scheme else { return false }
        return url.path.contains("/remote.php/dav/uploads/")
    }

    private func chunkRequest(_ url: URL, method: String, destination: URL, total: Int64) async throws -> URLRequest {
        var request = try await request(url, method: method)
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(String(total), forHTTPHeaderField: "OC-Total-Length")
        return request
    }

    func nextcloudChunkedUpload(local: URL, path: String, replacing: String?, cursor: inout UploadCheckpoint,
                                save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let destination = try webdavURL(path)
        // A session from an earlier attempt is used only if it is still on the server and still meant for this file.
        if let session = cursor.url {
            var alive = false
            if isNextcloudUploadCollection(session), cursor.remoteID == nil || cursor.remoteID == path {
                let (data, response) = try await webdavRequest(session, method: "PROPFIND", depth: "0",
                                                               body: #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 207 || (200..<300).contains(status) { alive = true }
                else if status != 404 { try HTTP.validate(response, data: data) }
            }
            if !alive {
                // A collection that is gone after every chunk was sent may mean the MOVE went through and only its
                // answer was lost; the file at the destination with the right size says which.
                if cursor.offset == total, let current = try? await webdavPropfind(path, depth: "0").first, current.file.size == total {
                    cursor.complete = true; cursor.url = nil; try save(cursor); progress(total, total)
                    return UploadReceipt(remoteID: path, verification: .unavailable)
                }
                if isNextcloudUploadCollection(session) { await abandonUploadSessions(urls: [session], sessionIDs: []) }
                cursor.url = nil; cursor.offset = 0
            }
        }
        if cursor.url == nil {
            let collection = try await uploadsCollection("icloudy-" + UUID().uuidString)
            var create = try await chunkRequest(collection, method: "MKCOL", destination: destination, total: total)
            let (data, response) = try await send(&create)
            try HTTP.validate(response, data: data)
            cursor.url = collection; cursor.chunkSize = chunkOverride ?? Self.chunkSize(for: total); cursor.offset = 0; cursor.remoteID = path
            try save(cursor)
        }
        guard let collection = cursor.url else { throw CloudError.message(L("No hay sesión de subida.")) }
        let chunk = cursor.chunkSize ?? Self.chunkSize(for: total)
        progress(cursor.offset, total)
        while cursor.offset < total {
            try Task.checkCancellation()
            try cursor.sourceStamp?.validate(local)
            let offset = cursor.offset, length = min(chunk, total - offset)
            let number = Int(offset / chunk) + 1
            let data = try await blockingIO { try S3Provider.readPart(local, offset: offset, length: length).data }
            try cursor.sourceStamp?.validate(local)
            try await TransferThrottle.upload(data.count)
            var put = try await chunkRequest(collection.appendingPathComponent(Self.chunkName(number)), method: "PUT", destination: destination, total: total)
            put.timeoutInterval = 600
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // A chunk is addressed by its number, so sending it twice stores it once: safe to repeat after a 5xx.
            let (body, response) = try await sendBlock { try await upload(&put, from: data) }
            try HTTP.validate(response, data: body)
            cursor.offset = offset + length
            try save(cursor)
            progress(cursor.offset, total)
        }
        var assemble = try await chunkRequest(collection.appendingPathComponent(".file"), method: "MOVE", destination: destination, total: total)
        assemble.timeoutInterval = 3600
        assemble.setValue(replacing == nil ? "F" : "T", forHTTPHeaderField: "Overwrite")
        if let modified = cursor.modified { assemble.setValue(String(Int(modified.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime") }
        let (data, response) = try await send(&assemble)
        try HTTP.validate(response, data: data)
        cursor.url = nil; cursor.offset = total; cursor.complete = true
        try save(cursor)
        progress(total, total)
        // Nextcloud keeps no checksum that a third party can compare, so the commit is all there is to go by.
        return UploadReceipt(remoteID: path, verification: .unavailable)
    }
}
