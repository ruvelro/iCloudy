import Foundation

/// Public links on Nextcloud and ownCloud are OCS shares of type 3. Each one is separate, with its own expiry,
/// password and permissions, and the account's own shares can all be listed by leaving out the path.
extension WebDAVProvider {
    static func nextcloudLink(_ value: [String: Any]) -> PublicLink? {
        guard (value["share_type"] as? NSNumber)?.intValue == 3,
              let id = (value["id"] as? NSNumber)?.stringValue ?? value["id"] as? String,
              let path = value["path"] as? String else { return nil }
        let folder = (value["item_type"] as? String) == "folder"
        let name = webdavName(path)
        let url = (value["url"] as? String).flatMap(URL.init(string:))
        let file = CloudFile(id: webdavNormalize(path), name: name, mime: folder ? "application/vnd.google-apps.folder" : mime(forName: name),
                             size: nil, modified: nil, webURL: nil, isFolder: folder)
        let bits = (value["permissions"] as? NSNumber)?.intValue ?? 1
        // A protected link reports its password hashed, in `password` on recent servers and in `share_with` on older ones.
        let secret = [value["password"], value["share_with"]].contains { ($0 as? String).map { !$0.isEmpty } ?? false }
        let hidden = (value["hide_download"] as? NSNumber)?.intValue
        return PublicLink(handle: id, file: file, url: url, access: bits & 2 != 0 || bits & 4 != 0 ? .edit : .view,
                          expires: LinkDates.ocs(value["expiration"] as? String), hasPassword: secret,
                          allowsDownload: hidden.map { $0 == 0 }, location: webdavNormalize(path))
    }

    private func nextcloudLinks(path: String?) async throws -> [PublicLink] {
        guard account.flavor == "nextcloud" else { throw CloudError.message(L("Este servidor WebDAV no admite enlaces públicos desde iCloudy. Créalos en su interfaz web.")) }
        guard var components = URLComponents(url: try nextcloudSharesURL(), resolvingAgainstBaseURL: false) else {
            throw CloudError.message(L("No se pudo construir la dirección de compartición."))
        }
        components.queryItems = (components.queryItems ?? [])
            + (path.map { [URLQueryItem(name: "path", value: $0), URLQueryItem(name: "reshares", value: "true")] }
               ?? [URLQueryItem(name: "shared_with_me", value: "false")])
        let ocs = try await ocsRequest(components.url!, method: "GET")
        return (ocs["data"] as? [[String: Any]] ?? []).compactMap(Self.nextcloudLink)
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        try await nextcloudLinks(path: Self.webdavNormalize(file.id))
    }

    /// Always a new share: unlike the quick action, which reuses an existing link, this is the place to ask for one
    /// with different settings, and Nextcloud keeps each link apart.
    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        guard account.flavor == "nextcloud" else { throw CloudError.message(L("Este servidor WebDAV no admite enlaces públicos desde iCloudy. Créalos en su interfaz web.")) }
        var form = ["path": Self.webdavNormalize(file.id), "shareType": "3",
                    "permissions": String(Self.nextcloudPermissions(options.access == .edit ? .editor : .viewer, folder: file.isFolder))]
        if options.access == .edit, file.isFolder { form["publicUpload"] = "true" }
        if let expires = options.expires { form["expireDate"] = LinkDates.day(expires) }
        if let password = options.password, !password.isEmpty { form["password"] = password }
        let ocs = try await ocsRequest(try nextcloudSharesURL(), method: "POST", form: form)
        guard let created = (ocs["data"] as? [String: Any]).flatMap(Self.nextcloudLink) else {
            throw CloudError.message(L("El servidor no devolvió el enlace. Comprueba que compartir está habilitado."))
        }
        return created
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        var components = URLComponents(url: try nextcloudSharesURL(), resolvingAgainstBaseURL: false)!
        components.path += "/" + link.handle
        _ = try await ocsRequest(components.url!, method: "DELETE")
    }

    func allPublicLinks() async throws -> [PublicLink] {
        try await nextcloudLinks(path: nil)
    }
}
