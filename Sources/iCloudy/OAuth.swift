import AppKit
import CryptoKit
import Network

enum HTTP {
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)!
    }
    static func json(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message(L("Respuesta no válida del servicio.")) }
        return result
    }
    static func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        guard (200..<300).contains(response.statusCode) else {
            let (code, message) = errorDetails(data)
            let fallback = "El servicio devolvió HTTP \(response.statusCode). \(response.statusCode == 401 ? L("Vuelve a conectar la cuenta.") : L("Inténtalo de nuevo más tarde."))"
            throw ServiceError(status: response.statusCode, detail: message ?? fallback, code: code,
                               retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? ""))
        }
    }
    /// Drive and Graph nest the error as an object; the OAuth token endpoints follow RFC 6749 with `error` and `error_description` strings.
    static func errorDetails(_ data: Data) -> (code: String?, message: String?) {
        guard let object = try? json(data) else { return (nil, nil) }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? (error["status"] as? String)
            return (code, error["message"] as? String)
        }
        if let code = object["error"] as? String {
            return (code, (object["error_description"] as? String) ?? code)
        }
        // Dropbox describes the failure in a flat summary string alongside a tagged error object.
        if let summary = object["error_summary"] as? String { return (summary, summary) }
        // Box uses `code` and `message` at the top level.
        if let code = object["code"] as? String { return (code, object["message"] as? String ?? code) }
        return (nil, nil)
    }
    static func token(cloud: Cloud, values: [String: String], session: URLSession = .shared) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: cloud.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try json(data)
    }
}

@MainActor
final class OAuth {
    private var listener: NWListener?
    private var callback: CheckedContinuation<String, Error>?
    private var readiness: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""
    private var connections: [NWConnection] = []
    private var cancelled = false
    private let session: URLSession
    private let openURL: (URL) -> Bool
    /// Account picker, consent screen and a second factor can easily take several minutes.
    static let loginTimeout: Duration = .seconds(600)

