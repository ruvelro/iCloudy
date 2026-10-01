import Foundation

/// SFTP as a provider. Like FTP and WebDAV, items are addressed by their absolute path on the server and "root" is
/// the base path of the account. Unlike FTP, everything travels inside one encrypted SSH connection, the server's
/// identity is checked against the key it showed the first time, and the server can report its free space.
@MainActor
final class SFTPProvider: CloudSession, CloudProvider {
    var sftpClient: SFTPClient?
    override func invalidate() {
        super.invalidate()
        if let sftpClient { Task { await sftpClient.close() } }
        sftpClient = nil
    }
}

extension SFTPProvider {
    struct SFTPEndpoint {
        let host: String
        let port: UInt16
        let base: String
    }
    static func sftpEndpoint(_ server: String) throws -> SFTPEndpoint {
        guard let components = URLComponents(string: server), let host = components.host, !host.isEmpty,
              (components.scheme ?? "sftp").lowercased() == "sftp" else {
            throw CloudError.message(L("Esta cuenta SFTP no tiene una dirección de servidor válida. Vuelve a conectarla."))
        }
        guard let port = UInt16(exactly: components.port ?? 22), port > 0 else {
            throw CloudError.message(L("El puerto SFTP debe estar entre 1 y 65535."))
        }
        var base = components.path
        if base.hasSuffix("/"), base.count > 1 { base = String(base.dropLast()) }
        return SFTPEndpoint(host: host, port: port, base: base.isEmpty ? "/" : base)
    }
    /// The key the server showed when the account was connected, which every later session must show again.
    static func storedHostKey(_ account: Account) -> Data? {
        account.options["hostKey"].flatMap { Data(base64Encoded: $0) }
    }

    /// The live session for this account, created on first use and reused afterwards.
    func sftp() async throws -> SFTPClient {
        if let sftpClient { return sftpClient }
        guard let server = account.serverURL else {
            throw CloudError.message(L("Esta cuenta SFTP no tiene una dirección de servidor válida. Vuelve a conectarla."))
        }
        let endpoint = try Self.sftpEndpoint(server)
        let secret = try await token()
        guard let decoded = Data(base64Encoded: secret), let pair = String(data: decoded, encoding: .utf8),
              let separator = pair.firstIndex(of: ":") else {
            expireSession()
            throw CloudError.sessionExpired(nil)
        }
        let transport = SSHTransport(host: endpoint.host, port: endpoint.port,
                                     user: String(pair[pair.startIndex..<separator]),
                                     password: String(pair[pair.index(after: separator)...]),
                                     expectedHostKey: Self.storedHostKey(account))
        let client = SFTPClient(transport: transport, account: account.id)
        sftpClient = client
        return client
    }
    func sftpPath(_ id: String) throws -> String {
        guard let server = account.serverURL else { throw CloudError.message(L("Esta cuenta SFTP no tiene una dirección de servidor válida. Vuelve a conectarla.")) }
        let base = try Self.sftpEndpoint(server).base
        guard id != "root" else { return base }
        return id.hasPrefix("/") ? id : FTPListing.join(base, id)
    }
    nonisolated static func sftpFile(_ entry: SFTPClient.Entry, parent: String) -> CloudFile {
        // A symbolic link is listed under its own name but never browsed as a folder: where it points is unknown.
        let folder = entry.attributes.isDirectory && !entry.attributes.isSymbolicLink
        return CloudFile(id: FTPListing.join(parent, entry.name), name: entry.name,
                         mime: folder ? "application/vnd.google-apps.folder" : mime(forName: entry.name),
                         size: folder ? nil : entry.attributes.size.map { Int64(clamping: $0) },
                         modified: entry.attributes.modified, webURL: nil, isFolder: folder)
    }
    /// A wrong password is an expired session rather than a refusal: only new credentials fix it.
    private func sftpTranslating<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let error as CloudError {
            if case .message(let text) = error, text.contains(L("rechazó el usuario o la contraseña")) {
                expireSession(text)
                throw CloudError.sessionExpired(text)
            }
            throw error
        }
    }

    func sftpList(parent: String) async throws -> [CloudFile] {
        let path = try sftpPath(parent)
        let entries = try await sftpTranslating { try await sftp().list(path) }
        return Self.sorted(entries.map { Self.sftpFile($0, parent: path) })
    }
    func sftpCreateFolder(name: String, parent: String) async throws -> String {
        let path = FTPListing.join(try sftpPath(parent), name)
        try await sftpTranslating { try await sftp().mkdir(path) }
        return path
    }
    func sftpMove(file: CloudFile, toPath: String) async throws {
        let client = try await sftp()
        // Neither RENAME nor posix-rename is asked to overwrite: what is at the destination is checked first, and
        // a race that puts something there in between is reported by the server rather than papered over.
        if (try? await client.stat(toPath)) != nil {
            throw CloudError.message(L("Ya existe un elemento con ese nombre en el destino."))
        }
        try await sftpTranslating { try await client.rename(file.id, to: toPath) }
    }
    /// SFTP deletes for good, and RMDIR wants an empty directory, so folders are emptied depth first.
    func sftpDelete(file: CloudFile) async throws {
        try Task.checkCancellation()
        let client = try await sftp()
        guard file.isFolder else {
            try await sftpTranslating { try await client.remove(file.id) }
            return
        }
        for child in try await sftpList(parent: file.id) { try await sftpDelete(file: child) }
        try await sftpTranslating { try await client.rmdir(file.id) }
    }
    func sftpUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let path = try replacing ?? FTPListing.join(sftpPath(parent), name)
        cursor.offset = 0; try save(cursor)
        // The client reports from its own actor; the callback only ever runs back here, on the main actor.
        let relay: @MainActor @Sendable (Int64) -> Void = { sent in progress(min(sent, total), total) }
        try await sftpTranslating { try await sftp().upload(local, to: path) { sent in Task { @MainActor in relay(sent) } } }
        cursor.offset = total; cursor.complete = true; try save(cursor); progress(total, total)
        // The protocol reports no checksum; the closing status is the only confirmation.
        return UploadReceipt(remoteID: path, verification: .unavailable)
    }
    func sftpTrail(id: String) throws -> [CloudFile] {
        guard id != "root" else { return [] }
        let base = try sftpPath("root")
        var relative = id
        if base != "/", relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)) }
        let parts = relative.split(separator: "/").map(String.init)
        return parts.indices.map { index in
            let path = FTPListing.join(base, parts[0...index].joined(separator: "/"))
            return CloudFile(id: path, name: parts[index], mime: "application/vnd.google-apps.folder",
                             size: nil, modified: nil, webURL: nil, isFolder: true)
        }
    }
}

