import Foundation

extension CloudAPI {
    static func googleFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        let mime = value["mimeType"] as? String ?? "application/octet-stream"
        return CloudFile(id: id, name: name, mime: mime, size: (value["size"] as? String).flatMap(Int64.init), modified: date(value["modifiedTime"] as? String), webURL: (value["webViewLink"] as? String).flatMap(URL.init(string:)), isFolder: mime == "application/vnd.google-apps.folder")
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
        return [URLQueryItem(name: "corpora", value: "drive"), URLQueryItem(name: "driveId", value: drive),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"), URLQueryItem(name: "supportsAllDrives", value: "true")]
    }

    func googleParent(_ parent: String) -> String {
        parent == "root" ? (account.driveID ?? "root") : parent
    }

    func googleList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        let fields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,webViewLink)"

        var page: String?
        repeat {
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            switch parent {
            case Collection.recent.rootID:
                // One page of what the user opened last; folders are noise here.
                url.queryItems = [URLQueryItem(name: "q", value: "trashed = false and mimeType != 'application/vnd.google-apps.folder'"), URLQueryItem(name: "orderBy", value: "viewedByMeTime desc"), URLQueryItem(name: "pageSize", value: "100"), URLQueryItem(name: "fields", value: fields)]
            case Collection.shared.rootID:
                url.queryItems = [URLQueryItem(name: "q", value: "sharedWithMe = true and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "pageToken", value: page)]
            default:
                let escaped = googleParent(parent).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                url.queryItems = [URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "pageToken", value: page)]
            }
            url.queryItems = (url.queryItems ?? []) + googleDriveScope
            let result = try await json(url.url!)
            files += (result["files"] as? [[String: Any]] ?? []).compactMap(Self.googleFile)
            page = parent == Collection.recent.rootID ? nil : result["nextPageToken"] as? String
            if page != nil { onPage?(Self.sorted(files)) }
        } while page != nil
        return Self.sorted(files)
    }
}
