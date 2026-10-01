import Foundation

/// Graph's driveItem versions: newest first, the current one at the top. They carry a size and an author but no
/// hashes, so a downloaded version is checked by its size alone. Restoring is one call on the server; deleting a
/// single version is not offered by Graph.
extension OneDriveProvider {
    static func graphVersion(_ value: [String: Any]) -> FileVersion? {
        guard let id = value["id"] as? String else { return nil }
        let by = (value["lastModifiedBy"] as? [String: Any])?["user"] as? [String: Any]
        return FileVersion(id: id, modified: date(value["lastModifiedDateTime"] as? String), size: (value["size"] as? NSNumber)?.int64Value,
                           author: by?["displayName"] as? String ?? by?["email"] as? String)
    }

    func versions(of file: CloudFile) async throws -> [FileVersion] {
        var result: [FileVersion] = []
        var next: URL? = URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/versions")!
        while let url = next {
            guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message(L("Paginación no válida.")) }
            let answer = try await json(url)
            result += (answer["value"] as? [[String: Any]] ?? []).compactMap(Self.graphVersion)
            next = (answer["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        // Graph lists the newest first; sorting by date keeps that true for a page boundary that says otherwise.
        result.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        if !result.isEmpty { result[0].isCurrent = true }
        return result
    }

    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/versions/\(Self.segment(version))/content")!)
    }

    /// Graph answers 204 and keeps what was current as a new version.
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/versions/\(Self.segment(version.id))/restoreVersion")!, method: "POST")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
