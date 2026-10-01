import Foundation

/// Box file versions. The versions endpoint lists only the earlier ones, so the current version is read from the
/// file itself and put at the top. Restoring promotes an old version to current; deleting sends one version to the
/// trash, which Box allows for any but the current. Free accounts keep no history and Box answers 403.
extension BoxProvider {
    static let boxVersionFields = "id,sha1,size,modified_at,modified_by,trashed_at"

    static func boxVersion(_ value: [String: Any]) -> FileVersion? {
        guard let id = value["id"] as? String else { return nil }
        let by = value["modified_by"] as? [String: Any]
        return FileVersion(id: id, modified: date(value["modified_at"] as? String), size: (value["size"] as? NSNumber)?.int64Value,
                           author: by?["name"] as? String ?? by?["login"] as? String,
                           checksum: (value["sha1"] as? String).flatMap { $0.isEmpty ? nil : ContentHash(algorithm: .sha1, value: $0) })
    }

    func versions(of file: CloudFile) async throws -> [FileVersion] {
        let current = try await json(URL(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))?fields=file_version,size,modified_at,modified_by,sha1")!)
        var earlier: [FileVersion] = []
        var offset = 0
        do {
            while true {
                let page = try await json(URL(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))/versions?fields=\(Self.boxVersionFields)&limit=1000&offset=\(offset)")!)
                let entries = page["entries"] as? [[String: Any]] ?? []
                // A version in Box's trash is listed with the date it went there; it is no longer one to offer.
                earlier += entries.filter { $0["trashed_at"] == nil || $0["trashed_at"] is NSNull }.compactMap(Self.boxVersion)
                offset += entries.count
                guard !entries.isEmpty, offset < (page["total_count"] as? NSNumber)?.intValue ?? 0 else { break }
            }
        } catch let error as ServiceError where error.status == 403 {
            throw CloudError.message(L("Esta cuenta de Box no guarda versiones anteriores. El historial de versiones depende del plan de Box."))
        }
        earlier.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        // The current version is described by the file: its own size, date and SHA-1 under the version's id.
        var head = (current["file_version"] as? [String: Any]).flatMap { version -> FileVersion? in
            var merged = current; merged["id"] = version["id"]
            if let sha1 = version["sha1"] as? String { merged["sha1"] = sha1 }
            return Self.boxVersion(merged)
        }
        head?.isCurrent = true
        return (head.map { [$0] } ?? []) + earlier.filter { $0.id != head?.id }
    }

    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        var url = URLComponents(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))/content")!
        url.queryItems = [URLQueryItem(name: "version", value: version)]
        return try await request(url.url!)
    }

    /// Promoting copies the old version on top as a new current one; the previous current stays in the list.
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        _ = try await json(URL(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))/versions/current")!, method: "POST",
                           body: ["type": "file_version", "id": version.id])
    }

    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws {
        var request = try await request(URL(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))/versions/\(Self.segment(version.id))")!, method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
