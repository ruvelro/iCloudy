import Foundation

extension CloudAPI {
    func rename(file: CloudFile, name: String) async throws {
        if let demo { try demo.rename(file.id, name: name); return }
        switch account.cloud {
        case .google:
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/" + Self.segment(file.id)), method: "PATCH", body: ["name": name])
        case .microsoft:
            _ = try await json(URL(string: "\(graphDrive)/items/" + Self.segment(file.id))!, method: "PATCH", body: ["name": name])
        case .dropbox: try await dropboxRename(file: file, name: name)
        case .ftp: try await ftpRename(file: file, name: name)
        case .volume: try await volumeRename(file: file, name: name)
        case .mega: try await megaRename(file: file, name: name)
        case .o2: try await o2Rename(file: file, name: name)
        case .box: _ = try await boxUpdate(file, body: ["name": name])
        case .webdav: try await webdavRename(file: file, name: name)
        }
    }

    func rootID() async throws -> String {
        if demo != nil { return "root" }
        // Dropbox, Box and WebDAV name their root directly; only Drive and Graph hide it behind an alias.
        if let drive = account.driveID, account.cloud == .google { return drive }
        guard [.google, .microsoft].contains(account.cloud) else { return account.cloud.rootAlias }
        if let rootIDCache { return rootIDCache }
        let endpoint = account.cloud == .google ? googleURL("https://www.googleapis.com/drive/v3/files/root?fields=id") : URL(string: "\(graphDrive)/root?$select=id")!
        guard let id = try await json(endpoint)["id"] as? String else { throw CloudError.message(L("No se pudo identificar la carpeta raíz.")) }
        rootIDCache = id
        return id
    }

