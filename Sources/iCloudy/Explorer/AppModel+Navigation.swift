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
            }
        }
    }

    /// The files a multi-selection acts on: only what the list shows. The selection keeps ids of rows the filter has
    /// hidden, and acting on those sent things to the bin that were not on screen.
    func selection(_ ids: Set<String>) -> [CloudFile] { Self.selected(ids, among: visibleFiles) }

    static func selected(_ ids: Set<String>, among visible: [CloudFile]) -> [CloudFile] { visible.filter { ids.contains($0.id) } }

    func select(_ id: String?) { preview.close(); globalSearch.cancel(); showGlobalSearch = false; selectedAccountID = id; collection = .files; path = []; search = ""; files = []; reload() }

    func show(_ target: Collection) {
        guard let account, target != collection || !path.isEmpty else { return }
        guard Self.collections(for: account).contains(target) else { return }
        preview.close(); collection = target; path = []; search = ""; files = []
        // Recents only make sense in time order; the user can switch back afterwards.
        if target == .recent { sortMode = "date" } else if sortMode == "date" && target == .files { sortMode = "name" }
        reload()
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
        navigationTask?.cancel(); let request = UUID(); navigationID = request; loading = true
        navigationTask = Task {
            do {
                let trail = try await client(account).folderTrail(id: target)
                try Task.checkCancellation()
                guard navigationID == request else { return }
                preview.close(); globalSearch.cancel(); showGlobalSearch = false
                selectedAccountID = account.id; collection = .files; path = trail; search = ""; files = []; reload()
            } catch {
                guard navigationID == request else { return }
                loading = false
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func showPreview(_ file: CloudFile) {
        guard let account else { return }
        noteForSpotlight(file, account: account)
        do { preview.show(file: file, account: account, client: try client(account)) }
        catch { self.error = error.localizedDescription }
    }

    func navigate(_ file: CloudFile) {
        guard file.isFolder, let account else { return }
        noteForSpotlight(file, account: account)
        preview.close(); path.append(file); search = ""; files = []; reload()
    }

    func back(to count: Int) { preview.close(); path = Array(path.prefix(count)); search = ""; files = []; reload() }

    /// What the "Actualizar" button does: forget what the provider handed out earlier and ask again. `reload(fresh:)`
    /// alone was enough for providers that are asked folder by folder, not for one that sends the whole account once.
    func refresh() {
        if let account, let client = try? client(account) { client.dropCaches() }
        reload(fresh: true)
    }

    /// `fresh` skips the cached copy, e.g. right after a write the cache cannot know about yet.
    func reload(fresh: Bool = false) {
        navigationTask?.cancel()
        let requestID = UUID(); navigationID = requestID
        guard let account else { files = []; loading = false; showingCachedListing = false; return }
        refreshStorage(account)
        let parent = folderID; loading = true
        // Show what was there last time at once; the provider's answer replaces it when it arrives.
        if !fresh, Prefs.bool(Prefs.listingCache, default: true), files.isEmpty,
           let cached = listings.cached(accountID: account.id, parent: parent) { files = cached; showingCachedListing = true }
        else if fresh { showingCachedListing = false }
        navigationTask = Task {
            do {
                // Intermediate pages appear as they arrive; `loading` stays on until the last one.
                let result = try await client(account).list(parent: parent) { partial in
                    guard self.navigationID == requestID else { return }
                    self.files = partial; self.showingCachedListing = false
                }
                guard navigationID == requestID else { return }
                files = result; loading = false; showingCachedListing = false
                listings.store(result, accountID: account.id, parent: parent)
                // Drop entries whose local file the user has moved or deleted meanwhile.
                localCopies.verify(result, accountID: account.id)
            } catch {
                guard navigationID == requestID else { return }
                loading = false
                // An expired session already shows a banner with a reconnect button; an extra alert would only repeat it.
                if (error as? CloudError)?.isSessionExpired == true { return }
                if !isOnline { return } // the banner already says so
                if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
