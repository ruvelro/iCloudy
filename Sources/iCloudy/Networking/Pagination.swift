import Foundation

/// Follows a cursor-paged listing to its end. Every provider had its own loop, and none of them noticed a server that
/// hands back a cursor it already gave: the listing then spun for ever, one request after another.
@MainActor
enum Pagination {
    struct Looping: LocalizedError {
        var errorDescription: String? { L("El servicio devolvió la misma página una y otra vez, así que se ha dejado de pedir más.") }
    }
    /// `first` is the first page; `cursor` reads where the next one starts, or nil at the end; `next` fetches it.
    /// `each` sees every page, the first included, and `between` runs before each further request (to show what is
    /// already there). A repeated cursor, or more than `limit` pages, ends the walk with `Looping`.
    static func follow(first: [String: Any], cursor: ([String: Any]) -> String?, next: (String) async throws -> [String: Any],
                       each: ([String: Any]) -> Void, between: () -> Void = {}, limit: Int = 100_000) async throws {
        var page = first
        var seen: Set<String> = []
        while true {
            each(page)
            guard let position = cursor(page) else { return }
            guard seen.insert(position).inserted, seen.count <= limit else { throw Looping() }
            between()
            try Task.checkCancellation()
            page = try await next(position)
        }
    }
}
