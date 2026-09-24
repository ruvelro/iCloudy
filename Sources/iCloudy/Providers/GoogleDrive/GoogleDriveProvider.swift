import Foundation

@MainActor
final class GoogleDriveProvider: CloudSession, CloudProvider {
    var rootIDCache: String?
}

extension GoogleDriveProvider {
    static func googleFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        let mime = value["mimeType"] as? String ?? "application/octet-stream"
        return CloudFile(
            id: id, name: name, mime: mime, size: (value["size"] as? String).flatMap(Int64.init), modified: date(value["modifiedTime"] as? String),
            webURL: (value["webViewLink"] as? String).flatMap(URL.init(string:)), isFolder: mime == "application/vnd.google-apps.folder")
    }

    var googleAllDrives: [URLQueryItem] {
        account.driveID == nil ? [] : [URLQueryItem(name: "supportsAllDrives", value: "true")]
    }

    func googleURL(_ string: String) -> URL {
        guard account.driveID != nil, var components = URLComponents(string: string) else { return URL(string: string)! }
        components.queryItems = (components.queryItems ?? []) + googleAllDrives
        return components.url ?? URL(string: string)!
    }

    var googleDriveScope: [URLQueryItem] {
        guard let drive = account.driveID else { return [] }
        return [
            URLQueryItem(name: "corpora", value: "drive"), URLQueryItem(name: "driveId", value: drive),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"), URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
    }

    func googleParent(_ parent: String) -> String {
        parent == "root" ? (account.driveID ?? "root") : parent
    }

    func googleList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        let fields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,webViewLink" + (parent == Collection.trash.rootID ? ",explicitlyTrashed)" : ")")

        var page: String?
        repeat {
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            switch parent {
            case Collection.recent.rootID:
                // One page of what the user opened last; folders are noise here.
                url.queryItems = [
                    URLQueryItem(name: "q", value: "trashed = false and mimeType != 'application/vnd.google-apps.folder'"), URLQueryItem(name: "orderBy", value: "viewedByMeTime desc"),
                    URLQueryItem(name: "pageSize", value: "100"), URLQueryItem(name: "fields", value: fields),
                ]
            case Collection.shared.rootID:
                url.queryItems = [
                    URLQueryItem(name: "q", value: "sharedWithMe = true and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields),
                    URLQueryItem(name: "pageToken", value: page),
                ]
            case Collection.trash.rootID:
                // Drive marks every descendant of a binned folder as trashed too. Only what was binned by itself is
                // listed, the way Drive's own bin does; the rest comes and goes with its folder.
                url.queryItems = [
                    URLQueryItem(name: "q", value: "trashed = true"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields),
                    URLQueryItem(name: "pageToken", value: page),
                ]
            default:
                let escaped = googleParent(parent).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                url.queryItems = [
                    URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields),
                    URLQueryItem(name: "pageToken", value: page),
                ]
            }
            url.queryItems = (url.queryItems ?? []) + googleDriveScope
            let result = try await json(url.url!)
            let entries = (result["files"] as? [[String: Any]] ?? [])
            files += (parent == Collection.trash.rootID ? entries.filter { $0["explicitlyTrashed"] as? Bool != false } : entries).compactMap(Self.googleFile)
            page = parent == Collection.recent.rootID ? nil : result["nextPageToken"] as? String
            if page != nil { onPage?(Self.sorted(files)) }
        } while page != nil
        return Self.sorted(files)
    }
}

