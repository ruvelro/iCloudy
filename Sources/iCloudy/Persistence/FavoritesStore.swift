import Foundation

/// The favorites and the file they live in.
///
/// They used to be an array on the model that seven places edited and saved by hand, one of them from outside the
/// model, each with a synchronous write on the main actor. An unreadable file also started an empty list that the
/// first star then wrote over it, so every favorite was gone for good. Here every change goes through one owner,
/// is written in the background, and a file that cannot be read is set aside before anything replaces it.
@MainActor
@Observable
final class FavoritesStore {
    private(set) var items: [Favorite] = [] { didSet { keys = Set(items.map(\.id)) } }
    /// `accountID:fileID` of every favorite, so a row asks a set instead of walking the list.
    private(set) var keys: Set<String> = []
    @ObservationIgnored let url: URL
    /// Why the stored list could not be read, said once when the app starts.
    @ObservationIgnored private(set) var loadError: String?
    /// Runs after every change, for what mirrors the list elsewhere: Spotlight.
    @ObservationIgnored var didChange: (() -> Void)?
    /// A background write that failed.
    @ObservationIgnored var saveFailed: ((String) -> Void)?

    init(url: URL = LocalStore.directory.appendingPathComponent("favorites.json")) {
        self.url = url
        do { items = try LocalStore.read(StoreEnvelope<[Favorite]>.self, from: url)?.items ?? [] }
        catch {
            // Starting empty is fine; writing that empty list over bytes a later version might read is not.
            let kept = try? LocalStore.setAside(url)
            loadError = L("No se pudieron leer los favoritos: \(error.localizedDescription) La lista empieza vacía.")
                + (kept.map { " " + L("El archivo original se conserva en \($0.path).") } ?? "")
        }
        // Property observers do not run while an initializer sets its own properties.
        keys = Set(items.map(\.id))
    }

    func contains(accountID: String, fileID: String) -> Bool { keys.contains(accountID + ":" + fileID) }

    func toggle(_ file: CloudFile, accountID: String, path: [CloudFile], collection: Collection) {
        if contains(accountID: accountID, fileID: file.id) { items.removeAll { $0.accountID == accountID && $0.file.id == file.id } }
        else { items.append(Favorite(accountID: accountID, file: file, path: path, collection: collection)) }
        save()
    }

    /// Drags a favourite to where another one is, the way the clouds and the tabs are reordered.
    func move(_ id: Favorite.ID, to target: Favorite.ID) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        items.insert(items.remove(at: from), at: to)
        save()
    }

    /// One place up (-1) or down (+1), for the keyboard and the context menu.
    func move(_ id: Favorite.ID, by offset: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }), items.indices.contains(from + offset) else { return }
        items.swapAt(from, from + offset)
        save()
    }

    func canMove(_ id: Favorite.ID, by offset: Int) -> Bool {
        items.firstIndex(where: { $0.id == id }).map { items.indices.contains($0 + offset) } ?? false
    }

    /// The item is gone. `inside` also drops the favorites that live below it, which are gone with it.
    func remove(accountID: String, fileID: String, inside: Bool = true) {
        let before = items.count
        items.removeAll { $0.accountID == accountID && ($0.file.id == fileID || (inside && $0.path.contains { $0.id == fileID })) }
        if items.count != before { save() }
    }

    /// The item now lives in `path`, in the files collection, as a move leaves it.
    func moved(accountID: String, fileID: String, to path: [CloudFile]) {
        var changed = false
        for i in items.indices where items[i].accountID == accountID && items[i].file.id == fileID {
            items[i].path = path; items[i].collection = .files; changed = true
        }
        if changed { save() }
    }

    /// Follows a rename or a move whose provider changed the item's identity, and the favorites below it.
    func apply(_ change: RemoteIdentityChange, accountID: String, destinationPath: [CloudFile]?) {
        guard items.contains(where: { $0.accountID == accountID }) else { return }
        for i in items.indices where items[i].accountID == accountID {
            let old = items[i].file.id
            items[i].file = change.file(items[i].file)
            items[i].path = items[i].path.map(change.file)
            if let destinationPath {
                if old == change.oldID { items[i].path = destinationPath }
                else if let position = items[i].path.firstIndex(where: { $0.id == change.newID }) {
                    items[i].path = destinationPath + items[i].path[position...]
                }
            }
        }
        save()
    }

    /// Publishes the favorites of the accounts that are connected. Favorites are kept when an account is disconnected,
    /// on purpose, but publishing them again put back in the system's search what disconnecting had just removed.
    func publish(to spotlight: SpotlightIndex, connected: Set<String>, label: (String) -> String) {
        spotlight.refreshFavorites(items.filter { connected.contains($0.accountID) }, label: label)
    }

    /// Written in the background; a burst of changes, such as a whole selection sent to the trash, costs one write.
    private func save() {
        StoreWriter.shared.later(StoreEnvelope(items), to: url) { [weak self] error in
            self?.saveFailed?(L("No se pudieron guardar los favoritos: \(error.localizedDescription)"))
        }
        didChange?()
    }
}
