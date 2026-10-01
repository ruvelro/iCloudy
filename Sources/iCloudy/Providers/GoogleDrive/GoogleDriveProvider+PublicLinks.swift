import Foundation

/// Public links on Drive are permissions of type "anyone": one per item, as a reader or a writer, revoked by
/// deleting the permission. The account-wide list is a search on the items' visibility.
extension GoogleDriveProvider {
    static let googleLinkFields = "id,type,role,expirationTime,allowFileDiscovery"

    /// The link an "anyone" permission makes, or nil for every other kind of grant.
    static func googleLink(_ value: [String: Any], file: CloudFile) -> PublicLink? {
        guard (value["type"] as? String) == "anyone" else { return nil }
        // Drive names the permission "anyoneWithLink"; a listing that leaves the id out still revokes with that name.
        let handle = value["id"] as? String ?? "anyoneWithLink"
        let writer = ["writer", "fileOrganizer", "organizer"].contains(value["role"] as? String ?? "")
        return PublicLink(handle: handle, file: file, url: file.webURL, access: writer ? .edit : .view,
                          expires: date(value["expirationTime"] as? String),
                          audience: (value["allowFileDiscovery"] as? Bool) == true ? L("Cualquiera puede encontrarlo en la web") : nil,
                          isInherited: (value["permissionDetails"] as? [[String: Any]])?.first?["inherited"] as? Bool ?? false)
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        var item = file
        if item.webURL == nil {
            let metadata = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=\(Self.googleFileFields)"))
            item = Self.googleFile(metadata) ?? file
        }
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions")!
        url.queryItems = [URLQueryItem(name: "fields", value: "permissions(\(Self.googleLinkFields),permissionDetails),nextPageToken"),
                          URLQueryItem(name: "pageSize", value: "100")] + googleAllDrives
        var result: [PublicLink] = []
        var page: String?
        repeat {
            var paged = url
            if let page { paged.queryItems?.append(URLQueryItem(name: "pageToken", value: page)) }
            let answer = try await json(paged.url!)
            result += (answer["permissions"] as? [[String: Any]] ?? []).compactMap { Self.googleLink($0, file: item) }
            page = answer["nextPageToken"] as? String
        } while page != nil
        return result
    }

    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions")!
        url.queryItems = [URLQueryItem(name: "fields", value: Self.googleLinkFields)] + googleAllDrives
        var body: [String: Any] = ["type": "anyone", "role": options.access == .edit ? "writer" : "reader"]
        if let expires = options.expires { body["expirationTime"] = LinkDates.iso(expires) }
        let answer: [String: Any]
        do { answer = try await json(url.url!, method: "POST", body: body) }
        catch let error as ServiceError where options.expires != nil && [400, 403].contains(error.status)
            && ((error.detail ?? "") + (error.code ?? "")).lowercased().contains("expir") {
            // Whether an "anyone" link may expire depends on the account and its administrator, and Drive only says
            // so by refusing. Nothing was created, so the person can choose again.
            throw CloudError.message(L("Google Drive no admite fecha de caducidad en enlaces para cualquiera en esta cuenta. Depende del tipo de cuenta y de la política de la organización. No se ha creado ningún enlace: créalo sin caducidad o compártelo con personas concretas."))
        }
        var item = file
        if item.webURL == nil {
            let metadata = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=webViewLink"))
            let link = (metadata["webViewLink"] as? String).flatMap(URL.init(string:))
            item = CloudFile(id: file.id, name: file.name, mime: file.mime, size: file.size, modified: file.modified, webURL: link,
                             isFolder: file.isFolder, checksum: file.checksum)
        }
        guard let link = Self.googleLink(answer.merging(["type": "anyone"]) { current, _ in current }, file: item), link.url != nil else {
            throw CloudError.message(L("Google no devolvió un enlace para este elemento."))
        }
        return link
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        var request = try await request(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(link.file.id))/permissions/\(Self.segment(link.handle))"), method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }

    /// Items whose visibility is "anyone with the link" or public on the web. A personal account looks at what it
    /// owns, because a link somebody else made is theirs to revoke; a shared drive looks at the drive.
    func allPublicLinks() async throws -> [PublicLink] {
        var clauses = ["(visibility = 'anyoneWithLink' or visibility = 'anyoneCanFind')", "trashed = false"]
        if account.driveID == nil { clauses.append("'me' in owners") }
        var result: [PublicLink] = []
        var page: String?
        repeat {
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            url.queryItems = [URLQueryItem(name: "q", value: clauses.joined(separator: " and ")),
                              URLQueryItem(name: "pageSize", value: "100"),
                              URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.googleFileFields),permissions(\(Self.googleLinkFields)))")]
                + (account.driveID == nil ? [URLQueryItem(name: "corpora", value: "user")] : googleDriveScope)
                + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let answer = try await json(url.url!)
            for value in answer["files"] as? [[String: Any]] ?? [] {
                guard let file = Self.googleFile(value) else { continue }
                // Shared drives do not list permissions inside a search, so the link is described by its default.
                let permissions = value["permissions"] as? [[String: Any]] ?? [["type": "anyone", "role": "reader"]]
                result += permissions.compactMap { Self.googleLink($0, file: file) }
            }
            page = answer["nextPageToken"] as? String
        } while page != nil
        return result
    }
}
