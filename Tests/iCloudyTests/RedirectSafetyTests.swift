import XCTest
import Network
@testable import iCloudy

private final class HTTPListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func once(_ body: () -> Void) {
        let first = lock.withLock { let first = !finished; finished = true; return first }
        if first { body() }
    }
}

/// Exercises URLSession's actual redirect callbacks, including custom progress delegates.
private final class LoopbackHTTP: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "redirect-test")
    private let lock = NSLock()
    private var requests: [String] = []
    private let response: (String) -> String
    init(response: @escaping (String) -> String) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            var bytes = Data()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { bytes.append(data) }
                    let text = String(decoding: bytes, as: UTF8.self)
                    if text.contains("\r\n\r\n") {
                        self.lock.withLock { self.requests.append(text) }
                        connection.send(content: Data(self.response(text).utf8), contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    } else if complete || error != nil { connection.cancel() } else { read() }
                }
            }
            read()
        }
        let ready = HTTPListenerReady()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.once { continuation.resume() }
                case .failed(let error): ready.once { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/start")!
    }
    func stop() { listener.cancel() }
    func received() -> [String] { lock.withLock { requests } }
}

@MainActor
final class RedirectSafetyTests: XCTestCase {
    func testDownloadDelegateStripsCredentialsAtAnotherPort() async throws {
        let destination = try LoopbackHTTP { _ in "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" }
        let target = try await destination.start(); defer { destination.stop() }
        let redirect = try LoopbackHTTP { _ in "HTTP/1.1 302 Found\r\nLocation: \(target.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        let start = try await redirect.start(); defer { redirect.stop() }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: start); request.timeoutInterval = 3
        request.setValue("Bearer FAKE", forHTTPHeaderField: "Authorization")
        request.setValue("private=FAKE", forHTTPHeaderField: "Cookie")
        let (file, response) = try await session.download(for: request, delegate: DownloadProgress { _, _ in })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try String(contentsOf: file), "ok")
        let received = try XCTUnwrap(destination.received().first)
        XCTAssertFalse(received.lowercased().contains("authorization:"), received)
        XCTAssertFalse(received.contains("private=FAKE"), received)
    }
    func testUploadDelegatesRefuseCrossOriginBodyReplay() async throws {
        let destination = try LoopbackHTTP { _ in "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }
        let target = try await destination.start(); defer { destination.stop() }
        for status in [302, 307, 308] {
        let redirect = try LoopbackHTTP { _ in "HTTP/1.1 \(status) Redirect\r\nLocation: \(target.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        let start = try await redirect.start(); defer { redirect.stop() }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let delegates: [RedirectGuard] = [RedirectGuard.shared, UploadProgress { _ in }, O2UploadReporter(total: 6) { _, _ in }]
        for delegate in delegates {
            var request = URLRequest(url: start); request.httpMethod = "POST"; request.timeoutInterval = 3
            request.setValue("Bearer FAKE", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.upload(for: request, from: Data("secret".utf8), delegate: delegate)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
        }
        }
        XCTAssertTrue(destination.received().isEmpty, "No upload body or token exchange may reach the other origin")
    }
    func testPolicyRejectsDowngradesAndPreservesOnlySameOriginAuthorization() async throws {
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.com/a")!)
        request.setValue("Bearer FAKE", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        for address in ["http://example.com/a", "file:///tmp/a", "https://user:pass@example.com/a"] {
            var next = request; next.url = URL(string: address)!
            let result = await RedirectGuard.shared.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next)
            XCTAssertNil(result, address)
        }
        var next = request; next.url = URL(string: "https://example.com:443/b")!
        let result = await RedirectGuard.shared.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next)
        XCTAssertEqual(result?.value(forHTTPHeaderField: "Authorization"), "Bearer FAKE")
    }
}
