import XCTest
import CryptoKit
@testable import iCloudy

/// A provider kept in memory with opaque ids, the way Drive or OneDrive address items. It lists a SHA-256 for every
/// file so the vault's own check of the ciphertext has something to compare, and it lets a test damage stored bytes.
@MainActor
final class MemoryProvider: CloudSession, CloudProvider {
    struct Item { var name: String; var parent: String; var folder: Bool; var data: Data; var checksum: String? }
    var items: [String: Item] = [:]
    var operations: [String] = []

    init() { super.init(account: Account(id: "memory", cloud: .google, name: "Memoria", email: "memoria", clientID: "", clientSecret: nil)) }

    private func file(_ id: String, _ item: Item) -> CloudFile {
        CloudFile(id: id, name: item.name, mime: item.folder ? "application/vnd.google-apps.folder" : "application/octet-stream",
                  size: item.folder ? nil : Int64(item.data.count), modified: nil, webURL: nil, isFolder: item.folder,
                  checksum: item.checksum.map { ContentHash(algorithm: .sha256, value: $0) })
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func path(_ id: String) -> String {
        guard let item = items[id] else { return "" }
        return item.parent == "root" ? item.name : path(item.parent) + "/" + item.name
    }
    var paths: [String] { items.keys.map(path).sorted() }
    func id(at path: String) -> String? { items.keys.first { self.path($0) == path } }

    func list(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        operations.append("list")
        return items.filter { $0.value.parent == parent }.map { file($0.key, $0.value) }
    }
    func createFolder(name: String, parent: String) async throws -> String {
        operations.append("mkdir \(name)")
        guard !items.values.contains(where: { $0.parent == parent && $0.name == name }) else { throw CloudError.message("existe") }
        let id = UUID().uuidString
        items[id] = Item(name: name, parent: parent, folder: true, data: Data(), checksum: nil)
        return id
    }
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest { throw CloudError.message("no") }
    func rename(file: CloudFile, name: String) async throws { operations.append("rename"); items[file.id]?.name = name }
    func move(file: CloudFile, to destination: String) async throws { operations.append("move"); items[file.id]?.parent = destination }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)?) async throws { throw CloudError.message("no") }
    func trash(file: CloudFile) async throws {
        operations.append("trash")
        func remove(_ id: String) {
            for child in items.filter({ $0.value.parent == id }).map(\.key) { remove(child) }
            items[id] = nil
        }
        remove(file.id)
    }
    func publicLink(for file: CloudFile) async throws -> URL { throw CloudError.message("no") }
    func searchPage(term: String, cursor: String?, filters: SearchFilters, referenceDate: Date) async throws -> SearchPage { SearchPage(hits: [], next: nil) }
    func folderTrail(id: String) async throws -> [CloudFile] { [] }
    func storageQuota() async throws -> StorageQuota { StorageQuota(used: 0, total: 1) }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let item = items[file.id] else { throw ServiceError(status: 404, detail: "no existe") }
        if let maxBytes, item.data.count > maxBytes { throw CloudError.message("límite") }
        try item.data.write(to: destination)
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        operations.append("upload \(name)")
        let data = try Data(contentsOf: local)
        let id = replacing ?? UUID().uuidString
        if replacing == nil, items.values.contains(where: { $0.parent == parent && $0.name == name }) { throw CloudError.message("existe") }
        items[id] = Item(name: replacing.flatMap { items[$0]?.name } ?? name, parent: replacing.flatMap { items[$0]?.parent } ?? parent,
                         folder: false, data: data, checksum: Self.sha256(data))
        progress(Int64(data.count), Int64(data.count))
        return UploadReceipt(remoteID: id, verification: .verified)
    }
}

