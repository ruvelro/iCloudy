import Foundation

/// Identifies the installed application, never a user's credentials.
struct OAuthConfiguration: Codable {
    var googleClientID: String
    var googleDesktopClientSecret: String
    var microsoftClientID: String
    var dropboxAppKey: String = ""
    var boxClientID: String = ""
    var boxClientSecret: String = ""
    var pcloudClientID: String = ""
    var pcloudClientSecret: String = ""

    /// Older builds shipped a plist with only the first three keys; missing ones simply mean "not configured yet".
    init(googleClientID: String = "", googleDesktopClientSecret: String = "", microsoftClientID: String = "",
         dropboxAppKey: String = "", boxClientID: String = "", boxClientSecret: String = "",
         pcloudClientID: String = "", pcloudClientSecret: String = "") {
        self.googleClientID = googleClientID; self.googleDesktopClientSecret = googleDesktopClientSecret
        self.microsoftClientID = microsoftClientID; self.dropboxAppKey = dropboxAppKey
        self.boxClientID = boxClientID; self.boxClientSecret = boxClientSecret
        self.pcloudClientID = pcloudClientID; self.pcloudClientSecret = pcloudClientSecret
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(googleClientID: try values.decodeIfPresent(String.self, forKey: .googleClientID) ?? "",
                  googleDesktopClientSecret: try values.decodeIfPresent(String.self, forKey: .googleDesktopClientSecret) ?? "",
                  microsoftClientID: try values.decodeIfPresent(String.self, forKey: .microsoftClientID) ?? "",
                  dropboxAppKey: try values.decodeIfPresent(String.self, forKey: .dropboxAppKey) ?? "",
                  boxClientID: try values.decodeIfPresent(String.self, forKey: .boxClientID) ?? "",
                  boxClientSecret: try values.decodeIfPresent(String.self, forKey: .boxClientSecret) ?? "",
                  pcloudClientID: try values.decodeIfPresent(String.self, forKey: .pcloudClientID) ?? "",
                  pcloudClientSecret: try values.decodeIfPresent(String.self, forKey: .pcloudClientSecret) ?? "")
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "OAuth", withExtension: "plist") else {
            throw CloudError.message(L("Esta versión aún no tiene habilitada la conexión de cuentas. Instala una versión configurada de iCloudy."))
        }
        return try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Returns the registered client for a cloud, or explains that this build has none. WebDAV has no client at all:
    /// the user brings their own server and password.
    func client(for cloud: Cloud) throws -> (id: String, secret: String) {
        guard !cloud.isSelfHosted else {
            throw CloudError.message(L("\(cloud.title) no usa OAuth: introduce la dirección del servidor y tus credenciales."))
        }
        let raw: String, secret: String
        switch cloud {
        case .google: raw = googleClientID; secret = googleDesktopClientSecret
        case .microsoft: raw = microsoftClientID; secret = ""
        case .dropbox: raw = dropboxAppKey; secret = ""
        case .box: raw = boxClientID; secret = boxClientSecret
        case .webdav, .ftp, .sftp, .volume, .mega, .o2: raw = ""; secret = ""
        case .pcloud: raw = pcloudClientID; secret = pcloudClientSecret
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid: Bool
        switch cloud {
        case .google: valid = id.hasSuffix(".apps.googleusercontent.com") && !id.contains(" ") && id.count > 30
        case .microsoft: valid = UUID(uuidString: id) != nil
        // Dropbox app keys and Box client ids are opaque alphanumeric strings.
        case .dropbox: valid = id.count >= 10 && id.allSatisfy { $0.isLetter || $0.isNumber }
        case .box: valid = id.count >= 20 && id.allSatisfy { $0.isLetter || $0.isNumber }
        case .webdav, .ftp, .sftp, .volume, .mega, .o2: valid = false
        // pCloud's client ids are short alphanumeric strings, and without PKCE the secret is required to sign in.
        case .pcloud: valid = id.count >= 8 && id.allSatisfy { $0.isLetter || $0.isNumber } && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard valid else {
            throw CloudError.message(L("La conexión con \(cloud.title) todavía no está habilitada en esta versión de iCloudy. No necesitas configurar nada en tu cuenta."))
        }
        return (id, secret)
    }
}

enum OAuthRequest {
    /// The port registered with both providers. Google accepts any loopback port; Microsoft requires this exact one.
    static let defaultPort: UInt16 = 53682
    static let redirectURI = redirectURI(port: defaultPort)
    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/callback" }
    /// True when the provider accepts a loopback redirect on a port other than the registered one, which lets a busy
    /// 53682 fall back to an ephemeral one. Google ignores the port of a loopback redirect and Box checks only
    /// scheme, host and path; Microsoft and Dropbox compare the whole address. See `docs/OAUTH.md`.
    static func toleratesAnyPort(_ cloud: Cloud) -> Bool { OAuthProviderSettings.settings(for: cloud)?.toleratesAnyPort ?? false }

    static func authorizationEndpoint(_ cloud: Cloud) -> String { OAuthProviderSettings.settings(for: cloud)?.authorizationEndpoint ?? "" }
    static func authorizationURL(cloud: Cloud, clientID: String, state: String, challenge: String, port: UInt16 = defaultPort) -> URL {
        var url = URLComponents(string: authorizationEndpoint(cloud))!
        var values = ["client_id": clientID, "redirect_uri": redirectURI(port: port), "response_type": "code", "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "prompt": "select_account"]
        values.removeValue(forKey: "prompt")
        values.merge(OAuthProviderSettings.settings(for: cloud)?.authorizationParameters ?? [:]) { _, providerValue in providerValue }
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    /// `toleratesMissingState` accepts a callback with no `state` at all, for a provider known to drop it; one that
    /// carries a `state` still has to carry exactly the expected one.
    static func callbackCode(target: String, expectedState: String, toleratesMissingState: Bool = false) throws -> String {
        guard target.hasPrefix("/callback?"), let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/callback" else {
            throw CloudError.message(L("Respuesta de inicio de sesión no válida."))
        }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let stateless = toleratesMissingState && states.isEmpty
        guard !expectedState.isEmpty, stateless || (states.count == 1 && states.first?.value == expectedState) else {
            throw CloudError.message(L("No se pudo verificar la respuesta de inicio de sesión."))
        }
        if items.contains(where: { $0.name == "error" }) {
            throw CloudError.message(L("No se ha autorizado el acceso. Puedes volver a intentarlo cuando quieras."))
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw CloudError.message(L("El servicio no completó el inicio de sesión."))
        }
        return code
    }
}
