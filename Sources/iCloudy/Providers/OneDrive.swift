import Foundation

extension CloudAPI {
    static func microsoftFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        // Shared remote items need another drive identity; expose them as browser links in this MVP.
        let remote = value["remoteItem"] != nil
        return CloudFile(id: id, name: name, mime: remote ? "application/vnd.google-apps.shortcut" : ((value["file"] as? [String: Any])?["mimeType"] as? String ?? "application/octet-stream"), size: (value["size"] as? NSNumber)?.int64Value, modified: date(value["lastModifiedDateTime"] as? String), webURL: (value["webUrl"] as? String).flatMap(URL.init(string:)), isFolder: !remote && value["folder"] != nil)
    }

    var graphDrive: String {
        account.driveID.map { "https://graph.microsoft.com/v1.0/drives/" + Self.segment($0) } ?? "https://graph.microsoft.com/v1.0/me/drive"
    }

    func graphItem(_ id: String) -> String { id == "root" ? "root" : "items/" + Self.segment(id) }

    func graphList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        let select = "$select=id,name,size,folder,file,remoteItem,webUrl,lastModifiedDateTime"

        let route: String
        switch parent {
        case Collection.recent.rootID: route = "recent?\(select)"
        case Collection.shared.rootID: route = "sharedWithMe?\(select)"
        default: route = "\(graphItem(parent))/children?$top=200&\(select)"
        }
        var next: URL? = URL(string: "\(graphDrive)/\(route)")!
        while let url = next {
            guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message(L("Paginación no válida.")) }
            let result = try await json(url)
            files += (result["value"] as? [[String: Any]] ?? []).compactMap(Self.microsoftFile)
            next = (result["@odata.nextLink"] as? String).flatMap(URL.init(string:))
            if next != nil { onPage?(Self.sorted(files)) }
        }
        return Self.sorted(files)
    }
}
