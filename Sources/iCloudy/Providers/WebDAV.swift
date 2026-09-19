import Foundation

/// Plain WebDAV, which also covers Nextcloud, ownCloud and most home NAS boxes. Items are addressed by their path
/// under the configured base URL, and "root" is that base. There is no OAuth, no search and no recycle bin here.
extension CloudAPI {
    func webdavBase() throws -> URLComponents {
        guard let server = account.serverURL, let components = URLComponents(string: server), components.host != nil else {
            throw CloudError.message(L("Esta cuenta WebDAV no tiene una dirección de servidor válida. Vuelve a conectarla."))
        }
        return components
    }
    nonisolated static func webdavNormalize(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }
    func webdavURL(_ id: String) throws -> URL {
        var components = try webdavBase()
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let relative = id == "root" ? "/" : Self.webdavNormalize(id)
        let encoded = relative.split(separator: "/").map { Self.segment(String($0)) }.joined(separator: "/")
        components.percentEncodedPath = encoded.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + encoded
        guard let url = components.url else { throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor.")) }
        return url
    }
    /// Path prefix the server adds to every href, stripped so ids stay relative to the account's base.
    private func webdavBasePath() throws -> String {
        let path = try webdavBase().path
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed
    }

    func webdavRequest(_ url: URL, method: String, depth: String? = nil, body: String? = nil) async throws -> (Data, URLResponse) {
        var request = try await request(url, method: method)
        if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await send(&request)
        return (data, response)
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop>
    <d:displayname/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/><d:resourcetype/>
    <d:quota-available-bytes/><d:quota-used-bytes/>
    </d:prop></d:propfind>
    """

    func webdavPropfind(_ id: String, depth: String) async throws -> [WebDAVEntry] {
        let (data, response) = try await webdavRequest(try webdavURL(id), method: "PROPFIND", depth: depth, body: Self.propfindBody)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        guard http.statusCode == 207 || (200..<300).contains(http.statusCode) else { try HTTP.validate(response, data: data); return [] }
        let entries = WebDAVEntry.parse(data, basePath: try webdavBasePath())
        // A proxy or a misread address answers a PROPFIND with the site's own web page, and a 200. Reading that as an
        // empty folder left the account showing nothing, for ever, with no error to explain it.
        guard http.statusCode == 207 || !entries.isEmpty else {
            throw CloudError.message(L("El servidor respondió algo que no es un listado de WebDAV. Comprueba la dirección de la cuenta y vuelve a conectarla."))
        }
        return entries
    }

    func webdavList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        let requested = Self.webdavNormalize(parent == "root" ? "/" : parent)
        let files = try await webdavPropfind(parent, depth: "1")
            .filter { $0.path != requested }        // the first entry is the folder itself
            .map(\.file)
        return Self.sorted(files)
    }

    func webdavCreateFolder(name: String, parent: String) async throws -> String {
        let parentPath = Self.webdavNormalize(parent == "root" ? "/" : parent)
        let path = (parentPath == "/" ? "" : parentPath) + "/" + name
        let (data, response) = try await webdavRequest(try webdavURL(path), method: "MKCOL")
        try HTTP.validate(response, data: data)
        return path
    }

    /// MOVE and COPY carry the target in a header, as an absolute URL on the same server.
    private func webdavRelocate(_ file: CloudFile, to path: String, method: String) async throws {
        var request = try await request(try webdavURL(file.id), method: method)
        request.setValue(try webdavURL(path).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite") // never clobber something already there
        var mutable = request
        let (data, response) = try await send(&mutable)
        try HTTP.validate(response, data: data)
    }
    /// What the item is called on the server: the last segment of its path. `file.name` is the `displayname`, which
    /// some servers report with different capitalisation or a title of their own, and building a destination from it
    /// renamed the item as a side effect of moving it.
    nonisolated static func webdavName(_ id: String) -> String {
        webdavNormalize(id).split(separator: "/").last.map(String.init) ?? id
    }
    func webdavRename(file: CloudFile, name: String) async throws {
        let parent = Self.dropboxParent(Self.webdavNormalize(file.id))
        try await webdavRelocate(file, to: (parent == "" ? "" : parent) + "/" + name, method: "MOVE")
    }
    func webdavMove(file: CloudFile, to destination: String) async throws {
        let parent = Self.webdavNormalize(destination == "root" ? "/" : destination)
        try await webdavRelocate(file, to: (parent == "/" ? "" : parent) + "/" + Self.webdavName(file.id), method: "MOVE")
    }
    func webdavCopy(file: CloudFile, to destination: String) async throws {
        let parent = Self.webdavNormalize(destination == "root" ? "/" : destination)
        try await webdavRelocate(file, to: (parent == "/" ? "" : parent) + "/" + Self.webdavName(file.id), method: "COPY")
    }
    /// WebDAV has no trash of its own: DELETE is final. The confirmation dialog says so for these accounts.
    func webdavDelete(file: CloudFile) async throws {
        let (data, response) = try await webdavRequest(try webdavURL(file.id), method: "DELETE")
        try HTTP.validate(response, data: data)
    }
    func webdavQuota() async throws -> StorageQuota {
        guard let root = try await webdavPropfind("root", depth: "0").first, let used = root.quotaUsed else {
            throw CloudError.message(L("El proveedor no ha informado del espacio utilizado."))
        }
        // The standard reports what is left, not the capacity; the total is the sum of both.
        return StorageQuota(used: used, total: root.quotaAvailable.map { used + $0 })
    }
    /// Breadcrumbs come straight from the path; every ancestor is a collection on the same server.
    func webdavTrail(id: String) -> [CloudFile] {
        // The root has no crumbs of its own; reading the alias as a path invented a folder called "root".
        guard id != "root" else { return [] }
        let parts = Self.webdavNormalize(id).split(separator: "/").map(String.init)
        return parts.indices.map { index in
            let path = "/" + parts[0...index].joined(separator: "/")
            return CloudFile(id: path, name: parts[index], mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        }
    }

    /// Nextcloud and ownCloud share files through their own OCS API, which lives beside the WebDAV path rather than
    /// inside it: everything before `/remote.php` is the installation's root, so subdirectory installs work too.
    func nextcloudSharesURL() throws -> URL {
        var components = try webdavBase()
        let path = components.path
        if let marker = path.range(of: "/remote.php") { components.path = String(path[path.startIndex..<marker.lowerBound]) }
        components.path += "/ocs/v2.php/apps/files_sharing/api/v1/shares"
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw CloudError.message(L("No se pudo construir la dirección de compartición.")) }
        return url
    }

    /// The public link this item already has, if any. Nextcloud happily makes a second one every time it is asked,
    /// and each has to be revoked separately, so asking twice for the same file left a trail of live links.
    private func nextcloudExistingLink(for file: CloudFile) async throws -> URL? {
        guard var components = URLComponents(url: try nextcloudSharesURL(), resolvingAgainstBaseURL: false) else { return nil }
        let existing = components.queryItems ?? []
        components.queryItems = existing + [URLQueryItem(name: "path", value: Self.webdavNormalize(file.id))]
        guard let url = components.url else { return nil }
        var request = try await request(url, method: "GET")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let (data, response) = try await send(&request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? HTTP.json(data), let ocs = body["ocs"] as? [String: Any],
              let shares = ocs["data"] as? [[String: Any]] else { return nil }
        // Share type 3 is the public link; the rest are shares with a person or a group.
        return shares.first { ($0["share_type"] as? NSNumber)?.intValue == 3 }
            .flatMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
    }

    func nextcloudPublicLink(for file: CloudFile) async throws -> URL {
        if let existing = try? await nextcloudExistingLink(for: file) { return existing }
        var request = try await request(try nextcloudSharesURL(), method: "POST")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // shareType 3 is a public link; permission 1 is read only.
        request.httpBody = HTTP.form(["path": Self.webdavNormalize(file.id), "shareType": "3", "permissions": "1"])
        var mutable = request
        let (data, response) = try await send(&mutable)
        // OCS puts its own refusals in the body, and only sometimes in the status. Reading the body first keeps the
        // server's explanation, such as a policy that demands a password, instead of a bare HTTP code.
        if let body = try? HTTP.json(data), let ocs = body["ocs"] as? [String: Any] {
            if let payload = ocs["data"] as? [String: Any], let link = (payload["url"] as? String).flatMap(URL.init(string:)) { return link }
            if let message = (ocs["meta"] as? [String: Any])?["message"] as? String, !message.isEmpty {
                throw CloudError.message(L("El servidor rechazó crear el enlace: \(message)"))
            }
        }
        try HTTP.validate(response, data: data)
        throw CloudError.message(L("El servidor no devolvió el enlace. Comprueba que compartir está habilitado."))
    }

    /// WebDAV has no resumable protocol: a PUT either lands whole or is repeated. The file is streamed from disk.
    func webdavUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                      save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let parentPath = Self.webdavNormalize(parent == "root" ? "/" : parent)
        let path = replacing ?? ((parentPath == "/" ? "" : parentPath) + "/" + name)
        var request = try await request(try webdavURL(path), method: "PUT")
        request.timeoutInterval = 3600
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if replacing == nil { request.setValue("*", forHTTPHeaderField: "If-None-Match") } // do not overwrite by accident
        let total = cursor.total
        let delegate = UploadProgress { sent in Task { @MainActor in progress(min(sent, total), total) } }
        cursor.offset = 0; try save(cursor)
        let (data, response) = try await session.upload(for: request, fromFile: local, delegate: delegate)
        try HTTP.validate(response, data: data)
        cursor.offset = total; cursor.complete = true; try save(cursor); progress(total, total)
        // Plain WebDAV reports no checksum, so the upload cannot be verified beyond the server accepting it.
        return UploadReceipt(remoteID: path, verification: .unavailable)
    }
}

/// One `<d:response>` of a PROPFIND multistatus document.
struct WebDAVEntry {
    let path: String
    let file: CloudFile
    let quotaUsed: Int64?
    let quotaAvailable: Int64?

    static func parse(_ data: Data, basePath: String) -> [WebDAVEntry] {
        let parser = XMLParser(data: data)
        let delegate = WebDAVParserDelegate(basePath: basePath)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.entries
    }
}

/// Minimal multistatus reader: it only looks at the handful of properties iCloudy asks for. Servers answer with one
/// `propstat` block per status, so the properties of a 404 block are dropped without discarding the whole item.
final class WebDAVParserDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [WebDAVEntry] = []
    private let basePath: String
    private var text = ""
    private var href = ""
    /// Properties accepted so far for the current response, and the ones of the propstat block being read.
    private var properties: [String: String] = [:]
    private var pending: [String: String] = [:]
    private var isCollection = false
    private var pendingCollection = false
    private var propstatStatus = ""

    init(basePath: String) { self.basePath = basePath }

    private static let known: Set<String> = ["displayname", "getcontentlength", "getlastmodified", "getcontenttype", "quota-used-bytes", "quota-available-bytes"]
    private static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "response": href = ""; properties = [:]; isCollection = false; propstatStatus = ""
        case "propstat": pending = [:]; pendingCollection = false; propstatStatus = ""
        case "collection": pendingCollection = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href": href = value
        case "status": propstatStatus = value
        case "propstat":
            // "HTTP/1.1 200 OK" and friends; anything else means those properties are not available.
            let accepted = propstatStatus.isEmpty || propstatStatus.contains(" 2")
            if accepted {
                properties.merge(pending) { _, new in new }
                isCollection = isCollection || pendingCollection
            }
        case "response": finishResponse()
        default:
            if Self.known.contains(element), !value.isEmpty { pending[element] = value }
        }
        text = ""
    }
    private func finishResponse() {
        guard !href.isEmpty else { return }
        // An href may be absolute or path-only, and is always percent-encoded.
        let rawPath = URLComponents(string: href)?.path ?? href.removingPercentEncoding ?? href
        var path = rawPath
        // Some servers, and most reverse proxies, echo the base with different capitalisation. Leaving it in made
        // every id carry the prefix twice once it was turned back into a URL.
        if !basePath.isEmpty, path.lowercased().hasPrefix(basePath.lowercased()) { path = String(path.dropFirst(basePath.count)) }
        path = CloudAPI.webdavNormalize(path.isEmpty ? "/" : path)
        let name = properties["displayname"] ?? path.split(separator: "/").last.map(String.init) ?? "/"
        let file = CloudFile(id: path, name: name,
                             mime: isCollection ? "application/vnd.google-apps.folder" : (properties["getcontenttype"] ?? CloudAPI.mime(forName: name)),
                             size: isCollection ? nil : properties["getcontentlength"].flatMap(Int64.init),
                             modified: properties["getlastmodified"].flatMap(Self.rfc1123.date(from:)),
                             webURL: nil, isFolder: isCollection)
        entries.append(WebDAVEntry(path: path, file: file,
                                   quotaUsed: properties["quota-used-bytes"].flatMap(Int64.init),
                                   quotaAvailable: properties["quota-available-bytes"].flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }))
    }
}

/// Reports how many bytes of a streamed upload have left the Mac.
final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: (Int64) -> Void
    init(report: @escaping (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}
