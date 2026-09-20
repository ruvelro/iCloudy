import Foundation

@MainActor
final class OneDriveProvider: CloudSession, CloudProvider {
    var rootIDCache: String?
}

extension OneDriveProvider {
    static func microsoftFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        // Shared remote items need another drive identity; expose them as browser links in this MVP.
        let remote = value["remoteItem"] != nil
        return CloudFile(
            id: id, name: name, mime: remote ? "application/vnd.google-apps.shortcut" : ((value["file"] as? [String: Any])?["mimeType"] as? String ?? "application/octet-stream"),
            size: (value["size"] as? NSNumber)?.int64Value, modified: date(value["lastModifiedDateTime"] as? String), webURL: (value["webUrl"] as? String).flatMap(URL.init(string:)),
            isFolder: !remote && value["folder"] != nil)
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

extension OneDriveProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        return try await graphList(parent: parent, onPage: onPage)
    }

    func createFolder(name: String, parent: String) async throws -> String {
        let result: [String: Any]
        result = try await json(URL(string: "\(graphDrive)/\(graphItem(parent))/children")!, method: "POST", body: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "rename"])
        guard let id = result["id"] as? String else { throw CloudError.message(L("No se pudo crear la carpeta.")) }
        return id
    }

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        return try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/content")!)
    }

    func rename(file: CloudFile, name: String) async throws {
        _ = try await json(URL(string: "\(graphDrive)/items/" + Self.segment(file.id))!, method: "PATCH", body: ["name": name])
    }

    func move(file: CloudFile, to destination: String) async throws {
        let target = destination == "root" ? try await rootID() : destination

        _ = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))")!, method: "PATCH", body: ["parentReference": ["id": target]])
    }

    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        let target = destination == "root" ? try await rootID() : destination

        var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/copy")!, method: "POST", body: ["parentReference": ["id": target]])
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
        if (response as? HTTPURLResponse)?.statusCode == 202 {
            guard let address = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                let monitor = URL(string: address), Self.validCopyMonitor(monitor)
            else {
                throw CloudError.message(L("OneDrive aceptó la copia pero no devolvió su seguimiento. Comprueba el destino antes de repetirla."))
            }
            if let accepted {
                try accepted(monitor)
                return
            }
            while true {
                let status = try await remoteCopyStatus(monitor)
                if status == .completed { return }
                if status == .failed { throw CloudError.message(L("OneDrive no pudo completar la copia.")) }
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    func trash(file: CloudFile) async throws {
        // Graph's DELETE on a driveItem is a recycle-bin move and answers 204 without a body.
        var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))")!, method: "DELETE")
        let (data, response) = try await send(&request)
        try HTTP.validate(response, data: data)
    }

    func publicLink(for file: CloudFile) async throws -> URL {
        let result = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/createLink")!, method: "POST", body: ["type": "view", "scope": "anonymous"])
        guard let link = ((result["link"] as? [String: Any])?["webUrl"] as? String).flatMap(URL.init(string:)) else {
            throw CloudError.message(L("OneDrive no devolvió el enlace. La organización puede no permitir enlaces anónimos."))
        }
        return link
    }

    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        let encoded = Self.segment(term.replacingOccurrences(of: "'", with: "''"))
        guard let url = URL(string: cursor ?? "\(graphDrive)/root/search(q='\(encoded)')?$top=100&$select=id,name,size,folder,file,remoteItem,webUrl,lastModifiedDateTime,parentReference"),
            url.scheme == "https", url.host == "graph.microsoft.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443
        else {
            throw CloudError.message(L("Paginación de búsqueda no válida."))
        }
        let response = try await json(url)
        let hits = (response["value"] as? [[String: Any]] ?? []).compactMap { value -> SearchHit? in
            guard let file = Self.microsoftFile(value) else { return nil }
            return SearchHit(accountID: account.id, file: file, parentID: (value["parentReference"] as? [String: Any])?["id"] as? String)
        }
        return SearchPage(hits: hits, next: response["@odata.nextLink"] as? String)
    }

    func folderTrail(id: String) async throws -> [CloudFile] {
        var result: [CloudFile] = []
        var current: String? = id
        var seen: Set<String> = []
        var googleRoot: String? = nil
        googleRoot = nil
        while let folderID = current, folderID != "root", folderID != googleRoot, folderID != account.driveID {
            try Task.checkCancellation()
            guard seen.insert(folderID).inserted, seen.count <= 64 else { throw CloudError.message(L("No se pudo resolver la ruta de la carpeta.")) }
            let value: [String: Any]
            let file: CloudFile?

            value = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(folderID))?$select=id,name,folder,root,parentReference,webUrl")!)
            if value["root"] != nil { break }
            file = Self.microsoftFile(value)
            current = (value["parentReference"] as? [String: Any])?["id"] as? String

            guard let file, file.isFolder else { throw CloudError.message(L("La carpeta del resultado ya no está disponible.")) }
            result.insert(file, at: 0)
        }
        return result
    }

    func storageQuota() async throws -> StorageQuota {
        let endpoint: String
        endpoint = "\(graphDrive)?$select=quota"
        return try Self.parseQuota(await json(URL(string: endpoint)!))
    }

    func rootID() async throws -> String {
        if let rootIDCache { return rootIDCache }
        let endpoint = URL(string: "\(graphDrive)/root?$select=id")!
        guard let id = try await json(endpoint)["id"] as? String else { throw CloudError.message(L("No se pudo identificar la carpeta raíz.")) }
        rootIDCache = id
        return id
    }

    func availableDrives() async throws -> [RemoteDrive] {
        var drives: [RemoteDrive] = []
        var seen: Set<String> = []
        // The sites the user follows, plus the tenant's root site, is a useful set without crawling everything.
        var sites: [(id: String, name: String)] = []
        if let root = try? await json(URL(string: "https://graph.microsoft.com/v1.0/sites/root?$select=id,displayName")!),
            let id = root["id"] as? String
        {
            sites.append((id, root["displayName"] as? String ?? L("Sitio principal")))
        }
        if let followed = try? await json(URL(string: "https://graph.microsoft.com/v1.0/me/followedSites?$select=id,displayName")!) {
            for value in followed["value"] as? [[String: Any]] ?? [] {
                guard let id = value["id"] as? String else { continue }
                sites.append((id, value["displayName"] as? String ?? id))
            }
        }
        for site in sites.prefix(12) {
            guard let result = try? await json(URL(string: "https://graph.microsoft.com/v1.0/sites/\(Self.segment(site.id))/drives?$select=id,name,driveType")!) else { continue }
            for value in result["value"] as? [[String: Any]] ?? [] {
                guard let id = value["id"] as? String, seen.insert(id).inserted else { continue }
                drives.append(RemoteDrive(id: id, name: value["name"] as? String ?? site.name, detail: site.name))
            }
        }
        return drives
    }
}

extension OneDriveProvider {
    nonisolated static func validCopyMonitor(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
            let host = url.host?.lowercased()
        else { return false }
        return host == "graph.microsoft.com" || host == "api.onedrive.com" || host.hasSuffix(".sharepoint.com")
    }
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State {
        guard Self.validCopyMonitor(url) else { throw CloudError.message(L("OneDrive devolvió una dirección de seguimiento no válida.")) }
        // Monitor URLs on storage servers are capability URLs. Never forward the Graph bearer token to them.
        let request = url.host == "graph.microsoft.com" ? try await request(url) : URLRequest(url: url)
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        try HTTP.validate(response, data: data)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch (body?["status"] as? String)?.lowercased() {
        case "completed": return .completed
        case "failed", "deletefailed": return .failed
        case "inprogress", "notstarted", "updating", "waiting": return .monitoring
        default: throw CloudError.message(L("OneDrive todavía no ha confirmado el resultado de la copia."))
        }
    }
}
