import Foundation

/// Handles cancellation before registration, timeout, and late callbacks with exactly one resume.
final class SocketWait<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var timer: DispatchWorkItem?
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    @discardableResult
    func resolve(_ value: Result<T, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let continuation = self.continuation; self.continuation = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: value)
        return true
    }
    func arm(timeout: TimeInterval, cancel: @escaping @Sendable () -> Void) {
        let timer = DispatchWorkItem { [weak self] in
            if self?.resolve(.failure(CloudError.message(L("El servidor FTP no respondió a tiempo.")))) == true { cancel() }
        }
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    }
}
