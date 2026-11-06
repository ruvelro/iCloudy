import Foundation

/// How a WebDAV account proves who it is, kept in `options["auth"]`. Accounts from before this option are Basic.
enum WebDAVAuth: String, CaseIterable, Identifiable {
    /// User and password in every request, which is what most servers expect over HTTPS.
    case basic
    /// User and password hashed with the server's nonce, for servers that refuse Basic (some NAS boxes, older IIS).
    /// The password never travels.
    case digest
    /// An OAuth or OpenID Connect access token, as `Authorization: Bearer`. For servers such as ownCloud Infinite Scale
    /// that sign in through their identity provider. iCloudy does not renew it: when it expires, the account asks to
    /// be connected again with a new one.
    case bearer
    var id: String { rawValue }
    static let option = "auth"
}

extension Account {
    var webdavAuth: WebDAVAuth { options[WebDAVAuth.option].flatMap(WebDAVAuth.init(rawValue:)) ?? .basic }
}

extension WebDAVProvider {
    /// The user and password inside a Basic credential, which Digest needs separately.
    func passwordPair() async throws -> (user: String, password: String) {
        let secret = try await token()
        guard let decoded = Data(base64Encoded: secret).flatMap({ String(data: $0, encoding: .utf8) }),
              let colon = decoded.firstIndex(of: ":") else {
            expireSession(); throw CloudError.sessionExpired(nil)
        }
        return (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
    }

    /// Asks the server for a Digest challenge with a request that carries no credentials at all, so that a Digest
    /// account never sends its password in Basic form, not even once.
    func fetchDigestChallenge() async throws -> HTTPDigest.Challenge {
        var probe = URLRequest(url: try webdavURL("root"))
        probe.httpMethod = "PROPFIND"
        probe.setValue("0", forHTTPHeaderField: "Depth")
        Diagnostics.stamp(&probe, account: account)
        let (_, response) = try await session.data(for: probe, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse, let challenge = HTTPDigest.challenge(in: http) else {
            throw CloudError.message(L("El servidor ya no pide autenticación Digest. Vuelve a conectar la cuenta."))
        }
        return challenge
    }

    func digestHeader(_ challenge: HTTPDigest.Challenge, method: String, url: URL) async throws -> String {
        let (user, password) = try await passwordPair()
        digestCount += 1
        return HTTPDigest.authorization(challenge: challenge, user: user, password: password, method: method, url: url, count: digestCount)
    }

    func webdavAuthorization(method: String, url: URL) async throws -> String {
        switch account.webdavAuth {
        case .bearer:
            return "Bearer " + (try await token())
        case .digest:
            let challenge: HTTPDigest.Challenge
            if let known = digestChallenge { challenge = known }
            else { challenge = try await fetchDigestChallenge(); digestChallenge = challenge; digestCount = 0 }
            return try await digestHeader(challenge, method: method, url: url)
        case .basic:
            // A server that turned out to want Digest is answered that way from then on, without a round of 401s.
            if let digestChallenge { return try await digestHeader(digestChallenge, method: method, url: url) }
            return "Basic " + (try await token())
        }
    }

    /// A Digest challenge is answered with the stored user and password, whether the account was connected for
    /// Digest or the server switched to it since. A token cannot be turned into a Digest response.
    func webdavAnswer(_ refusal: HTTPURLResponse, method: String, url: URL) async throws -> String? {
        guard account.webdavAuth != .bearer, let challenge = HTTPDigest.challenge(in: refusal) else { return nil }
        digestChallenge = challenge; digestCount = 0
        return try await digestHeader(challenge, method: method, url: url)
    }
}
