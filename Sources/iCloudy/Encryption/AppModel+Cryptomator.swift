import AppKit
import SwiftUI

extension AppModel {
    /// True while the explorer shows the inside of an unlocked vault.
    var inEncryptedVault: Bool { account?.isCryptomatorVault == true }

    /// Vaults live in real folders of real accounts; the demo and a vault itself are neither.
    var canHostVault: Bool { account.map { !$0.isDemo && !$0.isCryptomatorVault } ?? false }

    /// The folder on screen holds a vault that is still locked.
    var currentFolderIsLockedVault: Bool {
        guard canHostVault, let account, let folder = path.last, collection == .files else { return false }
        return CryptomatorVault.isVault(files) && cryptomator.unlocked(base: account.id, folder: folder.id) == nil
    }

    /// The account and the provider behind a vault, resolved again on every call so a reconnected account is used.
    private func vaultStorage(_ base: Account) -> () throws -> any CloudProvider {
        { [weak self] in
            guard let self else { throw CryptomatorError.locked }
            return try self.client(base).provider
        }
    }

    private func wireVaults() {
        guard cryptomator.didLock == nil else { return }
        cryptomator.isBusy = { [weak self] id in self?.queue.hasActive(accountID: id) ?? false }
        cryptomator.didLock = { [weak self] entry in self?.vaultDidLock(entry) }
    }

    /// "Abrir bóveda…". A passphrase kept in the Keychain is tried first; the sheet only appears when it is missing or
    /// no longer opens the vault.
    func requestVaultUnlock(_ folder: CloudFile) {
        guard canHostVault, let account else { return }
        wireVaults()
        if let open = cryptomator.unlocked(base: account.id, folder: folder.id) { select(open.id); return }
        let request = CryptomatorVaults.Request(base: account, folder: folder)
        guard let remembered = cryptomator.rememberedPassphrase(base: account.id, folder: folder.id) else { cryptomator.unlocking = request; return }
        Task {
            if let problem = await unlockVault(request, passphrase: remembered, remember: false) {
                if problem == CryptomatorError.invalidPassphrase.errorDescription {
                    cryptomator.forgetPassphrase(CryptomatorVaults.accountID(base: account.id, folder: folder.id))
                }
                cryptomator.unlocking = request
            }
        }
    }

    /// The folder on screen, unlocked.
    func unlockCurrentFolder() {
        guard let folder = path.last else { return }
        requestVaultUnlock(folder)
    }

    /// Returns what went wrong, for the sheet to show beside the passphrase, or nil once the vault is open on screen.
    func unlockVault(_ request: CryptomatorVaults.Request, passphrase: String, remember: Bool) async -> String? {
        wireVaults()
        do {
            let entry = try await cryptomator.unlock(folder: request.folder, base: request.base, provider: vaultStorage(request.base),
                                                     passphrase: passphrase, remember: remember)
            select(entry.id)
            return nil
        } catch is CancellationError {
            return nil
        } catch { return error.localizedDescription }
    }

    /// "Crear bóveda cifrada…" on a folder, or on the folder on screen when `parent` is nil.
    func requestVaultCreation(in parent: CloudFile? = nil) {
        guard canHostVault, let account, collection == .files else { return }
        let folder = parent ?? path.last ?? CloudFile(id: folderID, name: L("Mis archivos"), mime: CryptomatorProvider.folderMime,
                                                      size: nil, modified: nil, webURL: nil, isFolder: true)
        cryptomator.creating = CryptomatorVaults.Request(base: account, folder: folder)
    }

    /// Creates the vault, then opens it. Returns what went wrong, or nil once the new vault is on screen.
    func createVault(_ request: CryptomatorVaults.Request, name: String, passphrase: String, remember: Bool) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = FileNames.problem(with: trimmed, for: request.base.cloud) { return problem }
        do {
            let api = try client(request.base)
            let siblings = try await api.list(parent: request.folder.id)
            guard !siblings.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
                return L("Ya existe un elemento con ese nombre. Elige otro.")
            }
            let folder = try await CryptomatorVault.create(named: trimmed, in: request.folder.id, provider: api.provider, passphrase: passphrase)
            let vault = CloudFile(id: folder, name: trimmed, mime: CryptomatorProvider.folderMime, size: nil, modified: Date(), webURL: nil, isFolder: true)
            if selectedAccountID == request.base.id { reload(fresh: true) }
            return await unlockVault(CryptomatorVaults.Request(base: request.base, folder: vault), passphrase: passphrase, remember: remember)
        } catch { return error.localizedDescription }
    }

    /// "Bloquear". Refused while the vault has transfers in flight, like disconnecting an account.
    func lockVault(_ id: String) {
        guard !queue.hasActive(accountID: id) else {
            error = L("Pausa o termina las transferencias de esta bóveda antes de bloquearla.")
            return
        }
        cryptomator.lock(id)
    }

    /// Leaves a vault that has just locked: its preview closes and the explorer goes back to the account that holds it.
    private func vaultDidLock(_ entry: CryptomatorVaults.Unlocked) {
        if preview.model.account?.id == entry.id { preview.close() }
        quotas.remove(entry.id)
        if selectedAccountID == entry.id { select(entry.base.id) }
    }
}
