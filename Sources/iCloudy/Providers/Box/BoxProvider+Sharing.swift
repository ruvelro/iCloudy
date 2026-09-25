import Foundation

/// Sharing with people on Box: a collaboration per person, on the file or the folder itself. Box notifies the person
/// and lists pending invitations beside accepted ones.
extension BoxProvider {
    static func boxCollaboration(_ value: [String: Any]) -> SharePermission? {
        guard let id = value["id"] as? String else { return nil }
        let role = value["role"] as? String ?? "viewer"
        let who = value["accessible_by"] as? [String: Any]
        let name = who?["name"] as? String ?? who?["login"] as? String ?? (value["invite_email"] as? String) ?? id
        let email = who?["login"] as? String ?? value["invite_email"] as? String
        let isOwner = role == "owner"
        // Box's ladder: viewer, previewer, uploader, previewer uploader, viewer uploader, co-owner, editor.
        let level: ShareRole? = isOwner ? nil : ["editor", "co-owner", "viewer uploader", "uploader", "previewer uploader"].contains(role) ? .editor : .viewer
        let pending = (value["status"] as? String) == "pending"
        return SharePermission(id: id, kind: pending ? .pending : (who?["type"] as? String) == "group" ? .group : .person,
                               name: name, email: email, role: level, isOwner: isOwner)
    }
    func permissions(for file: CloudFile) async throws -> [SharePermission] {
        var url = URLComponents(string: "https://api.box.com/2.0/\(Self.boxRoute(file))/\(Self.segment(file.id))/collaborations")!
        url.queryItems = [URLQueryItem(name: "fields", value: "id,role,status,accessible_by,invite_email"), URLQueryItem(name: "limit", value: "1000")]
        let answer = try await json(url.url!)
        return (answer["entries"] as? [[String: Any]] ?? []).compactMap(Self.boxCollaboration)
    }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws {
        let body: [String: Any] = ["item": ["type": file.isFolder ? "folder" : "file", "id": file.id],
                                   "accessible_by": ["type": "user", "login": recipient],
                                   "role": role == .editor ? "editor" : "viewer"]
        _ = try await json(URL(string: "https://api.box.com/2.0/collaborations?notify=true")!, method: "POST", body: body)
    }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws {
        var request = try await request(URL(string: "https://api.box.com/2.0/collaborations/\(Self.segment(permission.id))")!, method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
