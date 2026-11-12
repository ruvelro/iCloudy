import Foundation

/// Dropbox hands out a cursor for one folder and everything below it, so its feed is already scoped: whatever
/// `list_folder/continue` answers from that cursor happened inside the folder that was asked about.
extension DropboxProvider {
    func changeCursor(for folder: String) async throws -> String? {
        let result = try await dropboxRPC("files/list_folder/get_latest_cursor",
                                          ["path": dropboxPath(folder), "recursive": true, "include_deleted": true], repeatable: true)
        guard let cursor = result["cursor"] as? String else {
            throw CloudError.message(L("Dropbox no devolvió la posición de su registro de cambios."))
        }
        return cursor
    }

    func changes(since cursor: String, in folder: String) async throws -> ChangeBatch {
        var batch = ChangeBatch(cursor: cursor, scoped: true)
        var more = true
        var pages = 0
        while more {
            pages += 1
            let result: [String: Any]
            do {
                guard pages <= ChangeFeedLimits.pages else { throw ServiceError(status: 409, code: "reset/") }
                result = try await dropboxRPC("files/list_folder/continue", ["cursor": batch.cursor], repeatable: true)
            } catch let error as ServiceError where error.status == 409 && error.code?.hasPrefix("reset") == true {
                // Dropbox retired the cursor (the folder was moved or replaced, or it is simply too old).
                batch.reset = true
                batch.cursor = try await changeCursor(for: folder) ?? cursor
                return batch
            }
            for entry in result["entries"] as? [[String: Any]] ?? [] {
                batch.changes.append(RemoteChange(id: entry["path_lower"] as? String))
            }
            if let next = result["cursor"] as? String { batch.cursor = next }
            more = result["has_more"] as? Bool ?? false
        }
        return batch
    }
}
