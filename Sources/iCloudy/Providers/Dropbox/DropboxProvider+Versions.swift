import Foundation

/// Dropbox revisions, addressed by `rev`. The list comes newest first with the current content at the top, each
/// entry a full file description with its own `content_hash`. Restoring is one call; single revisions cannot be
/// deleted.
extension DropboxProvider {
    static func dropboxRevision(_ value: [String: Any]) -> FileVersion? {
        guard let rev = value["rev"] as? String else { return nil }
        return FileVersion(id: rev, modified: date(value["server_modified"] as? String), size: (value["size"] as? NSNumber)?.int64Value,
                           checksum: (value["content_hash"] as? String).map { ContentHash(algorithm: .dropbox, value: $0) })
    }

    /// 100 is the most Dropbox hands out; its own history page stops well before that for most plans.
    func versions(of file: CloudFile) async throws -> [FileVersion] {
        let answer = try await dropboxRPC("files/list_revisions", ["path": dropboxPath(file.id), "mode": "path", "limit": 100], repeatable: true)
        var result = (answer["entries"] as? [[String: Any]] ?? []).compactMap(Self.dropboxRevision)
        result.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        // A deleted file has revisions too, but none of them is current.
        if !result.isEmpty, answer["is_deleted"] as? Bool != true { result[0].isCurrent = true }
        return result
    }

    /// The download endpoint takes a revision in place of a path, spelt "rev:…".
    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        var request = try await request(URL(string: "https://content.dropboxapi.com/2/files/download")!, method: "POST")
        request.setValue(Self.asciiJSON(["path": "rev:" + version]), forHTTPHeaderField: "Dropbox-API-Arg")
        return request
    }

    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        _ = try await dropboxRPC("files/restore", ["path": dropboxPath(file.id), "rev": version.id])
    }
}
