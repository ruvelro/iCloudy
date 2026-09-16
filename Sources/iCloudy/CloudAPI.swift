import Foundation

@MainActor
final class CloudAPI {
    let account: Account
    let session: URLSession
    let demo: DemoStore?
    private let tokenProvider: (() async throws -> String)?
    private var refreshTask: Task<String, Error>?
    private var invalidated = false
    func invalidate() {
        invalidated = true
        refreshTask?.cancel()
    }
    init(account: Account, session: URLSession = .shared, demo: DemoStore? = nil, tokenProvider: (() async throws -> String)? = nil) {
        self.demo = demo
        self.account = account; self.session = session; self.tokenProvider = tokenProvider
    }

    func token() async throws -> String {
        guard !invalidated else { throw CancellationError() }
        if let tokenProvider { return try await tokenProvider() }
        if let refreshTask { return try await refreshTask.value }
        guard let credential = try Vault.read(Credential.self, key: account.id) else { throw CloudError.message("Conecta de nuevo esta cuenta.") }
        if credential.expires.timeIntervalSinceNow > 90 { return credential.accessToken }
        let task = Task { () throws -> String in
            var fields = ["client_id": account.clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"]
            if let secret = account.clientSecret { fields["client_secret"] = secret }
            let result = try await HTTP.token(cloud: account.cloud, values: fields)
            try Task.checkCancellation()
            guard !self.invalidated else { throw CancellationError() }
            guard let access = result["access_token"] as? String else { throw CloudError.message("No se pudo renovar la sesión. Vuelve a conectar la cuenta.") }
            let updated = Credential(accessToken: access, refreshToken: result["refresh_token"] as? String ?? credential.refreshToken, expires: Date().addingTimeInterval(result["expires_in"] as? Double ?? 3600))
            try Vault.save(updated, key: account.id)
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

    func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let request = try await request(url, method: method, body: body)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
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

    func list(parent: String) async throws -> [CloudFile] {
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
            } while page != nil
        } else {
            var next: URL? = URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(graphItem(parent))/children?$top=200&$select=id,name,size,folder,file,remoteItem,webUrl,lastModifiedDateTime")!
            while let url = next {
                guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message("Paginación no válida.") }
                let result = try await json(url)
                files += (result["value"] as? [[String: Any]] ?? []).compactMap(Self.microsoftFile)
                next = (result["@odata.nextLink"] as? String).flatMap(URL.init(string:))
            }
        }
        return files.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
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

    func upload(local: URL, parent: String, progress: @escaping (Double) -> Void) async throws {
        let values = try local.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw CloudError.message("Los enlaces simbólicos no se suben: \(local.lastPathComponent)") }
        if values.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [])
            let folder = try await createFolder(name: local.lastPathComponent, parent: parent)
            for (index, child) in children.enumerated() {
                try Task.checkCancellation()
                try await upload(local: child, parent: folder) { fraction in progress((Double(index) + fraction) / Double(max(1, children.count))) }
            }
            progress(1)
            return
        }
        guard values.isRegularFile == true else { throw CloudError.message("Tipo de archivo no compatible: \(local.lastPathComponent)") }
        let total = Int64(values.fileSize ?? 0)
        let sessionURL: URL
        if account.cloud == .google {
            var initial = try await request(URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!, method: "POST", body: ["name": local.lastPathComponent, "parents": [parent]])
            initial.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            initial.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
            let (data, response) = try await session.data(for: initial)
            try HTTP.validate(response, data: data)
            guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), let url = URL(string: location), url.scheme == "https" else { throw CloudError.message("No se pudo iniciar la subida.") }
            sessionURL = url
        } else if total == 0 {
            // A random suffix avoids replacing an existing zero-byte file via PUT.
            let name = local.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(8) + (local.pathExtension.isEmpty ? "" : "." + local.pathExtension)
            var empty = try await request(URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(graphItem(parent)):/\(Self.segment(name)):/content")!, method: "PUT")
            empty.httpBody = Data()
            empty.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: empty)
            try HTTP.validate(response, data: data)
            progress(1); return
        } else {
            let result = try await json(URL(string: "https://graph.microsoft.com/v1.0/me/drive/\(graphItem(parent)):/\(Self.segment(local.lastPathComponent)):/createUploadSession")!, method: "POST", body: ["item": ["@microsoft.graph.conflictBehavior": "rename", "name": local.lastPathComponent]])
            guard let uploadURL = result["uploadUrl"] as? String, let url = URL(string: uploadURL), url.scheme == "https" else { throw CloudError.message("No se pudo iniciar la subida.") }
            sessionURL = url
        }
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        var offset: Int64 = 0
        repeat {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 5 * 1024 * 1024) ?? Data()
            guard !chunk.isEmpty || total == 0 else { throw CloudError.message("El archivo cambió durante la subida. Vuelve a intentarlo.") }
            guard offset + Int64(chunk.count) <= total else { throw CloudError.message("El archivo creció durante la subida. Vuelve a intentarlo.") }
            var upload = URLRequest(url: sessionURL)
            upload.httpMethod = "PUT"
            upload.timeoutInterval = 180
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.setValue(total == 0 ? "bytes */0" : "bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            let (data, response) = try await session.upload(for: upload, from: chunk)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let isLast = offset + Int64(chunk.count) == total
            if isLast {
                guard [200, 201].contains(status) else { try HTTP.validate(response, data: data); throw CloudError.message("El servidor no confirmó la subida completa.") }
            } else if account.cloud == .google {
                guard status == 308 else { try HTTP.validate(response, data: data); throw CloudError.message("Respuesta inesperada durante la subida.") }
                guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range") == "bytes=0-\(offset + Int64(chunk.count) - 1)" else { throw CloudError.message("El servidor solo recibió parte del bloque. La subida quedó incompleta.") }
            } else {
                guard status == 202 else { try HTTP.validate(response, data: data); throw CloudError.message("Respuesta inesperada durante la subida.") }
                let result = try HTTP.json(data)
                guard let ranges = result["nextExpectedRanges"] as? [String], ranges.first?.hasPrefix("\(offset + Int64(chunk.count))-") == true else { throw CloudError.message("El servidor solo recibió parte del bloque. La subida quedó incompleta.") }
            }
            offset += Int64(chunk.count)
            progress(total == 0 ? 1 : Double(offset) / Double(total))
        } while offset < total
    }

    func download(file: CloudFile, to destination: URL, exportMime: String? = nil, maxBytes: Int64? = nil, progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws {
        if let demo { try await demo.download(file, to: destination, maxBytes: maxBytes, progress: progress); return }
        var url: URL
        if account.cloud == .google {
            var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))" + (exportMime == nil ? "" : "/export"))!
            parts.queryItems = [URLQueryItem(name: exportMime == nil ? "alt" : "mimeType", value: exportMime ?? "media")]
            url = parts.url!
        } else { url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(Self.segment(file.id))/content")! }
        let delegate = DownloadProgress(maxBytes: maxBytes) { bytes, total in Task { @MainActor in progress(bytes, total) } }
        let temporary: URL, response: URLResponse
        do { (temporary, response) = try await session.download(for: request(url), delegate: delegate) }
        catch {
            if delegate.exceededLimit { throw CloudError.message("La vista previa supera el límite de descarga autorizado.") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try HTTP.validate(response)
        if let maxBytes {
            let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(actual) <= maxBytes else { throw CloudError.message("La vista previa supera el límite de descarga autorizado.") }
        }
        // moveItem refuses to overwrite an existing destination.
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func downloadTree(file: CloudFile, into folder: URL, progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        if file.isFolder {
            let destination = FileNames.available(in: folder, name: file.name)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let children = try await list(parent: file.id)
            for (index, child) in children.enumerated() {
                try await downloadTree(file: child, into: destination) { fraction in progress((Double(index) + fraction) / Double(max(1, children.count))) }
            }
        } else if file.isGoogleDocument {
            guard let url = file.webURL else { throw CloudError.message("No hay enlace para \(file.name).") }
            let destination = FileNames.available(in: folder, name: file.name + ".webloc")
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
            try data.write(to: destination, options: .withoutOverwriting)
        } else {
            try await download(file: file, to: FileNames.available(in: folder, name: file.name))
        }
        progress(1)
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
