import Foundation

/// Nextcloud's bin, which plain WebDAV does not have: deleting a file on Nextcloud moves it to
/// `/remote.php/dav/trashbin/{user}/trash`, named with a `.d{timestamp}` suffix. That collection is listed with its own
/// properties (the original name, where it was and when it went), an item is restored by moving it onto
/// `/restore/{name}` and deleted for good with DELETE, and deleting the whole collection empties the bin.
///
/// Binned items get ids of their own, `trash:/` and their path inside the bin, so nothing mistakes one for a live file.
extension WebDAVProvider {
    static let trashPrefix = "trash:/"
    var hasNextcloudTrash: Bool { account.flavor == "nextcloud" }
    static func isTrashed(_ id: String) -> Bool { id.hasPrefix(trashPrefix) }

    private func trashURL(user: String, _ path: String = "") throws -> URL {
        let encoded = path.split(separator: "/").map { Self.segment(String($0)) }.joined(separator: "/")
        return try nextcloudURL("/remote.php/dav/trashbin/\(Self.segment(user))/trash" + (encoded.isEmpty ? "" : "/" + encoded))
    }

    static let trashBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns"><d:prop>
    <nc:trashbin-filename/><nc:trashbin-original-location/><nc:trashbin-deletion-time/>
    <d:getcontentlength/><d:getcontenttype/><d:resourcetype/>
    </d:prop></d:propfind>
    """

    /// The bin, or a folder inside it. `parent` is the bin's own alias or the id of a binned folder.
    func nextcloudTrashList(parent: String) async throws -> [CloudFile] {
        let user = try await nextcloudUser()
        let inside = Self.isTrashed(parent) ? String(parent.dropFirst(Self.trashPrefix.count)) : ""
        let url = try trashURL(user: user, inside)
        let entries: [NextcloudDAVResponse]
        do { entries = try await nextcloudPropfind(url, depth: "1", body: Self.trashBody) }
        catch let error as ServiceError where [404, 405].contains(error.status) {
            throw CloudError.message(L("Este servidor no tiene activada la papelera de Nextcloud."))
        }
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return Self.sorted(entries.compactMap { entry -> CloudFile? in
            let path = URLComponents(string: entry.href)?.path ?? entry.href
            let normalized = path.hasSuffix("/") ? path : path + "/"
            guard normalized != root, normalized.lowercased().hasPrefix(root.lowercased()) else { return nil }
            let name = String(normalized.dropFirst(root.count).dropLast())
            let display = entry.properties["trashbin-filename"] ?? name.removingPercentEncoding ?? name
            let folder = entry.properties["getcontenttype"] == "httpd/unix-directory" || (entry.properties["getcontentlength"] == nil && entry.properties["getcontenttype"] == nil)
            let id = Self.trashPrefix + (inside.isEmpty ? "" : inside + "/") + (name.removingPercentEncoding ?? name)
            return CloudFile(id: id, name: display,
                             mime: folder ? "application/vnd.google-apps.folder" : (entry.properties["getcontenttype"] ?? Self.mime(forName: display)),
                             size: folder ? nil : entry.properties["getcontentlength"].flatMap(Int64.init),
                             modified: entry.properties["trashbin-deletion-time"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
                             webURL: nil, isFolder: folder)
        })
    }

    func nextcloudRestore(_ file: CloudFile) async throws {
        guard Self.isTrashed(file.id) else { throw CloudError.message(L("Ese elemento no está en la papelera.")) }
        let user = try await nextcloudUser()
        let inside = String(file.id.dropFirst(Self.trashPrefix.count))
        var request = try await request(try trashURL(user: user, inside), method: "MOVE")
        let leaf = inside.split(separator: "/").last.map(String.init) ?? inside
        request.setValue(try nextcloudURL("/remote.php/dav/trashbin/\(Self.segment(user))/restore/\(Self.segment(leaf))").absoluteString,
                         forHTTPHeaderField: "Destination")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }

    /// From the bin, DELETE removes the item. From the tree, deleting only bins it, so the copy that lands in the bin
    /// is found by where it came from (the most recent with that original location) and removed too.
    func nextcloudDeletePermanently(_ file: CloudFile) async throws {
        let user = try await nextcloudUser()
        if Self.isTrashed(file.id) {
            let (data, response) = try await webdavRequest(try trashURL(user: user, String(file.id.dropFirst(Self.trashPrefix.count))), method: "DELETE")
            try HTTP.validate(response, data: data)
            return
        }
        try await webdavDelete(file: file)
        let location = try nextcloudOriginalLocation(file.id)
        let entries = try await nextcloudPropfind(try trashURL(user: user), depth: "1", body: Self.trashBody)
        let match = entries.filter { $0.properties["trashbin-original-location"] == location }
            .max { (Double($0.properties["trashbin-deletion-time"] ?? "") ?? 0) < (Double($1.properties["trashbin-deletion-time"] ?? "") ?? 0) }
        guard let match, let name = (URLComponents(string: match.href)?.path ?? match.href).split(separator: "/").last.map(String.init) else {
            // The server had the bin switched off, so the DELETE was already final.
            return
        }
        let (data, response) = try await webdavRequest(try trashURL(user: user, name.removingPercentEncoding ?? name), method: "DELETE")
        try HTTP.validate(response, data: data)
    }

    func nextcloudEmptyTrash() async throws {
        let (data, response) = try await webdavRequest(try trashURL(user: try await nextcloudUser()), method: "DELETE")
        try HTTP.validate(response, data: data)
    }

    /// Where Nextcloud says a binned item came from: its path below the user's files, without a leading slash. The
    /// account may be connected to a subfolder, whose own path below the user's files comes first.
    func nextcloudOriginalLocation(_ id: String) throws -> String {
        let base = try webdavBase().path
        var prefix = ""
        if let range = base.range(of: "/remote.php/dav/files/") {
            prefix = base[range.upperBound...].split(separator: "/").dropFirst().joined(separator: "/")
        } else if let range = base.range(of: "/remote.php/webdav") {
            prefix = base[range.upperBound...].split(separator: "/").joined(separator: "/")
        }
        let relative = Self.webdavNormalize(id).split(separator: "/").joined(separator: "/")
        return [prefix, relative].filter { !$0.isEmpty }.joined(separator: "/")
    }
}
