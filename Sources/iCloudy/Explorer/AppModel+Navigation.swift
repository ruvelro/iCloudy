import AppKit
import SwiftUI
import Combine

extension AppModel {
    /// Top-level views this account's provider can actually produce. Static because it depends only on the account,
    /// and because the header's layout rests on this never being empty, which is worth testing on its own.
    static func collections(for account: Account) -> [Collection] {
        let capabilities = account.capabilities
        return Collection.allCases.filter {
            switch $0 {
            case .files: return true
            case .recent: return capabilities.recents
            case .shared: return capabilities.sharedWithMe
            case .trash: return capabilities.trashListing
            }
        }
    }

    /// The files a multi-selection acts on: only what the list shows. The selection keeps ids of rows the filter has
    /// hidden, and acting on those sent things to the bin that were not on screen.
    func selection(_ ids: Set<String>) -> [CloudFile] { Self.selected(ids, among: visibleFiles) }

    static func selected(_ ids: Set<String>, among visible: [CloudFile]) -> [CloudFile] { visible.filter { ids.contains($0.id) } }

    func select(_ id: String?) { preview.close(); globalSearch.cancel(); showGlobalSearch = false; go(to: BrowserLocation(accountID: id)) }

    /// Takes a tab somewhere else, the focused one unless told otherwise. Everything that changes where a tab stands
    /// goes through here, so the listing, the filter and the selection of the old place never leak into the new one.
    func go(to target: BrowserLocation, tab id: BrowserState.ID? = nil) {
        let id = id ?? workspace.current.id
        workspace.update(id) { $0.open(target) }
        reload(tab: id)
    }

    func show(_ target: Collection) {
        guard let account, target != collection || !path.isEmpty else { return }
        guard Self.collections(for: account).contains(target) else { return }
        preview.close()
        // Recents only make sense in time order; the user can switch back afterwards.
        if target == .recent { sortMode = "date" } else if sortMode == "date" && target == .files { sortMode = "name" }
        go(to: BrowserLocation(accountID: account.id, collection: target))
    }

