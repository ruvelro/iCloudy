import Foundation
import UniformTypeIdentifiers

@MainActor
class CloudSession {
    let account: Account
    let session: URLSession
    private let tokenProvider: (() async throws -> String)?
    let credentials: CredentialStore
    private(set) var invalidated = false
    /// Set once the provider rejects the stored credential. Only reconnecting the account, which replaces this client, clears it.
    private(set) var sessionExpired = false
    /// Reports that the account needs signing in again, and why when the provider said something useful. The reason
    /// is shown to the user: an undocumented provider that drops sessions is impossible to diagnose from a report
    /// that only says "expired".
    var sessionDidExpire: ((String?) -> Void)?
    /// Reports a security-scoped bookmark that had to be renewed, so the account can keep the new one.
    var bookmarkDidRenew: ((Data) -> Void)?
    /// Reports that a renewed credential could not be written to the Keychain. The session keeps working for this
    /// run, but the next launch will read the retired one, so the person deserves to know before it happens.
    var credentialSaveDidFail: ((String) -> Void)?
    /// Keychain reads are synchronous and comparatively slow; the credential is read once per client and kept current here.
    private var cachedCredential: Credential?
    func dropCaches() {}
    func invalidate() { invalidated = true }
    init(account: Account, session: URLSession = .shared, tokenProvider: (() async throws -> String)? = nil, credentials: CredentialStore = KeychainCredentialStore()) {
        self.account = account; self.session = session; self.tokenProvider = tokenProvider; self.credentials = credentials
    }
    func expireSession(_ reason: String? = nil) {
        guard !sessionExpired else { return }
        sessionExpired = true
        Diagnostics.sessionExpired(account, reason: reason)
        sessionDidExpire?(reason)
    }

