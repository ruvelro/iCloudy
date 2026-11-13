import Foundation

/// Box keeps a stream of events per user. `stream_type=changes` leaves in only what alters the file tree, and each
/// event names the item it happened to and the folder that item is in.
extension BoxProvider {
    private func events(_ position: String, limit: Int) -> URL {
        var url = URLComponents(string: "https://api.box.com/2.0/events")!
        url.queryItems = [URLQueryItem(name: "stream_position", value: position), URLQueryItem(name: "stream_type", value: "changes"),
                          URLQueryItem(name: "limit", value: String(limit))]
        return url.url!
    }
    /// Box writes the position as a number in some answers and as a string in others.
    private static func position(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return (value as? NSNumber)?.stringValue
    }

    func changeCursor(for folder: String) async throws -> String? {
        guard let position = Self.position(try await json(events("now", limit: 1))["next_stream_position"]) else {
            throw CloudError.message(L("Box no devolvió la posición de su registro de cambios."))
        }
        return position
    }

    func changes(since cursor: String, in folder: String) async throws -> ChangeBatch {
        var batch = ChangeBatch(cursor: cursor)
        var pages = 0
        while true {
            pages += 1
            guard pages <= ChangeFeedLimits.pages else {
                batch.reset = true
                batch.cursor = try await changeCursor(for: folder) ?? cursor
                return batch
            }
            let result = try await json(events(batch.cursor, limit: 500))
            let entries = result["entries"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let source = entry["source"] as? [String: Any] else { continue }
                let parent = (source["parent"] as? [String: Any])?["id"] as? String
                batch.changes.append(RemoteChange(id: source["id"] as? String, parents: parent.map { [$0] } ?? []))
            }
            let next = Self.position(result["next_stream_position"])
            // The stream is drained when a page comes back empty or the position stops moving.
            guard !entries.isEmpty, let next, next != batch.cursor else {
                if let next { batch.cursor = next }
                return batch
            }
            batch.cursor = next
        }
    }
}
