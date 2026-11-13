import Foundation

/// Graph tracks a drive with delta links: a URL that answers what changed since it was issued, and a new one to ask
/// with next time. `token=latest` gets the first without enumerating the drive. The answer includes the folders
/// above every changed item, up to the root, which is why the caller decides by the ids it knows.
extension OneDriveProvider {
    private static let changeSelect = "$select=id,parentReference,deleted"

    /// A delta link is followed with the account's token, so it has to be one of Graph's own.
    private func graphLink(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme == "https", url.host == "graph.microsoft.com" else {
            throw CloudError.message(L("Paginación no válida."))
        }
        return url
    }

    func changeCursor(for folder: String) async throws -> String? {
        var next: URL? = URL(string: "\(graphDrive)/root/delta?token=latest&\(Self.changeSelect)")!
        var pages = 0
        while let url = next {
            pages += 1
            guard pages <= ChangeFeedLimits.pages else { break }
            let result = try await json(url)
            if let link = result["@odata.deltaLink"] as? String { return try graphLink(link).absoluteString }
            next = try (result["@odata.nextLink"] as? String).map(graphLink)
        }
        throw CloudError.message(L("OneDrive no devolvió la posición de su registro de cambios."))
    }

    func changes(since cursor: String, in folder: String) async throws -> ChangeBatch {
        var batch = ChangeBatch(cursor: cursor)
        var next: URL? = try graphLink(cursor)
        var pages = 0
        while let url = next {
            pages += 1
            let result: [String: Any]
            do {
                guard pages <= ChangeFeedLimits.pages else { throw ServiceError(status: 410) }
                result = try await json(url)
            } catch let error as ServiceError where error.status == 410 {
                // "resyncRequired": the link is too old to answer from. Anything may have changed.
                batch.reset = true
                batch.cursor = try await changeCursor(for: folder) ?? cursor
                return batch
            }
            for item in result["value"] as? [[String: Any]] ?? [] {
                let parent = (item["parentReference"] as? [String: Any])?["id"] as? String
                batch.changes.append(RemoteChange(id: item["id"] as? String, parents: parent.map { [$0] } ?? []))
            }
            if let link = result["@odata.deltaLink"] as? String { batch.cursor = try graphLink(link).absoluteString; break }
            next = try (result["@odata.nextLink"] as? String).map(graphLink)
        }
        return batch
    }
}
