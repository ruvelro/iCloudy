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
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("Respuesta no válida del servicio.") }
        return result
    }
    static func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse else { throw CloudError.message("Respuesta HTTP no válida.") }
        guard (200..<300).contains(response.statusCode) else {
            let (code, message) = errorDetails(data)
            let fallback = "El servicio devolvió HTTP \(response.statusCode). \(response.statusCode == 401 ? "Vuelve a conectar la cuenta." : "Inténtalo de nuevo más tarde.")"
            throw ServiceError(status: response.statusCode, detail: message ?? fallback, code: code)
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
        return (nil, nil)
    }
    static func token(cloud: Cloud, values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: cloud.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let (data, response) = try await URLSession.shared.data(for: request)
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
    /// Account picker, consent screen and a second factor can easily take several minutes.
    static let loginTimeout: Duration = .seconds(600)

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
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 53682)
        let server: NWListener
        do { server = try NWListener(using: parameters) }
        catch { throw CloudError.message("No se pudo preparar el inicio de sesión. Cierra otras instancias de iCloudy y vuelve a intentarlo.") }
        listener = server
        defer { stop() }
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection) }
        }
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
        let redirect = OAuthRequest.redirectURI
        let url = OAuthRequest.authorizationURL(cloud: cloud, clientID: clientID, state: expectedState, challenge: Self.challenge(verifier))
        let code: String = try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: Self.loginTimeout) } catch { return }
                self?.finish(.failure(CloudError.message("No llegó la respuesta del navegador en 10 minutos y se ha cancelado el inicio de sesión. Si aún estás en la página del proveedor, ciérrala y vuelve a pulsar «Continuar» para empezar de nuevo.")))
            }
            if !NSWorkspace.shared.open(url) { finish(.failure(CloudError.message("No se pudo abrir el navegador."))) }
        }
        var fields = ["client_id": clientID, "code": code, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier]
        if cloud == .google && !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        let tokens = try await HTTP.token(cloud: cloud, values: fields)
        guard !cancelled else { throw CancellationError() }
        guard let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String else { throw CloudError.message("El proveedor no devolvió acceso permanente. Repite el consentimiento.") }
        var request = URLRequest(url: URL(string: cloud == .google ? "https://openidconnect.googleapis.com/v1/userinfo" : "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName")!)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard !cancelled else { throw CancellationError() }
        try HTTP.validate(response, data: data)
        let profile = try HTTP.json(data)
        guard let identity = profile[cloud == .google ? "sub" : "id"] as? String else { throw CloudError.message("No se pudo identificar la cuenta.") }
        let email = profile["email"] as? String ?? profile["mail"] as? String ?? profile["userPrincipalName"] as? String ?? identity
        let account = Account(id: cloud.rawValue + ":" + identity, cloud: cloud, name: profile["name"] as? String ?? profile["displayName"] as? String ?? email, email: email, clientID: clientID, clientSecret: cloud == .google && !clientSecret.isEmpty ? clientSecret : nil)
        return (account, Credential(accessToken: access, refreshToken: refresh, expires: Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3600)))
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
                        NSApp.activate(ignoringOtherApps: true)
                    }
                })
            }
        }
    }
}
