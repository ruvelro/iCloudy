import Foundation

/// An unlocked vault, presented as a provider of its own. It wraps the provider of the folder the vault lives in and
/// translates every operation: names are encrypted and decrypted on the way through, contents are encrypted into a
/// temporary file before an upload and decrypted out of one after a download, and directories map to their
/// flattened storage folders under `d/`. Because it is a `CloudProvider`, the transfer queue, the preview and the
/// download checks work on it unchanged.
///
/// Item ids are made of the parent directory id and the stored node name, never of the underlying provider's ids:
/// `cm:F:<node>:<parent dirId>` for files and `cm:D:<node>:<parent dirId>` for folders. Renaming or moving a folder
/// therefore never changes the ids of what it contains, because those hang from its directory id, which never changes.
@MainActor
final class CryptomatorProvider: CloudSession, CloudProvider {
    static let dirFileName = "dir.c9r"
    static let dirIDBackupName = "dirid.c9r"
    static let longNameFileName = "name.c9s"
    static let longContentsFileName = "contents.c9r"
    static let folderMime = "application/vnd.google-apps.folder"

    /// The provider the vault is stored in. Asked for on every operation rather than captured, so reconnecting the
    /// underlying account does not leave the vault talking to a client that has been thrown away.
    private let base: () throws -> any CloudProvider
    /// The underlying id of the vault's folder.
    let vaultFolderID: String
    private var cryptor: CryptomatorCryptor?
    let shorteningThreshold: Int
    /// Called on every operation, so the vault can be locked after a while without use.
    var didUse: (() -> Void)?

    /// One entry of an encrypted directory.
    struct Node {
        enum Kind { case file, folder }
        let name: String
        let cleartext: String
        let kind: Kind
        /// The stored item: the file itself, or the folder of a directory or of a shortened name.
        let item: CloudFile
        /// For files, the stored bytes: the item itself, or `contents.c9r` inside a shortened name.
        let contents: CloudFile?
        /// The `dir.c9r` of a directory, when the listing already showed it.
        var dirFile: CloudFile?
    }

    private var storage: [String: CloudFile] = [:]         // dirId → its storage folder under d/XX/
    private var shards: [String: CloudFile] = [:]          // two-letter shard → folder under d/
    private var dataFolder: CloudFile?
    private var listings: [String: [String: Node]] = [:]   // dirId → node name → node
    private var directoryIDs: [String: String] = [:]       // folder item id → its dirId

    init(account: Account, base: @escaping () throws -> any CloudProvider, vaultFolderID: String, opened: CryptomatorVault.Opened) {
        self.base = base
        self.vaultFolderID = vaultFolderID
        self.cryptor = opened.cryptor
        self.shorteningThreshold = opened.config.shorteningThreshold
        super.init(account: account)
    }

    /// Forgets the keys. Every later call fails with "locked" instead of reaching the storage.
    func lock() {
        cryptor = nil
        listings = [:]; directoryIDs = [:]
    }
    var isLocked: Bool { cryptor == nil }
    override func invalidate() { super.invalidate(); lock() }
    override func dropCaches() {
        listings = [:]; storage = [:]; shards = [:]; dataFolder = nil
        (try? base())?.dropCaches()
    }
    override func token(force: Bool = false) async throws -> String { try await base().token(force: force) }

    private func keys() throws -> CryptomatorCryptor {
        guard let cryptor else { throw CryptomatorError.locked }
        didUse?()
        return cryptor
    }

    // MARK: - Ids

    static func itemID(_ kind: Node.Kind, node: String, parentDirID: String) -> String {
        "cm:" + (kind == .folder ? "D" : "F") + ":" + node + ":" + parentDirID
    }

