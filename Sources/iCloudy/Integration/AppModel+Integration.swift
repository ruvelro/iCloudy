import AppKit
import SwiftUI
import Combine

extension AppModel {
    /// Queues the given local files; returns false when the current view cannot receive uploads.
    @discardableResult func uploadFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(\.isFileURL)
        if !urls.isEmpty { return enqueueUploads(urls) }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = L("El portapapeles no contiene archivos ni texto.")
            return false
        }
        return uploadText(text)
    }

    /// Writes clipboard text to a temporary .txt and queues it. The temporary file lives in iCloudy's own cache.
    @discardableResult func uploadText(_ text: String) -> Bool {
        guard canWrite else { error = L("Abre una carpeta de «Mis archivos» para subir aquí. Recientes y Compartido conmigo son listas, no carpetas."); return false }
        do {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Pasteboard", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let url = FileNames.available(in: folder, name: "Portapapeles \(stamp).txt")
            try Data(text.utf8).write(to: url, options: .atomic)
            return enqueueUploads([url])
        } catch { self.error = error.localizedDescription; return false }
    }

    func syncAllMirrors() -> Int {
        for mirror in mirrors.mirrors { mirrors.syncNow(mirror.id) }
        return mirrors.mirrors.count
    }

    func storageSummary() -> String {
        guard !accounts.isEmpty else { return L("No hay ninguna cuenta conectada en iCloudy.") }
        return accounts.map { account in
            switch storageQuotas[account.id] {
            case .available(let quota): return accountTitle(account) + " (" + account.email + "): " + quota.summary
            case .unavailable(let message): return accountTitle(account) + " (" + account.email + "): " + message
            default: return accountTitle(account) + " (" + account.email + "): " + L("consultando…")
            }
        }.joined(separator: "\n")
    }

    /// Shared by the search view, the menu bar and the Shortcuts action.
    func startGlobalSearch(_ term: String) {
        preview.close()
        showGlobalSearch = true
        globalSearch.query = String(term.prefix(256))
        // Providers without a search API would only add an error row to every search.
        let submittedFilters = globalSearch.filters
        let submittedAt = Date()
        globalSearch.start(accounts: accounts.filter { $0.capabilities.search }) { [weak self] account, query, cursor in
            guard let self else { throw CancellationError() }
            return try await self.client(account).searchPage(term: query, cursor: cursor, filters: submittedFilters, referenceDate: submittedAt)
        }
    }

    /// Handles a Spotlight result: folders open in place, files open their preview, because only the item itself was indexed.
    func openSpotlightItem(identifier: String) {
        guard !loadingAccounts else { pendingSpotlightItem = identifier; return }
        guard let decoded = SpotlightIndex.decode(identifier: identifier),
              let entry = spotlight.items.first(where: { $0.accountID == decoded.accountID && $0.file.id == decoded.fileID }),
              let account = accounts.first(where: { $0.id == decoded.accountID }) else {
            error = L("Ese resultado ya no está disponible en iCloudy. Vuelve a conectar la cuenta o búscalo de nuevo.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if entry.file.isFolder { openFolder(accountID: account.id, folderID: entry.file.id) }
        else {
            showGlobalSearch = false
            selectedAccountID = account.id
            do { preview.show(file: entry.file, account: account, client: try client(account)) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Where this file stands: only in the cloud, downloaded, or downloaded but behind the cloud.
    func localStatus(_ file: CloudFile) -> LocalCopyStatus {
        guard let account else { return .cloudOnly }
        return localCopies.status(for: file, accountID: account.id)
    }

    func revealLocalCopy(_ file: CloudFile) {
        guard let copy = localStatus(file).copy else { return }
        if !localCopies.reveal(copy) {
            error = L("«\(copy.name)» ya no está en \(copy.path). Se ha quitado de la lista de copias locales.")
            localCopies.forget(accountID: copy.accountID, fileID: copy.fileID)
        }
    }

    func forgetLocalCopy(_ file: CloudFile) {
        guard let account else { return }
        localCopies.forget(accountID: account.id, fileID: file.id)
    }

    /// Republishes the favorites of the accounts that are actually connected. Favorites are kept when an account is
    /// disconnected, on purpose, but publishing them again put back in the system's search exactly what disconnecting
    /// had just removed from it.
    func refreshSpotlightFavorites() {
        let connected = Set(accounts.map(\.id))
        spotlight.refreshFavorites(favorites.filter { connected.contains($0.accountID) }) { [weak self] id in
            self?.accounts.first { $0.id == id }.map { self?.accountTitle($0) ?? $0.email } ?? id
        }
    }

    func noteForSpotlight(_ file: CloudFile, account: Account) {
        spotlight.note(file, accountID: account.id, path: path, accountLabel: accountTitle(account))
    }

    /// Reads the stored accounts off the main thread. The Keychain call can block for a long time: macOS asks the user
    /// for permission whenever the app's signature changes, and doing that inside `init` froze the launch before SwiftUI
    /// had built any window, leaving a running app with nothing on screen.
    func clearMaintenance(_ kind: Maintenance.Kind) throws {
        switch kind {
        case .listings: listings.clear()
        case .scratch: queue.cleanScratch()
        case .pasteboard:
            try Maintenance.clear(kind, preserving: queue.protectedLocalURLs)
        case .previews:
            // The viewer owns its active directory; old directories can be removed without interrupting it.
            try Maintenance.clear(kind, preserving: preview.model.protectedDirectories)
        case .localCopies: localCopies.clear()
        case .history: history.clear()
        case .spotlight: spotlight.clear()
        case .demo:
            guard !queue.items.contains(where: { (!$0.finished || queue.hasActive(accountID: $0.accountID) || ($0.targetAccountID.map { queue.hasActive(accountID: $0) } ?? false)) && ($0.accountID.hasPrefix("demo:") || ($0.targetAccountID?.hasPrefix("demo:") ?? false)) }) else {
                throw CloudError.message(L("La demo tiene transferencias pendientes. Termínalas o cancélalas antes de vaciarla."))
            }
            preview.close()
            sessions.remove { $0.hasPrefix("demo:") }; demo = nil
            try Maintenance.clear(kind)
        }
    }

    /// Asks for a local folder and mirrors it, one way, into the given remote folder of the current account.
    func pickMirrorSource(for folder: CloudFile, twoWay: Bool = false) async {
        guard let account, folder.isFolder else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = twoWay ? L("Sincronizar") : L("Reflejar")
        panel.message = twoWay
            ? L("La carpeta elegida y «\(folder.name)» se mantendrán iguales en los dos sentidos: lo que cambie en una se aplica en la otra. Lo borrado en un lado va a la papelera del otro, si la tiene; si un archivo cambia en los dos a la vez se conservan las dos versiones. Un borrado de la mayor parte de un lado se detiene y pregunta.")
            : L("Los archivos de la carpeta elegida se subirán a «\(folder.name)» y se mantendrán al día. Solo en un sentido: iCloudy nunca borra ni modifica lo local, y no elimina en la nube lo que borres aquí.")
        guard await panel.begin() == .OK, let local = panel.url else { return }
        do {
            try mirrors.add(local: local, account: account, folder: folder, path: path, mode: twoWay ? .twoWay : .upload)
            info = twoWay ? L("«\(local.lastPathComponent)» y «\(folder.name)» se sincronizan en ambos sentidos. La primera pasada está en marcha.")
                          : L("«\(local.lastPathComponent)» se refleja en «\(folder.name)». La primera sincronización está en cola.")
        } catch { self.error = error.localizedDescription }
    }

    func revealLocal(_ mirror: FolderMirror) { NSWorkspace.shared.activateFileViewerSelecting([mirror.localURL]) }

    /// Shows a downloaded item in the Finder, going through its security-scoped bookmark under the sandbox.
    func reveal(_ entry: HistoryEntry) {
        guard let target = entry.localURL else { return }
        var folder = target.deletingLastPathComponent()
        if let bookmark = entry.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { folder = resolved }
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let item = folder.appendingPathComponent(target.lastPathComponent)
        guard FileManager.default.fileExists(atPath: item.path) else { error = L("«\(target.lastPathComponent)» ya no está en \(folder.path)."); return }
        NSWorkspace.shared.activateFileViewerSelecting([item])
    }

    func openBrowser(_ file: CloudFile) {
        guard let url = file.webURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { error = L("No hay un enlace web disponible."); return }
        NSWorkspace.shared.open(url)
    }

    func isFavorite(_ file: CloudFile) -> Bool { favoriteKeys.contains((selectedAccountID ?? "") + ":" + file.id) }

    func toggleFavorite(_ file: CloudFile) {
        guard let account else { return }
        if isFavorite(file) { favorites.removeAll { $0.accountID == account.id && $0.file.id == file.id } }
        else { favorites.append(Favorite(accountID: account.id, file: file, path: path, collection: collection)) }
        do { try LocalStore.save(favorites, to: favoritesURL) } catch { self.error = error.localizedDescription }
        refreshSpotlightFavorites()
    }

    func openFavorite(_ favorite: Favorite) {
        guard accounts.contains(where: { $0.id == favorite.accountID }) else { error = L("Conecta la cuenta de este favorito."); return }
        preview.close()
        showGlobalSearch = false; globalSearch.cancel()
        selectedAccountID = favorite.accountID; collection = favorite.collection; path = favorite.path + (favorite.file.isFolder ? [favorite.file] : []); files = []; search = ""; reload()
    }
}
