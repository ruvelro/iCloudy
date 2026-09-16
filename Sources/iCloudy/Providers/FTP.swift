import Foundation

/// FTP as a provider. Items are addressed by their absolute path on the server, like WebDAV, and "root" is the base
/// path of the account. The protocol offers no search, no sharing links, no recycle bin and no checksums, which the
/// capability table reflects so the interface never offers them.
extension CloudAPI {
    /// Host, port, base path and whether the connection is wrapped in TLS, taken from the account's stored address.
    struct FTPEndpoint {
        let host: String
        let port: UInt16
        let base: String
        let security: FTPSession.Security
    }
    static func ftpEndpoint(_ server: String) throws -> FTPEndpoint {
        guard let components = URLComponents(string: server), let host = components.host, !host.isEmpty else {
            throw CloudError.message(L("Esta cuenta FTP no tiene una dirección de servidor válida. Vuelve a conectarla."))
        }
        let secure = (components.scheme ?? "ftp").lowercased() == "ftps"
        let port = UInt16(components.port ?? (secure ? 990 : 21))
        var base = components.path
        if base.hasSuffix("/"), base.count > 1 { base = String(base.dropLast()) }
        return FTPEndpoint(host: host, port: port, base: base.isEmpty ? "/" : base, security: secure ? .implicitTLS : .none)
    }

    /// The live control connection for this account, created on first use and reused afterwards.
    func ftp() async throws -> FTPSession {
        if let ftpSession { return ftpSession }
        guard let server = account.serverURL else {
            throw CloudError.message(L("Esta cuenta FTP no tiene una dirección de servidor válida. Vuelve a conectarla."))
        }
        let endpoint = try Self.ftpEndpoint(server)
        let secret = try await token()
        guard let decoded = Data(base64Encoded: secret), let pair = String(data: decoded, encoding: .utf8),
              let separator = pair.firstIndex(of: ":") else {
            expireSession()
            throw CloudError.sessionExpired(nil)
        }
        let session = FTPSession(host: endpoint.host, port: endpoint.port,
                                 user: String(pair[pair.startIndex..<separator]),
                                 password: String(pair[pair.index(after: separator)...]),
                                 security: endpoint.security)
        ftpSession = session
        return session
    }
    /// Maps iCloudy's "root" alias onto the account's base path.
    func ftpPath(_ id: String) throws -> String {
        guard let server = account.serverURL else { throw CloudError.message(L("Esta cuenta FTP no tiene una dirección de servidor válida. Vuelve a conectarla.")) }
        let base = try Self.ftpEndpoint(server).base
        guard id != "root" else { return base }
        return id.hasPrefix("/") ? id : base + "/" + id
    }

    func ftpList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        let files = try await ftp().list(path: try ftpPath(parent))
        return Self.sorted(files)
    }
    func ftpCreateFolder(name: String, parent: String) async throws -> String {
        let path = FTPListing.join(try ftpPath(parent), name)
        try await ftp().require("MKD " + path, L("No se pudo crear la carpeta."))
        return path
    }
    func ftpRename(file: CloudFile, name: String) async throws {
        let parent = CloudAPI.dropboxParent(file.id)
        try await ftpMove(file: file, toPath: FTPListing.join(parent.isEmpty ? "/" : parent, name))
    }
    func ftpMove(file: CloudFile, to destination: String) async throws {
        try await ftpMove(file: file, toPath: FTPListing.join(try ftpPath(destination), file.name))
    }
    private func ftpMove(file: CloudFile, toPath: String) async throws {
        let session = try await ftp()
        let from = try await session.command("RNFR " + file.id)
        guard from.code == 350 else { throw CloudError.message(L("El servidor no encontró el elemento que se quiere mover.")) }
        try await session.require("RNTO " + toPath, L("El servidor rechazó el nuevo nombre o destino."))
    }
    /// FTP deletes for good, and an empty directory is a precondition for RMD, so folders are emptied depth first.
    func ftpDelete(file: CloudFile) async throws {
        let session = try await ftp()
        guard file.isFolder else {
            try await session.require("DELE " + file.id, L("No se pudo eliminar el archivo."))
            return
        }
        for child in try await session.list(path: file.id) { try await ftpDelete(file: child) }
        try await session.require("RMD " + file.id, L("No se pudo eliminar la carpeta."))
    }
    func ftpDownload(file: CloudFile, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        let total = file.size ?? 0
        try await ftp().retrieve(path: file.id, to: destination) { sent in
            Task { @MainActor in progress(sent, total) }
        }
    }
    /// A plain STOR from start to finish: FTP has no session that survives a broken connection, so a retry starts over.
    func ftpUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                   save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let total = cursor.total
        let path = try replacing ?? FTPListing.join(ftpPath(parent), name)
        cursor.offset = 0; try save(cursor)
        try await ftp().store(local, to: path) { sent in
            Task { @MainActor in progress(min(sent, total), total) }
        }
        cursor.offset = total; cursor.complete = true; try save(cursor); progress(total, total)
        // Nothing to compare against: the protocol reports no checksum for the stored file.
        return UploadReceipt(remoteID: path, verification: .unavailable)
    }
    /// Breadcrumbs come from the path, as with WebDAV and Dropbox.
    func ftpTrail(id: String) throws -> [CloudFile] {
        let base = try ftpPath("root")
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
