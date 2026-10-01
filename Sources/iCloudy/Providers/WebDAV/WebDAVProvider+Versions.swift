import Foundation

/// Nextcloud's file versions, which live in a WebDAV collection of their own beside the files one:
/// `/remote.php/dav/versions/{user}/versions/{fileid}/{timestamp}`. They are found by the file's numeric id, not its
/// path, read with GET, restored by moving them onto `/restore/target` and deleted with DELETE. The collection lists
/// earlier versions only, so the current one is the file itself, put at the top. Plain WebDAV has nothing of this.
extension WebDAVProvider {
    /// The installation's root: everything before `/remote.php`, so subdirectory installs work too.
    func nextcloudRoot() throws -> URLComponents {
        var components = try webdavBase()
        let path = components.percentEncodedPath
        if let marker = path.range(of: "/remote.php") { components.percentEncodedPath = String(path[path.startIndex..<marker.lowerBound]) }
        else if path.hasSuffix("/") { components.percentEncodedPath = String(path.dropLast()) }
        components.query = nil
        return components
    }
    func nextcloudURL(_ encodedPath: String) throws -> URL {
        var components = try nextcloudRoot()
        components.percentEncodedPath += encodedPath
        guard let url = components.url else { throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor.")) }
        return url
    }

    /// The user id the versions collection is filed under. Usually right there in the address
    /// (`/remote.php/dav/files/ana`); with the legacy `/remote.php/webdav` the server is asked who it thinks this is.
    func nextcloudUser() async throws -> String {
        let path = try webdavBase().path
        if let range = path.range(of: "/remote.php/dav/files/") {
            let user = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            if !user.isEmpty { return user }
        }
        let body = #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>"#
        let entries = try await nextcloudPropfind(try nextcloudURL("/remote.php/dav/"), depth: "0", body: body)
        guard let principal = entries.first?.properties["current-user-principal"],
              let user = principal.split(separator: "/").last.map(String.init)?.removingPercentEncoding, !user.isEmpty else {
            throw CloudError.message(L("El servidor no dijo con qué usuario se ha iniciado sesión. Conecta la cuenta con la dirección /remote.php/dav/files/usuario."))
        }
        return user
    }

    /// The numeric id Nextcloud gives every file, which is what its versions are filed under.
    func nextcloudFileID(_ file: CloudFile) async throws -> String {
        let body = #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/></d:prop></d:propfind>"#
        guard let id = try await nextcloudPropfind(try webdavURL(file.id), depth: "0", body: body).first?.properties["fileid"], !id.isEmpty else {
            throw CloudError.message(L("El servidor no informó del identificador del archivo. Comprueba que es un Nextcloud."))
        }
        return id
    }

    func nextcloudVersionsURL(user: String, suffix: String = "") throws -> URL {
        try nextcloudURL("/remote.php/dav/versions/\(Self.segment(user))" + suffix)
    }

    func nextcloudPropfind(_ url: URL, depth: String, body: String) async throws -> [NextcloudDAVResponse] {
        let (data, response) = try await webdavRequest(url, method: "PROPFIND", depth: depth, body: body)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        // Nextcloud answers 404 under /versions when the app is disabled, and its 405 means there is no such collection.
        if [404, 405].contains(http.statusCode), url.path.contains("/remote.php/dav/versions/") {
            throw CloudError.message(L("Este servidor no tiene activada la aplicación de versiones de Nextcloud."))
        }
        guard http.statusCode == 207 else { try HTTP.validate(response, data: data); throw CloudError.message(L("El servidor respondió algo que no es un listado de WebDAV. Comprueba la dirección de la cuenta y vuelve a conectarla.")) }
        return NextcloudDAVResponse.parse(data)
    }

    static let nextcloudVersionsBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns"><d:prop>
    <d:getcontentlength/><d:getlastmodified/><d:getcontenttype/><nc:version-label/><nc:version-author/>
    </d:prop></d:propfind>
    """

    /// Each listed href ends in the version's timestamp. The id iCloudy keeps is "fileid/timestamp", so a download
    /// later needs no second request to find the file again.
    static func nextcloudVersions(_ entries: [NextcloudDAVResponse], fileID: String) -> [FileVersion] {
        entries.compactMap { entry in
            let parts = entry.href.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            guard parts.count >= 2, parts[parts.count - 2] == fileID, let stamp = parts.last, !stamp.isEmpty else { return nil }
            let modified = entry.properties["getlastmodified"].flatMap(NextcloudDAVResponse.rfc1123.date(from:))
                ?? TimeInterval(stamp).map(Date.init(timeIntervalSince1970:))
            return FileVersion(id: fileID + "/" + stamp, modified: modified, size: entry.properties["getcontentlength"].flatMap(Int64.init),
                               author: entry.properties["version-author"].flatMap { $0.isEmpty ? nil : $0 },
                               label: entry.properties["version-label"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func versions(of file: CloudFile) async throws -> [FileVersion] {
        guard account.flavor == "nextcloud" else { throw CloudError.message(account.versionsUnavailable) }
        let user = try await nextcloudUser(), fileID = try await nextcloudFileID(file)
        let entries = try await nextcloudPropfind(try nextcloudVersionsURL(user: user, suffix: "/versions/" + Self.segment(fileID)), depth: "1", body: Self.nextcloudVersionsBody)
        let current = FileVersion(id: fileID + "/current", modified: file.modified, size: file.size, isCurrent: true)
        // Newer servers also list the current content as a version of its own; the file describes it already.
        let earlier = Self.nextcloudVersions(entries, fileID: fileID).filter { version in
            guard let a = version.modified, let b = file.modified else { return true }
            return abs(a.timeIntervalSince(b)) >= 1
        }
        return [current] + earlier.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func nextcloudVersionURL(_ version: String) async throws -> URL {
        let parts = version.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CloudError.message(L("Esa versión ya no está disponible.")) }
        return try nextcloudVersionsURL(user: try await nextcloudUser(), suffix: "/versions/" + Self.segment(parts[0]) + "/" + Self.segment(parts[1]))
    }

    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        guard account.flavor == "nextcloud" else { throw CloudError.message(account.versionsUnavailable) }
        return try await request(try await nextcloudVersionURL(version))
    }

    /// Moving a version onto the restore target makes it current; Nextcloud keeps the replaced content as a version.
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        guard account.flavor == "nextcloud" else { throw CloudError.message(account.versionsUnavailable) }
        var request = try await request(try await nextcloudVersionURL(version.id), method: "MOVE")
        request.setValue(try nextcloudVersionsURL(user: try await nextcloudUser(), suffix: "/restore/target").absoluteString, forHTTPHeaderField: "Destination")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }

    /// Older servers answer 403 or 405: deleting a single version arrived in Nextcloud 26.
    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws {
        guard account.flavor == "nextcloud" else { throw CloudError.message(account.versionsUnavailable) }
        let (data, response) = try await webdavRequest(try await nextcloudVersionURL(version.id), method: "DELETE")
        do { try HTTP.validate(response, data: data) }
        catch let error as ServiceError where [403, 405, 501].contains(error.status) {
            throw CloudError.message(L("Este servidor no permite borrar versiones sueltas. Nextcloud lo admite desde la versión 26."))
        }
    }
}

/// One `<d:response>` of a PROPFIND against Nextcloud's own collections: its href and the plain-text properties of
/// the propstat blocks that came back 2xx. Unlike `WebDAVEntry`, it keeps whatever it is asked for, in any namespace,
/// and reads the href nested in `current-user-principal`.
struct NextcloudDAVResponse {
    let href: String
    let properties: [String: String]

    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func parse(_ data: Data) -> [NextcloudDAVResponse] {
        let parser = XMLParser(data: data)
        let delegate = Reader()
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.responses
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var responses: [NextcloudDAVResponse] = []
        private var stack: [String] = []
        private var text = ""
        private var href = ""
        private var properties: [String: String] = [:]
        private var pending: [String: String] = [:]
        private var status = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(element); text = ""
            switch element {
            case "response": href = ""; properties = [:]
            case "propstat": pending = [:]; status = ""
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            stack.removeLast()
            let parent = stack.last ?? ""
            switch element {
            case "href" where parent == "response": href = value
            case "href" where parent == "current-user-principal": pending["current-user-principal"] = value
            case "status" where parent == "propstat": status = value
            case "propstat": if status.isEmpty || status.contains(" 2") { properties.merge(pending) { _, new in new } }
            case "response": if !href.isEmpty { responses.append(NextcloudDAVResponse(href: href, properties: properties)) }
            default: if parent == "prop", !value.isEmpty { pending[element] = value }
            }
            text = ""
        }
    }
}