    /// The parts of an item id. The directory id comes last because, unlike a node name, it may contain a colon.
    static func parse(_ id: String) -> (kind: Node.Kind, node: String, parentDirID: String)? {
        guard id.hasPrefix("cm:") else { return nil }
        let rest = id.dropFirst(3)
        guard let kindChar = rest.first, rest.dropFirst().first == ":" else { return nil }
        let afterKind = rest.dropFirst(2)
        guard let separator = afterKind.firstIndex(of: ":") else { return nil }
        let node = String(afterKind[..<separator]), parent = String(afterKind[afterKind.index(after: separator)...])
        guard !node.isEmpty, kindChar == "D" || kindChar == "F" else { return nil }
        return (kindChar == "D" ? .folder : .file, node, parent)
    }

    static func isRoot(_ id: String) -> Bool { id == "root" || id.isEmpty }

    // MARK: - Directories

    /// The directory id of a folder item, read from its `dir.c9r` the first time it is needed.
    func directoryID(of folder: String) async throws -> String {
        _ = try keys()
        if Self.isRoot(folder) { return "" }
        if let known = directoryIDs[folder] { return known }
        guard let parsed = Self.parse(folder), parsed.kind == .folder else { throw CloudError.message(L("Esa carpeta no pertenece a esta bóveda.")) }
        let node = try await self.node(named: parsed.node, in: parsed.parentDirID)
        let provider = try base()
        var dirFile = node.dirFile
        if dirFile == nil {
            dirFile = try await provider.list(parent: node.item.id, onPage: nil).first { !$0.isFolder && $0.name == Self.dirFileName }
        }
        guard let dirFile else {
            throw CloudError.message(L("«\(node.cleartext)» no es una carpeta que iCloudy pueda abrir: puede ser un enlace simbólico creado con Cryptomator."))
        }
        let data = try await CryptomatorStorage.download(dirFile, provider: provider, limit: 1024)
        guard let id = String(data: data, encoding: .utf8), !id.isEmpty, id.count <= 1024 else {
            throw CryptomatorError.malformed(L("el archivo dir.c9r de «\(node.cleartext)» no es válido."))
        }
        directoryIDs[folder] = id
        return id
    }

