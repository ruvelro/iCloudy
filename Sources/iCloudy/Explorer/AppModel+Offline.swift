import AppKit
import SwiftUI
import Combine

/// What the offline hook compares: one tab's listing together with the place it is the listing of.
struct OfflineObservation: Equatable {
    let accountID: String?
    /// The folder on screen and every folder above it, any of which may be a pinned folder.
    let folders: [String]
    let files: [CloudFile]
    let cached: Bool
    init(_ tab: BrowserState) {
        accountID = tab.accountID
        folders = [tab.folderID] + tab.path.map(\.id)
        files = tab.files
        cached = tab.showingCachedListing
    }
}

/// "Disponible sin conexión": the model's side of the managed offline copies. The store and the refresher hold the
/// logic; this wires them to the accounts, the network, the listings and the preview, and offers the actions.
extension AppModel {
    /// Called once from `init`. Everything is observed from here, so the model's own code only needs to tell the
    /// store about renames, deletions and disconnections.
    func startOffline() {
        let refresher = offlineRefresher
        refresher.client = { [weak self] id in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) else { throw CloudError.message(L("Vuelve a conectar la cuenta.")) }
            return try self.client(account)
        }
        refresher.isOnline = { [weak self] in self?.isOnline ?? false }
        preview.model.localSource = { [weak self] file, account in self?.offlineCopy(of: file, accountID: account.id) }
        preview.model.didDownload = { [weak self] file, account, url in self?.offline.cachePreview(file, accountID: account.id, from: url) }
        // Badges live in rows the explorer draws from the model, so the store's changes have to reach it.
        // Throttled: a folder refresh records one copy per file, and each change redraws the whole explorer.
        offline.objectWillChange.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &refresher.subscriptions)
        // On launch, once the accounts are read from the Keychain; and whenever the network comes back.
        $loadingAccounts.removeDuplicates().filter { !$0 }.first()
            .sink { [weak self] _ in self?.offlineRefresher.refresh() }.store(in: &refresher.subscriptions)
        $isOnline.removeDuplicates().dropFirst().filter { $0 }
            .sink { [weak self] _ in self?.offlineRefresher.refresh() }.store(in: &refresher.subscriptions)
        // A listing that shows a pinned file changed, or a new file inside a pinned folder, refreshes that pin.
        // Only the focused tab's listing is compared. Its account and folder travel with its files: read after the
        // debounce, they could belong to the other pane if the focus moved in between.
        $workspace.map { OfflineObservation($0.current) }.removeDuplicates().debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] seen in self?.offlineObserve(seen) }.store(in: &refresher.subscriptions)
        refresher.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                let minutes = OfflineSettings.refreshMinutes
                guard minutes > 0, Date().timeIntervalSince(self.offlineRefresher.lastFullRefresh) >= Double(minutes) * 60 else { continue }
                self.offlineRefresher.refresh()
            }
        }
    }

    /// Compares what a fresh listing says with the copies kept, and refreshes the pins that are behind.
    func offlineObserve(_ seen: OfflineObservation) {
        guard isOnline, !seen.cached, let account = seen.accountID.flatMap({ id in accounts.first { $0.id == id } }), !offline.pins.isEmpty else { return }
        var due: Set<String> = []
        // Inside a pinned folder, a file without a copy is a new child the pin has to pick up.
        let enclosing = seen.folders.compactMap { offline.pin(for: $0, accountID: account.id) }.filter(\.file.isFolder)
        for file in seen.files where !file.isFolder {
            let entry = offline.entries[OfflineStore.key(accountID: account.id, fileID: file.id)]
            if let entry, let folder = entry.pinFolder, OfflinePolicy.changed(entry, file) { due.insert(folder) }
            else if entry?.isPinned != true, !file.isGoogleDocument, let pin = enclosing.first { due.insert(pin.folder) }
            if let pin = offline.pin(for: file.id, accountID: account.id), entry == nil { due.insert(pin.folder) }
        }
        due.subtract(offline.refreshing)
        if !due.isEmpty { offlineRefresher.refresh(accountID: account.id, scope: .pins(due)) }
    }

    /// The badge of a file of the selected account, or nil when it is not kept offline.
    func offlineStatus(_ file: CloudFile) -> OfflineStatus? {
        guard let account else { return nil }
        return offline.status(for: file, accountID: account.id)
    }
    /// The same, for a tab that need not be the focused one.
    func offlineStatus(_ file: CloudFile, in tab: BrowserState) -> OfflineStatus? {
        guard let id = tab.accountID else { return nil }
        return offline.status(for: file, accountID: id)
    }

    /// The copy to show instead of downloading. Online, only one that matches the listing; offline, any.
    func offlineCopy(of file: CloudFile, accountID: String) -> URL? {
        guard let url = offline.localURL(for: file, accountID: accountID, acceptChanged: !isOnline) else { return nil }
        offline.touch(OfflineStore.key(accountID: accountID, fileID: file.id))
        return url
    }

    func isPinnedOffline(_ file: CloudFile) -> Bool {
        guard let account else { return false }
        return offline.pin(for: file.id, accountID: account.id) != nil
    }

    func pinOffline(_ file: CloudFile) {
        guard let account else { return }
        // Pinned from Recientes or Compartido conmigo there is no folder to list it in; the refresh asks for the item.
        let parent = collection == .files || !path.isEmpty ? folderID : nil
        switch offline.pin(file, accountID: account.id, parentID: parent) {
        case .refused(let reason): error = reason
        case .alreadyPinned: info = L("«\(file.name)» ya está disponible sin conexión.")
        case .pinned(let pin):
            if isOnline { offlineRefresher.refresh(accountID: account.id, scope: .pins([pin.folder])) }
            else { info = L("«\(file.name)» se descargará para usarlo sin conexión en cuanto vuelva la red.") }
        }
    }

    func unpinOffline(_ file: CloudFile) {
        guard let account, let pin = offline.pin(for: file.id, accountID: account.id) else { return }
        removeOfflinePin(pin)
    }

    func removeOfflinePin(_ pin: OfflinePin) {
        offline.unpin(pin.folder)
        // A folder pinned inside this one shared its copies; the next refresh gives them back to it.
        if offline.pins.contains(where: { $0.accountID == pin.accountID }) { offlineRefresher.refresh(accountID: pin.accountID) }
    }

    /// Opens the managed copy in the app the system picks. The copy is read-only, so the app opens it that way:
    /// edits are saved as a copy, never back into the container and never back to the cloud.
    /// The copy may be behind the cloud; the badge says so, and a read-only copy cannot do harm by being opened.
    func openOffline(_ file: CloudFile, accountID: String? = nil) {
        guard let accountID = accountID ?? account?.id else { return }
        guard let url = offline.localURL(for: file, accountID: accountID, acceptChanged: true) else {
            error = L("«\(file.name)» todavía no tiene copia sin conexión en este Mac.")
            return
        }
        offline.touch(OfflineStore.key(accountID: accountID, fileID: file.id))
        NSWorkspace.shared.open(url)
    }

    func hasOfflineCopy(_ file: CloudFile, accountID: String? = nil) -> Bool {
        guard let accountID = accountID ?? account?.id else { return false }
        return offline.localURL(for: file, accountID: accountID, acceptChanged: true) != nil
    }

    /// Saves an editable copy of the managed one wherever the user chooses. It is the user's file from then on, and
    /// the cloud/Mac indicator records it like any other copy iCloudy put on this Mac.
    func saveOfflineCopy(_ file: CloudFile, accountID: String? = nil) async {
        guard let accountID = accountID ?? account?.id,
              let source = offline.localURL(for: file, accountID: accountID, acceptChanged: true) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FileNames.safe(file.name)
        panel.prompt = L("Guardar una copia")
        panel.message = L("La copia que guardes es tuya y se puede editar. Sus cambios no se suben a la nube; para eso usa la sincronización en ambos sentidos.")
        guard await panel.begin() == .OK, let destination = panel.url else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            // No overwrite, even when the panel approved it: an existing file of the user's is never replaced.
            try await blockingIO {
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            }
            let entry = offline.entries[OfflineStore.key(accountID: accountID, fileID: file.id)]
            localCopies.record(LocalCopy(accountID: accountID, fileID: file.id, name: file.name, path: destination.path,
                                         bookmark: try? TransferQueue.bookmark(destination), size: entry?.size ?? file.size ?? 0,
                                         remoteModified: entry?.remoteModified ?? file.modified, savedAt: Date(), origin: .download))
        } catch { self.error = L("No se pudo guardar la copia. Si ya existe un archivo con ese nombre, elige otro. \(error.localizedDescription)") }
    }

    func revealOffline(_ pin: OfflinePin) {
        let url = offline.location(of: pin)
        guard FileManager.default.fileExists(atPath: url.path) else { error = L("«\(pin.file.name)» todavía no tiene copia sin conexión en este Mac."); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Goes to where the pinned item lives in the cloud.
    func openOfflineLocation(_ pin: OfflinePin) {
        if pin.file.isFolder { openFolder(accountID: pin.accountID, folderID: pin.file.id) }
        else if let parent = pin.parentID { openFolder(accountID: pin.accountID, folderID: parent) }
    }

    func refreshOfflineNow(_ pin: OfflinePin? = nil) {
        guard isOnline else { error = L("Sin conexión. Las copias se actualizarán solas cuando vuelva la red."); return }
        if let pin { offlineRefresher.refresh(accountID: pin.accountID, scope: .pins([pin.folder])) }
        else { offlineRefresher.refresh() }
    }

    /// The line the disconnect confirmation adds when the account has offline copies, with what they take.
    func offlineDisconnectNote(_ account: Account) -> String {
        let bytes = ([account] + Self.dependents(of: account, in: accounts)).reduce(Int64(0)) { $0 + offline.bytes(accountID: $1.id) }
        guard bytes > 0 else { return "" }
        return "\n" + L("También se borrarán sus copias sin conexión de este Mac (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))).")
    }

    /// Keeps pins on items renamed or moved from iCloudy, and refreshes them so their copies follow the new names.
    func offlineFollow(_ change: RemoteIdentityChange, account: Account, destinationPath: [CloudFile]?) {
        let parent = destinationPath.map { $0.last?.id ?? Collection.files.rootID }
        let affected = offline.remap(change, accountID: account.id, newParentID: parent)
        if !affected.isEmpty { offlineRefresher.refresh(accountID: account.id, scope: .pins(affected)) }
    }

    /// What iCloudy kept offline about an account that is leaving.
    func forgetOffline(_ accountID: String) {
        offlineRefresher.cancel(accountID: accountID)
        offline.removeAccount(accountID)
    }
}
