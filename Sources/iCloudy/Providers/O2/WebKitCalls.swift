import Foundation
import WebKit

/// WebKit's cookie and data-store calls, awaited through continuations written here instead of the `async` versions
/// Swift generates from their completion handlers.
///
/// Built in the Swift 6 language mode with Swift 6.2, an `await` on some of those generated versions crashed: the
/// completion handler resumed a continuation that was no longer there ("Bad pointer dereference" inside
/// `_resumeCheckedContinuation`, on macOS 15, in the test that creates and removes two stores). Each wrapper resumes
/// its continuation exactly once, whatever WebKit does with the handler, and runs on the main actor as WebKit wants.
@MainActor
extension WKHTTPCookieStore {
    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            getAllCookies { cookies in if once.claim() { continuation.resume(returning: cookies) } }
        }
    }
    func store(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            setCookie(cookie) { if once.claim() { continuation.resume() } }
        }
    }
    func remove(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            delete(cookie) { if once.claim() { continuation.resume() } }
        }
    }
}

@MainActor
extension WKWebsiteDataStore {
    func erase(ofTypes types: Set<String>, modifiedSince date: Date) async {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            removeData(ofTypes: types, modifiedSince: date) { if once.claim() { continuation.resume() } }
        }
    }
    func erase(ofTypes types: Set<String>, for records: [WKWebsiteDataRecord]) async {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            removeData(ofTypes: types, for: records) { if once.claim() { continuation.resume() } }
        }
    }
    func records(ofTypes types: Set<String>) async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            fetchDataRecords(ofTypes: types) { records in if once.claim() { continuation.resume(returning: records) } }
        }
    }
    static func removeStore(forIdentifier identifier: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            remove(forIdentifier: identifier) { error in
                guard once.claim() else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// True the first time it is asked, false after.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