    /// The storage folder `d/XX/YYYY…` of a directory, created when asked to and missing.
    private func storageFolder(_ dirID: String, create: Bool = false) async throws -> CloudFile {
        if let known = storage[dirID] { return known }
        let cryptor = try keys(), provider = try base()
        let path = try cryptor.directoryPath(dirID)
        func child(_ name: String, of parent: String, create: Bool) async throws -> CloudFile {
            if let found = try await provider.list(parent: parent, onPage: nil).first(where: { $0.isFolder && $0.name == name }) { return found }
            guard create else { throw CryptomatorError.malformed(L("falta una carpeta cifrada; puede que no se haya terminado de sincronizar.")) }
            let id = try await provider.createFolder(name: name, parent: parent)
            return CloudFile(id: id, name: name, mime: Self.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
        }
        if dataFolder == nil { dataFolder = try await child(CryptomatorVault.dataName, of: vaultFolderID, create: create) }
        let shard: CloudFile
        if let known = shards[path.shard] { shard = known }
        else { shard = try await child(path.shard, of: dataFolder!.id, create: create); shards[path.shard] = shard }
        let folder = try await child(path.name, of: shard.id, create: create)
        storage[dirID] = folder
        return folder
    }

    /// Lists and decrypts one directory. Entries that do not decrypt are skipped: they are someone else's files, a
    /// conflict copy a sync client made, or damage, and none of them is a cleartext name to show.
    @discardableResult
    private func readDirectory(_ dirID: String) async throws -> [String: Node] {
        let cryptor = try keys(), provider = try base()
        let folder = try await storageFolder(dirID, create: dirID.isEmpty)
        var nodes: [String: Node] = [:]
        for child in try await provider.list(parent: folder.id, onPage: nil) where child.name != Self.dirIDBackupName {
            if child.name.hasSuffix(".c9r") {
                guard let clear = try? cryptor.decryptName(String(child.name.dropLast(4)), parentDirID: dirID) else { continue }
                nodes[child.name] = Node(name: child.name, cleartext: clear, kind: child.isFolder ? .folder : .file,
                                         item: child, contents: child.isFolder ? nil : child)
            } else if child.name.hasSuffix(".c9s"), child.isFolder {
                let inside = try await provider.list(parent: child.id, onPage: nil)
                guard let nameFile = inside.first(where: { !$0.isFolder && $0.name == Self.longNameFileName }),
                      let full = String(data: try await CryptomatorStorage.download(nameFile, provider: provider, limit: 64 * 1024), encoding: .utf8),
                      full.hasSuffix(".c9r"), CryptomatorCryptor.deflate(full) == child.name,
                      let clear = try? cryptor.decryptName(String(full.dropLast(4)), parentDirID: dirID) else { continue }
                if let contents = inside.first(where: { !$0.isFolder && $0.name == Self.longContentsFileName }) {
                    nodes[child.name] = Node(name: child.name, cleartext: clear, kind: .file, item: child, contents: contents)
                } else if let dirFile = inside.first(where: { !$0.isFolder && $0.name == Self.dirFileName }) {
                    nodes[child.name] = Node(name: child.name, cleartext: clear, kind: .folder, item: child, contents: nil, dirFile: dirFile)
                }
            }
        }
        listings[dirID] = nodes
        return nodes
    }

    private func node(named name: String, in dirID: String) async throws -> Node {
        if let node = listings[dirID]?[name] { return node }
        guard let node = try await readDirectory(dirID)[name] else {
            throw CloudError.message(L("El elemento ya no está en la bóveda. Actualiza la carpeta."))
        }
        return node
    }

    private func node(for id: String) async throws -> (node: Node, parentDirID: String) {
        guard let parsed = Self.parse(id) else { throw CloudError.message(L("Ese elemento no pertenece a esta bóveda.")) }
        return (try await node(named: parsed.node, in: parsed.parentDirID), parsed.parentDirID)
    }

    private func cloudFile(_ node: Node, parentDirID: String) -> CloudFile {
        let id = Self.itemID(node.kind, node: node.name, parentDirID: parentDirID)
        if node.kind == .folder {
            return CloudFile(id: id, name: node.cleartext, mime: Self.folderMime, size: nil, modified: node.item.modified, webURL: nil, isFolder: true)
        }
        // Cleartext size from the ciphertext size; a size no ciphertext can have is shown as unknown.
        let size = node.contents?.size.flatMap { cryptor?.cleartextSize(ciphertext: $0) }
        return CloudFile(id: id, name: node.cleartext, mime: Self.mime(forName: node.cleartext), size: size,
                         modified: node.contents?.modified ?? node.item.modified, webURL: nil, isFolder: false)
    }

    // MARK: - Listing

    func list(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        let dirID = try await directoryID(of: parent)
        let nodes = try await readDirectory(dirID)
        return Self.sorted(nodes.values.map { cloudFile($0, parentDirID: dirID) })
    }

    func currentMetadata(of file: CloudFile) async throws -> CloudFile? {
        guard let parsed = Self.parse(file.id) else { return nil }
        return try await readDirectory(parsed.parentDirID)[parsed.node].map { cloudFile($0, parentDirID: parsed.parentDirID) }
    }

    func rootID() async throws -> String { "root" }
    func folderTrail(id: String) async throws -> [CloudFile] {
        if Self.isRoot(id) { return [] }
        throw CloudError.message(L("Dentro de una bóveda solo se navega desde su carpeta raíz."))
    }
    func storageQuota() async throws -> StorageQuota { try await base().storageQuota() }

    // MARK: - Writing

    private func nodeName(_ name: String, in dirID: String) throws -> (node: String, full: String) {
        try keys().nodeName(name, parentDirID: dirID, threshold: shorteningThreshold)
    }

    private func forget(_ dirIDs: String...) { for id in dirIDs { listings[id] = nil } }

    func createFolder(name: String, parent: String) async throws -> String {
        let cryptor = try keys(), provider = try base()
        let parentDirID = try await directoryID(of: parent)
        let parentStorage = try await storageFolder(parentDirID, create: parentDirID.isEmpty)
        let names = try nodeName(name, in: parentDirID)
        let dirID = UUID().uuidString.lowercased()
        // The storage folder and its id backup first, so a node never points at a directory that does not exist.
        let storage = try await storageFolder(dirID, create: true)
        try await CryptomatorStorage.upload(Data(try cryptor.encrypt(Array(dirID.utf8))), name: Self.dirIDBackupName, parent: storage.id, provider: provider)
        let nodeFolder = try await provider.createFolder(name: names.node, parent: parentStorage.id)
        try await CryptomatorStorage.upload(Data(dirID.utf8), name: Self.dirFileName, parent: nodeFolder, provider: provider)
        if names.node != names.full {
            try await CryptomatorStorage.upload(Data(names.full.utf8), name: Self.longNameFileName, parent: nodeFolder, provider: provider)
        }
        forget(parentDirID)
        let id = Self.itemID(.folder, node: names.node, parentDirID: parentDirID)
        directoryIDs[id] = dirID
        return id
    }

    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let cryptor = try keys(), provider = try base()
        let parentDirID = try await directoryID(of: parent)
        let parentStorage = try await storageFolder(parentDirID, create: parentDirID.isEmpty)
        let names = try nodeName(name, in: parentDirID)
        let existing = try await readDirectory(parentDirID)
        var replaced: Node?
        if let replacing { replaced = try await node(for: replacing).node }
        // Replacing a file whose name differs only in case means a different encrypted name: the new one is written
        // beside it and the old one removed afterwards, rather than overwritten.
        var retire: Node?
        if let old = replaced, old.name != names.node { retire = old; replaced = nil }
        if replaced == nil, let clash = existing[names.node] { replaced = clash }
        if let target = replaced, target.kind != .file { throw CloudError.message(L("Ya hay una carpeta con ese nombre en la bóveda.")) }

        let encrypted = try CryptomatorStorage.scratch()
        defer { try? FileManager.default.removeItem(at: encrypted) }
        let source = local
        try await blockingIO { try cryptor.encryptFile(from: source, to: encrypted) }
        let clearTotal = cursor.total
        let report: (Int64, Int64) -> Void = { sent, total in
            progress(total > 0 ? Int64(Double(clearTotal) * Double(sent) / Double(total)) : sent, clearTotal)
        }
        let receipt: UploadReceipt
        if names.node == names.full {
            receipt = try await CryptomatorStorage.upload(file: encrypted, name: names.node, parent: parentStorage.id,
                                                          replacing: replaced?.contents?.id, provider: provider, progress: report)
        } else {
            let folder: String
            if let replaced { folder = replaced.item.id }
            else {
                folder = try await provider.createFolder(name: names.node, parent: parentStorage.id)
                try await CryptomatorStorage.upload(Data(names.full.utf8), name: Self.longNameFileName, parent: folder, provider: provider)
            }
            receipt = try await CryptomatorStorage.upload(file: encrypted, name: Self.longContentsFileName, parent: folder,
                                                          replacing: replaced?.contents?.id, provider: provider, progress: report)
        }
        if let retire { try await provider.trash(file: retire.item) }
        forget(parentDirID)
        cursor.offset = cursor.total; cursor.complete = true; try save(cursor)
        // The provider's verdict is about the ciphertext it stored, which is exactly what was sent.
        return UploadReceipt(remoteID: Self.itemID(.file, node: names.node, parentDirID: parentDirID), verification: receipt.verification)
    }

    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let cryptor = try keys(), provider = try base()
        let (node, _) = try await node(for: file.id)
        guard let contents = node.contents else { throw CloudError.message(L("Una carpeta no se descarga como archivo.")) }
        let encrypted = try CryptomatorStorage.scratch()
        defer { try? FileManager.default.removeItem(at: encrypted) }
        let clearTotal = file.size ?? 0
        try await provider.download(file: contents, to: encrypted, exportMime: nil, maxBytes: maxBytes.map { cryptor.ciphertextSize(cleartext: $0) }) { received, total in
            progress(total > 0 && clearTotal > 0 ? Int64(Double(clearTotal) * Double(received) / Double(total)) : received, clearTotal)
        }
        // The ciphertext is checked against what the provider lists for it, exactly as any other download.
        if provider.canVerifyDownload(of: contents) {
            let size = Int64((try encrypted.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            var problem: DownloadIntegrityError?
            if let expected = contents.size, expected != size {
                problem = .sizeMismatch(name: file.name, expected: cryptor.cleartextSize(ciphertext: expected) ?? expected,
                                        actual: cryptor.cleartextSize(ciphertext: size) ?? size)
            } else if let listed = contents.checksum {
                let algorithm = listed.algorithm, local = encrypted
                let (digest, _) = try await blockingIO { try ContentHasher.digest(of: local, algorithm: algorithm) }
                if !listed.matches(digest) { problem = .checksumMismatch(name: file.name) }
            }
            if let problem {
                // As for any provider: a file that changed since it was listed is not corruption.
                guard let parsed = Self.parse(file.id) else { throw problem }
                let fresh = try await readDirectory(parsed.parentDirID)[parsed.node]
                guard let fresh, let now = fresh.contents else { throw DownloadIntegrityError.changedRemotely(name: file.name, current: nil) }
                if CloudAPI.changed(contents, now) { throw DownloadIntegrityError.changedRemotely(name: file.name, current: cloudFile(fresh, parentDirID: parsed.parentDirID)) }
                throw problem
            }
        }
        let name = file.name
        do { try await blockingIO { try cryptor.decryptFile(from: encrypted, to: destination) } }
        catch is CancellationError { throw CancellationError() }
        catch { throw CryptomatorError.unauthentic(name) }
    }

    func rename(file: CloudFile, name: String) async throws {
        let (node, parentDirID) = try await node(for: file.id)
        try await relocate(node, from: parentDirID, to: parentDirID, name: name, id: file.id)
    }

    func move(file: CloudFile, to destination: String) async throws {
        let (node, parentDirID) = try await node(for: file.id)
        let target = try await directoryID(of: destination)
        if node.kind == .folder, try await directoryID(of: file.id) == target {
            throw CloudError.message(L("Una carpeta no puede moverse ni copiarse dentro de sí misma."))
        }
        try await relocate(node, from: parentDirID, to: target, name: node.cleartext, id: file.id)
    }

    /// Gives a node a new name, a new directory, or both. The encrypted name depends on both, so even a plain move
    /// renames the stored item, and a name crossing the shortening threshold changes the shape of the node.
    private func relocate(_ node: Node, from: String, to: String, name: String, id: String) async throws {
        let provider = try base()
        let names = try nodeName(name, in: to)
        let fromStorage = try await storageFolder(from), toStorage = try await storageFolder(to)
        let wasLong = node.name.hasSuffix(".c9s"), isLong = names.node.hasSuffix(".c9s")
        if node.kind == .file, wasLong != isLong {
            if isLong {
                // A plain file becomes `<hash>.c9s/contents.c9r` beside its `name.c9s`.
                let folder = try await provider.createFolder(name: names.node, parent: toStorage.id)
                try await CryptomatorStorage.upload(Data(names.full.utf8), name: Self.longNameFileName, parent: folder, provider: provider)
                _ = try await place(node.item, from: fromStorage.id, into: folder, named: Self.longContentsFileName, provider: provider)
            } else {
                // The contents come out under their own name, and the emptied `.c9s` folder goes.
                guard let contents = node.contents else { throw CryptomatorError.malformed(L("falta el contenido de un nombre largo.")) }
                _ = try await place(contents, from: node.item.id, into: toStorage.id, named: names.full, provider: provider)
                try await provider.trash(file: node.item)
            }
        } else {
            let placed = try await place(node.item, from: fromStorage.id, into: toStorage.id, named: names.node, provider: provider)
            if isLong || wasLong {
                let inside = try await provider.list(parent: placed.id, onPage: nil)
                let stale = inside.first { !$0.isFolder && $0.name == Self.longNameFileName }
                if isLong {
                    try await CryptomatorStorage.upload(Data(names.full.utf8), name: Self.longNameFileName, parent: placed.id, replacing: stale?.id, provider: provider)
                } else if let stale {
                    try await provider.trash(file: stale)
                }
            }
        }
        forget(from, to)
        if let dirID = directoryIDs.removeValue(forKey: id) {
            directoryIDs[Self.itemID(.folder, node: names.node, parentDirID: to)] = dirID
        }
    }

    /// Moves `item` into `folder` when it is elsewhere, then renames it when its name differs, following its id
    /// through both changes for the providers whose ids are paths.
    private func place(_ item: CloudFile, from current: String, into folder: String, named name: String, provider: any CloudProvider) async throws -> CloudFile {
        var item = item
        if current != folder {
            try await provider.move(file: item, to: folder)
            item = try provider.identityChange(file: item, name: item.name, destination: folder).file(item)
        }
        if item.name != name {
            try await provider.rename(file: item, name: name)
            item = try provider.identityChange(file: item, name: name, destination: nil).file(item)
        }
        return item
    }

    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        guard let parsed = Self.parse(file.id) else { return RemoteIdentityChange(oldID: file.id, newID: file.id, name: name, descendants: false) }
        let target: String
        if let destination {
            if Self.isRoot(destination) { target = "" }
            else if let known = directoryIDs[destination] { target = known }
            else { throw CloudError.message(L("No se pudo seguir el elemento movido. Actualiza la carpeta.")) }
        } else { target = parsed.parentDirID }
        let names = try nodeName(name, in: target)
        // What hangs below a folder is addressed by its directory id, which neither renaming nor moving changes.
        return RemoteIdentityChange(oldID: file.id, newID: Self.itemID(parsed.kind, node: names.node, parentDirID: target), name: name, descendants: false)
    }

