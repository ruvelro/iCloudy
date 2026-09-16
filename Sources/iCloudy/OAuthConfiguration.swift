import Foundation

/// Identifies the installed application, never a user's credentials.
struct OAuthConfiguration: Codable {
    var googleClientID: String
    var googleDesktopClientSecret: String
    var microsoftClientID: String

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "OAuth", withExtension: "plist") else {
            throw CloudError.message("Esta versión aún no tiene habilitada la conexión de cuentas. Instala una versión configurada de iCloudy.")
        }
        return try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func client(for cloud: Cloud) throws -> (id: String, secret: String) {
        let id = (cloud == .google ? googleClientID : microsoftClientID).trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = cloud == .google
            ? id.hasSuffix(".apps.googleusercontent.com") && !id.contains(" ") && id.count > 30
            : UUID(uuidString: id) != nil
        guard valid else {
            throw CloudError.message("La conexión con \(cloud.title) todavía no está habilitada en esta versión de iCloudy. No necesitas configurar nada en tu cuenta.")
        }
        return (id, cloud == .google ? googleDesktopClientSecret : "")
    }
}

enum OAuthRequest {
    static let redirectURI = "http://127.0.0.1:53682/callback"

    static func authorizationURL(cloud: Cloud, clientID: String, state: String, challenge: String) -> URL {
        var url = URLComponents(string: cloud == .google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        var values = ["client_id": clientID, "redirect_uri": redirectURI, "response_type": "code", "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "prompt": "select_account"]
        if cloud == .google {
            values["scope"] = "openid email profile https://www.googleapis.com/auth/drive"
            values["access_type"] = "offline"
            // Explicit consent ensures a refresh token, including when adding a previously used account.
            values["prompt"] = "consent select_account"
        } else {
            values["scope"] = "openid profile email offline_access User.Read Files.ReadWrite"
        }
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    static func callbackCode(target: String, expectedState: String) throws -> String {
        guard target.hasPrefix("/callback?"), let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/callback" else {
            throw CloudError.message("Respuesta de inicio de sesión no válida.")
        }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard !expectedState.isEmpty, states.count == 1, states.first?.value == expectedState else {
            throw CloudError.message("No se pudo verificar la respuesta de inicio de sesión.")
        }
        if items.contains(where: { $0.name == "error" }) {
            throw CloudError.message("No se ha autorizado el acceso. Puedes volver a intentarlo cuando quieras.")
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw CloudError.message("El servicio no completó el inicio de sesión.")
        }
        return code
    }
}
