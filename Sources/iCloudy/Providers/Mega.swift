import Foundation

/// Mega, using the same unofficial API its own web client speaks. Mega publishes no specification and no stable
/// contract for third parties, so this provider is marked experimental in the interface: it can stop working after a
/// change on Mega's side that no release note announces.
///
/// What is different from every other provider here is that the server holds no readable data. Names, folder
/// structure and contents are encrypted under a key derived from the password, so the tree arrives as ciphertext and
/// is decrypted on this Mac. That has two happy consequences: the whole tree comes in one response, which makes
/// search and breadcrumbs free, and downloads are verified against a MAC stored inside each file's own key.
extension CloudAPI {
    // MARK: - Session

    /// Signs in if needed. The session identifier and the master key live in the Keychain, so this is normally free.
    func megaSession() async throws -> MegaState {
        // A client whose account was disconnected must stop working, even though its session needs no refreshing.
        guard !invalidated else { throw CancellationError() }
        if let megaStateCache { return megaStateCache }
        guard let credential = try credentials.read(account.credentialKey), !credential.accessToken.isEmpty else {
            throw CloudError.sessionExpired(L("La sesión de Mega ha caducado. Vuelve a iniciar sesión."))
        }
        let masterKey = MegaCrypto.decode(credential.secret)
        guard masterKey.count == 16 else {
            throw CloudError.sessionExpired(L("La sesión de Mega ha caducado. Vuelve a iniciar sesión."))
        }
        let state = MegaState(sid: credential.accessToken, masterKey: masterKey)
        megaStateCache = state
        return state
    }
    func megaCall(_ payload: [String: Any]) async throws -> Any {
        let state = try await megaSession()
        do { return try await MegaAPI.call(payload, sid: state.sid, sequence: state.next(), session: session) }
        catch {
            if case CloudError.sessionExpired = error { expireSession() }
            throw error
        }
    }
    /// The whole tree, fetched once and kept until something changes it.
    @discardableResult
    func megaTree() async throws -> MegaState {
        let state = try await megaSession()
        guard !state.loaded else { return state }
        guard let answer = try await megaCall(["a": "f", "c": 1, "r": 1]) as? [String: Any],
              let files = answer["f"] as? [[String: Any]] else {
            throw CloudError.message(L("Mega no devolvió el contenido de la cuenta."))
        }
        let masterKey = state.masterKey
        state.adopt(try await blockingIO { MegaAPI.tree(files, masterKey: masterKey) })
        guard !state.root.isEmpty else { throw CloudError.message(L("No se encontró la raíz de la cuenta de Mega.")) }
        return state
    }
    /// Anything that changes the tree invalidates it: the next listing fetches it again rather than guessing.
    func megaChanged() { megaStateCache?.loaded = false }

    func megaHandle(_ id: String, in state: MegaState) throws -> String {
        let handle = id == "root" ? state.root : id
        guard !handle.isEmpty else { throw CloudError.message(L("Ese elemento de Mega ya no existe.")) }
        return handle
    }
    private func megaNode(_ id: String, in state: MegaState) throws -> MegaNode {
        guard let node = state.nodes[try megaHandle(id, in: state)] else {
            throw CloudError.message(L("Ese elemento de Mega ya no existe."))
        }
        return node
    }
    nonisolated static func megaFile(_ node: MegaNode) -> CloudFile {
        CloudFile(id: node.handle, name: node.name,
                  mime: node.isFolder ? "application/vnd.google-apps.folder" : mime(forName: node.name),
                  size: node.size, modified: node.modified, webURL: nil, isFolder: node.isFolder)
    }

    // MARK: - Browsing

    func megaList(parent: String) async throws -> [CloudFile] {
        let state = try await megaTree()
        let handle = try megaHandle(parent, in: state)
        let files = (state.children[handle] ?? []).compactMap { state.nodes[$0] }
            .filter { $0.kind <= 1 }.map(Self.megaFile)
        return Self.sorted(files)
    }
    func megaTrail(id: String) async throws -> [CloudFile] {
        let state = try await megaTree()
        var trail: [CloudFile] = []
        var current = try megaHandle(id, in: state)
        // The chain is walked upwards and reversed, with a bound so a malformed tree cannot loop forever.
        while let node = state.nodes[current], node.kind <= 1, trail.count < 64 {
            trail.append(Self.megaFile(node))
            current = node.parent
        }
        return trail.reversed()
    }
    /// The tree is already here and already decrypted, so search needs no request at all.
    func megaSearch(term: String) async throws -> SearchPage {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SearchPage(hits: [], next: nil) }
        let state = try await megaTree()
        let trash = state.trash
        let hits = state.nodes.values
            .filter { $0.kind <= 1 && $0.name.localizedCaseInsensitiveContains(needle) }
            .filter { node in
                // Items in the bin are not results; the chain upwards says whether one is inside it.
                var current = node.parent
                var steps = 0
                while let parent = state.nodes[current], steps < 64 {
                    if parent.handle == trash { return false }
                    current = parent.parent; steps += 1
                }
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(500)
            .map { SearchHit(accountID: account.id, file: Self.megaFile($0), parentID: $0.parent) }
        return SearchPage(hits: Array(hits), next: nil)
    }
    func megaQuota() async throws -> StorageQuota {
        guard let answer = try await megaCall(["a": "uq", "strg": 1, "xfer": 1]) as? [String: Any] else {
            throw CloudError.message(L("Mega no informó del espacio de la cuenta."))
        }
        let used = (answer["cstrg"] as? Double).map { Int64($0) } ?? 0
        let total = (answer["mstrg"] as? Double).map { Int64($0) }
        return StorageQuota(used: used, total: total)
    }

