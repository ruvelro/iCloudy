import Foundation

/// Mega, using the same unofficial API its own web client speaks. Mega publishes no specification and no stable
/// contract for third parties, so this provider is marked experimental in the interface: it can stop working after a
/// change on Mega's side that no release note announces.
///
/// What is different from every other provider here is that the server holds no readable data. Names, folder
/// structure and contents are encrypted under a key derived from the password, so the tree arrives as ciphertext and
/// is decrypted on this Mac. That has two happy consequences: the whole tree comes in one response, which makes
/// search and breadcrumbs free, and downloads are verified against a MAC stored inside each file's own key.
@MainActor
final class MegaProvider: CloudSession, CloudProvider {
    var megaStateCache: MegaState?
    var megaTreeTask: Task<MegaState, Error>?
    override func dropCaches() { megaStateCache?.expire() }
    override func invalidate() {
        super.invalidate()
        megaTreeTask?.cancel(); megaTreeTask = nil; megaStateCache = nil
    }
}

extension MegaProvider {
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
            if case CloudError.sessionExpired(let reason) = error { expireSession(reason) }
            throw error
        }
    }
    /// How long a fetched tree is trusted. Changes made from iCloudy are applied in place, but Mega does not push
    /// what other devices do, so a tree this old is fetched again on the next listing.
    static let megaTreeMaxAge: TimeInterval = 5 * 60
    /// The whole tree, fetched once and kept until something changes it, "Actualizar" asks for it, or it grows old.
    ///
    /// Only one fetch runs at a time. Opening the app starts a listing and a quota check together, and both wanted
    /// the tree: on a large account that meant downloading and decrypting the whole thing twice, side by side.
    @discardableResult
    func megaTree() async throws -> MegaState {
        let state = try await megaSession()
        let stale = state.loadedAt.map { Date().timeIntervalSince($0) > Self.megaTreeMaxAge } ?? true
        guard !state.loaded || stale else { return state }
        if let running = megaTreeTask { return try await running.value }
        let task = Task { try await megaFetchTree(state) }
        megaTreeTask = task
        defer { megaTreeTask = nil }
        return try await task.value
    }
    private func megaFetchTree(_ state: MegaState) async throws -> MegaState {
        guard let answer = try await megaCall(["a": "f", "c": 1, "r": 1]) as? [String: Any],
              let files = answer["f"] as? [[String: Any]] else {
            throw CloudError.message(L("Mega no devolvió el contenido de la cuenta."))
        }
        // `ok` carries the keys of the folders other accounts have shared in. Without them those items decrypt to
        // nothing and every one of them reads as unavailable.
        let shares = answer["ok"] as? [[String: Any]] ?? []
        let masterKey = state.masterKey
        state.adopt(try await blockingIO { MegaAPI.tree(files, masterKey: masterKey, shares: shares) })
        guard !state.root.isEmpty else { throw CloudError.message(L("No se encontró la raíz de la cuenta de Mega.")) }
        return state
    }
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
        if parent == Collection.trash.rootID {
            guard !state.trash.isEmpty else { throw CloudError.message(L("Esta cuenta de Mega no tiene papelera.")) }
        }
        let handle = parent == Collection.trash.rootID ? state.trash : try megaHandle(parent, in: state)
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
            .prefix(501)
            .map { SearchHit(accountID: account.id, file: Self.megaFile($0), parentID: $0.parent) }
        return SearchPage(hits: Array(hits.prefix(500)), next: nil, incomplete: hits.count > 500)
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
        let key = try MegaCrypto.randomKey(count: 16)
        let node: [String: Any] = ["h": "xxxxxxxx", "t": 1,
                                   "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": name], key: key)),
                                   "k": MegaCrypto.encode(try MegaCrypto.ecb(key, key: state.masterKey, encrypt: true))]
        let answer = try await megaCall(["a": "p", "t": target, "n": [node]])
        let created = (answer as? [String: Any])?["f"] as? [[String: Any]] ?? []
        state.insert(created)
        guard let handle = created.first?["h"] as? String else {
            throw CloudError.message(L("Mega no devolvió la carpeta creada."))
        }
        return handle
    }
    func megaRename(file: CloudFile, name: String) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard node.isReadable else { throw CloudError.message(L("Este elemento no se puede renombrar porque su clave no es de esta cuenta.")) }
        // The whole attribute set goes back with the new name, not the name alone: the fingerprint and the labels
        // that MEGAsync wrote are part of the node, and dropping them made the official clients lose the real date.
        let attributes = try MegaCrypto.encodeAttributes(node.attributes(named: name), key: node.contentKey)
        _ = try await megaCall(["a": "a", "n": node.handle,
                                "attr": MegaCrypto.encode(attributes),
                                "key": MegaCrypto.encode(try MegaCrypto.ecb(node.key, key: state.masterKey, encrypt: true))])
        state.rename(node.handle, to: name)
    }
    func megaMove(file: CloudFile, to destination: String) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        let target = try megaHandle(destination, in: state)
        _ = try await megaCall(["a": "m", "n": node.handle, "t": target])
        state.reparent(node.handle, to: target)
    }
    /// Mega copies without moving any bytes: the same encrypted content is attached to a second node.
    func megaCopy(file: CloudFile, to destination: String) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard !node.isFolder else { throw CloudError.message(L("Mega solo copia archivos, no carpetas.")) }
        guard node.isReadable else { throw CloudError.message(L("Este elemento no se puede copiar porque su clave no es de esta cuenta.")) }
        let entry: [String: Any] = ["h": node.handle, "t": 0,
                                    "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(node.attributes(named: node.name), key: node.contentKey)),
                                    "k": MegaCrypto.encode(try MegaCrypto.ecb(node.key, key: state.masterKey, encrypt: true))]
        let answer = try await megaCall(["a": "p", "t": try megaHandle(destination, in: state), "n": [entry]])
        state.insert((answer as? [String: Any])?["f"] as? [[String: Any]] ?? [])
    }
    /// Deleting means moving to Mega's own bin, which the user can undo from mega.nz or from iCloudy's Papelera.
    func megaTrash(file: CloudFile) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard !state.trash.isEmpty else { throw CloudError.message(L("Esta cuenta de Mega no tiene papelera.")) }
        guard node.parent != state.trash else {
            throw CloudError.message(L("Ese elemento ya está en la papelera. Restáuralo o elimínalo definitivamente desde ahí."))
        }
        // Mega's own clients note where the node came from before binning it, so it can go back to the same place.
        // It is a courtesy, not the deletion: a failure here must not stop the move.
        if node.isReadable, node.parent != state.root {
            var attributes = node.attributes(named: node.name)
            attributes["rr"] = node.parent
            if let encoded = try? MegaCrypto.encodeAttributes(attributes, key: node.contentKey),
               let data = try? JSONSerialization.data(withJSONObject: attributes) {
                if (try? await megaCall(["a": "a", "n": node.handle, "attr": MegaCrypto.encode(encoded), "i": "iCloudy"])) != nil {
                    state.annotate(node.handle, attributeJSON: data)
                }
            }
        }
        _ = try await megaCall(["a": "m", "n": node.handle, "t": state.trash])
        state.reparent(node.handle, to: state.trash)
    }
    /// Back to the folder it was binned from when that folder is still in the tree, else to the root.
    func megaRestore(file: CloudFile) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard node.parent == state.trash else { throw CloudError.message(L("Ese elemento no está en la papelera de Mega.")) }
        var destination = state.root
        if let origin = node.restoreTo, let folder = state.nodes[origin], folder.isFolder, !megaInTrash(origin, in: state) { destination = origin }
        _ = try await megaCall(["a": "m", "n": node.handle, "t": destination])
        state.reparent(node.handle, to: destination)
    }
    private func megaInTrash(_ handle: String, in state: MegaState) -> Bool {
        var current = handle, hops = 0
        while let node = state.nodes[current], hops < 64 {
            if node.kind == 4 || current == state.trash { return true }
            current = node.parent; hops += 1
        }
        return false
    }
    /// `d` removes a node and its subtree for good, wherever it is.
    func megaDeletePermanently(file: CloudFile) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        _ = try await megaCall(["a": "d", "n": node.handle])
        state.remove(node.handle)
    }
    func megaEmptyTrash() async throws {
        let state = try await megaTree()
        guard !state.trash.isEmpty else { throw CloudError.message(L("Esta cuenta de Mega no tiene papelera.")) }
        for handle in state.children[state.trash] ?? [] {
            try Task.checkCancellation()
            _ = try await megaCall(["a": "d", "n": handle])
            state.remove(handle)
        }
    }
    func megaPublicLink(for file: CloudFile) async throws -> URL {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard node.isReadable else { throw CloudError.message(L("Este elemento no se puede compartir porque su clave no es de esta cuenta.")) }
        // A folder is not shared the way a file is. Mega creates a share with its own key, re-encrypts every child
        // key under it and puts that key in the link; the folder's own key, which is what this used to publish,
        // opens nothing. It is a flow that cannot be checked without a real account, so rather than hand out a link
        // that probably does not work, iCloudy says what it cannot do.
        guard !node.isFolder else {
            throw CloudError.message(L("Mega comparte una carpeta con una clave de compartición aparte, un paso que iCloudy todavía no sabe dar. Crea el enlace de la carpeta desde mega.nz; los archivos sueltos sí se comparten desde aquí."))
        }
        guard let handle = try await megaCall(["a": "l", "n": node.handle]) as? String else {
            throw CloudError.message(L("Mega no devolvió el enlace."))
        }
        // The key goes in the fragment, which browsers never send to the server: without it the link is unreadable.
        guard let url = URL(string: "https://mega.nz/file/\(handle)#\(MegaCrypto.encode(node.key))") else {
            throw CloudError.message(L("Mega no devolvió el enlace."))
        }
        return url
    }

    // MARK: - Contents

    func megaDownload(file: CloudFile, to destination: URL, maxBytes: Int64? = nil, progress: @escaping (Int64, Int64) -> Void) async throws {
        let state = try await megaTree()
        let node = try megaNode(file.id, in: state)
        guard !node.isFolder, let parts = MegaCrypto.unpack(fileKey: node.key) else {
            throw CloudError.message(L("Este archivo de Mega no se puede descargar porque su clave no es de esta cuenta."))
        }
        var (base, size) = try await megaTransferAddress(node)
        try DownloadBudget.check(size, maximum: maxBytes)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CloudError.message(L("No se pudo crear el archivo de destino."))
        }
        let output = try FileHandle(forWritingTo: destination)
        var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at: destination) } }

        var macs: [Data] = []
        for chunk in MegaCrypto.chunks(of: size) {
            try Task.checkCancellation()
            let data = try await megaChunk(chunk, from: &base, of: node)
            let offset = chunk.offset
            let plain = try await blockingIO { try MegaCrypto.ctr(data, key: parts.key, nonce: parts.nonce, blockOffset: UInt64(offset / 16)) }
            try output.write(contentsOf: plain)
            macs.append(try await blockingIO { try MegaCrypto.chunkMAC(plain, key: parts.key, nonce: parts.nonce) })
            progress(chunk.offset + chunk.length, size)
        }
        // The expected MAC travels inside the file's own key, so a corrupted or tampered download is caught here.
        let collected = macs
        let computed = try await blockingIO { try MegaCrypto.metaMAC(chunks: collected, key: parts.key) }
        guard computed == parts.mac else {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw CloudError.message(L("El archivo descargado de Mega no supera su comprobación de integridad."))
        }
        complete = true
    }

    /// Where the bytes of a file live right now, and how many there are. The address is temporary: Mega hands out one
    /// that stops working after a while, which is long enough for most files and not for a large one.
    private func megaTransferAddress(_ node: MegaNode) async throws -> (URL, Int64) {
        guard let answer = try await megaCall(["a": "g", "g": 1, "ssl": MegaAPI.useTLS, "n": node.handle]) as? [String: Any],
              let address = answer["g"] as? String, let base = CloudSession.secureURL(address) else {
            throw CloudError.message(L("Mega no devolvió la dirección de descarga."))
        }
        return (base, (answer["s"] as? Double).map { Int64($0) } ?? node.size ?? 0)
    }
    /// One chunk, with the patience the rest of this provider already has. A download used to fail outright on a
    /// moment's trouble: no retry, no way to notice the address had expired, and a transfer quota that had run out
    /// arrived as a bare HTTP code.
    private func megaChunk(_ chunk: (offset: Int64, length: Int64), from address: inout URL, of node: MegaNode) async throws -> Data {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            guard let url = URL(string: "\(address.absoluteString)/\(chunk.offset)-\(chunk.offset + chunk.length - 1)") else {
                throw CloudError.message(L("Mega no devolvió la dirección de descarga."))
            }
            do {
                let delegate = DownloadProgress(maxBytes: chunk.length) { _, _ in }
                let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try DownloadBudget.check(Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), maximum: chunk.length)
                let data = try Data(contentsOf: temporary)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 509 is Mega's own code for a free account that has spent its transfer allowance for the day.
                guard status != 509 else {
                    throw CloudError.message(L("La cuenta de Mega ha agotado su cuota de transferencia. Espera a que se renueve o descarga el archivo desde mega.nz."))
                }
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                guard data.count == Int(chunk.length) else { throw URLError(.networkConnectionLost) }
                return data
            } catch let error as URLError {
                guard attempt < 3 else { throw MegaAPI.unreachable(error) }
                // The address has a life of its own, shorter than a large download, so the next try asks for another.
                if let refreshed = try? await megaTransferAddress(node).0 { address = refreshed }
                try await Task.sleep(nanoseconds: MegaAPI.waitDelay(attempt))
            }
        }
        throw CloudError.message(L("Mega no entregó una parte de «\(node.name)» después de varios intentos."))
    }

    func megaUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let state = try await megaTree()
        if cursor.remoteID != nil {
            return try await megaFinishReplacement(state: state, cursor: &cursor, save: save)
        }
        let target = try megaHandle(parent, in: state)
        let total = cursor.total
        guard let answer = try await megaCall(["a": "u", "s": total, "ssl": MegaAPI.useTLS]) as? [String: Any],
              let address = (answer["p"] as? String).flatMap(CloudSession.secureURL) else {
            throw CloudError.message(L("Mega no aceptó la subida."))
        }
        // Mega has no resumable upload for third parties, so a restart begins again from zero.
        cursor.offset = 0; cursor.url = nil; try save(cursor)

        let material = try MegaCrypto.randomKey(count: 24)
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
            try cursor.sourceStamp?.validate(local)
            let plain = try await blockingIO { try input.read(upToCount: Int(chunk.length)) ?? Data() }
            try await TransferThrottle.upload(plain.count)
            try cursor.sourceStamp?.validate(local)
            guard plain.count == Int(chunk.length) else { throw CloudError.message(L("El tamaño del origen ha cambiado.")) }
            let offset = chunk.offset
            let cipher = try await blockingIO { try MegaCrypto.ctr(plain, key: key, nonce: nonce, blockOffset: UInt64(offset / 16)) }
            if !plain.isEmpty { macs.append(try await blockingIO { try MegaCrypto.chunkMAC(plain, key: key, nonce: nonce) }) }

            guard let url = URL(string: "\(address.absoluteString)/\(chunk.offset)") else {
                throw CloudError.message(L("Mega no aceptó la subida."))
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // The storage servers answer -3 when they are not ready for a piece, exactly as the API does. Giving up
            // on that would lose the whole upload over a moment's delay.
            var text = ""
            for attempt in 0..<5 {
                let (data, response) = try await session.upload(for: request, from: cipher, delegate: RedirectGuard.shared)
                try HTTP.validate(response, data: data)
                text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard text.hasPrefix("-") else { break }
                let code = Int(text) ?? -1
                guard code == -3, attempt < 4 else { throw MegaAPI.failure(code) }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
            // The last chunk answers with the token that turns the uploaded bytes into a node.
            if !text.isEmpty, !text.hasPrefix("-") { token = text }
            sent += chunk.length
            // No checkpoint in between: Mega has no resumable upload for third parties, so writing an offset here
            // would promise a restart that begins again from zero anyway.
            progress(sent, total)
        }
        guard let token else { throw CloudError.message(L("Mega no confirmó la subida.")) }

        let mac = try MegaCrypto.metaMAC(chunks: macs, key: key)
        let packed = MegaCrypto.pack(key: key, nonce: nonce, mac: mac)
        let entry: [String: Any] = ["h": token, "t": 0,
                                    "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": name], key: key)),
                                    "k": MegaCrypto.encode(try MegaCrypto.ecb(packed, key: state.masterKey, encrypt: true))]
        try cursor.sourceStamp?.validate(local)
        let created = try await megaCall(["a": "p", "t": target, "n": [entry]])
        let entries = (created as? [String: Any])?["f"] as? [[String: Any]] ?? []
        state.insert(entries)
        guard let handle = entries.first?["h"] as? String else {
            throw CloudError.message(L("Mega no devolvió el archivo subido."))
        }
        cursor.remoteID = handle
        cursor.pendingRetirementID = replacing
        cursor.offset = total
        try save(cursor)
        return try await megaFinishReplacement(state: state, cursor: &cursor, save: save)

    }
    private func megaFinishReplacement(state: MegaState, cursor: inout UploadCheckpoint,
                                       save: (UploadCheckpoint) throws -> Void) async throws -> UploadReceipt {
        if let old = cursor.pendingRetirementID {
            guard !state.trash.isEmpty else { throw CloudError.message(L("Mega no devolvió la papelera para retirar la versión anterior.")) }
            if state.nodes[old]?.parent != state.trash {
                _ = try await megaCall(["a": "m", "n": old, "t": state.trash])
                state.reparent(old, to: state.trash)
            }
        }
        cursor.pendingRetirementID = nil
        cursor.complete = true
        cursor.integrity = .unavailable
        try save(cursor)
        return UploadReceipt(remoteID: cursor.remoteID, verification: .unavailable)
    }

}

