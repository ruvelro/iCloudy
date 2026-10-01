import Foundation

/// Creating and opening vaults in a folder of any provider. A vault is an ordinary folder holding
/// `vault.cryptomator`, `masterkey.cryptomator` and a `d` tree of encrypted directories; nothing here depends on
/// which cloud it lives in, only on the operations every provider already offers.
@MainActor
enum CryptomatorVault {
    static let configName = "vault.cryptomator"
    static let masterkeyName = "masterkey.cryptomator"
    static let dataName = "d"
    /// Small control files (configuration, masterkey, directory ids, long names) never come close to this.
    nonisolated static let controlFileLimit: Int64 = 64 * 1024

    struct Opened {
        let cryptor: CryptomatorCryptor
        let config: CryptomatorVaultConfig
    }

    /// Whether a folder's listing is that of a vault. Used to offer "Abrir bóveda" only where it can work.
    static func isVault(_ files: [CloudFile]) -> Bool {
        files.contains { !$0.isFolder && $0.name == configName } && files.contains { !$0.isFolder && $0.name == masterkeyName }
    }

    /// Creates `name` inside `parent` and turns it into an empty vault. Returns the id of the new folder.
    static func create(named name: String, in parent: String, provider: any CloudProvider, passphrase: String,
                       costParam: Int = CryptomatorMasterkeyFile.defaultCostParam) async throws -> String {
        let masterkey = try CryptomatorMasterkey.random()
        // scrypt takes a noticeable moment by design; it never runs on the main actor.
        let file = try await blockingIO { try CryptomatorMasterkeyFile.lock(masterkey, passphrase: passphrase, costParam: costParam) }
        let config = CryptomatorVaultConfig.new()
        let token = try config.token(rawKey: masterkey.raw)
        let cryptor = CryptomatorCryptor(masterkey: masterkey, combo: config.cipherCombo)

        let folder = try await provider.createFolder(name: name, parent: parent)
        _ = try await CryptomatorStorage.upload(try file.encoded(), name: masterkeyName, parent: folder, provider: provider)
        _ = try await CryptomatorStorage.upload(Data(token.utf8), name: configName, parent: folder, provider: provider)
        // The root directory's storage folder, and inside it the encrypted backup of its (empty) id, as cryptofs does.
        let data = try await provider.createFolder(name: dataName, parent: folder)
        let path = try cryptor.directoryPath("")
        let shard = try await provider.createFolder(name: path.shard, parent: data)
        let root = try await provider.createFolder(name: path.name, parent: shard)
        _ = try await CryptomatorStorage.upload(Data(try cryptor.encrypt([])), name: CryptomatorProvider.dirIDBackupName, parent: root, provider: provider)
        return folder
    }

    /// Reads the configuration and the masterkey of the vault in `folder` and unlocks it with `passphrase`.
    static func open(folder: String, provider: any CloudProvider, passphrase: String) async throws -> Opened {
        let files = try await provider.list(parent: folder, onPage: nil)
        guard let configFile = files.first(where: { !$0.isFolder && $0.name == configName }) else {
            if let legacy = files.first(where: { !$0.isFolder && $0.name == masterkeyName }),
               let data = try? await CryptomatorStorage.download(legacy, provider: provider),
               let masterkey = try? CryptomatorMasterkeyFile.decode(data), masterkey.version < 8 {
                throw CryptomatorError.unsupported(L("es de un formato anterior al 8. Ábrela una vez con Cryptomator para que la actualice."))
            }
            throw CryptomatorError.notAVault
        }
        let token = String(decoding: try await CryptomatorStorage.download(configFile, provider: provider), as: UTF8.self)
        let keyID = try CryptomatorVaultConfig.unverifiedKeyID(token)
        guard keyID.hasPrefix(CryptomatorVaultConfig.masterkeyKeyIDPrefix),
              let keyName = CryptomatorVaultConfig(keyID: keyID, format: 8, shorteningThreshold: 220, jti: "", cipherCombo: .sivGCM).masterkeyFileName else {
            throw CryptomatorError.unsupported(L("su clave la gestiona Cryptomator Hub u otro servicio, no una contraseña."))
        }
        guard let keyFile = files.first(where: { !$0.isFolder && $0.name == keyName }) else { throw CryptomatorError.notAVault }
        let masterkeyFile = try CryptomatorMasterkeyFile.decode(try await CryptomatorStorage.download(keyFile, provider: provider))
        let masterkey = try await blockingIO { try masterkeyFile.unlock(passphrase: passphrase) }
        let config = try CryptomatorVaultConfig.verify(token, rawKey: masterkey.raw)
        return Opened(cryptor: CryptomatorCryptor(masterkey: masterkey, combo: config.cipherCombo), config: config)
    }
}

/// Reading and writing the small control files of a vault through a provider, by way of a temporary file.
@MainActor
enum CryptomatorStorage {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iCloudy-Cryptomator", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(UUID().uuidString)
    }

    static func download(_ file: CloudFile, provider: any CloudProvider, limit: Int64 = CryptomatorVault.controlFileLimit) async throws -> Data {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try await provider.download(file: file, to: url, exportMime: nil, maxBytes: limit) { _, _ in }
        return try Data(contentsOf: url)
    }

    /// Returns the provider's id for the new file when it reports one.
    @discardableResult
    static func upload(_ data: Data, name: String, parent: String, replacing: String? = nil, provider: any CloudProvider) async throws -> String? {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .withoutOverwriting)
        return try await upload(file: url, name: name, parent: parent, replacing: replacing, provider: provider) { _, _ in }.remoteID
    }

    /// Uploads a local file in one go. Ciphertext is regenerated with fresh nonces on every attempt, so a provider's
    /// resumable session is never carried over from one attempt to the next: it would mix bytes of two encryptions.
    static func upload(file url: URL, name: String, parent: String, replacing: String?, provider: any CloudProvider,
                       progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var cursor = UploadCheckpoint(total: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        cursor.sourceStamp = try UploadSourceStamp(url)
        return try await provider.uploadFile(local: url, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: { _ in }, progress: progress)
    }
}