    /// `force` renews even when the local clock still considers the token valid, e.g. after a 401.
    func token(force: Bool = false) async throws -> String {
        guard !invalidated else { throw CancellationError() }
        if let tokenProvider { return try await tokenProvider() }
        guard !sessionExpired else { throw CloudError.sessionExpired(nil) }
        if cachedCredential == nil { cachedCredential = try credentials.read(account.credentialKey) }
        guard var credential = cachedCredential else { expireSession(); throw CloudError.sessionExpired(nil) }
        if !force, credential.expires.timeIntervalSinceNow > 90 { return credential.accessToken }
        // The cached copy may be older than what another client sharing this entry has already written, and renewing
        // from a refresh token the provider has retired would fail for no reason.
        if let stored = try? credentials.read(account.credentialKey), stored.expires > credential.expires {
            credential = stored; cachedCredential = stored
            if !force, stored.expires.timeIntervalSinceNow > 90 { return stored.accessToken }
        }
        // A self-hosted password has no refresh endpoint: if the server stops accepting it, only new credentials help.
        guard !account.cloud.isSelfHosted else {
            if force { expireSession(); throw CloudError.sessionExpired(nil) }
            return credential.accessToken
        }
        let current = credential
        do {
            let renewed = try await TokenRefresher.refresh(key: account.credentialKey) { [self] in
                try await exchangeRefreshToken(current)
            }
            // Whether this client is still wanted is this client's business. Asking inside the shared work would let
            // one account being disconnected abort the renewal another account is waiting on.
            guard !invalidated else { throw CancellationError() }
            cachedCredential = renewed
            Diagnostics.tokenRenewed(account)
            return renewed.accessToken
        } catch let error as CloudError {
            Diagnostics.tokenFailed(account, error: error)
            // The refresh may have been started by another client sharing this entry; this one has to notice too.
            if case .sessionExpired(let reason) = error { expireSession(reason) }
            throw error
        }
    }
    /// Trades the refresh token for a new one. Runs inside `TokenRefresher`, so only one of these is in flight per
    /// Keychain entry however many clients are waiting on it.
    private func exchangeRefreshToken(_ credential: Credential) async throws -> Credential {
        var fields = ["client_id": account.clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"]
        if let secret = account.clientSecret { fields["client_secret"] = secret }
        let result: [String: Any]
        do { result = try await HTTP.token(cloud: account.cloud, values: fields, session: session) }
        catch let error as ServiceError where (400..<500).contains(error.status) && !error.retryable {
            // invalid_grant, revoked consent or a deleted client: retrying cannot fix it, only a new sign-in.
            try Task.checkCancellation()
            throw CloudError.sessionExpired(error.code == nil ? nil : error.detail)
        }
        try Task.checkCancellation()
        guard let access = result["access_token"] as? String else { throw CloudError.message(L("No se pudo renovar la sesión. Vuelve a conectar la cuenta.")) }
        let updated = Credential(accessToken: access, refreshToken: result["refresh_token"] as? String ?? credential.refreshToken,
                                 expires: Date().addingTimeInterval(result["expires_in"] as? Double ?? 3600))
        // The provider has retired the old refresh token by now, so this one is the only one that still works. It is
        // adopted before the Keychain write, and a write that fails keeps the session alive for this run instead of
        // throwing away the only token there is. An entry that is no longer there belongs to an account somebody
        // disconnected while this was in flight, and writing it back would resurrect what was just deleted.
        cachedCredential = updated
        guard (try? credentials.read(account.credentialKey)) != nil else { return updated }
        do { try credentials.save(updated, key: account.credentialKey) }
        catch {
            credentialSaveDidFail?(L("No se pudo guardar la sesión renovada de \(account.cloud.title): \(error.localizedDescription) La cuenta funciona ahora, pero habrá que volver a conectarla al abrir iCloudy de nuevo."))
        }
        return updated
    }

    func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        Diagnostics.stamp(&request, account: account)
        request.setValue(account.cloud.authorizationScheme + " " + (try await token()), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends an authenticated request. A first 401 renews the token and retries once; a second 401 means the provider
    /// no longer honours this account, so the session is marked as expired instead of failing silently on every call.
    func send(_ request: inout URLRequest) async throws -> (Data, URLResponse) {
        Diagnostics.stamp(&request, account: account)
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        // A self-hosted server asking for Digest is not rejecting the password: iCloudy only speaks Basic. Calling
        // that an expired session sent people to re-type credentials that were right all along.
        if account.cloud.isSelfHosted, (response as? HTTPURLResponse)?.statusCode == 401,
           let challenge = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased(),
           challenge.contains("digest"), !challenge.contains("basic") {
            throw CloudError.message(L("Este servidor pide autenticación Digest, que iCloudy todavía no habla. Habilita la autenticación Basic sobre HTTPS en el servidor, o usa una contraseña de aplicación si la ofrece."))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil else { return (data, response) }
        request.setValue(account.cloud.authorizationScheme + " " + (try await token(force: true)), forHTTPHeaderField: "Authorization")
        let (retriedData, retriedResponse) = try await session.data(for: request, delegate: RedirectGuard.shared)
        if (retriedResponse as? HTTPURLResponse)?.statusCode == 401 { expireSession(); throw CloudError.sessionExpired(nil) }
        return (retriedData, retriedResponse)
    }

    /// How long to wait before repeating a refused request, or nil when it must not be repeated.
    ///
    /// A rate limit usually means the request was never processed, and a 5xx may have been applied before the failure
    /// came back. Neither is worth betting a duplicate on: a gateway can answer 429 after the origin already acted,
    /// so both are repeated only for methods that do the same thing twice as they do once. `repeatable` is for the
    /// calls that are reads despite being POSTs, which is most of Dropbox's API.
    static func retryDelay(_ response: URLResponse?, method: String, attempt: Int, repeatable: Bool = false) -> Double? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let idempotent = repeatable || ["GET", "HEAD", "PUT", "DELETE", "PATCH"].contains(method.uppercased())
        guard idempotent, http.statusCode == 429 || [500, 502, 503, 504].contains(http.statusCode) else { return nil }
        let announced = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
        return min(max(1, announced ?? pow(2, Double(attempt))), 30)
    }

    /// Tells the provider to forget upload sessions a cancelled transfer will never finish. Every failure here is
    /// ignored on purpose: the sessions expire by themselves, so this is a courtesy, not a step that can fail.

    /// Sends a body to a content host with the same policy as `send`: a first 401 renews the token and repeats the
    /// block, a second means the account is gone. The block uploads of Dropbox and Box go straight to their own hosts
    /// and used to miss that, so a token that expired mid-upload failed the transfer with a bare "HTTP 401".
    func upload(_ request: inout URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        Diagnostics.stamp(&request, account: account)
        let (body, response) = try await session.upload(for: request, from: data, delegate: RedirectGuard.shared)
        guard (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil else { return (body, response) }
        request.setValue(account.cloud.authorizationScheme + " " + (try await token(force: true)), forHTTPHeaderField: "Authorization")
        let (retriedBody, retriedResponse) = try await session.upload(for: request, from: data, delegate: RedirectGuard.shared)
        if (retriedResponse as? HTTPURLResponse)?.statusCode == 401 { expireSession(); throw CloudError.sessionExpired(nil) }
        return (retriedBody, retriedResponse)
    }

    func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try await request(url, method: method, body: body)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await send(&request)
            if attempt < 3, let delay = Self.retryDelay(response, method: method, attempt: attempt) {
                Diagnostics.retrying(account, method: method, url: url, status: (response as? HTTPURLResponse)?.statusCode, attempt: attempt + 1, delay: delay)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            try HTTP.validate(response, data: data)
            return try HTTP.json(data)
        }
        throw CloudError.message(L("El servicio no responde."))
    }


    nonisolated static func secureURL(_ address: String) -> URL? {
        guard var components = URLComponents(string: address), components.host?.isEmpty == false else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        return components.url
    }

    nonisolated static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }

    static func sorted(_ files: [CloudFile]) -> [CloudFile] {
        files.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    nonisolated static func mime(forName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }

    static func dropboxParent(_ path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }
    func downloadHTTP(_ initialRequest: URLRequest, to destination: URL, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let delegate = DownloadProgress(maxBytes: maxBytes) { bytes, total in Task { @MainActor in progress(bytes, total) } }
        var request = initialRequest
        Diagnostics.stamp(&request, account: account)
        var temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
            if (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil {
                // Same policy as `send`: renew once, then treat a repeated 401 as a revoked session.
                try? FileManager.default.removeItem(at: temporary)
                request.setValue(account.cloud.authorizationScheme + " " + (try await token(force: true)), forHTTPHeaderField: "Authorization")
                (temporary, response) = try await session.download(for: request, delegate: delegate)
            }
        } catch {
            if delegate.exceededLimit { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        if (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil { expireSession(); throw CloudError.sessionExpired(nil) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The error body landed in the temporary file. Read a bounded prefix so the provider's message survives,
            // e.g. Google's explanation when an export exceeds its size limit.
            let body = (try? FileHandle(forReadingFrom: temporary))?.readData(ofLength: 64 * 1024) ?? Data()
            try HTTP.validate(response, data: body)
        }
        if let maxBytes {
            let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(actual) <= maxBytes else { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
        }
        // moveItem refuses to overwrite an existing destination.
        let downloaded = temporary
        try await blockingIO { try FileManager.default.moveItem(at: downloaded, to: destination) }
    }
}
