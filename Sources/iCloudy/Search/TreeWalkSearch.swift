import Foundation

/// Search for providers that have none: the tree is walked folder by folder and names are matched here. It costs one
/// listing per folder, so each page walks a bounded number of folders and the next page carries on from the same
/// place; "Cargar más" in the search window keeps going. Very large trees stop at `folderLimit`, and the results say
/// they are incomplete.
struct TreeWalk {
    let term: String
    var pending: [String]
    var visited = 0
    var started = Date()
}

enum TreeWalkSearch {
    static let foldersPerPage = 40
    static let secondsPerPage: TimeInterval = 12
    static let folderLimit = 6_000
    /// A walk left unfinished is forgotten after this long, so an abandoned search does not keep its queue forever.
    static let lifetime: TimeInterval = 30 * 60
}

extension CloudProvider {
    func walkSearch(term: String, cursor: String?) async throws -> SearchPage {
        let now = Date()
        treeWalks = treeWalks.filter { now.timeIntervalSince($0.value.started) < TreeWalkSearch.lifetime }
        var walk: TreeWalk
        if let cursor {
            guard let saved = treeWalks.removeValue(forKey: cursor), saved.term == term else {
                throw CloudError.message(L("Esta búsqueda ha caducado. Vuelve a buscar."))
            }
            walk = saved
        } else {
            walk = TreeWalk(term: term, pending: [try await rootID()])
        }
        var hits: [SearchHit] = []
        var listed = 0
        let pageStart = Date()
        while !walk.pending.isEmpty, listed < TreeWalkSearch.foldersPerPage, Date().timeIntervalSince(pageStart) < TreeWalkSearch.secondsPerPage,
              walk.visited < TreeWalkSearch.folderLimit {
            try Task.checkCancellation()
            let folder = walk.pending.removeFirst()
            listed += 1; walk.visited += 1
            let children: [CloudFile]
            do { children = try await list(parent: folder, onPage: nil) }
            catch let error as CloudError where error.isSessionExpired { throw error }
            catch is CancellationError { throw CancellationError() }
            // A folder this account may not read is skipped, as `find` would; the rest of the tree is still worth it.
            catch { continue }
            for child in children {
                if child.name.localizedCaseInsensitiveContains(term) { hits.append(SearchHit(accountID: account.id, file: child, parentID: folder)) }
                if child.isFolder { walk.pending.append(child.id) }
            }
        }
        guard !walk.pending.isEmpty else { return SearchPage(hits: hits, next: nil) }
        guard walk.visited < TreeWalkSearch.folderLimit else { return SearchPage(hits: hits, next: nil, incomplete: true) }
        let token = UUID().uuidString
        treeWalks[token] = walk
        return SearchPage(hits: hits, next: token)
    }
}
