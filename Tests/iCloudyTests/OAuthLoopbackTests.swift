import XCTest
import Network
@testable import iCloudy

/// Plays the browser: a raw HTTP GET over TCP to the loopback listener, outside URLSession and App Transport Security.
private func loopbackGET(_ url: URL) async throws -> String {
    guard let port = url.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) }) else { throw URLError(.badURL) }
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let queue = DispatchQueue(label: "loopback-test") // serial: state and receive callbacks never race
    final class Once: @unchecked Sendable { var done = false } // callbacks are @Sendable; a captured var could not be mutated
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
        let finish: @Sendable (Result<String, Error>) -> Void = { result in
            guard !once.done else { return }
            once.done = true; connection.cancel(); continuation.resume(with: result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET \(url.path)?\(url.query ?? "") HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error { finish(.failure(error)); return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error { finish(.failure(error)) }
                        else if let data, !data.isEmpty { finish(.success(String(decoding: data, as: UTF8.self))) }
                        else { finish(.failure(URLError(.networkConnectionLost))) }
                    }
                })
            case .failed(let error): finish(.failure(error))
            case .cancelled: finish(.failure(URLError(.cancelled)))
            default: break
            }
        }
        connection.start(queue: queue)
    }
}

/// Written from the detached "browser" task and read on the main actor once `signIn` returns.
private final class BrowserOutcome: @unchecked Sendable {
    var wrongStateAnswered = false
    var callbackPage = ""
}

@MainActor
final class OAuthLoopbackTests: XCTestCase {
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testLoopbackFlowRejectsWrongStateThenExchangesTheCode() async throws {
        var tokenBody = ""
        StubProtocol.handler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                tokenBody = requestBody(request)
                return (200, [:], Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8))
            }
            XCTAssertEqual(request.url?.host, "openidconnect.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            return (200, [:], Data(#"{"sub":"user-1","email":"user@example.com","name":"User"}"#.utf8))
        }
        var authorization: URL?
        let outcome = BrowserOutcome()
        let oauth = OAuth(session: stubbedSession()) { url in
            authorization = url
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let state = query.first { $0.name == "state" }!.value!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            _ = Task.detached { // failures surface through the assertions on `outcome`, not through this task
                // A forged state must be dropped without any HTTP answer.
                if (try? await loopbackGET(URL(string: redirect + "?state=attacker&code=evil")!)) != nil { outcome.wrongStateAnswered = true }
                outcome.callbackPage = try await loopbackGET(URL(string: redirect + "?state=\(state)&code=the-code")!)
            }
            return true
        }
        let watchdog = Task { try? await Task.sleep(for: .seconds(20)); oauth.cancel() }
        defer { watchdog.cancel() }
        let (account, credential) = try await oauth.signIn(cloud: .google, clientID: "client-id", clientSecret: "desktop-metadata")

        XCTAssertEqual(account.id, "google:user-1")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.clientSecret, "desktop-metadata")
        XCTAssertEqual(credential.accessToken, "access")
        XCTAssertEqual(credential.refreshToken, "refresh")
        XCTAssertFalse(outcome.wrongStateAnswered, "The listener must not respond to a mismatched state")
        XCTAssertTrue(outcome.callbackPage.hasPrefix("HTTP/1.1 200"), outcome.callbackPage)
        XCTAssertTrue(outcome.callbackPage.contains("iCloudy"))
        XCTAssertTrue(tokenBody.contains("code=the-code"))
        XCTAssertTrue(tokenBody.contains("grant_type=authorization_code"))
        XCTAssertTrue(tokenBody.contains("code_verifier="))
        XCTAssertTrue(tokenBody.contains("client_secret=desktop-metadata"))
        let query = URLComponents(url: try XCTUnwrap(authorization), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(authorization?.host, "accounts.google.com")
        XCTAssertNotNil(query.first { $0.name == "code_challenge" }?.value)
        let redirect = try XCTUnwrap(query.first { $0.name == "redirect_uri" }?.value)
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:"), redirect)
        let verifier = tokenBody.components(separatedBy: "code_verifier=")[1].components(separatedBy: "&")[0]
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, OAuth.challenge(verifier), "PKCE challenge must match the verifier sent later")
    }

    func testCancelUnblocksAWaitingSignIn() async throws {
        StubProtocol.handler = { _ in XCTFail("Nothing should be exchanged after cancel"); return (500, [:], Data()) }
        let oauth = OAuth(session: stubbedSession()) { _ in true } // the "browser" never comes back
        // Google: if the fixed port is still closing from the previous test, the ephemeral fallback keeps this deterministic.
        let attempt = Task { try await oauth.signIn(cloud: .google, clientID: "client-id", clientSecret: "") }
        try await Task.sleep(for: .milliseconds(200))
        oauth.cancel()
        let result = await attempt.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }
}