extension SFTPProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        try await sftpList(parent: parent)
    }
    func createFolder(name: String, parent: String) async throws -> String {
        try await sftpCreateFolder(name: name, parent: parent)
    }
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        throw CloudError.message(L("Este proveedor no usa peticiones HTTP."))
    }
    func rename(file: CloudFile, name: String) async throws {
        let parent = CloudSession.dropboxParent(file.id)
        try await sftpMove(file: file, toPath: FTPListing.join(parent.isEmpty ? "/" : parent, name))
    }
    func move(file: CloudFile, to destination: String) async throws {
        try await sftpMove(file: file, toPath: FTPListing.join(try sftpPath(destination), file.name))
    }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        throw CloudError.message(L("SFTP no copia en el servidor. Descarga el archivo y vuelve a subirlo."))
    }
    func trash(file: CloudFile) async throws { try await sftpDelete(file: file) }
    func publicLink(for file: CloudFile) async throws -> URL {
        throw CloudError.message(L("SFTP no tiene enlaces públicos."))
    }
    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        throw CloudError.message(L("SFTP no ofrece búsqueda. Navega por las carpetas o usa el filtro de la carpeta actual."))
    }
    func folderTrail(id: String) async throws -> [CloudFile] { try sftpTrail(id: id) }
    func storageQuota() async throws -> StorageQuota {
        let base = try sftpPath("root")
        guard let space = try await sftpTranslating({ try await sftp().statvfs(base) }) else {
            throw CloudError.message(L("Este servidor SFTP no informa del espacio disponible."))
        }
        return StorageQuota(used: max(0, space.total - space.free), total: space.total)
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try await sftpUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let total = file.size ?? 0
        let relay: @MainActor @Sendable (Int64) -> Void = { got in progress(got, total) }
        try await sftpTranslating { try await sftp().download(file.id, to: destination, maxBytes: maxBytes) { got in Task { @MainActor in relay(got) } } }
    }
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        let newID = FTPListing.join(try destination.map(sftpPath) ?? (file.id as NSString).deletingLastPathComponent, name)
        return RemoteIdentityChange(oldID: file.id, newID: newID, name: name, descendants: file.isFolder)
    }
}

@MainActor
struct SFTPAuthentication {
    /// Connects once to prove the address and the credentials, and keeps the server's key for every later session.
    func signInSFTP(server: String, username: String, password: String) async throws -> (Account, Credential) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "sftp://" + trimmed
        guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty,
              (components.scheme ?? "").lowercased() == "sftp" else {
            throw CloudError.message(L("Escribe una dirección válida, por ejemplo sftp://servidor.ejemplo.com/carpeta"))
        }
        let (username, password) = LoginAddress.credentials(embeddedIn: &components, username: username, password: password)
        guard !username.isEmpty else { throw CloudError.message(L("Introduce el usuario del servidor.")) }
        components.query = nil; components.fragment = nil
        if components.path.hasSuffix("/"), components.path.count > 1 { components.path = String(components.path.dropLast()) }
        guard let port = UInt16(exactly: components.port ?? 22), port > 0 else {
            throw CloudError.message(L("El puerto SFTP debe estar entre 1 y 65535."))
        }
        let transport = SSHTransport(host: host, port: port, user: username, password: password, expectedHostKey: nil)
        let client = SFTPClient(transport: transport)
        let hostKey: Data
        do {
            // A listing of the base path proves the session works and that the path exists; a wrong path is the
            // most common mistake and deserves a plain answer.
            _ = try await client.list(components.path.isEmpty ? "/" : components.path)
            guard let key = await client.hostKey else { throw CloudError.message(L("El servidor no presentó ninguna clave.")) }
            hostKey = key
        } catch let error as SFTPClient.Refusal where error.isNotFound {
            await client.close()
            throw CloudError.message(L("La carpeta «\(components.path)» no existe en el servidor. Comprueba la ruta de la dirección."))
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        guard let base = components.url?.absoluteString else {
            throw CloudError.message(L("Escribe una dirección válida, por ejemplo sftp://servidor.ejemplo.com/carpeta"))
        }
        var account = Account(id: "sftp:" + host + ":" + String(port) + components.path + "#" + username, cloud: .sftp,
                              name: host, email: username + "@" + host, clientID: "", clientSecret: nil, serverURL: base)
        account.options["hostKey"] = hostKey.base64EncodedString()
        account.options["hostKeyFingerprint"] = SSHHostKey.fingerprint(hostKey)
        return (account, Credential(accessToken: Data("\(username):\(password)".utf8).base64EncodedString(),
                                    refreshToken: "", expires: .distantFuture))
    }
}
