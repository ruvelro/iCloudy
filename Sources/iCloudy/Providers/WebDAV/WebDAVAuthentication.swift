import Foundation

@MainActor
struct WebDAVAuthentication {
    var session: URLSession = .shared

    func signInWebDAV(server: String, username: String, password: String) async throws -> (Account, Credential) {
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
        let account = Account(id: "webdav:" + host + components.path + "#" + username, cloud: .webdav,
                              name: host, email: username + "@" + host, clientID: "", clientSecret: nil,
                              serverURL: base.absoluteString)
        // Basic credentials never expire on their own; only the server can revoke them.
        return (account, Credential(accessToken: secret, refreshToken: "", expires: .distantFuture))
    }
}
