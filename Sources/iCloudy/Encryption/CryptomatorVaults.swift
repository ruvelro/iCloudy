import AppKit
import Combine

/// The vaults unlocked in this run. Each one is shown as an account of its own, with an id that names the account
/// and the folder it lives in, so a transfer queued before it was locked finds it again once it is unlocked. Nothing
/// about an unlocked vault is written to disk: its keys live here and nowhere else, and quitting the app forgets them.
@MainActor
final class CryptomatorVaults: ObservableObject {
    struct Unlocked: Identifiable {
        let account: Account
        let base: Account
        let folder: CloudFile
        let client: CloudAPI
        let provider: CryptomatorProvider
        var id: String { account.id }
    }

    /// A folder waiting for a passphrase: the vault to unlock, or the folder to create a vault in.
    struct Request: Identifiable {
        let id = UUID()
        let base: Account
        let folder: CloudFile
    }

    nonisolated static let accountPrefix = "cryptomator:"
    static let baseOption = "cryptomatorBase"
    static let folderOption = "cryptomatorFolder"
    /// Minutes without use before a vault locks itself. Zero means never.
    nonisolated static let idlePreference = "cryptomatorIdleMinutes"
    nonisolated static let defaultIdleMinutes = 15
    /// Cryptomator asks for at least this many characters when it creates a vault.
    static let minimumPassphraseLength = 8

    @Published private(set) var unlocked: [Unlocked] = []
    @Published var unlocking: Request?
    @Published var creating: Request?
    /// What the app does when a vault locks: leave it if it is on screen, close a preview from it.
    var didLock: ((Unlocked) -> Void)?
    /// Whether a vault has transfers in flight. Those keep it unlocked when it would otherwise time out.
    var isBusy: ((String) -> Bool)?
    /// Something about a remembered passphrase did not reach the Keychain. The vault itself is not affected, so this
    /// is reported rather than thrown: the person still has to know the passphrase was not saved, or not forgotten.
    var didFail: ((String) -> Void)?
    private var lastUse: [String: Date] = [:]
    private var idleCheck: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?
    private let passphrases: KeychainStorage

