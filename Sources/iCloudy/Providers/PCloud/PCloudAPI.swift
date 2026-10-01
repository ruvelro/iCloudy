import Foundation

/// pCloud keeps each account in one of two data centres and answers for it only from that region's host:
/// `api.pcloud.com` in the United States and `eapi.pcloud.com` in Europe. The host is learnt at sign-in and kept with
/// the account, in `options["apiHost"]`.
enum PCloudRegion {
    static let unitedStates = "api.pcloud.com"
    static let europe = "eapi.pcloud.com"

    /// Only these two hosts ever see the token or the client secret, whatever a callback or a response names.
    static func host(named name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        return [unitedStates, europe].contains(name) ? name : nil
    }
    /// pCloud numbers its regions: 1 is the United States, 2 is Europe.
    static func host(locationID: Int?) -> String? {
        switch locationID {
        case 1: return unitedStates
        case 2: return europe
        default: return nil
        }
    }
    /// An account written before the host was kept, or carrying one that is not pCloud's, talks to the default host.
    static func host(for account: Account) -> String { host(named: account.options["apiHost"]) ?? unitedStates }
}

/// pCloud answers HTTP 200 whatever happened and puts the outcome in `result`: 0 for success, a four-digit code
/// otherwise, beside an English `error`. The first digit is the kind: 1xxx a malformed request, 2xxx a refusal about
/// the account or the item, 4xxx too many attempts, 5xxx the server's own failure.
///
/// Refusals are turned into the errors the rest of the app already understands: a `ServiceError` with an HTTP-like
/// status, so that "not found" reaches the download check as a 404 and a server failure reaches the queue as
/// retryable, and `CloudError.sessionExpired` for a token pCloud no longer honours.
enum PCloudError {
    /// The token is gone: pCloud issues no refresh token, so only a new sign-in brings the account back.
    static let sessionCodes: Set<Int> = [1000, 2000, 2094, 2095]

    static func result(of body: [String: Any]) -> Int? { (body["result"] as? NSNumber)?.intValue }

    /// The body itself when it reports success, or the error it describes.
    static func check(_ body: [String: Any]) throws -> [String: Any] {
        guard let code = result(of: body) else { throw CloudError.message(L("pCloud devolvió una respuesta sin resultado.")) }
        guard code != 0 else { return body }
        throw error(code: code, detail: body["error"] as? String)
    }

    static func error(code: Int, detail: String?) -> Error {
        if sessionCodes.contains(code) { return CloudError.sessionExpired(detail) }
        let tag = "pcloud.\(code)"
        switch code {
        case 2002: return ServiceError(status: 404, detail: L("Una de las carpetas de la ruta ya no existe en pCloud."), code: tag)
        case 2005: return ServiceError(status: 404, detail: L("La carpeta ya no existe en pCloud."), code: tag)
        case 2009: return ServiceError(status: 404, detail: L("El archivo ya no existe en pCloud."), code: tag)
        case 2001: return ServiceError(status: 400, detail: L("pCloud no admite ese nombre."), code: tag)
        case 2003: return ServiceError(status: 403, detail: L("pCloud no permite esta operación sobre este elemento."), code: tag)
        case 2004: return ServiceError(status: 409, detail: L("Ya existe un archivo o una carpeta con ese nombre en pCloud."), code: tag)
        case 2008: return ServiceError(status: 507, detail: L("No queda espacio en la cuenta de pCloud."), code: tag)
        case 2012: return ServiceError(status: 400, detail: L("pCloud no aceptó el código de autorización. Vuelve a intentar la conexión."), code: tag)
        // A block on this address, not on the account: it lifts by itself, so the queue waits and tries again.
        case 4000: return ServiceError(status: 429, detail: L("pCloud ha bloqueado por un tiempo las peticiones desde esta red por exceso de intentos. Se volverá a intentar en un minuto."), code: tag, retryAfter: 60)
        case 5000, 5001: return ServiceError(status: 503, detail: L("pCloud ha tenido un error interno. Se volverá a intentar."), code: tag)
        default:
            let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ServiceError(status: 400, detail: text.isEmpty ? L("pCloud rechazó la operación (código \(String(code))).")
                                                                : L("pCloud rechazó la operación (código \(String(code))): \(text)"), code: tag)
        }
    }
}

extension PCloudProvider {
    /// Folders are named "d" plus their folderid and files "f" plus their fileid, which is how pCloud's own `id`
    /// field spells them. Both numbers survive renames and moves, so an item keeps its identity in favourites,
    /// mirrors and the queue.
    nonisolated static func folderID(_ id: String) -> String {
        if id == Collection.files.rootID || id.isEmpty { return "0" }
        return id.hasPrefix("d") ? String(id.dropFirst()) : id
    }
    nonisolated static func numericID(_ id: String) -> String {
        id.hasPrefix("d") || id.hasPrefix("f") ? String(id.dropFirst()) : id
    }
    /// The parameter that names this item in a call: pCloud keeps separate methods, and ids, for files and folders.
    nonisolated static func itemParameter(_ file: CloudFile) -> [String: String] {
        file.isFolder ? ["folderid": folderID(file.id)] : ["fileid": numericID(file.id)]
    }

    /// Dates come as Unix seconds when `timeformat=timestamp` is asked for, and as RFC 1123 text otherwise.
    nonisolated static func pcloudDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }

    /// One entry of `metadata`. The listing's `hash` is pCloud's own change marker, not a digest of the content, so no
    /// checksum is taken from it; `checksumfile` gives the real one when it is needed.
    nonisolated static func pcloudFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String, !id.isEmpty else { return nil }
        let folder = (value["isfolder"] as? Bool) ?? id.hasPrefix("d")
        let type = value["contenttype"] as? String
        return CloudFile(id: id, name: name,
                         mime: folder ? "application/vnd.google-apps.folder" : (type?.isEmpty == false ? type! : mime(forName: name)),
                         size: folder ? nil : (value["size"] as? NSNumber)?.int64Value,
                         modified: pcloudDate(value["modified"]),
                         webURL: nil, isFolder: folder)
    }

    /// The digest `checksumfile` reports, in the strongest algorithm on offer: SHA-256 in Europe, SHA-1 in the
    /// United States, where MD5 is the only other one.
    nonisolated static func pcloudChecksum(_ body: [String: Any]) -> ContentHash? {
        if let value = body["sha256"] as? String, !value.isEmpty { return ContentHash(algorithm: .sha256, value: value) }
        if let value = body["sha1"] as? String, !value.isEmpty { return ContentHash(algorithm: .sha1, value: value) }
        if let value = body["md5"] as? String, !value.isEmpty { return ContentHash(algorithm: .md5, value: value) }
        return nil
    }
}
