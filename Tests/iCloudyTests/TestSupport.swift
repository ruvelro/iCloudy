import XCTest
@testable import iCloudy

// Shared helpers for the whole suite. What lives here:
//
// - `StubProtocol`: the HTTP stand-in. `StubProtocol.handler = { request in … }` answers the requests of the test that
//   set it and of no other one: every handler belongs to the test that was running when it was set, and is dropped
//   when that test ends. A session built with `StubProtocol.session()` (or `makeStubbedClient`) also tags its requests
//   with that test, so a request a finished test leaves behind fails instead of reaching the next test's handler.
// - `makeStubbedClient(_:)`: a `CloudAPI` for one provider over that stub.
// - `wait(until:)`, `assertStays(_:for:)`, `drainMainActor()`: polling with a deadline instead of fixed sleeps.
// - `temporaryRoot()`: a folder of the test's own, removed when it ends.
// - `MemoryCredentials`: the Keychain stand-in.
//
// Per-test isolation is installed before the first test by a load-time hook (Tests/iCloudyTestBootstrap), which also
// works when `swift test --parallel` or `--filter` runs a single test per process. Every test gets its own
// `Prefs.defaults` suite and its own `LocalStore.directory`, and a watchdog stops the process when one test runs for
// longer than `ICLOUDY_TEST_TIMEOUT` seconds (120 by default), so a hang shows its name instead of eating the CI job.

// MARK: - Isolation between tests

@_cdecl("icloudy_tests_bootstrap")
func icloudyTestsBootstrap() { TestIsolation.install() }

enum TestIsolation {
    private static let lock = NSLock()
    private static var installed = false
    private static var currentScope = 0
    /// Every test runs in a scope of its own. Changes when a test starts; read from any thread.
    static var scope: Int { lock.lock(); defer { lock.unlock() }; return currentScope }

    /// Seconds one test may take before the watchdog stops the run.
    static let timeLimit: TimeInterval = {
        ProcessInfo.processInfo.environment["ICLOUDY_TEST_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
    }()

    /// One preferences suite per process: parallel runs are separate processes and must not share it.
    static let defaultsSuite = "icloudy-tests.\(ProcessInfo.processInfo.processIdentifier)"
    /// Where `LocalStore.directory` points, one subfolder per test.
    static let storeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("icloudy-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func install() {
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        isolateStorage(for: 0)
        XCTestObservationCenter.shared.addTestObserver(Observer())
    }

    fileprivate static func begin(_ test: XCTestCase) {
        lock.lock(); currentScope += 1; let scope = currentScope; lock.unlock()
        isolateStorage(for: scope)
    }

    fileprivate static func end(_ test: XCTestCase) {
        StubProtocol.dropHandlers()
    }

    private static func isolateStorage(for scope: Int) {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        Prefs.defaults = defaults
        if let previous = LocalStore.directoryOverride { try? FileManager.default.removeItem(at: previous) }
        LocalStore.directoryOverride = storeRoot.appendingPathComponent("\(scope)", isDirectory: true)
    }

    fileprivate static func finishBundle() {
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(defaultsSuite).plist")
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: storeRoot)
    }

    private final class Observer: NSObject, XCTestObservation {
        private var watchdog: DispatchSourceTimer?

        func testCaseWillStart(_ testCase: XCTestCase) {
            TestIsolation.begin(testCase)
            let limit = TestIsolation.timeLimit
            testCase.executionTimeAllowance = max(60, limit)
            let name = testCase.name
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + limit)
            timer.setEventHandler {
                FileHandle.standardError.write(Data("\n*** \(name) has been running for more than \(Int(limit)) s. Stopping the test process so the hang is reported here (ICLOUDY_TEST_TIMEOUT changes the limit).\n".utf8))
                fatalError("Test watchdog: \(name) exceeded \(Int(limit)) s")
            }
            timer.resume()
            watchdog = timer
        }

        func testCaseDidFinish(_ testCase: XCTestCase) {
            watchdog?.cancel(); watchdog = nil
            TestIsolation.end(testCase)
        }

        func testBundleDidFinish(_ testBundle: Bundle) { TestIsolation.finishBundle() }
    }
}

// MARK: - HTTP stub

final class StubProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)

    /// The header that carries the test a request belongs to. Removed before the handler sees the request.
    static let scopeHeader = "X-iCloudy-Test-Scope"

    private static let lock = NSLock()
    private static var handlers: [Int: Handler] = [:]

    /// The handler of the running test. Setting it installs it for this test only; it is dropped when the test ends.
    static var handler: Handler? {
        get { TestIsolation.install(); return handler(scope: TestIsolation.scope) }
        set {
            TestIsolation.install()
            let scope = TestIsolation.scope
            lock.lock(); handlers[scope] = newValue; lock.unlock()
        }
    }

    private static func handler(scope: Int) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[scope]
    }

    fileprivate static func dropHandlers() {
        lock.lock(); handlers.removeAll(); lock.unlock()
    }

    /// A configuration whose requests go to this stub and carry the running test, so they can only ever reach the
    /// handler that test installs.
    static func configuration(_ base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        TestIsolation.install()
        base.protocolClasses = [StubProtocol.self]
        var headers = base.httpAdditionalHeaders ?? [:]
        headers[scopeHeader] = String(TestIsolation.scope)
        base.httpAdditionalHeaders = headers
        return base
    }

    static func session(_ base: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration(base))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        // Sessions configured by hand (`protocolClasses = [StubProtocol.self]`) carry no tag and are served by the
        // running test's handler, as they always were.
        let scope = request.value(forHTTPHeaderField: Self.scopeHeader).flatMap(Int.init) ?? TestIsolation.scope
        request.setValue(nil, forHTTPHeaderField: Self.scopeHeader)
        guard let handler = Self.handler(scope: scope) else {
            let reason = scope == TestIsolation.scope
                ? "No StubProtocol.handler is installed for this test"
                : "This request belongs to a test that has already finished"
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: [
                NSLocalizedDescriptionKey: "\(reason): \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"]))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// URLProtocol receives POST bodies as a stream, not as `httpBody`.
