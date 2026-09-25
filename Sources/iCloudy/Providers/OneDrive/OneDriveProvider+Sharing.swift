import Foundation

/// Sharing with people on OneDrive and SharePoint: Graph's `invite` sends the invitation and creates the permission;
/// links created elsewhere appear in the same list and can be revoked from here.
extension OneDriveProvider {
    static func graphPermission(_ value: [String: Any]) -> SharePermission? {
        guard let id = value["id"] as? String else { return nil }
        let roles = value["roles"] as? [String] ?? []
        let isOwner = roles.contains("owner")
        let level: ShareRole? = isOwner ? nil : roles.contains("write") ? .editor : .viewer
        let inherited = value["inheritedFrom"] != nil
        if let link = value["link"] as? [String: Any] {
            let scope = link["scope"] as? String ?? "anonymous"
            let name = scope == "anonymous" ? L("Cualquiera con el enlace") : scope == "organization" ? L("Personas de la organización") : L("Enlace")
            return SharePermission(id: id, kind: .link, name: name, email: nil, role: level, isOwner: false, isInherited: inherited)
        }
        // One grant may name several people; the first named identity labels the row.
        var identities = (value["grantedToIdentitiesV2"] as? [[String: Any]]) ?? []
        if let single = value["grantedToV2"] as? [String: Any] { identities.insert(single, at: 0) }
        if identities.isEmpty, let legacy = value["grantedTo"] as? [String: Any] { identities = [legacy] }
        let user = identities.first?["user"] as? [String: Any] ?? identities.first?["siteUser"] as? [String: Any]
        let group = identities.first?["group"] as? [String: Any]
        let name = user?["displayName"] as? String ?? group?["displayName"] as? String ?? user?["email"] as? String
            ?? (value["invitation"] as? [String: Any])?["email"] as? String ?? id
        let email = user?["email"] as? String ?? (value["invitation"] as? [String: Any])?["email"] as? String
        return SharePermission(id: id, kind: group != nil ? .group : .person, name: name, email: email, role: level, isOwner: isOwner, isInherited: inherited)
    }
    func permissions(for file: CloudFile) async throws -> [SharePermission] {
        var result: [SharePermission] = []
        var next: URL? = URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/permissions")!
        while let url = next {
            guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message(L("Paginación no válida.")) }
            let answer = try await json(url)
            result += (answer["value"] as? [[String: Any]] ?? []).compactMap(Self.graphPermission)
            next = (answer["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return result
    }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws {
        let body: [String: Any] = ["recipients": [["email": recipient]], "roles": [role == .editor ? "write" : "read"],
                                   "requireSignIn": true, "sendInvitation": true]
        let answer = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/invite")!, method: "POST", body: body)
        guard (answer["value"] as? [[String: Any]])?.isEmpty == false else {
            throw CloudError.message(L("OneDrive no creó el permiso. La organización puede restringir con quién se comparte."))
        }
    }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws {
        var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/permissions/\(Self.segment(permission.id))")!, method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
