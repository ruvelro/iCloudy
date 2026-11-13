import Foundation
import CryptoKit

/// Telegram, through the Bot API and a private channel the person owns.
///
/// It is the odd one out among these providers. The others browse storage that already has folders, names and
/// dates; Telegram has a channel full of messages and nothing else. So iCloudy brings the file system with it: a
/// JSON index, pinned in the channel, saying which messages make up which file and where it sits in the tree.
///
/// Two consequences follow from that, one good and one bad.
///
/// The good one: renaming, moving, copying and searching are changes to a local index, so they are instant and move
/// no bytes at all. Copying a four-gigabyte file duplicates a list of identifiers. Search needs no request.
///
/// The bad one: **the bot is the key**. A `file_id` belongs to the bot that uploaded it, the Bot API offers no way
/// to read a message by its identifier, and a bot cannot read the history of a channel. Delete the bot and the
/// messages are still in the channel — visible and downloadable from the Telegram app — but iCloudy can no longer
/// reach them. The connection sheet says so before anything is uploaded.
///
/// And the ceiling that shapes everything: a bot downloads at most 20 MB per `getFile`, whatever it managed to
/// upload. Every file is therefore cut into parts of `TelegramLimits.part`, however small the file.
@MainActor
final class TelegramProvider: CloudSession, CloudProvider {
    /// Open channel: the bot token, the tree read from the pinned index and where that index lives.
    var telegramStateCache: TelegramSession?
    /// The index read in flight, so two listings started at once do not both fetch and parse the whole tree.
    var telegramIndexTask: Task<TelegramSession, Error>?
    /// Telegram pushes nothing: another Mac writing to the channel is only noticed by reading the index again.
    override func dropCaches() { telegramStateCache?.loaded = false }
    override func invalidate() {
        super.invalidate()
        telegramIndexTask?.cancel(); telegramIndexTask = nil; telegramStateCache = nil
    }
}

extension TelegramProvider {
    // MARK: - Session

    /// The channel this account browses. It is not a secret, so it lives beside the account and not in the Keychain.
    var telegramChat: String { account.options["chat"] ?? "" }

    /// Restores the bot token from the Keychain. There is nothing to refresh: a bot token lasts until its owner
    /// revokes it in BotFather, and when that happens no amount of retrying brings it back.
    func telegramSession() throws -> TelegramSession {
        guard !invalidated else { throw CancellationError() }
        if let telegramStateCache { return telegramStateCache }
        guard let credential = try credentials.read(account.credentialKey), !credential.accessToken.isEmpty,
              !telegramChat.isEmpty else {
            throw CloudError.sessionExpired(L("Falta el token del bot de Telegram. Vuelve a conectar la cuenta."))
        }
        let state = TelegramSession(token: credential.accessToken, chatID: telegramChat)
        state.adopt(bookmark: credential.secret)
        telegramStateCache = state
        return state
    }
    /// Writes back where the index was last seen. Without this, a Mac that had to re-pin the index would have to do
    /// it again on every launch.
    func telegramPersist(_ state: TelegramSession) {
        guard state.renewed else { return }
        state.renewed = false
        guard var credential = try? credentials.read(account.credentialKey) else { return }
        credential.secret = state.bookmark
        try? credentials.save(credential, key: account.credentialKey)
    }