extension GoogleDriveProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        return try await googleList(parent: parent, onPage: onPage)
    }

    func createFolder(name: String, parent: String) async throws -> String {
        let result: [String: Any]
        result = try await json(
            googleURL("https://www.googleapis.com/drive/v3/files"), method: "POST", body: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [googleParent(parent)]])
        guard let id = result["id"] as? String else { throw CloudError.message(L("No se pudo crear la carpeta.")) }
        return id
    }

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))" + (exportMime == nil ? "" : "/export"))!
        parts.queryItems = [URLQueryItem(name: exportMime == nil ? "alt" : "mimeType", value: exportMime ?? "media")] + googleAllDrives
        return try await request(parts.url!)
    }

    func rename(file: CloudFile, name: String) async throws {
        _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/" + Self.segment(file.id)), method: "PATCH", body: ["name": name])
    }

    func move(file: CloudFile, to destination: String) async throws {
        let target = destination == "root" ? try await rootID() : destination

        // Drive items can have several parents; moving means replacing all of them with the destination.
        let current = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=parents"))
        let parents = (current["parents"] as? [String] ?? []).filter { $0 != target }
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))")!
        url.queryItems =
            [URLQueryItem(name: "addParents", value: target), URLQueryItem(name: "removeParents", value: parents.joined(separator: ",")), URLQueryItem(name: "fields", value: "id,parents")]
            + googleAllDrives
        _ = try await json(url.url!, method: "PATCH", body: [:])
    }

    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        let target = destination == "root" ? try await rootID() : destination

        guard !file.isFolder else { throw CloudError.message(L("Google Drive no permite copiar carpetas. Copia los archivos que contiene.")) }
        _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/copy"), method: "POST", body: ["parents": [target], "name": file.name])
    }

    func trash(file: CloudFile) async throws {
        _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))"), method: "PATCH", body: ["trashed": true])
    }

    /// Drive remembers where a binned item came from, so clearing the flag is the whole restoration.
    func restore(file: CloudFile) async throws {
        _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))"), method: "PATCH", body: ["trashed": false])
    }

    /// A DELETE skips the bin whether or not the item is in it. Drive answers 204 with no body.
    func deletePermanently(file: CloudFile) async throws {
        var request = try await request(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))"), method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }

    /// One request empties the whole bin; a shared drive's bin is addressed by its drive id.
    func emptyTrash() async throws {
        let scope = account.driveID.map { "?driveId=" + Self.segment($0) } ?? ""
        var request = try await request(googleURL("https://www.googleapis.com/drive/v3/files/trash" + scope), method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }

    func publicLink(for file: CloudFile) async throws -> URL {
        _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions"), method: "POST", body: ["role": "reader", "type": "anyone"])
        let metadata = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=webViewLink"))
        guard let link = (metadata["webViewLink"] as? String).flatMap(URL.init(string:)) ?? file.webURL else { throw CloudError.message(L("Google no devolvió un enlace para este elemento.")) }
        return link

    }

    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        let terms = term.split(whereSeparator: \.isWhitespace).map {
            String($0).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        }
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        url.queryItems =
            [
                URLQueryItem(
                    name: "q",
                    value: (["trashed = false"] + terms.map { "(name contains '\($0)' or fullText contains '\($0)')" } + Self.googleFilterClauses(filters, now: referenceDate)).joined(
                        separator: " and ")),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "pageSize", value: "100"), URLQueryItem(name: "pageToken", value: cursor),
                URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(id,name,mimeType,size,modifiedTime,webViewLink,parents,driveId)"),
                // A shared-drive account searches that drive; anything else searches the person's own corpus. Sending
                // both values of `corpora` at once, as this once did, is a contradiction Drive answers with 400.
            ] + (account.driveID == nil ? [URLQueryItem(name: "corpora", value: "user")] : googleDriveScope)
        let response = try await json(url.url!)
        let hits = (response["files"] as? [[String: Any]] ?? []).compactMap { value -> SearchHit? in
            // A personal account cannot browse shared-drive items; a scoped account sees nothing else.
            guard account.driveID != nil || value["driveId"] == nil, let file = Self.googleFile(value) else { return nil }
            return SearchHit(accountID: account.id, file: file, parentID: (value["parents"] as? [String])?.first)
        }
        return SearchPage(hits: hits, next: response["nextPageToken"] as? String, incomplete: response["incompleteSearch"] as? Bool ?? false)

    }

    func folderTrail(id: String) async throws -> [CloudFile] {
        var result: [CloudFile] = []
        var current: String? = id
        var seen: Set<String> = []
        let googleRoot = try await json(googleURL("https://www.googleapis.com/drive/v3/files/root?fields=id"))["id"] as? String

        while let folderID = current, folderID != "root", folderID != googleRoot, folderID != account.driveID {
            try Task.checkCancellation()
            guard seen.insert(folderID).inserted, seen.count <= 64 else { throw CloudError.message(L("No se pudo resolver la ruta de la carpeta.")) }
            let value: [String: Any]
            let file: CloudFile?

            value = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(folderID))?fields=id,name,mimeType,parents,webViewLink"))
            file = Self.googleFile(value)
            current = (value["parents"] as? [String])?.first

            guard let file, file.isFolder else { throw CloudError.message(L("La carpeta del resultado ya no está disponible.")) }
            result.insert(file, at: 0)
        }
        return result
    }

    func storageQuota() async throws -> StorageQuota {
        let endpoint: String
        // `about` describes the person's own storage. A shared drive draws on the organisation's pool and reports
        // nothing of its own, so showing the personal figure under its name would be a plain lie.
        guard account.driveID == nil else {
            throw CloudError.message(L("Una unidad compartida de Google no informa de su propio espacio."))
        }
        endpoint = "https://www.googleapis.com/drive/v3/about?fields=storageQuota"
        return try Self.parseQuota(await json(URL(string: endpoint)!))
    }

    func rootID() async throws -> String {
        if let drive = account.driveID { return drive }
        if let rootIDCache { return rootIDCache }
        let endpoint = googleURL("https://www.googleapis.com/drive/v3/files/root?fields=id")
        guard let id = try await json(endpoint)["id"] as? String else { throw CloudError.message(L("No se pudo identificar la carpeta raíz.")) }
        rootIDCache = id
        return id
    }

    func availableDrives() async throws -> [RemoteDrive] {
        let result = try await json(URL(string: "https://www.googleapis.com/drive/v3/drives?pageSize=100&fields=drives(id,name)")!)
        return (result["drives"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
            return RemoteDrive(id: id, name: name, detail: L("Unidad compartida de Google Drive"))
        }
    }
}

extension GoogleDriveProvider {
    static func googleFilterClauses(_ filters: SearchFilters, now: Date = Date()) -> [String] {
        var clauses: [String] = []
        switch filters.type {
        case .all: break
        case .folders: clauses.append("mimeType = 'application/vnd.google-apps.folder'")
        case .images: clauses.append("mimeType contains 'image/'")
        case .video: clauses.append("mimeType contains 'video/'")
        case .audio: clauses.append("mimeType contains 'audio/'")
        case .documents:
            clauses.append(
                "(mimeType contains 'application/vnd.google-apps.' or mimeType = 'application/pdf' or mimeType contains 'text/' or mimeType contains 'officedocument' or mimeType contains 'application/msword' or mimeType contains 'application/vnd.ms-' or mimeType contains 'opendocument')"
            )
        case .other: clauses.append("mimeType != 'application/vnd.google-apps.folder' and not mimeType contains 'image/' and not mimeType contains 'video/' and not mimeType contains 'audio/'")
        }
        if filters.age != .any {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            clauses.append("modifiedTime > '\(formatter.string(from: now.addingTimeInterval(-Double(filters.age.rawValue) * 86400)))'")
        }
        return clauses
    }
}