func requestBody(_ request: URLRequest) -> String { String(decoding: requestData(request), as: UTF8.self) }
/// The same, for bodies that are not text: an encrypted upload, for instance.
func requestData(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return data
}

// MARK: - Clients

/// A session whose requests are answered by `StubProtocol.handler`.
func stubbedSession() -> URLSession { StubProtocol.session() }

/// An account as the provider tests build them. WebDAV gets a Nextcloud-like server unless one is given.
func stubbedAccount(_ cloud: Cloud, id: String = "test", name: String = "Test", email: String = "test@example.com",
                    clientID: String = "client", server: String? = nil, options: [String: String] = [:]) -> Account {
    Account(id: id, cloud: cloud, name: name, email: email, clientID: clientID, clientSecret: nil,
            serverURL: server, bookmark: nil, options: options)
}

/// A client for `account` over the HTTP stub. With `credentials` the provider reads and renews tokens there;
/// without, every request carries `token`.
@MainActor
func makeStubbedClient(_ account: Account, credentials: CredentialStore? = nil, token: String = "test-token") -> CloudAPI {
    if let credentials { return CloudAPI(account: account, session: stubbedSession(), credentials: credentials) }
    return CloudAPI(account: account, session: stubbedSession(), tokenProvider: { token })
}

@MainActor
func makeStubbedClient(_ cloud: Cloud, id: String = "test", email: String = "test@example.com", server: String? = nil,
                       options: [String: String] = [:], credentials: CredentialStore? = nil, token: String = "test-token") -> CloudAPI {
    makeStubbedClient(stubbedAccount(cloud, id: id, email: email, server: server, options: options), credentials: credentials, token: token)
}

/// In-memory replacement for the Keychain so refresh logic runs without touching the user's real keychain.
final class MemoryCredentials: CredentialStore {
    var stored: [String: Credential] = [:]
    var reads = 0
    /// Set to play a locked Keychain: reads still work, writes do not.
    var refuseSaves = false
    func read(_ key: String) throws -> Credential? { reads += 1; return stored[key] }
    func save(_ credential: Credential, key: String) throws {
        if refuseSaves { throw CloudError.message("Llavero bloqueado") }
        stored[key] = credential
    }
}

// MARK: - Files

/// The repository checkout, found from this file rather than from the working directory.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A path inside the repository, such as "Resources/Info.plist" or "Sources/iCloudy".
func repositoryURL(_ relativePath: String) -> URL { repositoryRoot.appendingPathComponent(relativePath) }

struct TestTimeout: Error, CustomStringConvertible {
    let description: String
}

extension XCTestCase {
    /// A new, empty folder for this test, removed when it ends.
    func temporaryRoot(_ prefix: String = "icloudy-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Waiting

    /// Polls `condition` until it holds, failing the test (and throwing) if it does not within `timeout`. The
    /// replacement for a fixed `Task.sleep` followed by an assertion: as fast as the code allows, and only as slow as
    /// the deadline on a loaded CI machine.
    @MainActor
    func wait(until condition: @MainActor () throws -> Bool, timeout: Duration = .seconds(15), poll: Duration = .milliseconds(5),
              _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if try condition() { return }
            if clock.now >= deadline { break }
            try await Task.sleep(for: poll)
        }
        let text = message()
        let description = "Timed out after \(timeout)" + (text.isEmpty ? "" : ": \(text)")
        XCTFail(description, file: file, line: line)
        throw TestTimeout(description: description)
    }

    /// Checks that `condition` keeps holding for `duration`, failing as soon as it does not. For assertions that
    /// something does *not* happen, which no amount of polling can prove: the duration is the claim being made.
    @MainActor
    func assertStays(_ condition: @MainActor () throws -> Bool, for duration: Duration = .milliseconds(100),
                     _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        repeat {
            guard try condition() else {
                let text = message()
                XCTFail("Stopped holding" + (text.isEmpty ? "" : ": \(text)"), file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        } while clock.now < deadline
        if !(try condition()) {
            let text = message()
            XCTFail("Stopped holding" + (text.isEmpty ? "" : ": \(text)"), file: file, line: line)
        }
    }

    /// Lets whatever is queued on the main actor run: enough for work that only hops back to it.
    @MainActor
    func drainMainActor(_ turns: Int = 20) async {
        for _ in 0..<turns { await Task.yield() }
    }
}