    func previewSearchHit(_ hit: SearchHit) {
        guard let account = accounts.first(where: { $0.id == hit.accountID }) else { return }
        do { preview.show(file: hit.file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }

    func openSearchLocation(_ hit: SearchHit) {
        guard let target = hit.file.isFolder ? hit.file.id : hit.parentID else { return }
        openFolder(accountID: hit.accountID, folderID: target)
    }

    /// Jumps to a remote folder of any connected account, rebuilding the breadcrumbs from the provider.
    func openFolder(accountID: String, folderID target: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { error = L("Conecta la cuenta de esta transferencia para abrir su carpeta."); return }
        // The jump lands in the tab that asked for it, even if another one has the focus by the time the trail arrives.
        let tab = workspace.current.id
        navigationTasks[tab]?.cancel(); let request = UUID()
        workspace.update(tab) { $0.navigationID = request; $0.loading = true }
        navigationTasks[tab] = Task {
            do {
                let trail = try await client(account).folderTrail(id: target)
                try Task.checkCancellation()
                guard isAwaited(request, by: tab) else { return }
                preview.close(); globalSearch.cancel(); showGlobalSearch = false
                go(to: BrowserLocation(accountID: account.id, collection: .files, path: trail), tab: tab)
            } catch {
                guard isAwaited(request, by: tab) else { return }
                workspace.update(tab) { $0.loading = false }
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// True while `request` is still the answer this tab is waiting for.
    func isAwaited(_ request: UUID, by tab: BrowserState.ID) -> Bool { workspace.tab(tab)?.navigationID == request }

    func showPreview(_ file: CloudFile) {
        guard let account else { return }
        noteForSpotlight(file, account: account)
        do { preview.show(file: file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }

    func navigate(_ file: CloudFile) {
        // A binned folder is restored or purged whole; what hangs below it is not browsed, the way the providers'
        // own bins work, so the list never shows a place nothing can be uploaded to or moved within.
        guard file.isFolder, let account, !inTrash else { return }
        noteForSpotlight(file, account: account)
        preview.close(); go(to: BrowserLocation(accountID: account.id, collection: collection, path: path + [file]))
    }

    var canGoBack: Bool { !workspace.current.back.isEmpty }
    var canGoForward: Bool { !workspace.current.forward.isEmpty }

    /// The previous place of the focused tab, like a browser's back button. Places of accounts that are no longer
    /// connected are skipped instead of opening an empty list.
    func goBack() { retrace { $0.goBack(where: $1) } }
    func goForward() { retrace { $0.goForward(where: $1) } }

    private func retrace(_ step: (inout BrowserState, (BrowserLocation) -> Bool) -> Bool) {
        let connected = Set(accounts.map(\.id))
        var moved = false
        workspace.update(workspace.current.id) { tab in
            moved = step(&tab) { place in place.accountID.map(connected.contains) ?? false }
        }
        guard moved else { return }
        preview.close(); globalSearch.cancel(); showGlobalSearch = false
        reload()
    }

    func back(to count: Int) { preview.close(); go(to: BrowserLocation(accountID: selectedAccountID, collection: collection, path: Array(path.prefix(count)))) }

    /// What the "Actualizar" button does: forget what the provider handed out earlier and ask again. `reload(fresh:)`
    /// alone was enough for providers that are asked folder by folder, not for one that sends the whole account once.
    func refresh() {
        if let account, let client = try? client(account) { client.dropCaches() }
        reload(fresh: true)
    }

    /// `fresh` skips the cached copy, e.g. right after a write the cache cannot know about yet.
    func reload(fresh: Bool = false) { reload(tab: workspace.current.id, fresh: fresh) }

    /// Lists again what the tabs on screen show, those of one account or all of them.
    func reloadVisible(accountID: String? = nil, fresh: Bool = false) {
        for tab in workspace.visibleTabs {
            guard let id = tab.accountID, accountID == nil || id == accountID, accounts.contains(where: { $0.id == id }) else { continue }
            reload(tab: tab.id, fresh: fresh)
        }
    }

    /// Lists one tab's folder. The answer is written into that tab, wherever it is by then, and only if it is still
    /// the one the tab is waiting for.
    func reload(tab id: BrowserState.ID, fresh: Bool = false) {
        navigationTasks[id]?.cancel()
        let requestID = UUID()
        workspace.update(id) { $0.navigationID = requestID }
        guard let state = workspace.tab(id), let account = accounts.first(where: { $0.id == state.accountID }) else {
            workspace.update(id) { $0.files = []; $0.loading = false; $0.showingCachedListing = false }
            return
        }
        refreshStorage(account)
        let parent = state.folderID
        // Show what was there last time at once; the provider's answer replaces it when it arrives.
        let cached = !fresh && Prefs.bool(Prefs.listingCache, default: true) && state.files.isEmpty ? listings.cached(accountID: account.id, parent: parent) : nil
        workspace.update(id) { tab in
            tab.loading = true
            if let cached { tab.files = cached; tab.showingCachedListing = true }
            else if fresh { tab.showingCachedListing = false }
        }
        navigationTasks[id] = Task {
            do {
                // Intermediate pages appear as they arrive; `loading` stays on until the last one.
                let result = try await client(account).list(parent: parent) { partial in
                    guard self.isAwaited(requestID, by: id) else { return }
                    self.workspace.update(id) { $0.files = partial; $0.showingCachedListing = false }
                }
                guard isAwaited(requestID, by: id) else { return }
                workspace.update(id) { $0.files = result; $0.loading = false; $0.showingCachedListing = false }
                listings.store(result, accountID: account.id, parent: parent)
                // Drop entries whose local file the user has moved or deleted meanwhile.
                localCopies.verify(result, accountID: account.id)
            } catch {
                guard isAwaited(requestID, by: id) else { return }
                workspace.update(id) { $0.loading = false }
                // An expired session already shows a banner with a reconnect button; an extra alert would only repeat it.
                if (error as? CloudError)?.isSessionExpired == true { return }
                if !isOnline { return } // the banner already says so
                if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
