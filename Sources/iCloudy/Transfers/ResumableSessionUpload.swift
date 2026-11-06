import Foundation

/// The block loop of a resumable upload session addressed by URL, which Google Drive and Microsoft Graph share: each
/// block is a PUT with `Content-Range`, the server answers "go on from here" until the last one, and the final answer
/// describes the file. The two used to have a copy each that differed in two lines; those two lines are `Wire`.
///
/// A block that fails for a transient reason (a 5xx, a 429, a dropped connection) is not the end of the upload any
/// more: after a back-off the server is asked where the session stands and the loop goes on from there. Before, the
/// error went up, the queue dropped the session and started the file again from its checkpoint.
@MainActor
struct ResumableSessionUpload {
    /// How the server says where it is.
    enum Standing {
        /// The offset of the next byte it expects.
        case next(Int64)
        /// The upload is complete; this is the item's description.
        case finished([String: Any])
    }
    struct Wire {
        /// The status of a block accepted mid-upload: 308 for Google, 202 for Graph.
        let inProgress: Int
        /// The next offset, read from that answer.
        let offset: (Data, URLResponse) throws -> Int64
        /// Asks the session where it stands, after a block whose answer did not arrive or was a transient refusal.
        let standing: () async throws -> Standing
    }
    nonisolated static let blockSize = 5 * 1024 * 1024
    /// Attempts per block, the first included.
    static let attemptsPerBlock = 4

    let session: URLSession
    let url: URL
    let cloud: Cloud
    let wire: Wire
    /// The wait before asking again after a transient failure. Tests shorten it.
    var delay: (_ attempt: Int, _ response: URLResponse?) -> Double = { attempt, response in
        RetryAfter.delay(announced: RetryAfter.seconds(response), attempt: attempt)
    }

    static func isTransient(status: Int) -> Bool { [408, 429, 500, 502, 503, 504].contains(status) }
    static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(code)
    }

    func run(local: URL, name: String, total: Int64, fileSize: Int?, cursor: inout UploadCheckpoint,
             save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        // Hash the bytes the server confirmed; a resumed session missed earlier blocks, so it cannot be verified.
        var hasher: UploadHasher? = cursor.offset == 0 ? UploadHasher(cloud: cloud) : nil
        var receipt = UploadReceipt(remoteID: nil, verification: .unavailable)
        // A server that keeps accepting a block without moving the offset on would otherwise be asked for ever. It is
        // the shape an empty file can take when the answer is a 308 with no range in it.
        var stalled = 0
        func finish(_ item: [String: Any]) throws -> UploadReceipt {
            cursor.offset = total
            cursor.complete = true
            let stamp = cursor.sourceStamp
            // The comparison is worked out here and only reported inside `finish`, after the checkpoint says
            // "pending": Swift 6.2 refuses to let the closure capture `item`, a non-Sendable dictionary.
            let verification = Result { try hasher?.verify(against: item, name: name) ?? .unavailable }
            return try cursor.finish(remoteID: item["id"] as? String, save: save) {
                try stamp?.validate(local)
                return try verification.get()
            }
        }
        repeat {
            try Task.checkCancellation()
            try cursor.sourceStamp?.validate(local)
            let before = cursor.offset
            let current = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard current.fileSize == fileSize, current.contentModificationDate == cursor.modified else { throw CloudError.message(L("El archivo cambió durante la subida.")) }
            // Reading 5 MiB blocks on the main actor stalled the interface on slow volumes.
            let data = try await blockingIO { try handle.read(upToCount: Self.blockSize) ?? Data() }
            try await TransferThrottle.upload(data.count)
            try cursor.sourceStamp?.validate(local)
            guard total == 0 || !data.isEmpty, cursor.offset + Int64(data.count) <= total else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }

            var attempt = 0
            var answer: (body: Data, response: URLResponse)?
            while answer == nil {
                var upload = URLRequest(url: url)
                upload.httpMethod = "PUT"
                upload.timeoutInterval = 180
                upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                upload.setValue(total == 0 ? "bytes */0" : "bytes \(cursor.offset)-\(cursor.offset + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
                var failure: (error: Error?, response: URLResponse?)?
                do {
                    let (body, response) = try await session.upload(for: upload, from: data, delegate: RedirectGuard.shared)
                    if Self.isTransient(status: (response as? HTTPURLResponse)?.statusCode ?? 0) { failure = (nil, response) }
                    else { answer = (body, response) }
                } catch where Self.isTransient(error) {
                    failure = (error, nil)
                }
                guard let failure else { break }
                attempt += 1
                guard attempt < Self.attemptsPerBlock else {
                    if let error = failure.error { throw error }
                    throw ServiceError(status: (failure.response as? HTTPURLResponse)?.statusCode ?? 0, retryAfter: RetryAfter.seconds(failure.response))
                }
                try await Task.sleep(for: .seconds(delay(attempt - 1, failure.response)))
                // Part of the block may have arrived: the server says how much, and only the rest is sent again.
                switch try await wire.standing() {
                case .finished(let item):
                    guard before + Int64(data.count) == total else { throw CloudError.message(L("El servidor confirmó una subida incompleta.")) }
                    hasher?.update(data)
                    receipt = try finish(item)
                case .next(let offset):
                    guard offset >= before, offset <= before + Int64(data.count) else { throw CloudError.message(L("El servidor devolvió un avance no válido.")) }
                    guard offset > before else { continue }
                    hasher?.update(data.prefix(Int(offset - before)))
                    cursor.offset = offset
                    try await blockingIO { try handle.seek(toOffset: UInt64(offset)) }
                }
                break
            }
            if let (body, response) = answer {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if [200, 201].contains(status) {
                    guard cursor.offset + Int64(data.count) == total else { throw CloudError.message(L("El servidor confirmó una subida incompleta.")) }
                    hasher?.update(data)
                    receipt = try finish((try? HTTP.json(body)) ?? [:])
                } else if status == wire.inProgress {
                    let received = try wire.offset(body, response)
                    guard received == cursor.offset + Int64(data.count) else { throw URLError(.networkConnectionLost) }
                    hasher?.update(data)
                    cursor.offset = received
                } else {
                    throw ServiceError(status: status)
                }
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
}
