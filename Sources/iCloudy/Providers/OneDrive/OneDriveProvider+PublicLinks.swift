import Foundation

/// Public links on OneDrive and SharePoint: `createLink` makes them, they come back as permissions with a `link`
/// facet, and deleting the permission revokes them. Graph has no call that lists every link of a drive.
extension OneDriveProvider {
    /// The link a permission carries, or nil for a grant to a person.
    static func graphLink(_ value: [String: Any], file: CloudFile) -> PublicLink? {
        guard let id = value["id"] as? String, let link = value["link"] as? [String: Any] else { return nil }
        let roles = value["roles"] as? [String] ?? []
        let audience: String?
        switch link["scope"] as? String ?? "anonymous" {
        case "anonymous": audience = nil
        case "organization": audience = L("Solo personas de la organización")
        default: audience = L("Solo personas concretas")
        }
        return PublicLink(handle: id, file: file, url: (link["webUrl"] as? String).flatMap(URL.init(string:)),
                          access: roles.contains("write") || (link["type"] as? String) == "edit" ? .edit : .view,
                          expires: date(value["expirationDateTime"] as? String),
                          hasPassword: value["hasPassword"] as? Bool ?? false,
                          allowsDownload: (link["preventsDownload"] as? Bool).map { !$0 },
                          audience: audience, isInherited: value["inheritedFrom"] != nil)
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        var result: [PublicLink] = []
        var next: URL? = URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/permissions")!
        while let url = next {
            guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message(L("Paginación no válida.")) }
            let answer = try await json(url)
            result += (answer["value"] as? [[String: Any]] ?? []).compactMap { Self.graphLink($0, file: file) }
            next = (answer["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return result
    }

    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        var body: [String: Any] = ["type": options.access == .edit ? "edit" : "view", "scope": "anonymous"]
        if let expires = options.expires { body["expirationDateTime"] = LinkDates.iso(expires) }
        if let password = options.password, !password.isEmpty { body["password"] = password }
        let answer: [String: Any]
        do { answer = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/createLink")!, method: "POST", body: body) }
        catch let error as ServiceError where !options.isPlain && [400, 403, 422].contains(error.status) {
            throw CloudError.message(L("OneDrive no creó el enlace con esas opciones: ") + (error.detail ?? "HTTP \(error.status)")
                                     + L(" En OneDrive personal la caducidad y la contraseña necesitan Microsoft 365; en una organización, las decide el administrador."))
        }
        guard let link = Self.graphLink(answer, file: file), link.url != nil else {
            throw CloudError.message(L("OneDrive no devolvió el enlace. La organización puede no permitir enlaces anónimos."))
        }
        // When a link of the same kind already exists, Graph hands that one back and ignores the new settings. The
        // link is real, but it is not the one that was asked for, and saying nothing would leave it open for longer.
        if (options.expires != nil && link.expires == nil) || (!(options.password ?? "").isEmpty && !link.hasPassword) {
            throw CloudError.message(L("OneDrive devolvió un enlace que ya existía, sin la caducidad o la contraseña pedidas. Revoca ese enlace y vuelve a crearlo."))
        }
        return link
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(link.file.id))/permissions/\(Self.segment(link.handle))")!, method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