    /// `session` carries the token and profile requests; `openURL` hands the authorization URL to the browser.
    /// Both are injectable so the loopback flow can run end to end in tests.
    init(session: URLSession = .shared, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.session = session; self.openURL = openURL
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    func signIn(cloud: Cloud, clientID: String, clientSecret: String) async throws -> (Account, Credential) {
        cancelled = false
        let verifier = Self.random()
        expectedState = Self.random()
        defer { stop() }
        // Microsoft and Dropbox validate the registered port, so for them it has to be the fixed one. Google ignores
        // the port of a loopback redirect and Box only checks scheme, host and path, so with those two a busy 53682
        // falls back to an ephemeral port instead of blocking the sign-in.
        let port: UInt16
        do { port = try await listen(on: OAuthRequest.defaultPort) }
        catch {
            guard OAuthRequest.toleratesAnyPort(cloud) else { throw CloudError.message(L("No se pudo preparar el inicio de sesión: el puerto \(OAuthRequest.defaultPort) está ocupado. Cierra otras instancias de iCloudy y vuelve a intentarlo.")) }
            port = try await listen(on: 0)
        }
        let redirect = OAuthRequest.redirectURI(port: port)
        let url = OAuthRequest.authorizationURL(cloud: cloud, clientID: clientID, state: expectedState, challenge: Self.challenge(verifier), port: port)
        let code: String = try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: Self.loginTimeout) } catch { return }
                self?.finish(.failure(CloudError.message(L("No llegó la respuesta del navegador en 10 minutos y se ha cancelado el inicio de sesión. Si aún estás en la página del proveedor, ciérrala y vuelve a pulsar «Continuar» para empezar de nuevo."))))
            }
            if !openURL(url) { finish(.failure(CloudError.message(L("No se pudo abrir el navegador.")))) }
        }
        var fields = ["client_id": clientID, "code": code, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier]
        // Google desktop clients and Box both expect their (public, extractable) secret alongside the PKCE verifier.
        if [.google, .box].contains(cloud) && !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        let tokens = try await HTTP.token(cloud: cloud, values: fields, session: session)
        guard !cancelled else { throw CancellationError() }
        guard let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String else { throw CloudError.message(L("El proveedor no devolvió acceso permanente. Repite el consentimiento.")) }
        var request = URLRequest(url: URL(string: Self.profileEndpoint(cloud))!)
        // Dropbox exposes the current account through an RPC, so it is a POST even though it only reads.
        if cloud == .dropbox { request.httpMethod = "POST" }
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard !cancelled else { throw CancellationError() }
        try HTTP.validate(response, data: data)
        let profile = try HTTP.json(data)
        let identityKey = cloud == .google ? "sub" : (cloud == .dropbox ? "account_id" : "id")
        guard let identity = profile[identityKey] as? String else { throw CloudError.message(L("No se pudo identificar la cuenta.")) }
        let email = profile["email"] as? String ?? profile["mail"] as? String ?? profile["userPrincipalName"] as? String
            ?? profile["login"] as? String ?? identity
        // Dropbox nests the display name; Box and Graph use plain strings under different keys.
        let name = profile["name"] as? String ?? (profile["name"] as? [String: Any])?["display_name"] as? String
            ?? ((profile["name"] as? [String: Any])?["display_name"] as? String) ?? profile["displayName"] as? String ?? email
        let account = Account(id: cloud.rawValue + ":" + identity, cloud: cloud, name: name, email: email, clientID: clientID,
                              clientSecret: [.google, .box].contains(cloud) && !clientSecret.isEmpty ? clientSecret : nil)
        return (account, Credential(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3600)))
    }

    static func profileEndpoint(_ cloud: Cloud) -> String {
        switch cloud {
        case .google: return "https://openidconnect.googleapis.com/v1/userinfo"
        case .microsoft: return "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName"
        case .dropbox: return "https://api.dropboxapi.com/2/users/get_current_account"
        case .box: return "https://api.box.com/2.0/users/me"
        case .webdav, .ftp, .volume, .mega, .o2: return ""
        }
    }

    /// WebDAV servers authenticate with a user name and a password, so there is no browser round trip. The credentials
    /// are checked with one PROPFIND before the account is stored, and they only ever reach the server the user typed.
    /// Mega signs in with the account's own e-mail and password: there is no OAuth and no application registration.
    /// The password never leaves this Mac. What is sent is a value derived from it, and what comes back is a session
    /// identifier that only the account's private key can unwrap.
    func signInMega(email: String, password: String) async throws -> (Account, Credential) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), !address.hasPrefix("@"), !password.isEmpty else {
            throw CloudError.message(L("Escribe el correo y la contraseña de tu cuenta de Mega."))
        }
        // A second-factor code is typed after the password, separated by a space, because Mega asks for both at once.
        var secret = password
        var code: String?
        if let space = password.lastIndex(of: " ") {
            let tail = String(password[password.index(after: space)...])
            if tail.count == 6, tail.allSatisfy(\.isNumber) {
                code = tail
                secret = String(password[password.startIndex..<space])
            }
        }
        let signed = try await MegaAPI.signIn(email: address, password: secret, code: code, session: session)
        let account = Account(id: "mega:" + address, cloud: .mega, name: L("Mega"), email: address, clientID: "", clientSecret: nil)
        let credential = Credential(accessToken: signed.sid, refreshToken: "", expires: .distantFuture,
                                    secret: MegaCrypto.encode(signed.masterKey))
        return (account, credential)
    }

    func signInWebDAV(server: String, username: String, password: String) async throws -> (Account, Credential) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host, !host.isEmpty, ["http", "https"].contains(components.scheme ?? "") else {
            throw CloudError.message(L("Escribe una dirección de servidor válida, por ejemplo https://nube.ejemplo.com/remote.php/dav/files/ana"))
        }
        let (username, password) = Self.credentials(embeddedIn: &components, username: username, password: password)
        guard !username.isEmpty, !password.isEmpty else { throw CloudError.message(L("Introduce el usuario y la contraseña del servidor.")) }
        // A Basic password travels in every single request. macOS blocks plain HTTP to anything but the local
        // network, and over the internet it would be handing the password to whoever is listening.
        if components.scheme?.lowercased() == "http", !Self.isLocalNetwork(host) {
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
        let (data, response) = try await session.data(for: probe)
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
        let account = Account(id: "webdav:" + host + components.path + "#" + username, cloud: .webdav,
                              name: host, email: username + "@" + host, clientID: "", clientSecret: nil,
                              serverURL: base.absoluteString)
        // Basic credentials never expire on their own; only the server can revoke them.
        return (account, Credential(accessToken: secret, refreshToken: "", expires: .distantFuture))
    }

    /// Signs in to an FTP or FTPS server. The credentials are proved against the server before anything is stored,
    /// exactly like WebDAV, and the connection is closed again straight away.
    func signInFTP(server: String, username: String, password: String) async throws -> (Account, Credential) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "ftp://" + trimmed
        guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty,
              ["ftp", "ftps"].contains((components.scheme ?? "").lowercased()) else {
            throw CloudError.message(L("Escribe una dirección válida, por ejemplo ftp://servidor.ejemplo.com/carpeta"))
        }
        let (username, password) = Self.credentials(embeddedIn: &components, username: username, password: password)
        guard !username.isEmpty else { throw CloudError.message(L("Introduce el usuario del servidor.")) }
        components.query = nil; components.fragment = nil
        if components.path.hasSuffix("/"), components.path.count > 1 { components.path = String(components.path.dropLast()) }
        let secure = components.scheme?.lowercased() == "ftps"
        let port = UInt16(components.port ?? (secure ? 990 : 21))
        let session = FTPSession(host: host, port: port, user: username, password: password,
                                 security: secure ? .implicitTLS : .none)
        do {
            try await session.connect()
            // PWD proves the session is usable, not just that the socket opened.
            _ = try await session.require("PWD", L("El servidor no respondió al comprobar la sesión."))
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        guard let base = components.url?.absoluteString else {
            throw CloudError.message(L("Escribe una dirección válida, por ejemplo ftp://servidor.ejemplo.com/carpeta"))
        }
        let account = Account(id: "ftp:" + host + ":" + String(port) + components.path + "#" + username, cloud: .ftp,
                              name: host, email: username + "@" + host, clientID: "", clientSecret: nil, serverURL: base)
        return (account, Credential(accessToken: Data("\(username):\(password)".utf8).base64EncodedString(),
                                    refreshToken: "", expires: .distantFuture))
    }

    /// True for an address that cannot leave the local network, which is where macOS still allows a connection in
    /// the clear: `.local` names, a bare host name, loopback, and the private IPv4 ranges.
    static func isLocalNetwork(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".local") { return true }
        // An IPv6 literal has no dots either, so it has to be recognised before the bare-name rule below: only
        // loopback and link-local are inside the building, and every other address is as public as any other.
        if name.contains(":") { return name == "::1" || name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") }
        if !name.contains(".") { return true }   // a bare name resolves only inside the local network
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 127 || parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    /// Password managers and NAS panels hand out addresses like `https://ana:secreta@nas/dav`. The address is stored
    /// outside the Keychain, so whatever rides in it is stripped here and treated as the credentials it is, unless the
    /// form already has its own. Nothing typed as an address ever ends up in `accounts.json`.
    static func credentials(embeddedIn components: inout URLComponents, username: String, password: String) -> (String, String) {
        let embeddedUser = components.user ?? "", embeddedPassword = components.password ?? ""
        components.user = nil; components.password = nil
        return (username.isEmpty ? embeddedUser : username, password.isEmpty ? embeddedPassword : password)
    }

    /// Binds the loopback listener and returns the port actually in use (`0` asks the system for a free one).
    private func listen(on requestedPort: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection) }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readiness = continuation
                server.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready: self.readiness?.resume(); self.readiness = nil
                        case .failed(let error):
                            self.readiness?.resume(throwing: error); self.readiness = nil
                            self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                server.start(queue: .main)
            }
        } catch {
            server.cancel(); listener = nil
            throw error
        }
        guard let port = server.port?.rawValue else { throw CloudError.message(L("No se pudo preparar el inicio de sesión.")) }
        return port
    }

    func cancel() {
        cancelled = true
        readiness?.resume(throwing: CancellationError()); readiness = nil
        finish(.failure(CancellationError()))
        stop()
    }
    private func stop() {
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }
    private func finish(_ result: Result<String, Error>) {
        callback?.resume(with: result); callback = nil
        timeout?.cancel(); timeout = nil
    }
    private func receive(_ connection: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { connections.append(connection); connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var accumulated = buffer
                accumulated.append(data ?? Data())
                guard accumulated.count < 16384, error == nil else { connection.cancel(); return }
                guard let request = String(data: accumulated, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, buffer: accumulated) } else { connection.cancel() }
                    return
                }
                let parts = request.components(separatedBy: "\r\n")[0].components(separatedBy: " ")
                guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]), components.path == "/callback" else { connection.cancel(); return }
                let items = components.queryItems ?? []
                guard items.first(where: { $0.name == "state" })?.value == self.expectedState else { connection.cancel(); return }
                let result = Result { try OAuthRequest.callbackCode(target: parts[1], expectedState: self.expectedState) }
                let body = "Puedes cerrar esta ventana y volver a iCloudy."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    connection.cancel()
                    Task { @MainActor in
                        self?.finish(result)
                        NSApp?.activate(ignoringOtherApps: true) // nil under XCTest
                    }
                })
            }
        }
    }
}
