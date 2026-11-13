import Foundation

/// Drive's change feed is one per user (or per shared drive), not per folder: a page token says "from here on" and
/// each change names the file and, while it exists, its parents.
extension GoogleDriveProvider {
    /// The shared drive whose feed this is, for an account restricted to one. `googleAllDrives` goes beside it.
    private var changedDrive: [URLQueryItem] {
        account.driveID.map { [URLQueryItem(name: "driveId", value: $0)] } ?? []
    }

    func changeCursor(for folder: String) async throws -> String? {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/changes/startPageToken")!
        let scope = changedDrive + googleAllDrives
        url.queryItems = scope.isEmpty ? nil : scope
        guard let token = try await json(url.url!)["startPageToken"] as? String else {
            throw CloudError.message(L("Google Drive no devolvió la posición de su registro de cambios."))
        }
        return token
    }

    func changes(since cursor: String, in folder: String) async throws -> ChangeBatch {
        var batch = ChangeBatch(cursor: cursor)
        var page: String? = cursor
        var pages = 0
        while let token = page {
            pages += 1
            guard pages <= ChangeFeedLimits.pages else {
                // Too much happened to be worth reading: say so, and start again from now.
                batch.reset = true
                batch.cursor = try await changeCursor(for: folder) ?? cursor
                return batch
            }
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")!
            url.queryItems = [
                URLQueryItem(name: "pageToken", value: token), URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "includeRemoved", value: "true"), URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,parents))"),
            ] + changedDrive + googleAllDrives + changedDrive.map { _ in URLQueryItem(name: "includeItemsFromAllDrives", value: "true") }
            let result = try await json(url.url!)
            for change in result["changes"] as? [[String: Any]] ?? [] {
                let file = change["file"] as? [String: Any]
                batch.changes.append(RemoteChange(id: change["fileId"] as? String ?? file?["id"] as? String, parents: file?["parents"] as? [String] ?? []))
            }
            if let next = result["newStartPageToken"] as? String { batch.cursor = next }
            page = result["nextPageToken"] as? String
        }
        return batch
    }
}
