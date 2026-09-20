import Foundation

final class DownloadProgress: RedirectGuard, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (Int64, Int64) -> Void
    let maxBytes: Int64?
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.withLock { exceeded } }
    init(maxBytes: Int64? = nil, report: @escaping (Int64, Int64) -> Void) { self.maxBytes = maxBytes; self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let maxBytes, totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            lock.withLock { exceeded = true }; downloadTask.cancel(); return
        }
        report(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }
}