    init(passphrases: KeychainStorage = KeychainStorage()) {
        self.passphrases = passphrases
        // Locking on quit is mostly symbolic, the process is about to end, but it also clears the keys from memory
        // before anything else in the shutdown gets a chance to run.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockAll() }
        }
    }

    nonisolated static func isVaultAccount(_ id: String) -> Bool { id.hasPrefix(accountPrefix) }
    static func accountID(base: String, folder: String) -> String { accountPrefix + base + "|" + folder }

    nonisolated static var idleMinutes: Int { UserDefaults.standard.object(forKey: idlePreference) as? Int ?? defaultIdleMinutes }

    func account(_ id: String?) -> Account? { unlocked.first { $0.id == id }?.account }
    func client(for id: String) -> CloudAPI? { unlocked.first { $0.id == id }?.client }
    func unlocked(base: String, folder: String) -> Unlocked? { unlocked.first { $0.id == Self.accountID(base: base, folder: folder) } }

    // MARK: - Unlocking

    /// Opens the vault in `folder` of `base`. `provider` resolves the base account's provider on every call.
    @discardableResult
    func unlock(folder: CloudFile, base: Account, provider: @escaping () throws -> any CloudProvider, passphrase: String, remember: Bool) async throws -> Unlocked {
        let id = Self.accountID(base: base.id, folder: folder.id)
        if let open = unlocked.first(where: { $0.id == id }) { return open }
        let opened = try await CryptomatorVault.open(folder: folder.id, provider: try provider(), passphrase: passphrase)
        if let open = unlocked.first(where: { $0.id == id }) { return open } // unlocked twice at once
        let account = Account(id: id, cloud: base.cloud, name: folder.name, email: base.email + " · " + folder.name,
                              clientID: base.clientID, clientSecret: nil, serverURL: base.serverURL, bookmark: nil,
                              options: [Self.baseOption: base.id, Self.folderOption: folder.id])
        let vault = CryptomatorProvider(account: account, base: provider, vaultFolderID: folder.id, opened: opened)
        vault.didUse = { [weak self] in self?.lastUse[id] = Date() }
        let entry = Unlocked(account: account, base: base, folder: folder, client: CloudAPI(provider: vault), provider: vault)
        unlocked.append(entry)
        lastUse[id] = Date()
        if remember {
            do { try passphrases.save(passphrase, key: Self.passphraseKey(id)) }
            catch { didFail?(L("La bóveda está abierta, pero su contraseña no se pudo guardar en el Llavero: \(error.localizedDescription) La próxima vez habrá que escribirla.")) }
        }
        startIdleCheck()
        return entry
    }

    // MARK: - Locking

    func lock(_ id: String) {
        guard let index = unlocked.firstIndex(where: { $0.id == id }) else { return }
        let entry = unlocked.remove(at: index)
        lastUse[id] = nil
        entry.client.invalidate()
        entry.provider.lock()
        didLock?(entry)
        if unlocked.isEmpty { idleCheck?.cancel(); idleCheck = nil }
    }

    func lockAll() { for entry in unlocked { lock(entry.id) } }

    /// A vault cannot outlive the account that stores it.
    func lockAll(storedIn baseID: String) { for entry in unlocked where entry.base.id == baseID { lock(entry.id) } }

    /// Locks every vault unused for longer than the setting allows, unless it is busy transferring.
    @discardableResult
    func lockIdle(now: Date = Date(), minutes: Int = CryptomatorVaults.idleMinutes) -> [String] {
        guard minutes > 0 else { return [] }
        let expired = unlocked.filter { entry in
            now.timeIntervalSince(lastUse[entry.id] ?? .distantPast) >= Double(minutes) * 60 && isBusy?(entry.id) != true
        }.map(\.id)
        for id in expired { lock(id) }
        return expired
    }

    /// Marks a vault as in use, e.g. while its transfers keep it busy.
    func touch(_ id: String, at date: Date = Date()) { if lastUse[id] != nil { lastUse[id] = date } }

    private func startIdleCheck() {
        guard idleCheck == nil else { return }
        idleCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                // Transfers in flight count as use, so the countdown starts when they end.
                for entry in self.unlocked where self.isBusy?(entry.id) == true { self.touch(entry.id) }
                self.lockIdle()
            }
        }
    }

    // MARK: - Remembered passphrases

    /// Only when the person asks for it, in this Mac's Keychain and only while it is unlocked.
    static func passphraseKey(_ vaultID: String) -> String { "cryptomator-passphrase:" + vaultID }

    func rememberedPassphrase(base: String, folder: String) -> String? {
        try? passphrases.read(String.self, key: Self.passphraseKey(Self.accountID(base: base, folder: folder)))
    }
    func hasRememberedPassphrase(_ id: String) -> Bool { (try? passphrases.read(String.self, key: Self.passphraseKey(id))) != nil }
    func forgetPassphrase(_ id: String) {
        do { try passphrases.delete(key: Self.passphraseKey(id)) }
        catch { didFail?(L("No se pudo borrar del Llavero la contraseña guardada de esta bóveda: \(error.localizedDescription) Sigue guardada; puedes quitarla desde Acceso a Llaveros.")) }
    }
}

extension Account {
    /// An unlocked vault presented as an account of its own.
    var isCryptomatorVault: Bool { CryptomatorVaults.isVaultAccount(id) }
}

extension CloudCapabilities {
    /// What a vault can do over a provider. Only the operations the encryption layer implements: no search, no
    /// links, no sharing and no copy, since all of them would hand out or duplicate ciphertext under its old name.
    static func cryptomatorVault(over cloud: Cloud) -> CloudCapabilities {
        let base = CloudCapabilities.of(cloud)
        return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false, publicLinks: false,
                                 copy: false, move: true, quota: base.quota, exportsDocuments: false,
                                 reversibleTrash: base.reversibleTrash, checksum: base.checksum)
    }
}
