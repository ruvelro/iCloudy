import Foundation

/// The transport for O2 Cloud. Funambol's SAPI answers every call with the same envelope: a `data` object when it
/// worked, an `error` object with a code when it did not, and HTTP 200 in both cases. So the status code says almost
/// nothing and the body says everything.
enum O2API {
    /// What the web client asks for in a listing, plus the two fields iCloudy needs to know how to address a file.
    static let mediaFields = ["name", "size", "modificationdate", "contenttype", "mediatype", "viewurl"]
    static let pageSize = 200

    struct Failure: Error, LocalizedError {
        let code: String
        let message: String?
        /// Some errors carry a replacement value, such as a rotated validation key.
        let data: String?
        var errorDescription: String? { message ?? L("O2 Cloud devolvió el error \(code).") }
        /// The session is gone rather than merely stale, so signing in again is the only way forward.
        var isExpiredSession: Bool { ["SEC-1001", "SEC-1002", "SEC-1004", "SEC-1005"].contains(code) }
    }

    static func url(host: String, path: String, action: String, state: O2Session?, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/sapi/" + path
        components.queryItems = [URLQueryItem(name: "action", value: action)] + query
            + (state.map { [URLQueryItem(name: "validationkey", value: $0.validationKey)] } ?? [])
        return components.url!
    }

    /// Reads the envelope. An error in the body is turned into a Failure even though the status was 200.
    static func payload(_ data: Data) throws -> [String: Any] {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudError.message(L("O2 Cloud devolvió una respuesta que no se entiende."))
        }
        if let error = body["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "?"
            throw Failure(code: code, message: friendly(code: code, server: error["message"] as? String),
                          data: error["data"] as? String)
        }
        return body["data"] as? [String: Any] ?? body
    }
    /// Turns the codes worth explaining into something a person can act on, and passes the rest through.
    private static func friendly(code: String, server: String?) -> String? {
        switch code {
        case "SEC-1001", "SEC-1002":
            return L("O2 Cloud rechazó el correo o la contraseña.")
        case "SEC-1003":
            return L("La sesión de O2 Cloud se ha renovado.")
        case "COM-1005":
            return L("O2 Cloud no admite esa operación.")
        case "PRO-1000", "PRO-1001":
            return L("La cuenta de O2 Cloud no tiene espacio suficiente.")
        case "MED-1006", "MED-1007":
            return L("Ese elemento ya no está en O2 Cloud.")
        default:
            return server
        }
    }

    static func call(_ path: String, action: String, query: [URLQueryItem], body: [String: Any]?, method: String?,
                     state: O2Session, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url(host: state.host, path: path, action: action, state: state, query: query))
        request.httpMethod = method ?? (body == nil ? "POST" : "POST")
        // The platform checks the referer on every call; without it the request is refused as cross-site.
        request.setValue("https://\(state.host)/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        if let header = state.cookieHeader { request.setValue(header, forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        guard http.statusCode != 401, http.statusCode != 403 else {
            throw Failure(code: "SEC-1002", message: L("O2 Cloud rechazó la sesión. Vuelve a iniciar sesión."), data: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.message(L("O2 Cloud devolvió HTTP \(http.statusCode)."))
        }
        return try payload(data)
    }

    /// What iCloudy keeps after a web sign-in: the key every later call carries, and the cookies that identify the
    /// session. There is no password to store, because iCloudy never sees one.
    struct StoredSession: Codable {
        var validationKey: String
        var cookies: [StoredCookie]
        struct StoredCookie: Codable {
            var name: String
            var value: String
            var domain: String
            var path: String
            var secure: Bool
        }
    }
    static func store(validationKey: String, cookies: [HTTPCookie]) -> String {
        let stored = StoredSession(validationKey: validationKey, cookies: cookies.map {
            StoredSession.StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure)
        })
        return (try? JSONEncoder().encode(stored)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    static func restore(_ text: String) -> (validationKey: String, cookies: [HTTPCookie])? {
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: Data(text.utf8)),
              !stored.validationKey.isEmpty else { return nil }
        let cookies = stored.cookies.compactMap { value -> HTTPCookie? in
            HTTPCookie(properties: [.name: value.name, .value: value.value, .domain: value.domain,
                                    .path: value.path.isEmpty ? "/" : value.path,
                                    .secure: value.secure ? "TRUE" : "FALSE"])
        }
        return (stored.validationKey, cookies)
    }

    /// Who the session belongs to, so the account has a name the person recognises.
    static func identity(host: String, state: O2Session, session: URLSession) async throws -> String {
        let profile = try await call("profile", action: "get", query: [], body: nil, method: "GET",
                                     state: state, session: session)
        for key in ["email", "username", "userid", "msisdn", "phonenumber"] {
            if let value = profile[key] as? String, !value.isEmpty { return value }
        }
        if let user = profile["user"] as? [String: Any] {
            for key in ["email", "username", "userid"] where (user[key] as? String)?.isEmpty == false {
                return user[key] as! String
            }
        }
        return host
    }

    /// Identifiers arrive as numbers in some responses and as strings in others.
    static func identifier(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    /// Dates arrive as `20240115T101530Z`, and occasionally as milliseconds since 1970.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String, !text.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let parsed = formatter.date(from: text) { return parsed }
            return CloudAPI.date(text)
        }
        if let number = value as? NSNumber {
            let milliseconds = number.doubleValue
            guard milliseconds > 0 else { return nil }
            return Date(timeIntervalSince1970: milliseconds > 100_000_000_000 ? milliseconds / 1000 : milliseconds)
        }
        return nil
    }
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
