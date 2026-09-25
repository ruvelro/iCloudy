import Foundation

/// Sharing with people on Dropbox. Files and folders are two different APIs: a file takes members directly, a
/// folder has to become a shared folder first, which Dropbox may do asynchronously.
extension DropboxProvider {
    private func dropboxAccess(_ value: [String: Any]?) -> (role: ShareRole?, owner: Bool) {
        let tag = (value?["access_type"] as? [String: Any])?[".tag"] as? String ?? (value?[".tag"] as? String) ?? "viewer"
        if tag == "owner" { return (nil, true) }
        return (tag == "editor" ? .editor : .viewer, false)
    }
    private func dropboxMembers(_ answer: [String: Any]) -> [SharePermission] {
        var result: [SharePermission] = []
        for entry in answer["users"] as? [[String: Any]] ?? [] {
            let user = entry["user"] as? [String: Any] ?? [:]
            let email = user["email"] as? String
            let access = dropboxAccess(entry)
            result.append(SharePermission(id: email ?? user["account_id"] as? String ?? UUID().uuidString, kind: .person,
                                          name: user["display_name"] as? String ?? email ?? "?", email: email,
                                          role: access.role, isOwner: access.owner, isInherited: entry["is_inherited"] as? Bool ?? false))
        }
        for entry in answer["groups"] as? [[String: Any]] ?? [] {
            let group = entry["group"] as? [String: Any] ?? [:]
            result.append(SharePermission(id: "group:" + (group["group_id"] as? String ?? ""), kind: .group,
                                          name: group["group_name"] as? String ?? L("Grupo"), email: nil, role: dropboxAccess(entry).role,
                                          isInherited: entry["is_inherited"] as? Bool ?? false))
        }
        for entry in answer["invitees"] as? [[String: Any]] ?? [] {
            let email = (entry["invitee"] as? [String: Any])?["email"] as? String ?? "?"
            result.append(SharePermission(id: email, kind: .pending, name: email, email: email, role: dropboxAccess(entry).role))
        }
        return result
    }
    /// The shared-folder id of a folder, creating the share when the folder has none yet.
    private func dropboxSharedFolderID(_ file: CloudFile, create: Bool) async throws -> String? {
        let metadata = try await dropboxRPC("files/get_metadata", ["path": file.id], repeatable: true)
        if let id = (metadata["sharing_info"] as? [String: Any])?["shared_folder_id"] as? String { return id }
        guard create else { return nil }
        var answer = try await dropboxRPC("sharing/share_folder", ["path": file.id])
        if answer[".tag"] as? String == "async_job_id", let job = answer["async_job_id"] as? String {
            for _ in 0..<30 {
                try await Task.sleep(for: .seconds(1))
                answer = try await dropboxRPC("sharing/check_share_job_status", ["async_job_id": job], repeatable: true)
                if answer[".tag"] as? String == "complete" { break }
                if answer[".tag"] as? String == "failed" { throw CloudError.message(L("Dropbox no pudo convertir la carpeta en compartida.")) }
            }
        }
        guard let id = answer["shared_folder_id"] as? String else { throw CloudError.message(L("Dropbox no devolvió la carpeta compartida.")) }
        return id
    }
    func permissions(for file: CloudFile) async throws -> [SharePermission] {
        if file.isFolder {
            guard let shared = try await dropboxSharedFolderID(file, create: false) else { return [] }
            return dropboxMembers(try await dropboxRPC("sharing/list_folder_members", ["shared_folder_id": shared], repeatable: true))
        }
        return dropboxMembers(try await dropboxRPC("sharing/list_file_members", ["file": file.id], repeatable: true))
    }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws {
        let member: [String: Any] = [".tag": "email", "email": recipient]
        let level = role == .editor ? "editor" : "viewer"
        if file.isFolder {
            let shared = try await dropboxSharedFolderID(file, create: true)!
            _ = try await dropboxRPC("sharing/add_folder_member", ["shared_folder_id": shared, "members": [["member": member, "access_level": level]], "quiet": false])
        } else {
            _ = try await dropboxRPC("sharing/add_file_member", ["file": file.id, "members": [member], "access_level": level, "quiet": false])
        }
    }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws {
        let member: [String: Any]
        if permission.kind == .group { member = [".tag": "dropbox_id", "dropbox_id": String(permission.id.dropFirst("group:".count))] }
        else { member = [".tag": "email", "email": permission.email ?? permission.id] }
        if file.isFolder {
            guard let shared = try await dropboxSharedFolderID(file, create: false) else { return }
            _ = try await dropboxRPC("sharing/remove_folder_member", ["shared_folder_id": shared, "member": member, "leave_a_copy": false])
        } else {
            _ = try await dropboxRPC("sharing/remove_file_member_2", ["file": file.id, "member": member])
        }
    }
}
