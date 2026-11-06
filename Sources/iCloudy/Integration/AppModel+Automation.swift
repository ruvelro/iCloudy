import Foundation

/// The file operations that Shortcuts, the command-line companion and AppleScript share, named by account and path
/// the way a person says them ("Documentos/Facturas"). Each one checks the account's capabilities first, so an
/// automation gets the same explanation the window would give instead of a provider's refusal.
extension AppModel {
    /// What is in a folder.
    func automationList(_ account: Account, path: String) async throws -> [CloudFile] {
        let place = try await resolve(path: path, in: account)
        if let file = place.file, !file.isFolder { throw CloudError.message(L("«\(file.name)» es un archivo, no una carpeta.")) }
        return try await client(account).list(parent: place.folderID)
    }

    /// Searches every connected account that can search (or one), first pages only, up to `limit` results. A failing
    /// account is skipped rather than failing the whole search; the results say which accounts answered.
    func automationSearch(_ term: String, in only: Account? = nil, limit: Int = 100) async -> [SearchHit] {
        let query = String(term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for account in only.map({ [$0] }) ?? accounts.filter({ $0.capabilities.search }) {
            guard hits.count < limit, let api = try? client(account) else { continue }
            if let page = try? await api.searchPage(term: query) { hits += page.hits.prefix(limit - hits.count) }
        }
        return hits
    }

    /// Queues the files for upload into `path` of `account`, which must be a folder. Returns how many were queued.
    @discardableResult func automationUpload(_ urls: [URL], to account: Account, path: String) async throws -> Int {
        let place = try await resolve(path: path, in: account)
        if let file = place.file, !file.isFolder { throw CloudError.message(L("«\(file.name)» es un archivo, no una carpeta.")) }
        let label = ([accountTitle(account)] + place.trail.map(\.name)).joined(separator: " / ")
        guard enqueueUploads(urls, target: (account, place.folderID, label)) else {
            throw CloudError.message(error ?? L("La cola no aceptó la subida."))
        }
        return urls.count
    }

    /// Creates `name` inside `path`. Returns the new folder's path from the top of the account.
    func automationCreateFolder(_ account: Account, in path: String, name: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { throw CloudError.message(L("Introduce un nombre válido.")) }
        if let problem = FileNames.problem(with: clean, for: account.cloud) { throw CloudError.message(problem) }
        let place = try await resolve(path: path, in: account)
        if let file = place.file, !file.isFolder { throw CloudError.message(L("«\(file.name)» es un archivo, no una carpeta.")) }
        _ = try await client(account).createFolder(name: clean, parent: place.folderID)
        reloadVisible(accountID: account.id, fresh: true)
        return (place.trail.map(\.name) + [clean]).joined(separator: "/")
    }

    /// Renames the item at `path`, moves it into the folder `destination`, or both. Never onto an existing name: the
    /// providers refuse that, and the automation says so.
    func automationMove(_ account: Account, path: String, to destination: String?, rename newName: String?) async throws {
        guard let file = try await resolve(path: path, in: account).file else { throw CloudError.message(L("Indica un archivo o una carpeta.")) }
        let api = try client(account)
        if let destination, !destination.trimmingCharacters(in: .whitespaces).isEmpty {
            let place = try await resolve(path: destination, in: account)
            if let folder = place.file, !folder.isFolder { throw CloudError.message(L("«\(folder.name)» es un archivo, no una carpeta.")) }
            try await api.move(file: file, to: place.folderID)
            if let newName = newName?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty, newName != file.name {
                let moved = try await api.list(parent: place.folderID).first { $0.name == file.name } ?? file
                try await api.rename(file: moved, name: newName)
            }
        } else if let newName = newName?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
            if let problem = FileNames.problem(with: newName, for: account.cloud) { throw CloudError.message(problem) }
            try await api.rename(file: file, name: newName)
        } else {
            throw CloudError.message(L("Indica una carpeta de destino, un nombre nuevo o los dos."))
        }
        reloadVisible(accountID: account.id, fresh: true)
    }

    /// The item at `path`, and whether sending it to the trash can be undone, for the confirmation that has to come
    /// before `automationTrash`.
    func automationTrashTarget(_ account: Account, path: String) async throws -> (file: CloudFile, reversible: Bool) {
        guard let file = try await resolve(path: path, in: account).file else { throw CloudError.message(L("Indica un archivo o una carpeta.")) }
        return (file, account.capabilities.reversibleTrash)
    }

    /// Sends the item to the provider's trash, or deletes it where there is none. The caller confirms first.
    func automationTrash(_ account: Account, file: CloudFile) async throws {
        try await client(account).trash(file: file)
        reloadVisible(accountID: account.id, fresh: true)
    }

    /// A link that stops working after `lifetime` seconds: a presigned or SAS URL where links are temporary by
    /// nature, otherwise a public link with that expiry where the provider takes one.
    func automationExpiringLink(_ account: Account, path: String, lifetime: Int) async throws -> URL {
        guard let file = try await resolve(path: path, in: account).file else { throw CloudError.message(L("Indica un archivo o una carpeta.")) }
        if let reason = account.limitation(.publicLink, for: [file]) { throw CloudError.message(reason) }
        let capabilities = account.capabilities
        if capabilities.temporaryLinks, let signer = try client(account).provider as? TemporaryLinkProvider {
            return try signer.temporaryLink(for: file, lifetime: min(lifetime, 7 * 24 * 3600))
        }
        guard capabilities.links.expiration else {
            throw CloudError.message(L("\(account.cloud.title) no crea enlaces con caducidad desde iCloudy."))
        }
        var options = PublicLinkOptions()
        options.expires = Date().addingTimeInterval(TimeInterval(lifetime))
        let link = try await client(account).createPublicLink(for: file, options: options)
        guard let url = link.url else { throw CloudError.message(L("El servidor no devolvió el enlace. Comprueba que compartir está habilitado.")) }
        return url
    }
}
