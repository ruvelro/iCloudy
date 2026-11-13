import Foundation

/// SFTP as a provider. Like FTP and WebDAV, items are addressed by their absolute path on the server and "root" is
/// the base path of the account. Unlike FTP, everything travels inside one encrypted SSH connection, the server's
/// identity is checked against the key it showed the first time, and the server can report its free space.
@MainActor
final class SFTPProvider: CloudSession, CloudProvider {
    var sftpClient: SFTPClient?
    /// How much of an upload goes in one stretch before the checkpoint is saved. Tests make it one block.
    var uploadSegment = SFTPProvider.defaultUploadSegment
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
    /// Where accounts connected before 0.8 kept the server's key: `accounts.json`, which any process of this user
    /// can rewrite. Read only to move it into the Keychain.
    static func legacyHostKey(_ account: Account) -> Data? {
        account.options["hostKey"].flatMap { Data(base64Encoded: $0) }
    }
    /// The key the server showed when the account was connected, which every later session must show again. It is
    /// read from the Keychain entry; an older account's copy in its options is moved there the first time, and from
    /// then on the Keychain is what counts, whatever the options say.
    func pinnedHostKey(_ credential: Credential?) -> Data? {
        if let pinned = credential?.hostKey.flatMap({ Data(base64Encoded: $0) }) { return pinned }
        guard let legacy = Self.legacyHostKey(account) else { return nil }
        if var credential {
            credential.hostKey = legacy.base64EncodedString()
            // A failed write only means the move is tried again next time; the session can still use the pin.
            try? credentials.save(credential, key: account.credentialKey)
        }
        return legacy
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
        // A key, when the account was connected with one, lives in the same Keychain entry as the password, and so
        // does the server's key.
        let credential = try credentials.read(account.credentialKey)
        let material = credential.flatMap { SFTPKeyMaterial.decode($0.secret) }
        let privateKey = try await material?.open()
        // An account with no pin at all (it should not exist) is refused by the transport rather than trusted.
        let transport = SSHTransport(host: endpoint.host, port: endpoint.port,
                                     user: String(pair[pair.startIndex..<separator]),
                                     password: String(pair[pair.index(after: separator)...]),
                                     privateKey: privateKey,
                                     expectedHostKey: pinnedHostKey(credential))
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

    /// The permission bits of an item, as the server has them now.
    func sftpPermissions(of file: CloudFile) async throws -> POSIXMode {
        let attributes = try await sftpTranslating { try await sftp().stat(file.id) }
        guard let permissions = attributes.permissions else { throw CloudError.message(L("El servidor no dice qué permisos tiene «\(file.name)».")) }
        return POSIXMode(bits: permissions)
    }
    /// chmod. With `recursive`, everything below a folder gets the same bits, except that a file is never made
    /// executable just because the folder above it has to be: its three x bits stay as they were.
    func sftpSetPermissions(_ mode: POSIXMode, on file: CloudFile, recursive: Bool) async throws {
        let client = try await sftp()
        try await sftpTranslating { try await client.setPermissions(file.id, mode: mode.bits) }
        guard recursive, file.isFolder else { return }
        var pending = [file.id]
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            for entry in try await client.list(folder) where entry.name != "." && entry.name != ".." {
                // A link is somebody else's file; changing what it points at from here would be a surprise.
                guard !entry.attributes.isSymbolicLink else { continue }
                let path = FTPListing.join(folder, entry.name)
                if entry.attributes.isDirectory {
                    try await client.setPermissions(path, mode: mode.bits)
                    pending.append(path)
                } else {
                    let runs = (entry.attributes.permissions ?? 0) & 0o111
                    try await client.setPermissions(path, mode: (mode.bits & ~0o111) | runs)
                }
            }
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
    /// How much of an upload goes in one stretch before the checkpoint is saved. The pipeline drains at each
    /// boundary, which costs one round trip per 16 MiB, and a dropped connection loses at most this much.
    nonisolated static let defaultUploadSegment: Int64 = 16 * 1024 * 1024

    /// The bytes go to a hidden name beside the target and take its place only once they are all there: a dropped
    /// connection used to leave a truncated file under the final name, indistinguishable from a good one. That hidden
    /// file is also the upload session: its path is the checkpoint's `sessionID`, `offset` counts the bytes the
    /// server confirmed, in order, and a retry continues from there, after checking that the partial on the server
    /// is still at least that long. The source is held to its stamp by the checkpoint, so a file that changed in
    /// between starts again instead of being stitched to its old self.
    func sftpUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let path = try replacing ?? FTPListing.join(sftpPath(parent), name)
        let temporary = FTPListing.partialName(for: path)
        let client = try await sftp()
        var start: Int64 = 0
        if cursor.sessionID == temporary, cursor.offset > 0, cursor.offset <= total,
           let size = try? await client.stat(temporary).size {
            start = min(cursor.offset, Int64(clamping: size))
        }
        cursor.sessionID = temporary; cursor.offset = start; try save(cursor)
        // The client reports from its own actor; the callback only ever runs back here, on the main actor.
        let relay: @MainActor @Sendable (Int64) -> Void = { sent in progress(min(sent, total), total) }
        progress(start, total)
        do {
            repeat {
                try Task.checkCancellation()
                let from = start, length = min(uploadSegment, total - start)
                try await sftpTranslating { try await client.upload(local, to: temporary, from: from, length: length) { sent in Task { @MainActor in relay(sent) } } }
                start += length
                cursor.offset = start; try save(cursor)
            } while start < total
            try await sftpTranslating { try await client.replace(path, with: temporary) }
        } catch {
            // Nothing confirmed yet: the hidden name is removed, as before. Otherwise it stays for the retry to
            // continue; cancelling the transfer removes it through `abandonUploadSessions`.
            if cursor.offset == 0 { try? await client.remove(temporary) }
            throw error
        }
        cursor.sessionID = nil
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
        // No search of its own: the tree is walked and names are matched here.
        try await walkSearch(term: term, cursor: cursor)
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
    /// Into a partial the queue keeps between attempts (`ResumableDownload`), the download continues from the bytes
    /// already there when they are of the same version, and what arrives before a failure is kept for the next try.
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let total = file.size ?? 0
        let resumable = ResumableDownload.isPartial(destination)
        let start = resumable ? try await blockingIO { try ResumableDownload.prepare(destination, for: file) } : 0
        let relay: @MainActor @Sendable (Int64) -> Void = { got in progress(got, total) }
        try await sftpTranslating {
            try await sftp().download(file.id, to: destination, from: start, keepPartial: resumable, maxBytes: maxBytes) { got in Task { @MainActor in relay(got) } }
        }
    }
    /// A cancelled upload's hidden partial is removed; nothing but such a partial ever is.
    func abandonUploadSessions(urls: [URL], sessionIDs: [String]) async {
        guard let client = try? await sftp() else { return }
        for path in sessionIDs where (path as NSString).lastPathComponent.hasSuffix(".icloudy-part") {
            try? await client.remove(path)
        }
    }
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        let newID = FTPListing.join(try destination.map(sftpPath) ?? (file.id as NSString).deletingLastPathComponent, name)
        return RemoteIdentityChange(oldID: file.id, newID: newID, name: name, descendants: file.isFolder)
    }
}