@MainActor
final class CryptomatorVaultTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("boveda-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private let vaultAccount = Account(id: "cryptomator:memory|v", cloud: .google, name: "Bóveda", email: "memoria · Bóveda", clientID: "", clientSecret: nil,
                                       options: ["cryptomatorBase": "memory", "cryptomatorFolder": "v"])

    /// Creates a vault with a cheap scrypt cost and returns it opened, as a client the app would use.
    private func vault(in storage: MemoryProvider, passphrase: String = "correcto caballo") async throws -> (client: CloudAPI, provider: CryptomatorProvider, folder: String) {
        let folder = try await CryptomatorVault.create(named: "Bóveda", in: "root", provider: storage, passphrase: passphrase, costParam: 16)
        let opened = try await CryptomatorVault.open(folder: folder, provider: storage, passphrase: passphrase)
        let provider = CryptomatorProvider(account: vaultAccount, base: { storage }, vaultFolderID: folder, opened: opened)
        return (CloudAPI(provider: provider), provider, folder)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func upload(_ data: Data, as name: String, to parent: String, in client: CloudAPI, replacing: String? = nil) async throws -> UploadReceipt {
        try await client.resumableUpload(local: try write(data, "x"), parent: parent, name: name, replacing: replacing, checkpoint: nil, save: { _ in }, progress: { _, _ in })
    }

    private func downloadData(_ file: CloudFile, from client: CloudAPI) async throws -> Data {
        let destination = scratch.appendingPathComponent(UUID().uuidString)
        try await client.download(file: file, to: destination)
        return try Data(contentsOf: destination)
    }

    func testCreatedVaultHasTheCryptomatorLayoutAndOpensOnlyWithItsPassphrase() async throws {
        let storage = MemoryProvider()
        let (_, provider, folder) = try await vault(in: storage)
        let listing = try await storage.list(parent: folder, onPage: nil)
        XCTAssertTrue(CryptomatorVault.isVault(listing))
        let opened = try await CryptomatorVault.open(folder: folder, provider: storage, passphrase: "correcto caballo")
        let root = try opened.cryptor.directoryPath("")
        XCTAssertTrue(storage.paths.contains("Bóveda/d/\(root.shard)/\(root.name)/dirid.c9r"), "\(storage.paths)")
        XCTAssertEqual(opened.config.cipherCombo, .sivGCM)
        XCTAssertEqual(opened.config.shorteningThreshold, 220)
        XCTAssertEqual(provider.shorteningThreshold, 220)
        let masterkey = try CryptomatorMasterkeyFile.decode(storage.items[storage.id(at: "Bóveda/masterkey.cryptomator")!]!.data)
        XCTAssertEqual(masterkey.version, 999)
        XCTAssertEqual(masterkey.scryptBlockSize, 8)

        do {
            _ = try await CryptomatorVault.open(folder: folder, provider: storage, passphrase: "correcto cabello")
            XCTFail("Una contraseña equivocada no abre")
        } catch { XCTAssertEqual(error as? CryptomatorError, .invalidPassphrase) }
        do {
            _ = try await CryptomatorVault.open(folder: "root", provider: storage, passphrase: "x")
            XCTFail("Una carpeta normal no es una bóveda")
        } catch { XCTAssertEqual(error as? CryptomatorError, .notAVault) }
    }

    func testFilesAndFoldersRoundTripWithLongNamesAndNothingLeaksInClear() async throws {
        let storage = MemoryProvider()
        let (client, _, _) = try await vault(in: storage)
        let longFolder = String(repeating: "Carpeta con un nombre muy largo ", count: 6)
        let longFile = String(repeating: "Informe trimestral ", count: 12) + ".pdf"
        let documents = try await client.createFolder(name: "Documentos", parent: "root")
        let deep = try await client.createFolder(name: longFolder, parent: documents)
        let big = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let receipt = try await upload(big, as: "grande.bin", to: deep, in: client)
        XCTAssertEqual(receipt.verification, .verified, "La suma del proveedor sobre el cifrado sigue contando")
        try await upload(Data("hola".utf8), as: longFile, to: deep, in: client)
        try await upload(Data(), as: "vacío.txt", to: "root", in: client)

        let root = try await client.list(parent: "root")
        XCTAssertEqual(root.map(\.name), ["Documentos", "vacío.txt"])
        XCTAssertEqual(root[1].size, 0)
        let inside = try await client.list(parent: try XCTUnwrap(root.first?.id))
        XCTAssertEqual(inside.map(\.name), [longFolder])
        let files = try await client.list(parent: inside[0].id)
        XCTAssertEqual(Set(files.map(\.name)), ["grande.bin", longFile])
        let bigFile = try XCTUnwrap(files.first { $0.name == "grande.bin" })
        XCTAssertEqual(bigFile.size, 100_000, "Se muestra el tamaño sin cifrar")
        XCTAssertNil(bigFile.checksum)
        let bigBack = try await downloadData(bigFile, from: client)
        XCTAssertEqual(bigBack, big)
        let longBack = try await downloadData(try XCTUnwrap(files.first { $0.name == longFile }), from: client)
        XCTAssertEqual(longBack, Data("hola".utf8))

        // On the storage side: shortened nodes in the shape Cryptomator expects, and no cleartext anywhere.
        let stored = storage.paths
        XCTAssertTrue(stored.contains { $0.hasSuffix(".c9s/contents.c9r") }, "Archivo de nombre largo")
        XCTAssertTrue(stored.contains { $0.hasSuffix(".c9s/dir.c9r") }, "Carpeta de nombre largo")
        XCTAssertEqual(stored.filter { $0.hasSuffix("/name.c9s") }.count, 2)
        XCTAssertEqual(stored.filter { $0.hasSuffix("/dirid.c9r") }.count, 3, "Raíz, Documentos y la carpeta larga")
        for path in stored {
            for clear in ["Documentos", "grande", "Informe", "Carpeta", "vacío", ".pdf", ".bin", ".txt"] {
                XCTAssertFalse(path.contains(clear), "«\(clear)» aparece en \(path)")
            }
        }
        for item in storage.items.values where item.name == "dir.c9r" {
            XCTAssertEqual(String(data: item.data, encoding: .utf8)?.count, 36, "dir.c9r guarda el UUID en claro, como manda el formato")
        }
    }

    func testRenameAndMoveReencryptNamesAndChangeShapeAcrossTheThreshold() async throws {
        let storage = MemoryProvider()
        let (client, _, _) = try await vault(in: storage)
        let a = try await client.createFolder(name: "A", parent: "root")
        let b = try await client.createFolder(name: "B", parent: "root")
        let receipt = try await upload(Data("contenido".utf8), as: "nota.txt", to: a, in: client)
        let inA = try await client.list(parent: a)
        var note = try XCTUnwrap(inA.first)
        XCTAssertEqual(note.id, receipt.remoteID)

        let long = String(repeating: "largo ", count: 50) + ".txt"
        try await client.rename(file: note, name: long)
        var change = try client.identityChange(file: note, name: long)
        note = change.file(note)
        var listed = try await client.list(parent: a)
        XCTAssertEqual(listed.map(\.name), [long]); XCTAssertEqual(listed[0].id, note.id, "El id previsto es el que se lista")
        XCTAssertTrue(storage.paths.contains { $0.hasSuffix(".c9s/contents.c9r") })

        try await client.move(file: note, to: b)
        change = try client.identityChange(file: note, name: long, destination: b)
        note = change.file(note)
        let emptied = try await client.list(parent: a)
        XCTAssertTrue(emptied.isEmpty)
        listed = try await client.list(parent: b)
        XCTAssertEqual(listed.map(\.id), [note.id])

        try await client.rename(file: note, name: "corta.txt")
        note = try client.identityChange(file: note, name: "corta.txt").file(note)
        listed = try await client.list(parent: b)
        XCTAssertEqual(listed.map(\.name), ["corta.txt"]); XCTAssertEqual(listed[0].id, note.id)
        XCTAssertFalse(storage.paths.contains { $0.contains(".c9s") }, "La carpeta .c9s vacía se ha ido")
        let noteBack = try await downloadData(listed[0], from: client)
        XCTAssertEqual(noteBack, Data("contenido".utf8))

        // A folder renamed past the threshold keeps its directory id, so what it holds keeps its ids.
        let top = try await client.list(parent: "root")
        var folderB = try XCTUnwrap(top.first { $0.name == "B" })
        let childBefore = try await client.list(parent: folderB.id).map(\.id)
        let longFolder = String(repeating: "carpeta ", count: 40)
        try await client.rename(file: folderB, name: longFolder)
        folderB = try client.identityChange(file: folderB, name: longFolder).file(folderB)
        let childLong = try await client.list(parent: folderB.id).map(\.id)
        XCTAssertEqual(childLong, childBefore)
        try await client.rename(file: folderB, name: "B2")
        folderB = try client.identityChange(file: folderB, name: "B2").file(folderB)
        let renamedTop = try await client.list(parent: "root").map(\.name)
        XCTAssertEqual(renamedTop, ["A", "B2"])
        XCTAssertFalse(storage.paths.contains { $0.hasSuffix("name.c9s") }, "Sin nombres largos, sin name.c9s")
        let childShort = try await client.list(parent: folderB.id).map(\.id)
        XCTAssertEqual(childShort, childBefore)
    }

    func testDeletingAFolderRemovesTheStorageOfEverythingBelowIt() async throws {
        let storage = MemoryProvider()
        let (client, _, folder) = try await vault(in: storage)
        let outer = try await client.createFolder(name: "Fuera", parent: "root")
        let inner = try await client.createFolder(name: "Dentro", parent: outer)
        try await upload(Data("x".utf8), as: "a.txt", to: inner, in: client)
        let storageFolders = { storage.paths.filter { $0.hasPrefix("Bóveda/d/") && $0.split(separator: "/").count == 4 } }
        XCTAssertEqual(storageFolders().count, 3)
        let before = try await client.list(parent: "root")
        try await client.trash(file: try XCTUnwrap(before.first))
        let after = try await client.list(parent: "root")
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(storageFolders().count, 1, "Solo queda la raíz: \(storage.paths)")
        XCTAssertNotNil(storage.id(at: "Bóveda/vault.cryptomator"))
        _ = folder
    }

    func testReplacingAFileKeepsOneNodeAndTheNewContents() async throws {
        let storage = MemoryProvider()
        let (client, _, _) = try await vault(in: storage)
        try await upload(Data("uno".utf8), as: "a.txt", to: "root", in: client)
        let initial = try await client.list(parent: "root")
        let first = try XCTUnwrap(initial.first)
        try await upload(Data("dos dos".utf8), as: "a.txt", to: "root", in: client, replacing: first.id)
        let listed = try await client.list(parent: "root")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].size, 7)
        let replacedBack = try await downloadData(listed[0], from: client)
        XCTAssertEqual(replacedBack, Data("dos dos".utf8))
    }

    func testTamperedChunkAndCorruptedCiphertextAreDetected() async throws {
        let storage = MemoryProvider()
        let (client, _, _) = try await vault(in: storage)
        try await upload(Data(repeating: 9, count: 70_000), as: "datos.bin", to: "root", in: client)
        let rootList = try await client.list(parent: "root")
        let file = try XCTUnwrap(rootList.first)
        let storedID = try XCTUnwrap(storage.items.first { $0.value.name.hasSuffix(".c9r") && $0.value.name != "dirid.c9r" && !$0.value.folder }?.key)

        // Changed behind the provider's back: its own checksum no longer matches.
        storage.items[storedID]!.data[200] ^= 1
        let destination = scratch.appendingPathComponent("salida")
        do { try await client.download(file: file, to: destination); XCTFail("Debe fallar") }
        catch { XCTAssertEqual(error as? DownloadIntegrityError, .checksumMismatch(name: "datos.bin")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        // Changed by someone who also fixed the checksum: authentication of the chunk catches it.
        storage.items[storedID]!.checksum = MemoryProvider.sha256(storage.items[storedID]!.data)
        // What was listed before no longer describes the stored bytes: that is a remote change, not corruption.
        do { try await client.download(file: file, to: destination); XCTFail("Debe fallar") }
        catch { XCTAssertTrue((error as? DownloadIntegrityError)?.retryable == true, "\(error)") }
        _ = try await client.list(parent: "root")
        do { try await client.download(file: file, to: destination); XCTFail("Debe fallar") }
        catch { XCTAssertEqual(error as? CryptomatorError, .unauthentic("datos.bin")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "No queda un archivo a medias")
    }

    func testLockedVaultRefusesEverything() async throws {
        let storage = MemoryProvider()
        let (client, provider, _) = try await vault(in: storage)
        _ = try await client.list(parent: "root")
        provider.lock()
        do { _ = try await client.list(parent: "root"); XCTFail("Bloqueada") }
        catch { XCTAssertEqual(error as? CryptomatorError, .locked) }
    }

    /// Keychain operations kept in a dictionary, so a test can see what was stored without touching the real one.
    private final class FakeKeychain {
        var values: [String: Data] = [:]
        var attributes: [String: [String: Any]] = [:]
        var operations: KeychainOperations {
            KeychainOperations(update: { query, changes in
                let key = (query as NSDictionary)[kSecAttrAccount] as! String
                guard self.values[key] != nil else { return errSecItemNotFound }
                self.values[key] = (changes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }, add: { item, _ in
                let dictionary = item as NSDictionary as! [String: Any]
                let key = dictionary[kSecAttrAccount as String] as! String
                self.values[key] = dictionary[kSecValueData as String] as? Data
                self.attributes[key] = dictionary
                return errSecSuccess
            }, copy: { query, result in
                guard let value = self.values[(query as NSDictionary)[kSecAttrAccount] as! String] else { return errSecItemNotFound }
                result?.pointee = value as CFData
                return errSecSuccess
            }, delete: { query in
                self.values[(query as NSDictionary)[kSecAttrAccount] as! String] = nil
                return errSecSuccess
            })
        }
    }

    func testUnlockedVaultsAreAccountsThatLockOnDemandWhenIdleAndWithTheirStorage() async throws {
        let storage = MemoryProvider()
        let folder = try await CryptomatorVault.create(named: "Privado", in: "root", provider: storage, passphrase: "contraseña larga", costParam: 16)
        let keychain = FakeKeychain()
        let vaults = CryptomatorVaults(passphrases: KeychainStorage(operations: keychain.operations))
        let base = Account(id: "memory", cloud: .google, name: "M", email: "m@example.com", clientID: "", clientSecret: nil)
        let vaultFolder = CloudFile(id: folder, name: "Privado", mime: CryptomatorProvider.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
        var locked: [String] = []
        vaults.didLock = { locked.append($0.id) }

        do {
            try await vaults.unlock(folder: vaultFolder, base: base, provider: { storage }, passphrase: "contraseña corta", remember: true)
            XCTFail("Contraseña equivocada")
        } catch { XCTAssertEqual(error as? CryptomatorError, .invalidPassphrase) }
        XCTAssertTrue(keychain.values.isEmpty, "Una contraseña que no abre no se guarda")

        let entry = try await vaults.unlock(folder: vaultFolder, base: base, provider: { storage }, passphrase: "contraseña larga", remember: true)
        XCTAssertTrue(entry.account.isCryptomatorVault)
        XCTAssertEqual(entry.id, CryptomatorVaults.accountID(base: "memory", folder: folder), "El mismo id cada vez que se abre")
        XCTAssertEqual(vaults.account(entry.id)?.name, "Privado")
        XCTAssertFalse(entry.account.capabilities.search); XCTAssertFalse(entry.account.capabilities.publicLinks)
        XCTAssertFalse(entry.account.capabilities.copy); XCTAssertTrue(entry.account.capabilities.move)
        XCTAssertEqual(vaults.rememberedPassphrase(base: "memory", folder: folder), "contraseña larga")
        let stored = try XCTUnwrap(keychain.attributes[CryptomatorVaults.passphraseKey(entry.id)])
        XCTAssertEqual(stored[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        // Idle: a busy vault stays open, an unused one locks.
        let now = Date()
        vaults.isBusy = { _ in true }
        XCTAssertTrue(vaults.lockIdle(now: now.addingTimeInterval(3600), minutes: 15).isEmpty)
        vaults.isBusy = { _ in false }
        XCTAssertTrue(vaults.lockIdle(now: now.addingTimeInterval(60), minutes: 15).isEmpty, "Un minuto no es inactividad")
        XCTAssertTrue(vaults.lockIdle(now: now.addingTimeInterval(3600), minutes: 0).isEmpty, "Cero es nunca")
        XCTAssertEqual(vaults.lockIdle(now: now.addingTimeInterval(16 * 60), minutes: 15), [entry.id])
        XCTAssertEqual(locked, [entry.id])
        XCTAssertNil(vaults.client(for: entry.id))
        do { _ = try await entry.client.list(parent: "root"); XCTFail("Bloqueada") } catch {}

        // Again, then gone with the account that stores it.
        let again = try await vaults.unlock(folder: vaultFolder, base: base, provider: { storage }, passphrase: "contraseña larga", remember: false)
        XCTAssertEqual(again.id, entry.id)
        vaults.lockAll(storedIn: "otra")
        XCTAssertEqual(vaults.unlocked.count, 1)
        vaults.lockAll(storedIn: "memory")
        XCTAssertTrue(vaults.unlocked.isEmpty)
        vaults.forgetPassphrase(entry.id)
        XCTAssertNil(vaults.rememberedPassphrase(base: "memory", folder: folder))
    }

    func testDecryptedNamesStayOffTheListingCache() async {
        let directory = scratch.appendingPathComponent("listados")
        let cache = ListingCache(directory: directory)
        let file = CloudFile(id: "cm:F:x.c9r:", name: "secreto.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        cache.store([file], accountID: CryptomatorVaults.accountID(base: "a", folder: "b"), parent: "root")
        await cache.settle()
        XCTAssertNil(cache.cached(accountID: CryptomatorVaults.accountID(base: "a", folder: "b"), parent: "root"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Nada escrito en disco")
        cache.store([file], accountID: "a", parent: "root")
        XCTAssertNotNil(cache.cached(accountID: "a", parent: "root"), "Las cuentas normales siguen igual")
    }

    func testItemIdsSurviveDirectoryIdsWithColons() {
        let id = CryptomatorProvider.itemID(.folder, node: "abc=.c9r", parentDirID: "a:b:c")
        let parsed = CryptomatorProvider.parse(id)
        XCTAssertEqual(parsed?.node, "abc=.c9r"); XCTAssertEqual(parsed?.parentDirID, "a:b:c"); XCTAssertEqual(parsed?.kind, .folder)
        XCTAssertNil(CryptomatorProvider.parse("root"))
        XCTAssertNil(CryptomatorProvider.parse("cm:X:a:b"))
    }

    /// A vault written on a real folder with the keys of Cryptomator's published vectors: the storage folders land at
    /// the paths cryptolib computes for those keys, and a directory whose `dir.c9r` was written by hand with the dirId
    /// of the published vector is found where Cryptomator would look for it.
    func testOnDiskLayoutMatchesCryptolibPathsForThePublishedKeys() async throws {
        let root = scratch.appendingPathComponent("volumen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let volume = CloudAPI(account: Account(id: "volume:cm", cloud: .volume, name: "v", email: "v", clientID: "", clientSecret: nil, serverURL: root.standardizedFileURL.path))
        let key = CryptomatorMasterkey(encryptionKey: [UInt8](repeating: 0x55, count: 32), macKey: [UInt8](repeating: 0x77, count: 32))
        let config = CryptomatorVaultConfig.new()
        let vaultURL = root.appendingPathComponent("Bóveda")
        try FileManager.default.createDirectory(at: vaultURL.appendingPathComponent("d/VL/WEHT553J5DR7OZLRJAYDIWFCXZABOD"), withIntermediateDirectories: true)
        try Data(try config.token(rawKey: key.raw).utf8).write(to: vaultURL.appendingPathComponent("vault.cryptomator"))
        try CryptomatorMasterkeyFile.lock(key, passphrase: "asd", costParam: 16).encoded().write(to: vaultURL.appendingPathComponent("masterkey.cryptomator"))
        // A subdirectory with the published dirId, made by hand the way Cryptomator lays it out.
        let cryptor = CryptomatorCryptor(masterkey: key)
        let node = try cryptor.encryptName("Publicado", parentDirID: "") + ".c9r"
        let nodeURL = vaultURL.appendingPathComponent("d/VL/WEHT553J5DR7OZLRJAYDIWFCXZABOD/" + node)
        try FileManager.default.createDirectory(at: nodeURL, withIntermediateDirectories: true)
        try Data("918acfbd-a467-3f77-93f1-f4a44f9cfe9c".utf8).write(to: nodeURL.appendingPathComponent("dir.c9r"))
        let published = vaultURL.appendingPathComponent("d/7C/3USOO3VU7IVQRKFMRFV3QE4VEZJECV")
        try FileManager.default.createDirectory(at: published, withIntermediateDirectories: true)
        let fileName = try cryptor.encryptName("dentro.txt", parentDirID: "918acfbd-a467-3f77-93f1-f4a44f9cfe9c") + ".c9r"
        try Data(try cryptor.encrypt(Array("visto".utf8))).write(to: published.appendingPathComponent(fileName))

        let folderID = vaultURL.standardizedFileURL.path
        let opened = try await CryptomatorVault.open(folder: folderID, provider: volume.provider, passphrase: "asd")
        let provider = CryptomatorProvider(account: vaultAccount, base: { volume.provider }, vaultFolderID: folderID, opened: opened)
        let client = CloudAPI(provider: provider)
        let top = try await client.list(parent: "root")
        XCTAssertEqual(top.map(\.name), ["Publicado"])
        let inside = try await client.list(parent: top[0].id)
        XCTAssertEqual(inside.map(\.name), ["dentro.txt"])
        let seen = try await downloadData(inside[0], from: client)
        XCTAssertEqual(seen, Data("visto".utf8))

        // Writing through the provider on a path-addressed store: a new folder appears under its own hash.
        let made = try await client.createFolder(name: "Nueva", parent: "root")
        let dirID = try await provider.directoryID(of: made)
        let path = try cryptor.directoryPath(dirID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("d/\(path.shard)/\(path.name)/dirid.c9r").path))
        try await upload(Data("hola".utf8), as: "x.txt", to: made, in: client)
        let inMade = try await client.list(parent: made)
        var x = try XCTUnwrap(inMade.first)
        try await client.move(file: x, to: top[0].id)
        x = try client.identityChange(file: x, name: x.name, destination: top[0].id).file(x)
        try await client.rename(file: x, name: String(repeating: "y", count: 200))
        let moved = try await client.list(parent: top[0].id)
        XCTAssertEqual(Set(moved.map(\.name)), ["dentro.txt", String(repeating: "y", count: 200)])
    }
}
