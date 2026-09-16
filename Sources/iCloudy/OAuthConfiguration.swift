import Foundation

/// Identifies the installed application, never a user's credentials.
struct OAuthConfiguration: Codable {
    var googleClientID: String
    var googleDesktopClientSecret: String
    var microsoftClientID: String
    var dropboxAppKey: String = ""
    var boxClientID: String = ""
    var boxClientSecret: String = ""

    /// Older builds shipped a plist with only the first three keys; missing ones simply mean "not configured yet".
    init(googleClientID: String = "", googleDesktopClientSecret: String = "", microsoftClientID: String = "",
         dropboxAppKey: String = "", boxClientID: String = "", boxClientSecret: String = "") {
        self.googleClientID = googleClientID; self.googleDesktopClientSecret = googleDesktopClientSecret
        self.microsoftClientID = microsoftClientID; self.dropboxAppKey = dropboxAppKey
        self.boxClientID = boxClientID; self.boxClientSecret = boxClientSecret
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(googleClientID: try values.decodeIfPresent(String.self, forKey: .googleClientID) ?? "",
                  googleDesktopClientSecret: try values.decodeIfPresent(String.self, forKey: .googleDesktopClientSecret) ?? "",
                  microsoftClientID: try values.decodeIfPresent(String.self, forKey: .microsoftClientID) ?? "",
                  dropboxAppKey: try values.decodeIfPresent(String.self, forKey: .dropboxAppKey) ?? "",
                  boxClientID: try values.decodeIfPresent(String.self, forKey: .boxClientID) ?? "",
                  boxClientSecret: try values.decodeIfPresent(String.self, forKey: .boxClientSecret) ?? "")
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
        case .webdav, .ftp: raw = ""; secret = ""
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid: Bool
        switch cloud {
        case .google: valid = id.hasSuffix(".apps.googleusercontent.com") && !id.contains(" ") && id.count > 30
        case .microsoft: valid = UUID(uuidString: id) != nil
        // Dropbox app keys and Box client ids are opaque alphanumeric strings.
        case .dropbox: valid = id.count >= 10 && id.allSatisfy { $0.isLetter || $0.isNumber }
        case .box: valid = id.count >= 20 && id.allSatisfy { $0.isLetter || $0.isNumber }
        case .webdav, .ftp: valid = false
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

    static func authorizationEndpoint(_ cloud: Cloud) -> String {
        switch cloud {
        case .google: return "https://accounts.google.com/o/oauth2/v2/auth"
        case .microsoft: return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        case .dropbox: return "https://www.dropbox.com/oauth2/authorize"
        case .box: return "https://account.box.com/api/oauth2/authorize"
        case .webdav, .ftp: return ""
        }
    }
    static func authorizationURL(cloud: Cloud, clientID: String, state: String, challenge: String, port: UInt16 = defaultPort) -> URL {
        var url = URLComponents(string: authorizationEndpoint(cloud))!
        var values = ["client_id": clientID, "redirect_uri": redirectURI(port: port), "response_type": "code", "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "prompt": "select_account"]
        if cloud == .google {
            values["scope"] = "openid email profile https://www.googleapis.com/auth/drive"
            values["access_type"] = "offline"
            // Explicit consent ensures a refresh token, including when adding a previously used account.
            values["prompt"] = "consent select_account"
        } else if cloud == .microsoft {
            values["scope"] = "openid profile email offline_access User.Read Files.ReadWrite"
        } else if cloud == .dropbox {
            // Without offline access Dropbox returns a short-lived token and no way to renew it.
            values["token_access_type"] = "offline"
            values["scope"] = "account_info.read files.metadata.read files.content.read files.content.write sharing.read sharing.write"
            values.removeValue(forKey: "prompt")
        } else if cloud == .box {
            // Box grants whatever the application is configured for; it rejects an explicit scope parameter it does not know.
            values.removeValue(forKey: "prompt")
        }
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    static func callbackCode(target: String, expectedState: String) throws -> String {
        guard target.hasPrefix("/callback?"), let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/callback" else {
            throw CloudError.message(L("Respuesta de inicio de sesión no válida."))
        }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard !expectedState.isEmpty, states.count == 1, states.first?.value == expectedState else {
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