    /// Runs one exchange with Telegram, waiting out a rate limit the way Telegram itself asks to be waited out.
    ///
    /// `repeatable` is false for anything that posts a message: a 429 means the message was refused and can be sent
    /// again, but a 5xx may have been applied before the failure came back, and a repeated part is a duplicate
    /// nobody would ever notice except as wasted space.
    func telegramRetrying<T>(repeatable: Bool, _ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await work() }
            catch let failure as TelegramAPI.Failure {
                if failure.isRevoked {
                    expireSession(failure.detail)
                    throw CloudError.sessionExpired(L("Telegram ya no acepta a este bot: \(failure.detail). Comprueba que sigue siendo administrador del canal y vuelve a conectar la cuenta."))
                }
                let retryable = failure.code == 429 || (repeatable && (500..<600).contains(failure.status))
                guard retryable, attempt < 3 else { throw CloudError.message(failure.detail) }
                let wait = failure.retryAfter ?? min(pow(2, Double(attempt)), 8)
                guard wait <= TelegramLimits.maxBackoff else {
                    throw CloudError.message(L("Telegram pide esperar \(Int(wait)) segundos antes de seguir con esta cuenta. Inténtalo más tarde."))
                }
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    /// One Bot API call, with its parameters in the query string. Telegram accepts GET for every method, which
    /// keeps everything that is not an upload to a single line.
    @discardableResult
    func telegramCall(_ method: String, query: [URLQueryItem], repeatable: Bool = true) async throws -> [String: Any] {
        let state = try telegramSession()
        guard let url = TelegramAPI.endpoint(token: state.token, method: method, query: query) else {
            throw CloudError.message(L("No se pudo construir la petición a Telegram."))
        }
        return try await telegramRetrying(repeatable: repeatable) {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            Diagnostics.stamp(&request, account: account)
            let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
            return try TelegramAPI.result(data, response: response, token: state.token)
        }
    }
    /// One multipart call: the two that carry bytes, `sendDocument` and `editMessageMedia`. Both post a message to
    /// the channel, so both go through the pacing that keeps the bot under twenty messages a minute.
    func telegramSend(_ method: String, envelope: URL, boundary: String, state: TelegramSession,
                      reporter: RedirectGuard = RedirectGuard.shared) async throws -> [String: Any] {
        guard let url = TelegramAPI.endpoint(token: state.token, method: method) else {
            throw CloudError.message(L("No se pudo construir la petición a Telegram."))
        }
        return try await telegramRetrying(repeatable: false) {
            try Task.checkCancellation()
            try await state.pace()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            Diagnostics.stamp(&request, account: account)
            let (data, response) = try await session.upload(for: request, fromFile: envelope, delegate: reporter)
            return try TelegramAPI.result(data, response: response, token: state.token)
        }
    }
    /// Fetches a whole file by its identifier, into memory. Used for the index and for one part at a time, which is
    /// bounded by the very ceiling that forces the parts to exist.
    func telegramFetch(fileID: String, state: TelegramSession) async throws -> Data {
        let answer = try await telegramCall("getFile", query: [URLQueryItem(name: "file_id", value: fileID)])
        guard let path = answer["file_path"] as? String,
              let url = TelegramAPI.contentURL(token: state.token, path: path) else {
            throw CloudError.message(L("Telegram no dijo dónde está ese archivo."))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.cachePolicy = .reloadIgnoringLocalCacheData
        Diagnostics.stamp(&request, account: account)
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.message(L("Telegram no entregó el contenido de ese archivo. La dirección caduca en una hora; vuelve a intentarlo."))
        }
        return data
    }

    // MARK: - The index

    /// The message that holds the index, if the one given is it. Anything else pinned in the channel is not.
    nonisolated static func telegramIndexDocument(_ message: [String: Any]?) -> [String: Any]? {
        guard let document = message?["document"] as? [String: Any],
              document["file_name"] as? String == TelegramLimits.indexName else { return nil }
        return document
    }

    /// The tree, read once per session and kept until the account is disconnected or "Actualizar" drops it.
    ///
    /// Only one read runs at a time: opening the app starts a listing and a search index together, and both want
    /// the tree.
    @discardableResult
    func telegramTree() async throws -> TelegramSession {
        let state = try telegramSession()
        if state.loaded { return state }
        if let running = telegramIndexTask { return try await running.value }
        let task = Task { try await telegramLoadIndex(state) }
        telegramIndexTask = task
        defer { telegramIndexTask = nil }
        return try await task.value
    }
    private func telegramLoadIndex(_ state: TelegramSession) async throws -> TelegramSession {
        let chatQuery = [URLQueryItem(name: "chat_id", value: state.chatID)]
        let opened = try await telegramCall("getChat", query: chatQuery)
        var pinned = opened["pinned_message"] as? [String: Any]

        // Somebody pinned something else in the channel. The index message is still there and iCloudy remembers
        // which one it is, so it is pinned again rather than declared missing and quietly replaced by an empty
        // tree, which is the one failure here that would lose an entire account's worth of files.
        if Self.telegramIndexDocument(pinned) == nil, let remembered = state.indexMessage {
            _ = try? await telegramCall("pinChatMessage", query: chatQuery + [
                URLQueryItem(name: "message_id", value: String(remembered)),
                URLQueryItem(name: "disable_notification", value: "true")], repeatable: false)
            let again = try await telegramCall("getChat", query: chatQuery)
            pinned = again["pinned_message"] as? [String: Any]
        }

        guard let pinned else {
            // Nothing pinned at all: a channel iCloudy has not used yet.
            state.index = TelegramIndex()
            state.indexMessage = nil; state.indexFingerprint = nil
            state.loaded = true
            return state
        }
        guard let document = Self.telegramIndexDocument(pinned), let fileID = document["file_id"] as? String else {
            throw CloudError.message(L("El mensaje fijado del canal no es el índice de iCloudy. Vuelve a fijar el mensaje «icloudy-index.json», o conecta un canal vacío."))
        }
        state.index = try TelegramIndex.decode(try await telegramFetch(fileID: fileID, state: state))
        let message = pinned["message_id"] as? Int
        let fingerprint = document["file_unique_id"] as? String
        // Only a change is worth a Keychain write; opening an account that is where it was left costs nothing.
        if state.indexMessage != message || state.indexFingerprint != fingerprint {
            state.indexMessage = message
            state.indexFingerprint = fingerprint
            state.renewed = true
        }
        state.loaded = true
        telegramPersist(state)
        return state
    }

    /// Changes the tree and writes it back, restoring the previous one if the write does not land. Without this a
    /// refused write left iCloudy showing a folder that existed only in its own memory.
    @discardableResult
    func telegramApply<T>(_ state: TelegramSession, _ change: (inout TelegramIndex) throws -> T) async throws -> T {
        let previous = state.index
        do {
            let result = try change(&state.index)
            try await telegramCommit(state)
            return result
        } catch {
            state.index = previous
            throw error
        }
    }

    /// Writes the index back to its pinned message.
    ///
    /// Before overwriting, it checks that the pinned document is still the one this Mac read. Two Macs on the same
    /// channel would otherwise take turns erasing each other's changes, and neither would ever be told.
    func telegramCommit(_ state: TelegramSession) async throws {
        state.index.updated = Date()
        let data = try state.index.encode()
        guard Int64(data.count) < TelegramLimits.indexCeiling else {
            throw CloudError.message(L("El índice de este canal ha superado los 19 MB, que es lo máximo que un bot puede descargar. El cambio no se ha guardado: reparte los archivos en otro canal."))
        }
        let boundary = "iCloudy-" + UUID().uuidString
        let answer: [String: Any]

        if let existing = state.indexMessage {
            try await telegramVerifyIndexIsCurrent(state, message: existing)
            let media = ["type": "document", "media": "attach://index"]
            let described = String(decoding: try JSONSerialization.data(withJSONObject: media, options: [.sortedKeys]), as: UTF8.self)
            let envelope = try await TelegramAPI.envelope(
                fields: ["chat_id": state.chatID, "message_id": String(existing), "media": described],
                part: "index", filename: TelegramLimits.indexName, mime: "application/json",
                body: .bytes(data), boundary: boundary)
            defer { try? FileManager.default.removeItem(at: envelope) }
            answer = try await telegramSend("editMessageMedia", envelope: envelope, boundary: boundary, state: state)
        } else {
            let envelope = try await TelegramAPI.envelope(
                fields: ["chat_id": state.chatID, "disable_notification": "true",
                         "disable_content_type_detection": "true"],
                part: "document", filename: TelegramLimits.indexName, mime: "application/json",
                body: .bytes(data), boundary: boundary)
            defer { try? FileManager.default.removeItem(at: envelope) }
            answer = try await telegramSend("sendDocument", envelope: envelope, boundary: boundary, state: state)
            guard let created = answer["message_id"] as? Int else {
                throw CloudError.message(L("Telegram no devolvió el mensaje del índice."))
            }
            // Pinning is what makes the index findable from another Mac: it is the only message the Bot API can
            // reach without knowing its identifier beforehand.
            try await telegramCall("pinChatMessage", query: [
                URLQueryItem(name: "chat_id", value: state.chatID),
                URLQueryItem(name: "message_id", value: String(created)),
                URLQueryItem(name: "disable_notification", value: "true")], repeatable: false)
        }

        guard let document = Self.telegramIndexDocument(answer), let message = answer["message_id"] as? Int else {
            throw CloudError.message(L("Telegram aceptó el índice pero no lo devolvió. Actualiza la cuenta antes de seguir cambiando nada."))
        }
        state.indexMessage = message
        state.indexFingerprint = document["file_unique_id"] as? String
        state.renewed = true
        telegramPersist(state)
    }
    /// Refuses to write over an index somebody else has changed since this one was read.
    private func telegramVerifyIndexIsCurrent(_ state: TelegramSession, message: Int) async throws {
        let chat = try await telegramCall("getChat", query: [URLQueryItem(name: "chat_id", value: state.chatID)])
        let pinned = chat["pinned_message"] as? [String: Any]
        guard let document = Self.telegramIndexDocument(pinned), pinned?["message_id"] as? Int == message,
              document["file_unique_id"] as? String == state.indexFingerprint else {
            throw CloudError.message(L("El índice del canal ha cambiado desde que se leyó: otro equipo ha escrito en él. Pulsa «Actualizar» y repite la operación; no se ha modificado nada."))
        }
    }

    // MARK: - Browsing

    nonisolated static func telegramFile(_ node: TelegramNode) -> CloudFile {
        CloudFile(id: node.id, name: node.name,
                  mime: node.folder ? "application/vnd.google-apps.folder" : node.mime,
                  size: node.folder ? nil : node.size, modified: node.modified, webURL: nil, isFolder: node.folder)
    }
    func telegramList(parent: String) async throws -> [CloudFile] {
        let state = try await telegramTree()
        return Self.sorted(state.index.children(of: parent).map(Self.telegramFile))
    }
    func telegramTrail(id: String) async throws -> [CloudFile] {
        let state = try await telegramTree()
        var trail: [CloudFile] = [], current = id, steps = 0
        while current != "root", steps < 64, let node = state.index.node(current) {
            trail.append(Self.telegramFile(node))
            current = node.parent
            steps += 1
        }
        return trail.reversed()
    }
    /// The tree is already here, so search costs no request at all.
    func telegramSearch(term: String) async throws -> SearchPage {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SearchPage(hits: [], next: nil) }
        let state = try await telegramTree()
        let hits = state.index.nodes
            .filter { $0.deleted == nil && $0.name.localizedCaseInsensitiveContains(needle) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(500)
            .map { SearchHit(accountID: account.id, file: Self.telegramFile($0), parentID: $0.parent) }
        return SearchPage(hits: Array(hits), next: nil)
    }
    /// Telegram publishes no quota for what a channel holds, so none is invented.
    func telegramQuota() async throws -> StorageQuota {
        throw CloudError.message(L("Telegram no informa del espacio disponible: su almacenamiento no tiene una cuota que consultar."))
    }

    // MARK: - Changing things

    private func telegramFolder(_ id: String, in index: TelegramIndex) throws -> String {
        guard id == "root" || index.node(id)?.folder == true else {
            throw CloudError.message(L("Ese destino no es una carpeta de Telegram."))
        }
        return id
    }
    func telegramCreateFolder(name: String, parent: String) async throws -> String {
        let state = try await telegramTree()
        return try await telegramApply(state) { index in
            let target = try telegramFolder(parent, in: index)
            let node = TelegramNode(id: UUID().uuidString, parent: target, name: name, folder: true)
            index.replace(node)
            return node.id
        }
    }
    func telegramRename(file: CloudFile, name: String) async throws {
        let state = try await telegramTree()
        try await telegramApply(state) { index in
            guard var node = index.node(file.id) else {
                throw CloudError.message(L("Ese elemento de Telegram ya no existe."))
            }
            node.name = name
            if !node.folder { node.mime = Self.mime(forName: name) }
            index.replace(node)
        }
    }
    func telegramMove(file: CloudFile, to destination: String) async throws {
        let state = try await telegramTree()
        try await telegramApply(state) { index in
            guard var node = index.node(file.id) else {
                throw CloudError.message(L("Ese elemento de Telegram ya no existe."))
            }
            let target = try telegramFolder(destination, in: index)
            guard !index.wouldLoop(file.id, into: target) else {
                throw CloudError.message(L("No se puede mover una carpeta dentro de sí misma."))
            }
            node.parent = target
            index.replace(node)
        }
    }
    /// Copying duplicates entries, not bytes: the copy points at the very same messages. It costs one index write
    /// and nothing else, whatever the file weighs.
    func telegramCopy(file: CloudFile, to destination: String) async throws {
        let state = try await telegramTree()
        try await telegramApply(state) { index in
            guard let source = index.node(file.id) else {
                throw CloudError.message(L("Ese elemento de Telegram ya no existe."))
            }
            let target = try telegramFolder(destination, in: index)
            guard !index.wouldLoop(file.id, into: target) else {
                throw CloudError.message(L("No se puede copiar una carpeta dentro de sí misma."))
            }
            // `subtree` hands back parents before their children, so the new parent is always already mapped.
            var mapping = [source.parent: target]
            for node in index.subtree(of: source.id) {
                var copy = node
                copy.id = UUID().uuidString
                copy.parent = mapping[node.parent] ?? target
                mapping[node.id] = copy.id
                index.nodes.append(copy)
            }
            index.updated = Date()
        }
    }
    /// Sends an item to the bin: its entry is marked, and it stops being listed. **The messages are not deleted.**
    /// They stay in the channel, visible and downloadable from the Telegram app, which is what makes this
    /// reversible. Nothing in iCloudy ever deletes a message from a channel.
    func telegramTrash(file: CloudFile) async throws {
        let state = try await telegramTree()
        try await telegramApply(state) { index in
            guard index.node(file.id) != nil else {
                throw CloudError.message(L("Ese elemento de Telegram ya no existe."))
            }
            let stamp = Date()
            for node in index.subtree(of: file.id) {
                var marked = node
                marked.deleted = stamp
                index.replace(marked)
            }
        }
    }

    // MARK: - Contents

    func telegramDownload(file: CloudFile, to destination: URL, maxBytes: Int64?,
                          progress: @escaping (Int64, Int64) -> Void) async throws {
        let state = try await telegramTree()
        guard let node = state.index.node(file.id), !node.folder else {
            throw CloudError.message(L("Ese elemento de Telegram ya no existe."))
        }
        // The size is known before a single byte is asked for, so a preview over the limit is refused for free.
        if let maxBytes, node.size > maxBytes {
            throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
        }
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CloudError.message(L("No se pudo crear el archivo de destino."))
        }
        let output = try FileHandle(forWritingTo: destination)
        var hasher = SHA256()
        var written: Int64 = 0
        // A part that never arrives must not leave half a file behind wearing the name of a whole one.
        var finished = false
        defer {
            try? output.close()
            if !finished { try? FileManager.default.removeItem(at: destination) }
        }
        for part in node.parts {
            try Task.checkCancellation()
            let data = try await telegramFetch(fileID: part.fileID, state: state)
            guard Int64(data.count) == part.size else {
                throw CloudError.message(L("Telegram entregó un trozo de «\(node.name)» con un tamaño distinto del anotado. La descarga se detiene sin dejar un archivo a medias."))
            }
            hasher.update(data: data)
            try output.write(contentsOf: data)
            written += Int64(data.count)
            progress(written, node.size)
        }
        // Telegram reports no checksum, so this compares against the digest iCloudy took of the bytes it sent. It
        // is the only provider here where the verification on the way down is as real as the one on the way up.
        if let expected = node.sha256, UploadHasher.hex(hasher.finalize()) != expected {
            throw CloudError.message(L("Lo descargado de «\(node.name)» no coincide con la huella anotada al subirlo. Puede estar dañado en el canal; no se conserva la copia."))
        }
        finished = true
        progress(written, node.size)
    }

