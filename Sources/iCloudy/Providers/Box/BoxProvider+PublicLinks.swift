import Foundation

/// Box gives every item at most one shared link, kept in the item's own `shared_link` field: creating sets it,
/// changing settings rewrites it and revoking sets it to null. There is no listing of all of an account's links.
extension BoxProvider {
    static func boxLink(_ value: [String: Any]?, file: CloudFile) -> PublicLink? {
        guard let value, let url = (value["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let permissions = value["permissions"] as? [String: Any] ?? [:]
        let audience: String?
        switch value["effective_access"] as? String ?? value["access"] as? String ?? "open" {
        case "company": audience = L("Solo personas de la empresa")
        case "collaborators": audience = L("Solo colaboradores del elemento")
        default: audience = nil
        }
        return PublicLink(handle: file.id, file: file, url: url,
                          access: permissions["can_edit"] as? Bool == true ? .edit : .view,
                          expires: date(value["unshared_at"] as? String),
                          hasPassword: value["is_password_enabled"] as? Bool ?? false,
                          allowsDownload: permissions["can_download"] as? Bool, audience: audience)
    }

    private func boxLinkURL(_ file: CloudFile) -> URL {
        URL(string: "https://api.box.com/2.0/\(Self.boxRoute(file))/\(Self.segment(file.id))?fields=shared_link")!
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        let answer = try await json(boxLinkURL(file))
        return Self.boxLink(answer["shared_link"] as? [String: Any], file: file).map { [$0] } ?? []
    }

    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        var permissions: [String: Any] = ["can_download": options.allowDownload]
        if options.access == .edit { permissions["can_edit"] = true }
        var link: [String: Any] = ["access": "open", "permissions": permissions]
        if let expires = options.expires { link["unshared_at"] = LinkDates.iso(expires) }
        if let password = options.password, !password.isEmpty { link["password"] = password }
        let answer: [String: Any]
        do { answer = try await json(boxLinkURL(file), method: "PUT", body: ["shared_link": link]) }
        catch let error as ServiceError where [400, 403].contains(error.status) {
            // Box words its refusals well (a password too short, an expiry on a free account, open links disabled by
            // the administrator), so its message is kept and only framed.
            throw CloudError.message(L("Box no creó el enlace con esos ajustes: ") + (error.detail ?? "HTTP \(error.status)")
                                     + L(" La caducidad necesita una cuenta de pago, y la organización puede no permitir enlaces abiertos."))
        }
        guard let created = Self.boxLink(answer["shared_link"] as? [String: Any], file: file) else {
            throw CloudError.message(L("Box no devolvió el enlace. La organización puede no permitir enlaces públicos."))
        }
        return created
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        // JSONSerialization writes NSNull as null, which is how Box is told to drop the link.
        _ = try await json(boxLinkURL(link.file), method: "PUT", body: ["shared_link": NSNull()])
    }
}
