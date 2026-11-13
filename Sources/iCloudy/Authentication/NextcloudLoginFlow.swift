import Foundation
import AppKit

/// Nextcloud's Login Flow v2: iCloudy asks the server for a login page and a polling token, the person signs in on
/// that page in their own browser (with whatever the server demands: two factors, SSO, WebAuthn), and the server hands
/// iCloudy an app password made for it alone, which can be revoked from the server's security settings.
///
/// It replaces typing the account's password, or creating an app password by hand, as the default way into a
/// Nextcloud. The manual form stays for servers that have the flow switched off.
/// https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html
@MainActor
struct NextcloudLoginFlow {
    var session: URLSession = .shared
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// How often the server is asked whether the person has finished. Its documentation does not set a rate; the
    /// desktop client asks every few seconds. Tests make it instant.
    var pollInterval: Duration = .seconds(2)
    /// The token the server hands out lives twenty minutes.
    var lifetime: Duration = .seconds(20 * 60)

    struct Grant: Equatable {
        let server: URL
        let loginName: String
        let appPassword: String
    }

    /// The installation's root from whatever was typed: a bare host, the address of its web interface, or the full
    /// WebDAV path copied from its settings. https unless the server is on the local network and said otherwise.
    static func installation(_ typed: String) throws -> URLComponents {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host, !host.isEmpty, ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw CloudError.message(L("Escribe la dirección de tu Nextcloud, por ejemplo nube.ejemplo.com"))
        }
        if components.scheme?.lowercased() == "http", !LoginAddress.isLocalNetwork(host) {
            throw CloudError.message(L("Esa dirección no usa cifrado, y la contraseña viajaría en claro en cada petición. Usa https://, o una dirección de tu red local."))
        }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        var path = components.path
        for marker in ["/remote.php", "/index.php", "/apps/", "/login"] {
            if let range = path.range(of: marker) { path = String(path[..<range.lowerBound]) }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components
    }

    /// The first step: where the person signs in, and where to ask for the result.
    func begin(_ root: URLComponents) async throws -> (login: URL, poll: URL, token: String) {
        var start = root
        start.path += "/index.php/login/v2"
        guard let url = start.url else { throw CloudError.message(L("Escribe la dirección de tu Nextcloud, por ejemplo nube.ejemplo.com")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("iCloudy", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let body = try? HTTP.json(data),
              let poll = body["poll"] as? [String: Any], let token = poll["token"] as? String, !token.isEmpty,
              let endpoint = (poll["endpoint"] as? String).flatMap(URL.init(string:)),
              let login = (body["login"] as? String).flatMap(URL.init(string:)) else {
            throw CloudError.message(L("Ese servidor no ofrece el inicio de sesión en el navegador de Nextcloud. Comprueba la dirección, o usa «Usuario y contraseña» con una contraseña de aplicación."))
        }
        // Both addresses have to belong to the server that was typed: a page elsewhere would be a place to type the
        // password into, and a polling address elsewhere would receive the app password.
        for url in [login, endpoint] {
            guard url.host?.lowercased() == root.host?.lowercased(), Self.isSecure(url) else {
                throw CloudError.message(L("El servidor propuso iniciar sesión en otra dirección (\(url.host ?? "")). Por seguridad no se ha abierto."))
            }
        }
        return (login, endpoint, token)
    }

    /// Asks until the person has signed in, the token expires or the task is cancelled. 404 means "not yet".
    func wait(poll endpoint: URL, token: String) async throws -> Grant {
        let clock = ContinuousClock()
        let deadline = clock.now + lifetime
        while clock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = HTTP.form(["token": token])
            do {
                let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    guard let body = try? HTTP.json(data), let server = (body["server"] as? String).flatMap(URL.init(string:)),
                          let name = body["loginName"] as? String, !name.isEmpty,
                          let password = body["appPassword"] as? String, !password.isEmpty else {
                        throw CloudError.message(L("El servidor terminó el inicio de sesión sin devolver una contraseña de aplicación."))
                    }
                    return Grant(server: server, loginName: name, appPassword: password)
                }
                if status != 404 { try HTTP.validate(response, data: data) }
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                // A laptop that sleeps while the person signs in drops one poll; the next one carries on.
            }
            try await Task.sleep(for: pollInterval)
        }
        throw CloudError.message(L("El inicio de sesión en el navegador caducó. Vuelve a intentarlo."))
    }

    /// The whole flow, ending in a WebDAV account with the Nextcloud flavour, checked with a PROPFIND like any other.
    func signIn(server typed: String, existing: [Account] = []) async throws -> (Account, Credential) {
        let root = try Self.installation(typed)
        let (login, poll, token) = try await begin(root)
        openBrowser(login)
        let grant = try await wait(poll: poll, token: token)
        // The files live under the user's own WebDAV root. The address is the one typed, rather than the one the
        // server reports: behind a proxy the two can differ, and the typed one is known to reach it.
        var dav = root
        dav.path += "/remote.php/dav/files/" + (await userID(root, grant: grant))
        guard let address = dav.url?.absoluteString else { throw CloudError.message(L("Escribe la dirección de tu Nextcloud, por ejemplo nube.ejemplo.com")) }
        var (account, credential) = try await WebDAVAuthentication(session: session)
            .signInWebDAV(server: address, username: grant.loginName, password: grant.appPassword, existing: existing)
        account.options["flavor"] = "nextcloud"
        return (account, credential)
    }

    /// The user id the files are kept under. It is the login name unless the server signs people in with something
    /// else (an e-mail address, an LDAP attribute), and then only the server knows it.
    func userID(_ root: URLComponents, grant: Grant) async -> String {
        var components = root
        components.path += "/ocs/v2.php/cloud/user"
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { return grant.loginName }
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("Basic " + Data("\(grant.loginName):\(grant.appPassword)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request, delegate: RedirectGuard.shared),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? HTTP.json(data), let ocs = body["ocs"] as? [String: Any],
              let id = (ocs["data"] as? [String: Any])?["id"] as? String, !id.isEmpty, !id.contains("/") else { return grant.loginName }
        return id
    }

    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && LoginAddress.isLocalNetwork(url.host ?? ""))
    }
}
