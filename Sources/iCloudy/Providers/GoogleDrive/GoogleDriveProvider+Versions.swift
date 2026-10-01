import Foundation

/// Drive's revisions. The list runs oldest to newest and its last entry is the content the file has today. Binary
/// files have their bytes under each revision; Google documents only have exports, through per-revision links.
extension GoogleDriveProvider {
    static let googleRevisionFields = "id,modifiedTime,size,md5Checksum,keepForever,lastModifyingUser(displayName,emailAddress)"

    /// One revision, or the list when `version` is nil, with the shared-drive flag `googleURL` adds where it applies.
    func googleRevisionURL(_ file: CloudFile, _ version: String? = nil, query: String = "") -> URL {
        googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/revisions" + (version.map { "/" + Self.segment($0) } ?? "") + query)
    }

    static func googleRevision(_ value: [String: Any]) -> FileVersion? {
        guard let id = value["id"] as? String else { return nil }
        let user = value["lastModifyingUser"] as? [String: Any]
        return FileVersion(id: id, modified: date(value["modifiedTime"] as? String), size: (value["size"] as? String).flatMap(Int64.init),
                           author: user?["displayName"] as? String ?? user?["emailAddress"] as? String,
                           checksum: (value["md5Checksum"] as? String).map { ContentHash(algorithm: .md5, value: $0) },
                           keepForever: value["keepForever"] as? Bool ?? false)
    }

    func versions(of file: CloudFile) async throws -> [FileVersion] {
        var result: [FileVersion] = []
        var page: String?
        repeat {
            var url = URLComponents(url: googleRevisionURL(file), resolvingAgainstBaseURL: false)!
            url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "fields", value: "nextPageToken,revisions(\(Self.googleRevisionFields))"),
                                                       URLQueryItem(name: "pageSize", value: "200")]
                + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let answer = try await json(url.url!)
            result += (answer["revisions"] as? [[String: Any]] ?? []).compactMap(Self.googleRevision)
            page = answer["nextPageToken"] as? String
        } while page != nil
        if !result.isEmpty { result[result.count - 1].isCurrent = true }
        return result.reversed()
    }

    /// `alt=media` for binary content. A Google document has none: its revision lists one export link per format,
    /// and those are only followed on Google's own hosts, where the token belongs.
    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        guard file.isGoogleDocument else { return try await request(googleRevisionURL(file, version, query: "?alt=media")) }
        guard let exportMime else { throw CloudError.message(L("Las versiones de un documento de Google solo se pueden exportar.")) }
        let revision = try await json(googleRevisionURL(file, version, query: "?fields=exportLinks"))
        guard let link = ((revision["exportLinks"] as? [String: Any])?[exportMime] as? String).flatMap(URL.init(string:)), Self.googleExportHost(link) else {
            throw CloudError.message(L("Google Drive no ofrece esta versión en ese formato."))
        }
        return try await request(link)
    }

    nonisolated static func googleExportHost(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "docs.google.com" || host == "www.googleapis.com"
    }

    /// Drive has no call that makes an old revision current again; uploading its bytes as new content does, and
    /// leaves what was current as one more revision.
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        try await restoreByUpload(version, of: file, parent: "root")
    }

    /// Drive refuses for Google documents and for the only revision left; its own explanation is passed on.
    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws {
        var request = try await request(googleRevisionURL(file, version.id), method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }
}
