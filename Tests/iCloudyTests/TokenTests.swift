import XCTest
@testable import iCloudy

/// In-memory replacement for the Keychain so refresh logic runs without touching the user's real keychain.
final class MemoryCredentials: CredentialStore {
    var stored: [String: Credential] = [:]
    var reads = 0
    func read(_ key: String) throws -> Credential? { reads += 1; return stored[key] }
    func save(_ credential: Credential, key: String) throws { stored[key] = credential }
}

@MainActor
final class TokenTests: XCTestCase {
    private let account = Account(id: "google:1", cloud: .google, name: "Test", email: "test@example.com", clientID: "client", clientSecret: "desktop-metadata")
    private let tokenHost = "oauth2.googleapis.com"

    private func client(_ store: MemoryCredentials) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: account, session: URLSession(configuration: config), credentials: store)
    }
    private func credential(expiresIn seconds: TimeInterval, access: String = "old") -> Credential {
        Credential(accessToken: access, refreshToken: "refresh-1", expires: Date().addingTimeInterval(seconds))
    }
    private let refreshed = Data(#"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":3600}"#.utf8)

    func testExpiredTokenIsRefreshedOnceForConcurrentCallersAndRotationIsStored() async throws {
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: -10)
        var posts = 0
        StubProtocol.handler = { [tokenHost, refreshed] request in
            XCTAssertEqual(request.url?.host, tokenHost)
            let body = requestBody(request)
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("refresh_token=refresh-1"))
            XCTAssertTrue(body.contains("client_secret=desktop-metadata"))
            posts += 1
            return (200, [:], refreshed)
        }
        let api = client(store)
        async let first = api.token()
        async let second = api.token()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, "fresh"); XCTAssertEqual(b, "fresh")
        XCTAssertEqual(posts, 1, "Concurrent callers share one refresh")
        XCTAssertEqual(store.stored[account.id]?.refreshToken, "refresh-2", "Rotated refresh tokens must be persisted")
        XCTAssertGreaterThan(store.stored[account.id]?.expires ?? .distantPast, Date())
        _ = try await api.token()
        XCTAssertEqual(posts, 1, "A fresh token is served from memory")
        XCTAssertEqual(store.reads, 1, "The Keychain is read once per client")
    }

    func testInvalidGrantMarksTheSessionExpiredWithTheProviderDetail() async throws {
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: -10)
        var posts = 0
        StubProtocol.handler = { _ in
            posts += 1
            return (400, [:], Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))
        }
        let api = client(store)
        var notifications = 0
        api.sessionDidExpire = { notifications += 1 }
        do { _ = try await api.token(); XCTFail("Expected an expired session") }
        catch let error as CloudError {
            XCTAssertTrue(error.isSessionExpired)
            XCTAssertTrue(error.localizedDescription.contains("revoked"), error.localizedDescription)
        }
        XCTAssertTrue(api.sessionExpired)
        XCTAssertEqual(notifications, 1)
        do { _ = try await api.token(); XCTFail("Expected an expired session") }
        catch let error as CloudError { XCTAssertTrue(error.isSessionExpired) }
        XCTAssertEqual(posts, 1, "An expired session must not hammer the token endpoint")
    }

    func testTransientTokenEndpointFailureIsNotAnExpiredSession() async throws {
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: -10)
        StubProtocol.handler = { _ in (503, [:], Data()) }
        let api = client(store)
        do { _ = try await api.token(); XCTFail("Expected a service error") }
        catch let error as ServiceError { XCTAssertTrue(error.retryable) }
        XCTAssertFalse(api.sessionExpired)
    }

    func testUnauthorizedResponseForcesOneRefreshAndRetries() async throws {
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: 3600)
        var sequence: [String] = []
        StubProtocol.handler = { [tokenHost, refreshed] request in
            if request.url?.host == tokenHost { sequence.append("refresh"); return (200, [:], refreshed) }
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            sequence.append(bearer)
            if bearer == "Bearer old" { return (401, [:], Data(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#.utf8)) }
            return (200, [:], Data(#"{"ok":true}"#.utf8))
        }
        let api = client(store)
        let result = try await api.json(URL(string: "https://www.googleapis.com/drive/v3/about?fields=storageQuota")!)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(sequence, ["Bearer old", "refresh", "Bearer fresh"])
        XCTAssertFalse(api.sessionExpired)
    }

    func testRepeatedUnauthorizedAfterRefreshExpiresTheSession() async throws {
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: 3600)
        var dataRequests = 0, refreshes = 0
        StubProtocol.handler = { [tokenHost, refreshed] request in
            if request.url?.host == tokenHost { refreshes += 1; return (200, [:], refreshed) }
            dataRequests += 1
            return (401, [:], Data())
        }
        let api = client(store)
        var notifications = 0
        api.sessionDidExpire = { notifications += 1 }
        do { _ = try await api.json(URL(string: "https://www.googleapis.com/drive/v3/files")!); XCTFail("Expected an expired session") }
        catch let error as CloudError { XCTAssertTrue(error.isSessionExpired) }
        XCTAssertEqual(dataRequests, 2); XCTAssertEqual(refreshes, 1); XCTAssertEqual(notifications, 1)
        XCTAssertTrue(api.sessionExpired)
    }

    func testMissingCredentialExpiresWithoutNetwork() async throws {
        StubProtocol.handler = { _ in XCTFail("No credential, no request"); return (500, [:], Data()) }
        let api = client(MemoryCredentials())
        do { _ = try await api.token(); XCTFail("Expected an expired session") }
        catch let error as CloudError { XCTAssertTrue(error.isSessionExpired) }
    }
}
