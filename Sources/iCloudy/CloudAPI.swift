import Foundation

@MainActor
final class CloudAPI {
    let account: Account
    let session: URLSession
    let demo: DemoStore?
    private let tokenProvider: (() async throws -> String)?
    private let credentials: CredentialStore
    private var refreshTask: Task<String, Error>?
    private var invalidated = false
    /// Set once the provider rejects the stored credential. Only reconnecting the account, which replaces this client, clears it.
    private(set) var sessionExpired = false
    var sessionDidExpire: (() -> Void)?
    /// Keychain reads are synchronous and comparatively slow; the credential is read once per client and kept current here.
    private var cachedCredential: Credential?
    func invalidate() {
        invalidated = true
        refreshTask?.cancel()
    }
    init(account: Account, session: URLSession = .shared, demo: DemoStore? = nil, tokenProvider: (() async throws -> String)? = nil, credentials: CredentialStore = KeychainCredentialStore()) {
        self.demo = demo
        self.account = account; self.session = session; self.tokenProvider = tokenProvider; self.credentials = credentials
    }
    func expireSession() {
        guard !sessionExpired else { return }
        sessionExpired = true
        sessionDidExpire?()
    }

    /// `force` renews even when the local clock still considers the token valid, e.g. after a 401.
    func token(force: Bool = false) async throws -> String {
        guard !invalidated else { throw CancellationError() }
        if let tokenProvider { return try await tokenProvider() }
        guard !sessionExpired else { throw CloudError.sessionExpired(nil) }
        if let refreshTask { return try await refreshTask.value }
        if cachedCredential == nil { cachedCredential = try credentials.read(account.id) }
        guard let credential = cachedCredential else { expireSession(); throw CloudError.sessionExpired(nil) }
        if !force, credential.expires.timeIntervalSinceNow > 90 { return credential.accessToken }
        let task = Task { () throws -> String in
            var fields = ["client_id": account.clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"]
            if let secret = account.clientSecret { fields["client_secret"] = secret }
            let result: [String: Any]
            do { result = try await HTTP.token(cloud: account.cloud, values: fields, session: session) }
            catch let error as ServiceError where (400..<500).contains(error.status) && !error.retryable {
                // invalid_grant, revoked consent or a deleted client: retrying cannot fix it, only a new sign-in.
                try Task.checkCancellation()
                guard !self.invalidated else { throw CancellationError() }
                self.expireSession()
                throw CloudError.sessionExpired(error.code == nil ? nil : error.detail)
            }
            try Task.checkCancellation()
            guard !self.invalidated else { throw CancellationError() }
            guard let access = result["access_token"] as? String else { throw CloudError.message("No se pudo renovar la sesión. Vuelve a conectar la cuenta.") }
            let updated = Credential(accessToken: access, refreshToken: result["refresh_token"] as? String ?? credential.refreshToken, expires: Date().addingTimeInterval(result["expires_in"] as? Double ?? 3600))
            try credentials.save(updated, key: account.id)
            self.cachedCredential = updated
            return access
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends an authenticated request. A first 401 renews the token and retries once; a second 401 means the provider
    /// no longer honours this account, so the session is marked as expired instead of failing silently on every call.
    func send(_ request: inout URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil else { return (data, response) }
        request.setValue("Bearer \(try await token(force: true))", forHTTPHeaderField: "Authorization")
        let (retriedData, retriedResponse) = try await session.data(for: request)
        if (retriedResponse as? HTTPURLResponse)?.statusCode == 401 { expireSession(); throw CloudError.sessionExpired(nil) }
        return (retriedData, retriedResponse)
    }

    func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try await request(url, method: method, body: body)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await send(&request)
            if method == "GET", let http = response as? HTTPURLResponse, [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 3 {
                let delay = min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt)), 30)
                try await Task.sleep(for: .seconds(max(1, delay)))
                continue
            }
            try HTTP.validate(response, data: data)
            return try HTTP.json(data)
        }
        throw CloudError.message("El servicio no responde.")
    }

    static func googleFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        let mime = value["mimeType"] as? String ?? "application/octet-stream"
        return CloudFile(id: id, name: name, mime: mime, size: (value["size"] as? String).flatMap(Int64.init), modified: date(value["modifiedTime"] as? String), webURL: (value["webViewLink"] as? String).flatMap(URL.init(string:)), isFolder: mime == "application/vnd.google-apps.folder")
    }
    static func microsoftFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        // Shared remote items need another drive identity; expose them as browser links in this MVP.
        let remote = value["remoteItem"] != nil
        return CloudFile(id: id, name: name, mime: remote ? "application/vnd.google-apps.shortcut" : ((value["file"] as? [String: Any])?["mimeType"] as? String ?? "application/octet-stream"), size: (value["size"] as? NSNumber)?.int64Value, modified: date(value["lastModifiedDateTime"] as? String), webURL: (value["webUrl"] as? String).flatMap(URL.init(string:)), isFolder: !remote && value["folder"] != nil)
    }
    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    func graphItem(_ id: String) -> String { id == "root" ? "root" : "items/" + Self.segment(id) }
    static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }

    /// Folders first, then by name. `onPage` receives the accumulated, sorted listing after each intermediate page so the
    /// explorer can show large folders progressively instead of waiting for the last page.
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        if let demo { return try demo.list(parent) }
        var files: [CloudFile] = []
        if account.cloud == .google {
            var page: String?
            repeat {
                var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                let escaped = parent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                url.queryItems = [URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,webViewLink)"), URLQueryItem(name: "pageToken", value: page)]
                let result = try await json(url.url!)
                files += (result["files"] as? [[String: Any]] ?? []).compactMap(Self.googleFile)
                page = result["nextPageToken"] as? String
                if page != nil { onPage?(Self.sorted(files)) }
            } while page != nil
        } else {
            var next: URL? = URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(graphItem(parent))/children?$top=200&$select=id,name,size,folder,file,remoteItem,webUrl,lastModifiedDateTime")!
            while let url = next {
                guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message("Paginación no válida.") }
                let result = try await json(url)
                files += (result["value"] as? [[String: Any]] ?? []).compactMap(Self.microsoftFile)
                next = (result["@odata.nextLink"] as? String).flatMap(URL.init(string:))
                if next != nil { onPage?(Self.sorted(files)) }
            }
        }
        return Self.sorted(files)
    }
    static func sorted(_ files: [CloudFile]) -> [CloudFile] {
        files.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    func createFolder(name: String, parent: String) async throws -> String {
        if let demo { return try demo.add(name: name, parent: parent, folder: true) }
        let result: [String: Any]
        if account.cloud == .google {
            result = try await json(URL(string: "https://www.googleapis.com/drive/v3/files")!, method: "POST", body: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent]])
        } else {
            result = try await json(URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(graphItem(parent))/children")!, method: "POST", body: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "rename"])
        }
        guard let id = result["id"] as? String else { throw CloudError.message("No se pudo crear la carpeta.") }
        return id
    }

    // Uploads live in ResumableUpload.swift; the queue drives them with checkpoints. There is no second, simpler path.

    func download(file: CloudFile, to destination: URL, exportMime: String? = nil, maxBytes: Int64? = nil, progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws {
        if let demo { try await demo.download(file, to: destination, maxBytes: maxBytes, progress: progress); return }
        var url: URL
        if account.cloud == .google {
            var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))" + (exportMime == nil ? "" : "/export"))!
            parts.queryItems = [URLQueryItem(name: exportMime == nil ? "alt" : "mimeType", value: exportMime ?? "media")]
            url = parts.url!
        } else { url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.segment(file.id))/content")! }
        let delegate = DownloadProgress(maxBytes: maxBytes) { bytes, total in Task { @MainActor in progress(bytes, total) } }
        var request = try await request(url)
        var temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
            if (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil {
                // Same policy as `send`: renew once, then treat a repeated 401 as a revoked session.
                try? FileManager.default.removeItem(at: temporary)
                request.setValue("Bearer \(try await token(force: true))", forHTTPHeaderField: "Authorization")
                (temporary, response) = try await session.download(for: request, delegate: delegate)
            }
        } catch {
            if delegate.exceededLimit { throw CloudError.message("La vista previa supera el límite de descarga autorizado.") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        if (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil { expireSession(); throw CloudError.sessionExpired(nil) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The error body landed in the temporary file. Read a bounded prefix so the provider's message survives,
            // e.g. Google's explanation when an export exceeds its size limit.
            let body = (try? FileHandle(forReadingFrom: temporary))?.readData(ofLength: 64 * 1024) ?? Data()
            try HTTP.validate(response, data: body)
        }
        if let maxBytes {
            let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(actual) <= maxBytes else { throw CloudError.message("La vista previa supera el límite de descarga autorizado.") }
        }
        // moveItem refuses to overwrite an existing destination.
        let downloaded = temporary
        try await blockingIO { try FileManager.default.moveItem(at: downloaded, to: destination) }
    }
}

final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (Int64, Int64) -> Void
    let maxBytes: Int64?
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.withLock { exceeded } }
    init(maxBytes: Int64? = nil, report: @escaping (Int64, Int64) -> Void) { self.maxBytes = maxBytes; self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let maxBytes, totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            lock.withLock { exceeded = true }; downloadTask.cancel(); return
        }
        report(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }
}