    /// Moves an item to another folder of the same account. The caller checks name clashes and cycles beforehand.
    func move(file: CloudFile, to destination: String) async throws {
        if let demo { try demo.move(file.id, to: destination); return }
        switch account.cloud {
        case .dropbox: try await dropboxMove(file: file, to: destination); return
        case .ftp: try await ftpMove(file: file, to: destination); return
        case .volume: try await volumeMove(file: file, to: destination); return
        case .mega: try await megaMove(file: file, to: destination); return
        case .o2: try await o2Move(file: file, to: destination); return
        case .webdav: try await webdavMove(file: file, to: destination); return
        case .box: _ = try await boxUpdate(file, body: ["parent": ["id": boxID(destination)]]); return
        case .google, .microsoft: break
        }
        let target = destination == "root" ? try await rootID() : destination
        if account.cloud == .google {
            // Drive items can have several parents; moving means replacing all of them with the destination.
            let current = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=parents"))
            let parents = (current["parents"] as? [String] ?? []).filter { $0 != target }
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))")!
            url.queryItems = [URLQueryItem(name: "addParents", value: target), URLQueryItem(name: "removeParents", value: parents.joined(separator: ",")), URLQueryItem(name: "fields", value: "id,parents")] + googleAllDrives
            _ = try await json(url.url!, method: "PATCH", body: [:])
        } else {
            _ = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))")!, method: "PATCH", body: ["parentReference": ["id": target]])
        }
    }

    /// Copies an item into another folder. Drive cannot copy folders; Graph copies asynchronously and answers 202.
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        if let demo { _ = try demo.copy(file.id, to: destination); return }
        switch account.cloud {
        case .dropbox: try await dropboxCopy(file: file, to: destination); return
        case .ftp: throw CloudError.message(L("FTP no puede copiar en el servidor. Descarga el archivo y vuelve a subirlo."))
        case .volume: try await volumeCopy(file: file, to: destination); return
        case .mega: try await megaCopy(file: file, to: destination); return
        case .o2: throw CloudError.message(L("O2 Cloud no copia archivos en el servidor. Descárgalo y vuelve a subirlo."))
        case .webdav: try await webdavCopy(file: file, to: destination); return
        case .box: try await boxCopy(file: file, to: destination); return
        case .google, .microsoft: break
        }
        let target = destination == "root" ? try await rootID() : destination
        if account.cloud == .google {
            guard !file.isFolder else { throw CloudError.message(L("Google Drive no permite copiar carpetas. Copia los archivos que contiene.")) }
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/copy"), method: "POST", body: ["parents": [target], "name": file.name])
        } else {
            var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/copy")!, method: "POST", body: ["parentReference": ["id": target]])
            let (data, response) = try await send(&request)
            try HTTP.validate(response, data: data)
            if (response as? HTTPURLResponse)?.statusCode == 202 {
                guard let address = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                      let monitor = URL(string: address), Self.validCopyMonitor(monitor) else {
                    throw CloudError.message(L("OneDrive aceptó la copia pero no devolvió su seguimiento. Comprueba el destino antes de repetirla."))
                }
                if let accepted { try accepted(monitor); return }
                while true {
                    let status = try await remoteCopyStatus(monitor)
                    if status == .completed { return }
                    if status == .failed { throw CloudError.message(L("OneDrive no pudo completar la copia.")) }
                    try await Task.sleep(for: .seconds(5))
                }
            }

        }
    }

    /// Moves the item to the provider's trash or recycle bin, which the user can undo on the web. Never a hard delete.
    func trash(file: CloudFile) async throws {
        if let demo { try demo.trash(file.id); return }
        switch account.cloud {
        case .dropbox: try await dropboxTrash(file: file); return
        case .box: try await boxTrash(file: file); return
        case .webdav: try await webdavDelete(file: file); return
        case .ftp: try await ftpDelete(file: file); return
        case .volume: try await volumeTrash(file: file); return
        case .mega: try await megaTrash(file: file); return
        case .o2: try await o2Trash(file: file); return
        case .google, .microsoft: break
        }
        if account.cloud == .google {
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))"), method: "PATCH", body: ["trashed": true])
        } else {
            // Graph's DELETE on a driveItem is a recycle-bin move and answers 204 without a body.
            var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))")!, method: "DELETE")
            let (data, response) = try await send(&request)
            try HTTP.validate(response, data: data)
        }
    }

    /// Grants read-only access to anyone holding the link and returns it. Both providers keep the permission until the
    /// owner removes it on the web, so the caller must confirm with the user first.
    func publicLink(for file: CloudFile) async throws -> URL {
        if let demo { return try demo.publicLink(file.id) }
        switch account.cloud {
        case .dropbox: return try await dropboxPublicLink(for: file)
        case .box: return try await boxPublicLink(for: file)
        case .webdav:
            guard account.flavor == "nextcloud" else {
                throw CloudError.message(L("Este servidor WebDAV no admite enlaces públicos desde iCloudy. Créalos en su interfaz web."))
            }
            return try await nextcloudPublicLink(for: file)
        case .ftp: throw CloudError.message(L("FTP no tiene enlaces públicos."))
        case .volume: throw CloudError.message(L("Un volumen no tiene enlaces públicos. Compártelo desde el Finder."))
        case .mega: return try await megaPublicLink(for: file)
        case .o2: return try await o2PublicLink(for: file)
        case .google, .microsoft: break
        }
        if account.cloud == .google {
            _ = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))/permissions"), method: "POST", body: ["role": "reader", "type": "anyone"])
            let metadata = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=webViewLink"))
            guard let link = (metadata["webViewLink"] as? String).flatMap(URL.init(string:)) ?? file.webURL else { throw CloudError.message(L("Google no devolvió un enlace para este elemento.")) }
            return link
        }
        let result = try await json(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/createLink")!, method: "POST", body: ["type": "view", "scope": "anonymous"])
        guard let link = ((result["link"] as? [String: Any])?["webUrl"] as? String).flatMap(URL.init(string:)) else { throw CloudError.message(L("OneDrive no devolvió el enlace. La organización puede no permitir enlaces anónimos.")) }
        return link
    }

}
