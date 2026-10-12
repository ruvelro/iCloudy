import Foundation
import Combine

/// A search kept under a name: the text and the filters, never the results, which are asked for again each time.
struct SavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: String
    var type: String
    var age: Int
    var size: String
    var accountID: String

    init(name: String, query: String, filters: SearchFilters) {
        self.name = name; self.query = query
        type = filters.type.rawValue; age = filters.age.rawValue; size = filters.size.rawValue; accountID = filters.accountID
    }
    /// Filters as they were saved. One a later version no longer knows falls back to "any", rather than losing the search.
    var filters: SearchFilters {
        SearchFilters(type: SearchFileType(rawValue: type) ?? .all, age: SearchAge(rawValue: age) ?? .any,
                      size: SearchSize(rawValue: size) ?? .any, accountID: accountID)
    }
}

@MainActor
final class SavedSearches: ObservableObject {
    @Published private(set) var items: [SavedSearch] = []
    @Published private(set) var failure: String?
    let url: URL

    init(url: URL = LocalStore.directory.appendingPathComponent("saved-searches.json")) {
        self.url = url
        do { items = try LocalStore.read([SavedSearch].self, from: url) ?? [] }
        catch { failure = L("No se pudieron leer las búsquedas guardadas: \(error.localizedDescription)") }
    }

    /// Saving under a name that exists replaces that search, as the Finder does with smart folders.
    func save(name: String, query: String, filters: SearchFilters) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let search = SavedSearch(name: trimmed, query: query, filters: filters)
        if let index = items.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) { items[index] = search }
        else { items.append(search) }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }
    func remove(_ id: SavedSearch.ID) { items.removeAll { $0.id == id }; persist() }

    private func persist() {
        do { try LocalStore.save(items, to: url); failure = nil }
        catch { failure = L("No se pudieron guardar las búsquedas: \(error.localizedDescription)") }
    }
}

extension AppModel {
    func runSavedSearch(_ search: SavedSearch) {
        globalSearch.filters = search.filters
        startGlobalSearch(search.query)
    }
}
