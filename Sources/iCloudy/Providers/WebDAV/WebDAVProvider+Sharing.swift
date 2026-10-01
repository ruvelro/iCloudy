import Foundation

/// Sharing with people on Nextcloud and ownCloud, through the same OCS API that makes the public links. A name is
/// taken as a user of the server; anything with an "@" is sent as an e-mail share, which reaches people outside it.
extension WebDAVProvider {
    /// OCS permission bits: 1 read, 2 update, 4 create, 8 delete, 16 share.
    static func nextcloudPermissions(_ role: ShareRole, folder: Bool) -> Int {
        role == .viewer ? 1 : folder ? 15 : 3
    }
    static func nextcloudShare(_ value: [String: Any]) -> SharePermission? {
        guard let id = (value["id"] as? NSNumber)?.stringValue ?? value["id"] as? String else { return nil }
        let type = (value["share_type"] as? NSNumber)?.intValue ?? 0
        let bits = (value["permissions"] as? NSNumber)?.intValue ?? 1
        let role: ShareRole = bits & 2 != 0 || bits & 4 != 0 ? .editor : .viewer
        let with = value["share_with"] as? String
        let display = value["share_with_displayname"] as? String
        switch type {
        case 3: return SharePermission(id: id, kind: .link, name: L("Cualquiera con el enlace"), email: nil, role: role)
        case 1: return SharePermission(id: id, kind: .group, name: display ?? with ?? L("Grupo"), email: nil, role: role)
        case 4: return SharePermission(id: id, kind: .person, name: display ?? with ?? "?", email: with, role: role)
        default: return SharePermission(id: id, kind: .person, name: display ?? with ?? "?", email: with.flatMap { $0.contains("@") ? $0 : nil }, role: role)
        }
    }
    func ocsRequest(_ url: URL, method: String, form: [String: String]? = nil) async throws -> [String: Any] {
        var request = try await request(url, method: method)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = HTTP.form(form)
        }
        let (data, response) = try await send(&request)
        if let body = try? HTTP.json(data), let ocs = body["ocs"] as? [String: Any] {
            let status = ((ocs["meta"] as? [String: Any])?["statuscode"] as? NSNumber)?.intValue ?? 200
            if status >= 400 || !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200) {
                let message = (ocs["meta"] as? [String: Any])?["message"] as? String ?? ""
                throw CloudError.message(message.isEmpty ? L("El servidor rechazó la operación de compartición.") : L("El servidor rechazó la operación de compartición: ") + message)
            }
            return ocs
        }
        try HTTP.validate(response, data: data)
        throw CloudError.message(L("El servidor no respondió como Nextcloud u ownCloud. Comprueba que la API de compartición está habilitada."))
    }
    func permissions(for file: CloudFile) async throws -> [SharePermission] {
        guard account.flavor == "nextcloud" else { throw CloudError.message(L("Solo Nextcloud y ownCloud comparten con personas. Activa esa opción al conectar la cuenta.")) }
        guard var components = URLComponents(url: try nextcloudSharesURL(), resolvingAgainstBaseURL: false) else { throw CloudError.message(L("No se pudo construir la dirección de compartición.")) }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "path", value: Self.webdavNormalize(file.id)), URLQueryItem(name: "reshares", value: "true")]
        let ocs = try await ocsRequest(components.url!, method: "GET")
        return (ocs["data"] as? [[String: Any]] ?? []).compactMap(Self.nextcloudShare)
    }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws {
        guard account.flavor == "nextcloud" else { throw CloudError.message(L("Solo Nextcloud y ownCloud comparten con personas. Activa esa opción al conectar la cuenta.")) }
        let form = ["path": Self.webdavNormalize(file.id), "shareType": recipient.contains("@") ? "4" : "0",
                    "shareWith": recipient, "permissions": String(Self.nextcloudPermissions(role, folder: file.isFolder))]
        _ = try await ocsRequest(try nextcloudSharesURL(), method: "POST", form: form)
    }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws {
        var components = URLComponents(url: try nextcloudSharesURL(), resolvingAgainstBaseURL: false)!
        components.path += "/" + permission.id
        _ = try await ocsRequest(components.url!, method: "DELETE")
    }
}