    /// Uploads a file as a run of documents in the channel, then writes the index that ties them together.
    ///
    /// The checkpoint carries the parts already accepted, so a resumed transfer sends only what is missing — the
    /// unit of resumption is one part, `TelegramLimits.part`, and not one byte. The digest is taken in a pass of
    /// its own over the local file, which costs a read from disk and nothing on the network, and is what makes a
    /// resumed upload verifiable at all: the earlier parts left this Mac in another run.
    func telegramUpload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                        save: (UploadCheckpoint) throws -> Void,
                        progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let state = try await telegramTree()
        let target = try telegramFolder(parent, in: state.index)
        let total = cursor.total
        cursor.chunkSize = TelegramLimits.part
        var parts = cursor.parts.compactMap(Self.telegramPart)
        guard parts.count == cursor.parts.count else {
            throw CloudError.message(L("El punto de reanudación de esta subida no se entiende. Cancélala y empieza de nuevo."))
        }
        // An empty file has nothing to send: Telegram refuses a document with no bytes. It is an entry and no more.
        if total > 0 {
            let expected = Int(((total - 1) / TelegramLimits.part) + 1)
            progress(cursor.offset, total)
            while cursor.offset < total {
                try Task.checkCancellation()
                let current = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard Int64(current.fileSize ?? 0) == total, current.contentModificationDate == cursor.modified else {
                    throw CloudError.message(L("El archivo cambió durante la subida."))
                }
                let length = min(TelegramLimits.part, total - cursor.offset)
                let number = parts.count + 1
                // One part keeps the file's own name, so a single document is recognisable from Telegram itself.
                // Several are numbered, which is what makes a manual rescue possible if the bot is ever lost.
                let label = expected == 1 ? name : "\(name).\(String(format: "%03d", number))"
                let boundary = "iCloudy-" + UUID().uuidString
                let envelope = try await TelegramAPI.envelope(
                    fields: ["chat_id": state.chatID, "disable_notification": "true",
                             "disable_content_type_detection": "true"],
                    part: "document", filename: label, mime: "application/octet-stream",
                    body: .window(local, offset: cursor.offset, length: length), boundary: boundary)
                defer { try? FileManager.default.removeItem(at: envelope) }
                let reporter = TelegramUploadReporter(base: cursor.offset, total: total, progress: progress)
                let answer = try await telegramSend("sendDocument", envelope: envelope, boundary: boundary,
                                                    state: state, reporter: reporter)
                guard let document = answer["document"] as? [String: Any],
                      let fileID = document["file_id"] as? String,
                      let message = answer["message_id"] as? Int else {
                    throw CloudError.message(L("Telegram aceptó un trozo de la subida pero no dijo cuál. Cancela la transferencia y vuelve a empezar."))
                }
                let stored = (document["file_size"] as? NSNumber)?.int64Value ?? length
                guard stored == length else {
                    throw CloudError.message(L("Telegram guardó un trozo de «\(name)» con un tamaño distinto del enviado. La subida se detiene."))
                }
                let sent = TelegramPart(fileID: fileID, messageID: message, size: length)
                parts.append(sent)
                cursor.parts.append(Self.telegramFragment(sent))
                cursor.offset += length
                try save(cursor)
                progress(cursor.offset, total)
            }
        }

