import Foundation

/// A folder that was open in some tab, and when.
struct RecentLocation: Identifiable, Codable, Equatable {
    var id: String { accountID + ":" + (path.last?.id ?? "") }
    let accountID: String
    /// The folders from the top of the account down to this one; empty for the top itself.
    var path: [CloudFile]
    var visited: Date

    var location: BrowserLocation { BrowserLocation(accountID: accountID, collection: .files, path: path) }
}

extension RecentLocation {
    enum CodingKeys: String, CodingKey { case accountID, path, visited }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try values.decode(String.self, forKey: .accountID),
                  path: try values.decodeIfPresent([CloudFile].self, forKey: .path) ?? [],
                  visited: try values.decodeIfPresent(Date.self, forKey: .visited) ?? .distantPast)
    }
}

/// The last folders visited, across tabs, panes and accounts: the Finder's "Carpetas recientes".
///
/// Kept the way the favourites are: one owner, written in the background, and a file that cannot be read is set
/// aside before an empty list replaces it. Only folders of "Mis archivos" are kept — a recents list or the bin is no
/// place to go back to — and never the decrypted names of a vault.
@MainActor
@Observable
final class RecentLocationsStore {
    static let limit = 20
    /// Newest first.
    private(set) var items: [RecentLocation] = []
    @ObservationIgnored let url: URL
    @ObservationIgnored private(set) var loadError: String?
    @ObservationIgnored var saveFailed: ((String) -> Void)?

    init(url: URL = LocalStore.directory.appendingPathComponent("recent-locations.json")) {
        self.url = url
        do { items = Array((try LocalStore.read(StoreEnvelope<[RecentLocation]>.self, from: url)?.items ?? []).prefix(Self.limit)) }
        catch {
            let kept = try? LocalStore.setAside(url)
            loadError = L("No se pudieron leer las carpetas recientes: \(error.localizedDescription) La lista empieza vacía.")
                + (kept.map { " " + L("El archivo original se conserva en \($0.path).") } ?? "")
        }
    }

    /// Puts `location` at the top, once. Returns false when it is not a place worth keeping.
    @discardableResult func note(_ location: BrowserLocation, at date: Date = Date()) -> Bool {
        guard let accountID = location.accountID, location.collection == .files,
              !CryptomatorVaults.isVaultAccount(accountID) else { return false }
        let entry = RecentLocation(accountID: accountID, path: location.path, visited: date)
        if items.first?.id == entry.id, items.first?.path.map(\.name) == entry.path.map(\.name) { return true }
        items.removeAll { $0.id == entry.id }
        items.insert(entry, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
        return true
    }

    func remove(_ id: RecentLocation.ID) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { save() }
    }

    func clear() {
        guard !items.isEmpty else { return }
        items = []
        save()
    }

    /// The item is gone, or has moved: every place at it or below it goes too.
    func forget(accountID: String, fileID: String) {
        let before = items.count
        items.removeAll { $0.accountID == accountID && $0.path.contains { $0.id == fileID } }
        if items.count != before { save() }
    }

    /// Follows a rename: the names (and, where the provider changes them, the ids) in each kept path.
    func apply(_ change: RemoteIdentityChange, accountID: String) {
        let before = items
        for i in items.indices where items[i].accountID == accountID { items[i].path = items[i].path.map(change.file) }
        if items != before { save() }
    }

    private func save() {
        StoreWriter.shared.later(StoreEnvelope(items), to: url) { [weak self] error in
            self?.saveFailed?(L("No se pudieron guardar las carpetas recientes: \(error.localizedDescription)"))
        }
    }
}

extension AppModel {
    /// Opens a recent folder in the focused tab, like a favourite.
    func openRecent(_ recent: RecentLocation) {
        guard accounts.contains(where: { $0.id == recent.accountID }) else { error = L("Conecta la cuenta de esta carpeta."); return }
        preview.close()
        ui.showGlobalSearch = false; globalSearch.cancel()
        go(to: recent.location)
    }

    /// What a recent folder is called in a list: its name, or the account's at the top.
    func recentTitle(_ recent: RecentLocation) -> String {
        recent.path.last?.name ?? accounts.first { $0.id == recent.accountID }.map { accountTitle($0) } ?? L("Inicio")
    }
}