@MainActor
struct SFTPAuthentication {
    /// Connects once to prove the address and the credentials, and keeps the server's key for every later session.
    /// The key is shown to the person through `trustHostKey` before anything secret is sent; by default the login
    /// form asks, through `LoginPrompts`.
    func signInSFTP(server: String, username: String, password: String, key: SFTPKeyMaterial? = nil,
                    trustHostKey: (@Sendable (LoginPrompts.HostKeyQuestion) async -> Bool)? = nil) async throws -> (Account, Credential) {
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
        guard !password.isEmpty || key != nil else { throw CloudError.message(L("Escribe la contraseña o elige una clave privada.")) }
        let privateKey = try await key?.open()
        let ask = trustHostKey ?? { question in await LoginPrompts.shared.trust(question) }
        let transport = SSHTransport(host: host, port: port, user: username, password: password, privateKey: privateKey, expectedHostKey: nil,
                                     approveHostKey: { blob in await ask(LoginPrompts.HostKeyQuestion(host: host, port: port, blob: blob)) })
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
        // Only the fingerprint, for showing, stays in the account; the pin itself goes to the Keychain.
        account.options["hostKeyFingerprint"] = SSHHostKey.fingerprint(hostKey)
        if let privateKey { account.options["keyFingerprint"] = privateKey.fingerprint }
        return (account, Credential(accessToken: Data("\(username):\(password)".utf8).base64EncodedString(),
                                    refreshToken: "", expires: .distantFuture, secret: key?.encoded ?? "",
                                    hostKey: hostKey.base64EncodedString()))
    }
}