    /// Removes a node. A folder takes its storage folder with it, and the storage folders of everything below, which
    /// live elsewhere under `d/`: deleting only the node would leave their ciphertext behind, unreachable.
    func trash(file: CloudFile) async throws {
        let provider = try base()
        let (node, parentDirID) = try await node(for: file.id)
        if node.kind == .folder, let dirID = try? await directoryID(of: file.id) {
            try await removeTree(dirID, provider: provider)
        }
        try await provider.trash(file: node.item)
        forget(parentDirID)
        directoryIDs[file.id] = nil
    }

    private func removeTree(_ dirID: String, provider: any CloudProvider) async throws {
        guard let storage = try? await storageFolder(dirID) else { return }
        for node in try await readDirectory(dirID).values where node.kind == .folder {
            let id = Self.itemID(.folder, node: node.name, parentDirID: dirID)
            if let child = try? await directoryID(of: id) { try await removeTree(child, provider: provider) }
        }
        try await provider.trash(file: storage)
        self.storage[dirID] = nil; listings[dirID] = nil
    }

    // MARK: - What a vault does not do

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        throw CloudError.message(L("El contenido de una bóveda solo se lee descifrándolo en este Mac."))
    }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)?) async throws {
        throw CloudError.message(L("Dentro de una bóveda no se puede copiar. Descarga el archivo y vuelve a subirlo."))
    }
    func publicLink(for file: CloudFile) async throws -> URL {
        throw CloudError.message(L("Un enlace público entregaría el archivo cifrado, que nadie podría abrir sin la contraseña."))
    }
    func searchPage(term: String, cursor: String?, filters: SearchFilters, referenceDate: Date) async throws -> SearchPage {
        throw CloudError.message(L("Las búsquedas no entran en las bóvedas cifradas."))
    }
    func canVerifyDownload(of file: CloudFile) -> Bool { true }
}