    // MARK: - Changing things

    func megaCreateFolder(name: String, parent: String) async throws -> String {
        let state = try await megaTree()
        let target = try megaHandle(parent, in: state)
        let key = MegaCrypto.randomKey(count: 16)
        let node: [String: Any] = ["h": "xxxxxxxx", "t": 1,
                                   "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": name], key: key)),
                                   "k": MegaCrypto.encode(try MegaCrypto.ecb(key, key: state.masterKey, encrypt: true))]
        let answer = try await megaCall(["a": "p", "t": target, "n": [node]])
        megaChanged()
        guard let created = ((answer as? [String: Any])?["f"] as? [[String: Any]])?.first,
              let handle = created["h"] as? String else {
            throw CloudError.message(L("Mega no devolvió la carpeta creada."))
        }
        return handle
    }
    func megaRename(file: CloudFile, name: String) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard node.isReadable else { throw CloudError.message(L("Este elemento no se puede renombrar porque su clave no es de esta cuenta.")) }
        let attributes = try MegaCrypto.encodeAttributes(["n": name], key: node.contentKey)
        _ = try await megaCall(["a": "a", "n": node.handle,
                                "attr": MegaCrypto.encode(attributes),
                                "key": MegaCrypto.encode(try MegaCrypto.ecb(node.key, key: state.masterKey, encrypt: true))])
        megaChanged()
    }
    func megaMove(file: CloudFile, to destination: String) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        _ = try await megaCall(["a": "m", "n": node.handle, "t": try megaHandle(destination, in: state)])
        megaChanged()
    }
    /// Mega copies without moving any bytes: the same encrypted content is attached to a second node.
    func megaCopy(file: CloudFile, to destination: String) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard !node.isFolder else { throw CloudError.message(L("Mega solo copia archivos, no carpetas.")) }
        guard node.isReadable else { throw CloudError.message(L("Este elemento no se puede copiar porque su clave no es de esta cuenta.")) }
        let entry: [String: Any] = ["h": node.handle, "t": 0,
                                    "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": node.name], key: node.contentKey)),
                                    "k": MegaCrypto.encode(try MegaCrypto.ecb(node.key, key: state.masterKey, encrypt: true))]
        _ = try await megaCall(["a": "p", "t": try megaHandle(destination, in: state), "n": [entry]])
        megaChanged()
    }
    /// Deleting means moving to Mega's own bin, which the user can undo from mega.nz.
    func megaTrash(file: CloudFile) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard !state.trash.isEmpty else { throw CloudError.message(L("Esta cuenta de Mega no tiene papelera.")) }
        guard node.parent != state.trash else {
            throw CloudError.message(L("Ese elemento ya está en la papelera. Vacíala desde mega.nz."))
        }
        _ = try await megaCall(["a": "m", "n": node.handle, "t": state.trash])
        megaChanged()
    }
    func megaPublicLink(for file: CloudFile) async throws -> URL {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard node.isReadable else { throw CloudError.message(L("Este elemento no se puede compartir porque su clave no es de esta cuenta.")) }
        guard let handle = try await megaCall(["a": "l", "n": node.handle]) as? String else {
            throw CloudError.message(L("Mega no devolvió el enlace."))
        }
        // The key goes in the fragment, which browsers never send to the server: without it the link is unreadable.
        let kind = node.isFolder ? "folder" : "file"
        guard let url = URL(string: "https://mega.nz/\(kind)/\(handle)#\(MegaCrypto.encode(node.key))") else {
            throw CloudError.message(L("Mega no devolvió el enlace."))
        }
        return url
    }

    // MARK: - Contents

    func megaDownload(file: CloudFile, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard !node.isFolder, let parts = MegaCrypto.unpack(fileKey: node.key) else {
            throw CloudError.message(L("Este archivo de Mega no se puede descargar porque su clave no es de esta cuenta."))
        }
        guard let answer = try await megaCall(["a": "g", "g": 1, "n": node.handle]) as? [String: Any],
              let address = answer["g"] as? String else {
            throw CloudError.message(L("Mega no devolvió la dirección de descarga."))
        }
        let size = (answer["s"] as? Double).map { Int64($0) } ?? node.size ?? 0
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CloudError.message(L("No se pudo crear el archivo de destino."))
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var macs: [Data] = []
        for chunk in MegaCrypto.chunks(of: size) {
            try Task.checkCancellation()
            guard let url = URL(string: "\(address)/\(chunk.offset)-\(chunk.offset + chunk.length - 1)") else {
                throw CloudError.message(L("Mega no devolvió la dirección de descarga."))
            }
            let (data, response) = try await session.data(from: url)
            try HTTP.validate(response, data: data)
            guard data.count == Int(chunk.length) else {
                throw CloudError.message(L("Mega envió un trozo incompleto del archivo."))
            }
            let offset = chunk.offset
            let plain = try await blockingIO { try MegaCrypto.ctr(data, key: parts.key, nonce: parts.nonce, blockOffset: UInt64(offset / 16)) }
            try output.write(contentsOf: plain)
            macs.append(try await blockingIO { try MegaCrypto.chunkMAC(plain, key: parts.key, nonce: parts.nonce) })
            progress(chunk.offset + chunk.length, size)
        }
        // The expected MAC travels inside the file's own key, so a corrupted or tampered download is caught here.
        let computed = try await blockingIO { try MegaCrypto.metaMAC(chunks: macs, key: parts.key) }
        guard computed == parts.mac else {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw CloudError.message(L("El archivo descargado de Mega no supera su comprobación de integridad."))
        }
    }

    func megaUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let state = try await megaTree()
        let target = try megaHandle(parent, in: state)
        let total = cursor.total
        guard let answer = try await megaCall(["a": "u", "s": total]) as? [String: Any],
              let address = answer["p"] as? String else {
            throw CloudError.message(L("Mega no aceptó la subida."))
        }
        // Mega has no resumable upload for third parties, so a restart begins again from zero.
        cursor.offset = 0; cursor.url = nil; try save(cursor)

        let material = MegaCrypto.randomKey(count: 24)
        let key = Data(material.prefix(16))
        let nonce = Data(material.suffix(8))
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }

        var macs: [Data] = []
        var token: String?
        var sent: Int64 = 0
        let pieces = MegaCrypto.chunks(of: total)
        for chunk in (pieces.isEmpty ? [(offset: Int64(0), length: Int64(0))] : pieces) {
            try Task.checkCancellation()
            let plain = try await blockingIO { try input.read(upToCount: Int(chunk.length)) ?? Data() }
            guard plain.count == Int(chunk.length) else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            let offset = chunk.offset
            let cipher = try await blockingIO { try MegaCrypto.ctr(plain, key: key, nonce: nonce, blockOffset: UInt64(offset / 16)) }
            if !plain.isEmpty { macs.append(try await blockingIO { try MegaCrypto.chunkMAC(plain, key: key, nonce: nonce) }) }

            guard let url = URL(string: "\(address)/\(chunk.offset)") else { throw CloudError.message(L("Mega no aceptó la subida.")) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: request, from: cipher)
            try HTTP.validate(response, data: data)
            // The last chunk answers with the token that turns the uploaded bytes into a node.
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                guard !text.hasPrefix("-") else { throw MegaAPI.failure(Int(text) ?? -1) }
                token = text
            }
            sent += chunk.length
            cursor.offset = sent; try save(cursor)
            progress(sent, total)
        }
        guard let token else { throw CloudError.message(L("Mega no confirmó la subida.")) }

        let mac = try MegaCrypto.metaMAC(chunks: macs, key: key)
        let packed = MegaCrypto.pack(key: key, nonce: nonce, mac: mac)
        let entry: [String: Any] = ["h": token, "t": 0,
                                    "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": name], key: key)),
                                    "k": MegaCrypto.encode(try MegaCrypto.ecb(packed, key: state.masterKey, encrypt: true))]
        let created = try await megaCall(["a": "p", "t": target, "n": [entry]])
        megaChanged()
        guard let node = ((created as? [String: Any])?["f"] as? [[String: Any]])?.first,
              let handle = node["h"] as? String else {
            throw CloudError.message(L("Mega no devolvió el archivo subido."))
        }
        // Mega never overwrites, so the previous version is replaced by putting it in the bin, where it is recoverable.
        if let replacing, let old = state.nodes[replacing], !state.trash.isEmpty, old.parent != state.trash {
            _ = try? await megaCall(["a": "m", "n": old.handle, "t": state.trash])
        }
        cursor.offset = total; cursor.complete = true; try save(cursor)
        // Mega stores the MAC that iCloudy itself computed, so there is no independent value to compare against.
        return UploadReceipt(remoteID: handle, verification: .unavailable)
    }
}
