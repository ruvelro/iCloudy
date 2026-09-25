import Foundation

/// Sharing with people on Drive: one permission per grantee. The owner and any "anyone with the link" grant come
/// back in the same list, so the sheet shows the whole picture.
extension GoogleDriveProvider {
    static func googlePermission(_ value: [String: Any]) -> SharePermission? {
        guard let id = value["id"] as? String else { return nil }
        let type = value["type"] as? String ?? "user"
        let role = value["role"] as? String ?? ""
        let kind: SharePermission.Kind
        switch type { case "anyone": kind = .link; case "group": kind = .group; case "domain": kind = .domain; default: kind = .person }
        let name = value["displayName"] as? String ?? value["emailAddress"] as? String ?? value["domain"] as? String
            ?? (kind == .link ? L("Cualquiera con el enlace") : id)
        // Drive's "commenter" and "fileOrganizer" sit between the two levels; each is shown as the nearer one.
        let level: ShareRole? = role == "owner" ? nil : ["writer", "fileOrganizer", "organizer"].contains(role) ? .editor : .viewer
        return SharePermission(id: id, kind: kind, name: name, email: value["emailAddress"] as? String, role: level,
                               isOwner: role == "owner", isInherited: (value["permissionDetails"] as? [[String: Any]])?.first?["inherited"] as? Bool ?? false)
    }
    func permissions(for file: CloudFile) async throws -> [SharePermission] {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions")!
        url.queryItems = [URLQueryItem(name: "fields", value: "permissions(id,type,role,emailAddress,displayName,domain,permissionDetails),nextPageToken"),
                          URLQueryItem(name: "pageSize", value: "100")] + googleAllDrives
        var result: [SharePermission] = []
        var page: String?
        repeat {
            var paged = url
            if let page { paged.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
            let answer = try await json(paged.url!)
            result += (answer["permissions"] as? [[String: Any]] ?? []).compactMap(Self.googlePermission)
            page = answer["nextPageToken"] as? String
        } while page != nil
        return result
    }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions")!
        url.queryItems = [URLQueryItem(name: "sendNotificationEmail", value: "true"), URLQueryItem(name: "fields", value: "id")] + googleAllDrives
        do {
            _ = try await json(url.url!, method: "POST", body: ["type": "user", "role": role == .editor ? "writer" : "reader", "emailAddress": recipient])
        } catch let error as ServiceError where error.status == 400 && (error.detail ?? "").lowercased().contains("group") {
            // A Google Group is shared as a group, not as a user; Drive says which one it is.
            _ = try await json(url.url!, method: "POST", body: ["type": "group", "role": role == .editor ? "writer" : "reader", "emailAddress": recipient])
        }
    }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws {
        var request = try await request(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions/\(Self.segment(permission.id))"), method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
