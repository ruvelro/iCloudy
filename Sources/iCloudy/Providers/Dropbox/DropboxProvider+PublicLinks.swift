import Foundation

/// Shared links on Dropbox. A link is identified by its own URL, settings are changed in place, and the account's
/// links can all be listed. Expiry, passwords and blocking downloads are paid features: Dropbox refuses them on a
/// Basic account with a `settings_error`, which is turned into a sentence that says so.
extension DropboxProvider {
    static func dropboxLink(_ value: [String: Any]) -> PublicLink? {
        guard let address = value["url"] as? String, let url = URL(string: address) else { return nil }
        let name = value["name"] as? String ?? url.lastPathComponent
        let folder = (value[".tag"] as? String) == "folder"
        let path = value["path_lower"] as? String
        let file = CloudFile(id: path ?? "", name: name, mime: folder ? "application/vnd.google-apps.folder" : mime(forName: name),
                             size: (value["size"] as? NSNumber)?.int64Value, modified: date(value["server_modified"] as? String),
                             webURL: url, isFolder: folder)
        let permissions = value["link_permissions"] as? [String: Any] ?? [:]
        func tag(_ key: String) -> String? { (permissions[key] as? [String: Any])?[".tag"] as? String }
        let visibility = tag("resolved_visibility") ?? ""
        let audience: String?
        switch tag("effective_audience") ?? visibility {
        case "team", "team_only", "team_and_password": audience = L("Solo miembros del equipo")
        case "members", "shared_folder_only": audience = L("Solo miembros de la carpeta")
        case "no_one": audience = L("Desactivado: nadie puede abrirlo")
        default: audience = nil
        }
        return PublicLink(handle: address, file: file, url: url,
                          access: tag("link_access_level") == "editor" ? .edit : .view,
                          expires: date(value["expires"] as? String),
                          hasPassword: permissions["require_password"] as? Bool ?? ["password", "team_and_password"].contains(visibility),
                          allowsDownload: permissions["allow_download"] as? Bool,
                          audience: audience, location: value["path_display"] as? String ?? path)
    }

    /// Dropbox explains a refusal in `error_summary`, a path of tags. Each known one becomes something a person can act on.
    static func dropboxLinkFailure(_ error: ServiceError) -> CloudError {
        let summary = error.code ?? error.detail ?? ""
        if summary.contains("not_authorized") || summary.contains("access_denied") {
            return .message(L("Dropbox no permite esos ajustes en esta cuenta: la caducidad, la contraseña y desactivar la descarga necesitan un plan de pago. No se ha creado ningún enlace."))
        }
        if summary.contains("email_not_verified") {
            return .message(L("Dropbox exige verificar el correo de la cuenta antes de crear enlaces."))
        }
        if summary.contains("invalid_settings") || summary.contains("settings_error") {
            return .message(L("Dropbox rechazó los ajustes del enlace: ") + summary)
        }
        if summary.contains("shared_link_not_found") {
            return .message(L("Ese enlace ya no existe en Dropbox."))
        }
        return .message(L("Dropbox rechazó la operación con el enlace: ") + summary)
    }

    private func dropboxLinkSettings(_ options: PublicLinkOptions) -> [String: Any] {
        var settings: [String: Any] = ["audience": "public", "access": options.access == .edit ? "editor" : "viewer"]
        if let expires = options.expires { settings["expires"] = LinkDates.iso(expires) }
        if let password = options.password, !password.isEmpty { settings["require_password"] = true; settings["link_password"] = password }
        // Only sent when switching it off: it is a paid setting, and stating the default would be refused for nothing.
        if !options.allowDownload { settings["allow_download"] = false }
        return settings
    }

    private func dropboxListLinks(_ body: [String: Any]) async throws -> [PublicLink] {
        var result: [PublicLink] = []
        var answer = try await dropboxRPC("sharing/list_shared_links", body, repeatable: true)
        while true {
            result += (answer["links"] as? [[String: Any]] ?? []).compactMap(Self.dropboxLink)
            guard answer["has_more"] as? Bool == true, let cursor = answer["cursor"] as? String else { break }
            answer = try await dropboxRPC("sharing/list_shared_links", ["cursor": cursor], repeatable: true)
        }
        return result
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        try await dropboxListLinks(["path": file.id, "direct_only": true])
    }

    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        let settings = dropboxLinkSettings(options)
        do {
            let answer = try await dropboxRPC("sharing/create_shared_link_with_settings", ["path": file.id, "settings": settings])
            guard let link = Self.dropboxLink(answer) else { throw CloudError.message(L("Dropbox no devolvió el enlace. La cuenta puede tener restringido compartir.")) }
            return link
        } catch let error as ServiceError where error.status == 409 && (error.code ?? "").contains("shared_link_already_exists") {
            // One link per item and access level. The existing one keeps its address and takes the new settings.
            let level = options.access == .edit ? LinkAccess.edit : .view
            guard let existing = try await publicLinks(for: file).first(where: { $0.access == level }) else { throw Self.dropboxLinkFailure(error) }
            if options.isPlain { return existing }
            var body: [String: Any] = ["url": existing.handle, "settings": settings.filter { $0.key != "access" && $0.key != "audience" }]
            if options.expires == nil, existing.expires != nil { body["remove_expiration"] = true }
            do {
                let answer = try await dropboxRPC("sharing/modify_shared_link_settings", body)
                return Self.dropboxLink(answer) ?? existing
            } catch let error as ServiceError where error.status == 409 { throw Self.dropboxLinkFailure(error) }
        } catch let error as ServiceError where error.status == 409 {
            throw Self.dropboxLinkFailure(error)
        }
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        do { _ = try await dropboxRPC("sharing/revoke_shared_link", ["url": link.handle]) }
        catch let error as ServiceError where error.status == 409 { throw Self.dropboxLinkFailure(error) }
    }

    func allPublicLinks() async throws -> [PublicLink] {
        try await dropboxListLinks([:])
    }
}