extension MegaProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        return try await megaList(parent: parent)
    }

    func createFolder(name: String, parent: String) async throws -> String {
        return try await megaCreateFolder(name: name, parent: parent)
    }

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        // None of them fetches with a plain request; `download` branches before reaching here.
                    throw CloudError.message(L("Este proveedor no usa peticiones HTTP."))
    }

    func rename(file: CloudFile, name: String) async throws {
        try await megaRename(file: file, name: name)
    }

    func move(file: CloudFile, to destination: String) async throws {
        try await megaMove(file: file, to: destination); return
    }

    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        try await megaCopy(file: file, to: destination); return
    }

    func trash(file: CloudFile) async throws {
        try await megaTrash(file: file); return
    }
    func restore(file: CloudFile) async throws { try await megaRestore(file: file) }
    func deletePermanently(file: CloudFile) async throws { try await megaDeletePermanently(file: file) }
    func emptyTrash() async throws { try await megaEmptyTrash() }

    func publicLink(for file: CloudFile) async throws -> URL {
        return try await megaPublicLink(for: file)
    }

    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        return try await megaSearch(term: term)
    }

    func folderTrail(id: String) async throws -> [CloudFile] {
        return try await megaTrail(id: id)
    }

    func storageQuota() async throws -> StorageQuota {
        return try await megaQuota()
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        return try await megaUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await megaDownload(file: file, to: destination, maxBytes: maxBytes, progress: progress)
    }
    func resumeCommittedUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt? {
        guard canResumeWithoutSource(checkpoint), var committed = checkpoint else { return nil }
        return try await megaUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &committed, save: save, progress: progress)
    }
}

extension MegaProvider {
    func canResumeWithoutSource(_ checkpoint: UploadCheckpoint?) -> Bool {
        guard let checkpoint else { return false }
        return checkpoint.remoteID != nil && !checkpoint.complete
    }
}
