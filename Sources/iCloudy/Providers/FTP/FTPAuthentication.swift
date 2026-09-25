import Foundation

@MainActor
struct FTPAuthentication {
    var session: URLSession = .shared

    func signInFTP(server: String, username: String, password: String) async throws -> (Account, Credential) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "ftp://" + trimmed
        guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty,
              ["ftp", "ftps", "ftpes"].contains((components.scheme ?? "").lowercased()) else {
            throw CloudError.message(L("Escribe una dirección válida, por ejemplo ftp://servidor.ejemplo.com/carpeta"))
        }
        let (username, password) = LoginAddress.credentials(embeddedIn: &components, username: username, password: password)
        guard !username.isEmpty else { throw CloudError.message(L("Introduce el usuario del servidor.")) }
        components.query = nil; components.fragment = nil
        if components.path.hasSuffix("/"), components.path.count > 1 { components.path = String(components.path.dropLast()) }
        let security = FTPProvider.ftpSecurity(scheme: components.scheme)
        guard let port = UInt16(exactly: components.port ?? (security == .implicitTLS ? 990 : 21)), port > 0 else {
            throw CloudError.message(L("El puerto FTP debe estar entre 1 y 65535."))
        }
        let session = FTPSession(host: host, port: port, user: username, password: password, security: security)
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
}
