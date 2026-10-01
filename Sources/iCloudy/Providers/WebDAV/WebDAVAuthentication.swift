import Foundation

@MainActor
struct WebDAVAuthentication {
    var session: URLSession = .shared

    /// `existing` are the accounts already connected: signing in again to one of them has to land on its id, whatever
    /// rule produced that id when it was created, so the Keychain entry and everything keyed by it carry over.
    func signInWebDAV(server: String, username: String, password: String, existing: [Account] = []) async throws -> (Account, Credential) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host, !host.isEmpty, ["http", "https"].contains(components.scheme ?? "") else {
            throw CloudError.message(L("Escribe una dirección de servidor válida, por ejemplo https://nube.ejemplo.com/remote.php/dav/files/ana"))
        }
        let (username, password) = LoginAddress.credentials(embeddedIn: &components, username: username, password: password)
        guard !username.isEmpty, !password.isEmpty else { throw CloudError.message(L("Introduce el usuario y la contraseña del servidor.")) }
        // A Basic password travels in every single request. macOS blocks plain HTTP to anything but the local
        // network, and over the internet it would be handing the password to whoever is listening.
        if components.scheme?.lowercased() == "http", !LoginAddress.isLocalNetwork(host) {
            throw CloudError.message(L("Esa dirección no usa cifrado, y la contraseña viajaría en claro en cada petición. Usa https://, o una dirección de tu red local."))
        }
        components.query = nil; components.fragment = nil
        if components.path.hasSuffix("/") { components.path = String(components.path.dropLast()) }
        guard let base = components.url else { throw CloudError.message(L("Escribe una dirección de servidor válida, por ejemplo https://nube.ejemplo.com/remote.php/dav/files/ana")) }

        let secret = Data("\(username):\(password)".utf8).base64EncodedString()
        var probe = URLRequest(url: base)
        probe.httpMethod = "PROPFIND"
        probe.setValue("0", forHTTPHeaderField: "Depth")
        probe.setValue("Basic " + secret, forHTTPHeaderField: "Authorization")
        probe.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        probe.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (data, response) = try await session.data(for: probe, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        switch http.statusCode {
        case 401, 403:
            throw CloudError.message(L("El servidor rechazó el usuario o la contraseña. Si tu servidor usa verificación en dos pasos, crea una contraseña de aplicación."))
        case 404:
            throw CloudError.message(L("El servidor respondió, pero esa ruta no existe. Comprueba la dirección completa de WebDAV."))
        case 207, 200..<300:
            break
        default:
            try HTTP.validate(response, data: data)
        }
        let id = WebDAVOrigin(components).map { WebDAVOrigin.accountID($0, username: username, among: existing) }
            ?? WebDAVOrigin.legacyID(host: host, path: components.path, username: username)
        let account = Account(id: id, cloud: .webdav,
                              name: host, email: username + "@" + host, clientID: "", clientSecret: nil,
                              serverURL: base.absoluteString)
        // Basic credentials never expire on their own; only the server can revoke them.
        return (account, Credential(accessToken: secret, refreshToken: "", expires: .distantFuture))
    }
}

/// What identifies a WebDAV server: scheme, host, effective port and base path. Two sign-ins are the same account
/// only when all four match and so does the user.
///
/// The account id used to be `webdav:` + host + path + `#` + user. It left out the scheme and the port, so
/// `https://nas:5006/dav` and `https://nas/dav` with the same user overwrote each other's Keychain entry and state.
/// Everything a person has (credential, favourites, mirrors, persisted transfers, caches, Spotlight entries) is keyed
/// by that id, so an existing one is never rewritten:
/// - https on its default port keeps that exact layout. It is by far the common case, and every other origin is now
///   spelled differently, so it can no longer be confused with them. Only the host is lowercased in new ids.
/// - Any other origin spells itself out: `webdav:http://nas:8080/dav#ana`.
/// - Signing in to a server and user that already have an account reuses that account's id, whichever of these rules
///   produced it, the old one with the host as typed included. An account created before this change on another port
///   or over http is found again this way instead of appearing twice.
/// - If the short layout is already held by a different origin (an old account on another port, whose id dropped the
///   port), the new account takes the spelled-out form, `webdav:https://nas/dav#ana`, instead of overwriting it.
struct WebDAVOrigin: Equatable {
    let scheme: String
    let host: String
    /// Nil when it is the scheme's default, so `https://nas:443` and `https://nas` are the same server.
    let port: Int?
    let path: String

    init?(_ components: URLComponents) {
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        self.scheme = scheme
        // Host names are case-insensitive: a typed `NAS.local` is the same machine as `nas.local`.
        self.host = host.lowercased()
        let standard = scheme == "https" ? 443 : 80
        port = components.port.flatMap { $0 == standard ? nil : $0 }
        // Paths are case-sensitive on a WebDAV server and stay as they are, minus a trailing slash.
        var path = components.path
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        self.path = path
    }
    init?(serverURL: String) {
        guard let components = URLComponents(string: serverURL) else { return nil }
        self.init(components)
    }

    /// The rule before scheme and port were part of the id, with the host exactly as `URLComponents` read it.
    static func legacyID(host: String, path: String, username: String) -> String {
        "webdav:" + host + path + "#" + username
    }
    /// The short layout for https on its default port, the spelled-out one for everything else.
    static func canonicalID(_ origin: WebDAVOrigin, username: String) -> String {
        origin.scheme == "https" && origin.port == nil
            ? legacyID(host: origin.host, path: origin.path, username: username)
            : explicitID(origin, username: username)
    }
    /// Never equal to a short id, because a host cannot contain `://`. An IPv6 literal is bracketed so that its
    /// colons cannot be read as a port.
    static func explicitID(_ origin: WebDAVOrigin, username: String) -> String {
        let host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[" + origin.host + "]" : origin.host
        return "webdav:" + origin.scheme + "://" + host + (origin.port.map { ":" + String($0) } ?? "") + origin.path + "#" + username
    }
    /// Every id this app could have given an account for this stored address and user, the old rule included.
    static func knownIDs(serverURL: String, username: String) -> Set<String> {
        guard let components = URLComponents(string: serverURL), let origin = WebDAVOrigin(components),
              let host = components.host else { return [] }
        return [legacyID(host: host, path: origin.path, username: username),
                canonicalID(origin, username: username), explicitID(origin, username: username)]
    }
    /// The id for signing in to `origin` as `username`, given the accounts already connected.
    static func accountID(_ origin: WebDAVOrigin, username: String, among existing: [Account]) -> String {
        let webdav = existing.filter { $0.cloud == .webdav }
        if let same = webdav.first(where: { account in
            guard let stored = account.serverURL, WebDAVOrigin(serverURL: stored) == origin else { return false }
            return knownIDs(serverURL: stored, username: username).contains(account.id)
        }) { return same.id }
        let canonical = canonicalID(origin, username: username)
        // Taken at this point means a different server holds it under the old rule.
        return webdav.contains { $0.id == canonical } ? explicitID(origin, username: username) : canonical
    }
}
