import XCTest
@testable import iCloudy

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
        let readsSoFar = store.reads
        _ = try await api.token()
        XCTAssertEqual(posts, 1, "A fresh token is served from memory")
        XCTAssertEqual(store.reads, readsSoFar, "And without going back to the Keychain")
    }

    func testTwoClientsSharingOneCredentialRenewItOnceBetweenThem() async throws {
        // A shared drive borrows the credential of the account it came from, so two clients read and write the same
        // entry. Microsoft retires the refresh token it just handed out, so two separate renewals leave one of them
        // holding a token the provider has already thrown away, and that account goes to "expired" for no reason.
        let parent = Account(id: "microsoft:1", cloud: .microsoft, name: "Ana", email: "ana@ejemplo.com", clientID: "client", clientSecret: nil)
        let drive = Account.scoped(to: "b!lib", named: "Documentos", from: parent)
        XCTAssertEqual(drive.credentialKey, parent.id)
        let store = MemoryCredentials(); store.stored[parent.id] = credential(expiresIn: -10)
        var used: [String] = []
        StubProtocol.handler = { request in
            let body = requestBody(request)
            used.append(body.contains("refresh_token=refresh-1") ? "refresh-1" : "otro")
            return (200, [:], Data(#"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":3600}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let parentAPI = CloudAPI(account: parent, session: session, credentials: store)
        let driveAPI = CloudAPI(account: drive, session: session, credentials: store)
        async let a = parentAPI.token()
        async let b = driveAPI.token()
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, "fresh"); XCTAssertEqual(second, "fresh")
        XCTAssertEqual(used, ["refresh-1"], "Una sola renovación entre las dos cuentas")

        // And one that arrives later, with its own stale copy in memory, picks up what the other already wrote
        // instead of spending the refresh token a second time.
        let latecomer = CloudAPI(account: drive, session: session, credentials: store)
        _ = try await latecomer.token()
        store.stored[parent.id] = Credential(accessToken: "fresh", refreshToken: "refresh-2", expires: Date().addingTimeInterval(-10))
        store.stored[parent.id] = Credential(accessToken: "renovado-fuera", refreshToken: "refresh-3", expires: Date().addingTimeInterval(3600))
        let reused = try await latecomer.token()
        XCTAssertEqual(reused, "fresh", "Mientras su copia vale, no consulta el Llavero")
        XCTAssertEqual(used.count, 1)
    }

    func testAKeychainThatRefusesTheWriteDoesNotThrowAwayTheOnlyLiveToken() async throws {
        // The provider has already retired the old refresh token by the time the write happens. Losing the new one
        // as well would mean no working token at all, and the account would break in the middle of a transfer.
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: -10)
        store.refuseSaves = true
        StubProtocol.handler = { [refreshed] _ in (200, [:], refreshed) }
        let api = client(store)
        var warning: String?
        api.credentialSaveDidFail = { warning = $0 }
        let renewed = try await api.token()
        XCTAssertEqual(renewed, "fresh", "La sesión renovada se usa aunque no se pueda guardar")
        let again = try await api.token()
        XCTAssertEqual(again, "fresh", "Y se sigue usando desde memoria")
        XCTAssertFalse(api.sessionExpired)
        XCTAssertEqual(store.stored[account.id]?.refreshToken, "refresh-1", "El Llavero se quedó como estaba")
        let message = try XCTUnwrap(warning)
        XCTAssertTrue(message.contains("Llavero") || message.contains("volver a conectarla"), message)
    }

    func testWhatIsWorthRepeatingDependsOnTheStatusAndTheMethod() {
        // A 429 means the provider did not process the request at all, so repeating it is safe whatever it was. A 5xx
        // may have been applied before the error came back, so a POST that creates something is not repeated.
        XCTAssertNotNil(CloudAPI.retryDelay(response(429), method: "POST", attempt: 0))
        XCTAssertNotNil(CloudAPI.retryDelay(response(429), method: "GET", attempt: 0))
        XCTAssertNil(CloudAPI.retryDelay(response(503), method: "POST", attempt: 0), "Podría haber creado la carpeta")
        XCTAssertNotNil(CloudAPI.retryDelay(response(503), method: "POST", attempt: 0, repeatable: true), "Salvo que sea una lectura")
        for method in ["GET", "PUT", "DELETE", "PATCH"] {
            XCTAssertNotNil(CloudAPI.retryDelay(response(503), method: method, attempt: 0), method)
        }
        XCTAssertNil(CloudAPI.retryDelay(response(404), method: "GET", attempt: 0))
        XCTAssertNil(CloudAPI.retryDelay(response(200), method: "GET", attempt: 0))
        XCTAssertNil(CloudAPI.retryDelay(nil, method: "GET", attempt: 0))
        // What the provider asks for wins over the backoff, within reason.
        XCTAssertEqual(CloudAPI.retryDelay(response(429, retryAfter: "7"), method: "GET", attempt: 0), 7)
        XCTAssertEqual(CloudAPI.retryDelay(response(429, retryAfter: "9999"), method: "GET", attempt: 0), 30, "Con un tope")
        XCTAssertEqual(CloudAPI.retryDelay(response(429), method: "GET", attempt: 3), 8, "Sin cabecera, se duplica la espera")
    }
    private func response(_ status: Int, retryAfter: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil,
                        headerFields: retryAfter.map { ["Retry-After": $0] })!
    }

    func testARefusalWithRetryAfterIsRepeatedAndTheWaitTravelsToTheQueue() async throws {
        let store = MemoryCredentials(); store.stored[account.id] = credential(expiresIn: 3600)
        var attempts = 0
        StubProtocol.handler = { _ in
            attempts += 1
            if attempts == 1 { return (429, ["Retry-After": "1"], Data(#"{"error":{"message":"rate limit"}}"#.utf8)) }
            return (200, [:], Data(#"{"ok":true}"#.utf8))
        }
        let api = client(store)
        // A rename is a PATCH: repeating it leaves the same name, so it is safe to wait and ask again.
        let result = try await api.json(URL(string: "https://www.googleapis.com/drive/v3/files/abc")!, method: "PATCH", body: ["name": "x"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(attempts, 2)

        // When the retries run out, the wait the provider asked for reaches the transfer queue with the error.
        attempts = 0
        StubProtocol.handler = { _ in attempts += 1; return (429, ["Retry-After": "2"], Data()) }
        do {
            _ = try await api.json(URL(string: "https://www.googleapis.com/drive/v3/files/abc")!, method: "PATCH", body: ["name": "x"])
            XCTFail("Cuatro negativas seguidas deben fallar")
        } catch let error as ServiceError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfter, 2)
            XCTAssertTrue(error.retryable)
        }
        XCTAssertEqual(attempts, 4)
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
        api.sessionDidExpire = { _ in notifications += 1 }
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
        api.sessionDidExpire = { _ in notifications += 1 }
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
