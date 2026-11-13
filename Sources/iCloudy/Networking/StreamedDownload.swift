import Foundation

/// A server answered a range request with something that cannot be appended to what is already on disk.
struct DownloadResumeRefused: Error {}

/// One GET written to a file as its bytes arrive.
///
/// `URLSession.download` keeps the body in a temporary file of its own and throws it away with the error, so a
/// connection lost at 19 of 20 GB left nothing to continue from. Here every block goes straight to the destination:
/// whatever arrived before a failure is still there for the next attempt to build on.
final class StreamedDownload: RedirectGuard, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        let response: HTTPURLResponse
        /// The body of a refusal, bounded: the provider's explanation, never the file.
        let errorBody: Data
        /// True when the server continued the file from `offset` rather than sending it whole.
        let continued: Bool
    }

    private let destination: URL
    private let offset: Int64
    private let maxBytes: Int64?
    private let report: (Int64, Int64) -> Void
    private let throttle: TaskThrottle?
    private let lock = NSLock()
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var errorBody = Data()
    private var base: Int64 = 0
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var continued = false
    private var failure: Error?
    private var exceeded = false
    private var continuation: CheckedContinuation<Outcome, Error>?

    var exceededLimit: Bool { lock.withLock { exceeded } }

    /// `offset` is how many bytes of `destination` the request asked to skip; zero for a plain GET.
    init(destination: URL, offset: Int64, maxBytes: Int64?, throttle: TaskThrottle?, report: @escaping (Int64, Int64) -> Void) {
        self.destination = destination; self.offset = offset; self.maxBytes = maxBytes; self.throttle = throttle; self.report = report
    }

    func run(_ request: URLRequest, session: URLSession) async throws -> Outcome {
        let task = session.dataTask(with: request)
        task.delegate = self
        // The task was created without a delegate, so nobody stamped the diagnostic context on it.
        Diagnostics.taskCreated(task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else { return .allow }
        lock.withLock { self.response = http }
        guard (200..<300).contains(http.statusCode) else { return .allow }
        do {
            if http.statusCode == 206, offset > 0 {
                // "bytes 100-199/200": anything that does not start where the file ends cannot be appended.
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let numbers = range.split(whereSeparator: { !$0.isNumber && $0 != "*" })
                guard numbers.first.flatMap({ Int64($0) }) == offset else { throw DownloadResumeRefused() }
                let writer = try FileHandle(forWritingTo: destination)
                guard try writer.seekToEnd() == UInt64(offset) else { try? writer.close(); throw DownloadResumeRefused() }
                let announced = numbers.count >= 3 ? Int64(numbers[2]) : nil
                lock.withLock {
                    handle = writer; base = offset; continued = true
                    total = announced ?? (http.expectedContentLength > 0 ? offset + http.expectedContentLength : 0)
                }
            } else {
                // The whole file, either because nothing was asked to be skipped or because the server no longer
                // has the bytes the partial file came from.
                // `truncate` on the open handle keeps the file itself, and with it the stamp that says what it is a
                // copy of.
                if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
                let writer = try FileHandle(forWritingTo: destination)
                try writer.truncate(atOffset: 0)
                lock.withLock { handle = writer; base = 0; total = max(0, http.expectedContentLength) }
            }
        } catch {
            lock.withLock { failure = error }
            return .cancel
        }
        let expected = lock.withLock { total }
        if let maxBytes, expected > maxBytes {
            lock.withLock { exceeded = true }
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let writer = lock.withLock { handle }
        guard let writer else {
            lock.withLock { if errorBody.count < 64 * 1024 { errorBody.append(data.prefix(64 * 1024 - errorBody.count)) } }
            return
        }
        do { try writer.write(contentsOf: data) }
        catch {
            lock.withLock { if failure == nil { failure = error } }
            dataTask.cancel()
            return
        }
        let (done, expected) = lock.withLock { () -> (Int64, Int64) in
            written += Int64(data.count)
            return (base + written, total)
        }
        if let maxBytes, done > maxBytes {
            lock.withLock { exceeded = true }
            dataTask.cancel()
            return
        }
        report(done, expected)
        throttle?.pass(Int64(data.count), of: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiting, result): (CheckedContinuation<Outcome, Error>?, Result<Outcome, Error>) = lock.withLock {
            try? handle?.close(); handle = nil
            let waiting = continuation; continuation = nil
            if let failure { return (waiting, .failure(failure)) }
            if exceeded { return (waiting, .failure(CloudError.message(L("La vista previa supera el límite de descarga autorizado.")))) }
            if let error { return (waiting, .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)) }
            guard let response else { return (waiting, .failure(CloudError.message(L("Respuesta HTTP no válida.")))) }
            return (waiting, .success(Outcome(response: response, errorBody: errorBody, continued: continued)))
        }
        waiting?.resume(with: result)
    }
}
