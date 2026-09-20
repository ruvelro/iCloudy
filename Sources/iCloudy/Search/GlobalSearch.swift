import Foundation
import Combine

struct SearchHit: Identifiable, Hashable {
    let accountID: String
    let file: CloudFile
    let parentID: String?
    var id: String { "\(accountID.utf8.count):\(accountID)\(file.id)" }
}
struct SearchPage {
    var hits: [SearchHit]
    var next: String?
    var incomplete = false
}
enum SearchFileType: String, CaseIterable, Identifiable {
    case all = "Todos", folders = "Carpetas", documents = "Documentos", images = "Imágenes", video = "Vídeos", audio = "Audio", other = "Otros"
    var id: String { rawValue }
    func matches(_ file: CloudFile) -> Bool {
        if self == .all { return true }
        let ext = (file.name as NSString).pathExtension.lowercased()
        let type: Self
        if file.isFolder { type = .folders }
        else if file.mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg"].contains(ext) { type = .images }
        else if file.mime.hasPrefix("video/") || ["mp4", "mov", "mkv", "avi", "webm"].contains(ext) { type = .video }
        else if file.mime.hasPrefix("audio/") || ["mp3", "wav", "m4a", "ogg", "flac"].contains(ext) { type = .audio }
        else if file.isGoogleDocument || file.mime == "application/pdf" || file.mime.hasPrefix("text/") || ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "rtf", "odt", "ods", "odp"].contains(ext) { type = .documents }
        else { type = .other }
        return type == self
    }
}
enum SearchAge: Int, CaseIterable, Identifiable {
    case any = 0, week = 7, month = 30, year = 365
    var id: Int { rawValue }
    var title: String { self == .any ? L("Cualquier fecha") : L("Últimos \(rawValue) días") }
}
enum SearchSize: String, CaseIterable, Identifiable {
    case any = "Cualquier tamaño", small = "Menos de 10 MB", medium = "10–100 MB", large = "100 MB o más"
    var id: String { rawValue }
}
struct SearchFilters {
    var type: SearchFileType = .all
    var age: SearchAge = .any
    var size: SearchSize = .any
    var accountID = ""
    func matches(_ hit: SearchHit, now: Date = Date()) -> Bool {
        guard accountID.isEmpty || accountID == hit.accountID, type.matches(hit.file) else { return false }
        if age != .any {
            guard let date = hit.file.modified, date >= now.addingTimeInterval(-Double(age.rawValue) * 86400) else { return false }
        }
        if size != .any {
            guard !hit.file.isFolder, let bytes = hit.file.size, bytes >= 0 else { return false }
            switch size {
            case .small: return bytes < 10_000_000
            case .medium: return bytes >= 10_000_000 && bytes < 100_000_000
            case .large: return bytes >= 100_000_000
            case .any: break
            }
        }
        return true
    }
}

@MainActor
final class GlobalSearch: ObservableObject {
    typealias Fetch = (Account, String, String?) async throws -> SearchPage
    @Published var query = ""
    @Published var filters = SearchFilters()
    @Published private(set) var submittedQuery = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var loadingIDs: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var cursors: [String: String] = [:]
    @Published private(set) var incompleteIDs: Set<String> = []
    @Published private(set) var wasCancelled = false
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var fetch: Fetch?
    private var accounts: [Account] = []
    private var seenCursors: [String: Set<String>] = [:]
    var visibleHits: [SearchHit] {
        hits.filter { filters.matches($0) }.sorted {
            if $0.file.isFolder != $1.file.isFolder { return $0.file.isFolder }
            return $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending
        }
    }
    func start(accounts: [Account], fetch: @escaping Fetch) {
        cancel()
        self.fetch = fetch; self.accounts = accounts
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = []; cursors = [:]; errors = [:]; incompleteIDs = []; seenCursors = [:]; wasCancelled = false
        guard !submittedQuery.isEmpty else { return }
        for account in accounts { loadMore(account.id) }
    }
    func loadMore(_ id: String) {
        guard !loadingIDs.contains(id), let account = accounts.first(where: { $0.id == id }), let fetch else { return }
        let request = generation, term = submittedQuery
        loadingIDs.insert(id); errors[id] = nil; wasCancelled = false
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if generation == request { loadingIDs.remove(id); tasks[id] = nil } }
            do {
                // Bounded batches keep large searches responsive; the user can explicitly fetch more.
                for _ in 0..<3 {
                    let cursor = cursors[id]
                    let page = try await fetch(account, term, cursor)
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    var ids = Set(hits.map(\.id))
                    hits += page.hits.filter { $0.accountID == id && ids.insert($0.id).inserted }
                    if page.incomplete { incompleteIDs.insert(id) }
                    cursors[id] = page.next
                    guard let next = page.next else { break }
                    guard seenCursors[id, default: []].insert(next).inserted else {
                        cursors[id] = nil; throw CloudError.message(L("El proveedor repitió una página. Se conservan los resultados recibidos; vuelve a buscar para actualizar."))
                    }
                }
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                errors[id] = error.localizedDescription
            }
        }
    }
    func cancel() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        if !loadingIDs.isEmpty { wasCancelled = true }
        loadingIDs = []
    }
    func removeAccount(_ id: String) {
        // Invalidate all callbacks so an in-flight request cannot restore a disconnected account.
        cancel(); accounts.removeAll { $0.id == id }; hits.removeAll { $0.accountID == id }
        cursors[id] = nil; errors[id] = nil; incompleteIDs.remove(id)
        if filters.accountID == id { filters.accountID = "" }
    }
}

