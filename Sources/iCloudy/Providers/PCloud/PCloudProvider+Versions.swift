import Foundation

/// pCloud keeps earlier versions of a file as revisions: `listrevisions` lists them, `getfilelink` reads one by its
/// `revisionid` and `revertrevision` makes it current again, keeping the replaced one as a revision. There is no call
/// to delete a single revision, so none is offered.
extension PCloudProvider {
    /// The current version has no revision id of its own; this stands for it.
    static let currentRevision = "current"

    func versions(of file: CloudFile) async throws -> [FileVersion] {
        let body = try await pcloud("listrevisions", ["fileid": Self.numericID(file.id), "timeformat": "timestamp"])
        let metadata = body["metadata"] as? [String: Any]
        let current = FileVersion(id: Self.currentRevision, modified: Self.pcloudDate(metadata?["modified"]) ?? file.modified,
                                  size: (metadata?["size"] as? NSNumber)?.int64Value ?? file.size, isCurrent: true)
        let earlier = (body["revisions"] as? [[String: Any]] ?? []).compactMap { value -> FileVersion? in
            guard let id = (value["revisionid"] as? NSNumber)?.stringValue else { return nil }
            return FileVersion(id: id, modified: Self.pcloudDate(value["created"]), size: (value["size"] as? NSNumber)?.int64Value)
        }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return [current] + earlier
    }

    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        try await pcloudContentRequest(for: file, revision: version == Self.currentRevision ? nil : version)
    }

    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        _ = try await pcloud("revertrevision", ["fileid": Self.numericID(file.id), "revisionid": version.id], write: true)
    }
}

/// Link management over the one account-wide list pCloud keeps: an item's links are the entries that point at it,
/// and revoking deletes the entry. pCloud links have no password and expire only on paid plans; neither is offered.
extension PCloudProvider {
    private func publicLink(_ link: PCloudPublicLink, file: CloudFile?) -> PublicLink? {
        guard let file else { return nil }
        return PublicLink(handle: link.id, file: file, url: link.url)
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        try await pcloudPublicLinks().filter { $0.itemID == file.id }.compactMap { publicLink($0, file: file) }
    }

    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        guard options.isPlain else { throw CloudError.message(L("pCloud solo crea enlaces de solo lectura, sin caducidad ni contraseña.")) }
        let url = try await pcloudPublicLink(for: file)
        let made = try await pcloudPublicLinks().first { $0.itemID == file.id && $0.url == url }
        return made.flatMap { publicLink($0, file: file) } ?? PublicLink(handle: "", file: file, url: url)
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        guard !link.handle.isEmpty else { throw CloudError.message(L("Vuelve a abrir la lista de enlaces para revocar este.")) }
        _ = try await pcloud("deletepublink", ["linkid": link.handle], write: true)
    }

    func allPublicLinks() async throws -> [PublicLink] {
        let body = try await pcloud("listpublinks", ["timeformat": "timestamp"])
        return (body["publinks"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = (value["linkid"] as? NSNumber)?.stringValue, let url = (value["link"] as? String).flatMap(URL.init(string:)),
                  let metadata = value["metadata"] as? [String: Any], let file = Self.pcloudFile(metadata) else { return nil }
            var link = PublicLink(handle: id, file: file, url: url)
            link.expires = Self.pcloudDate(value["expires"])
            return link
        }
    }
}