        // The digest covers the whole file, including parts sent before this run, so it is taken here and not as
        // the bytes go by.
        let digest = try await Self.telegramDigest(of: local)
        let node = TelegramNode(id: UUID().uuidString, parent: target, name: name, folder: false,
                                size: total, mime: Self.mime(forName: name),
                                modified: cursor.modified ?? Date(), sha256: digest, parts: parts)
        // A failed index write leaves the parts in the channel and the checkpoint pointing at them: retrying the
        // transfer repeats only this last step, and nothing is uploaded twice.
        try await telegramApply(state) { index in
            if let replacing, var previous = index.node(replacing) {
                // Replacing bins the old entry rather than deleting its messages: the previous version stays
                // recoverable from the Telegram app, like everything else this provider never really deletes.
                previous.deleted = Date()
                index.replace(previous)
            }
            index.replace(node)
        }
        cursor.complete = true
        try save(cursor)
        progress(total, total)
        // The checksum is iCloudy's own, over the very bytes that were sent, and the download checks against it.
        return UploadReceipt(remoteID: node.id, verification: .verified)
    }

    /// A private channel has no public address, and making one public would publish every file in it.
    func telegramPublicLink(for file: CloudFile) async throws -> URL {
        throw CloudError.message(L("Un canal privado de Telegram no tiene enlaces públicos. Reenvía el mensaje desde la app de Telegram a quien quieras."))
    }

    // MARK: - Odds and ends

    nonisolated static func telegramFragment(_ part: TelegramPart) -> String {
        let values: [String: Any] = ["file": part.fileID, "message": part.messageID, "size": part.size]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    nonisolated static func telegramPart(_ text: String) -> TelegramPart? {
        guard let data = text.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fileID = values["file"] as? String, let message = values["message"] as? Int,
              let size = (values["size"] as? NSNumber)?.int64Value else { return nil }
        return TelegramPart(fileID: fileID, messageID: message, size: size)
    }
    /// SHA-256 of a local file, read in blocks so nothing large sits in memory.
    nonisolated static func telegramDigest(of local: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try await blockingIO { try handle.read(upToCount: 4 * 1024 * 1024) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return UploadHasher.hex(hasher.finalize())
    }
}

extension TelegramProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        try await telegramList(parent: parent)
    }
    func createFolder(name: String, parent: String) async throws -> String {
        try await telegramCreateFolder(name: name, parent: parent)
    }
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        // Telegram needs one request per part, and its addresses are handed out by `getFile` an hour at a time;
        // `download` never reaches here.
        throw CloudError.message(L("Este proveedor no usa peticiones HTTP."))
    }
    func rename(file: CloudFile, name: String) async throws {
        try await telegramRename(file: file, name: name)
    }
    func move(file: CloudFile, to destination: String) async throws {
        try await telegramMove(file: file, to: destination)
    }
    /// Nothing is sent: the copy points at the very same messages the original does.
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        try await telegramCopy(file: file, to: destination)
    }
    func trash(file: CloudFile) async throws {
        try await telegramTrash(file: file)
    }
    func publicLink(for file: CloudFile) async throws -> URL {
        try await telegramPublicLink(for: file)
    }
    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        try await telegramSearch(term: term)
    }
    func folderTrail(id: String) async throws -> [CloudFile] {
        try await telegramTrail(id: id)
    }
    func storageQuota() async throws -> StorageQuota {
        try await telegramQuota()
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try await telegramUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await telegramDownload(file: file, to: destination, maxBytes: maxBytes, progress: progress)
    }
}
