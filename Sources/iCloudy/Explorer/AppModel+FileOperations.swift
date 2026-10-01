import AppKit
import SwiftUI
import Combine

extension AppModel {
    /// Copies the provider's own web link; it opens only for people who already have access.
    func copyLink(_ file: CloudFile) {
        guard let url = file.webURL else { error = L("Este elemento no tiene enlace web."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        info = L("Enlace copiado. Solo funciona para quien ya tenga acceso a «\(file.name)».")
    }

    /// Sharing with anyone is irreversible from the app, so the view asks for confirmation before calling this.
    func createPublicLink(_ file: CloudFile, account target: Account? = nil) async {
        guard let account = target ?? account else { return }
        do {
            let link = try await client(account).publicLink(for: file)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            info = account.capabilities.links.manage
                ? L("Enlace público copiado. Cualquiera que lo tenga podrá ver «\(file.name)». Para revocarlo, abre «Enlaces públicos…» en su menú.")
                : L("Enlace público copiado. Cualquiera que lo tenga podrá ver «\(file.name)». Para revocarlo, usa la web del proveedor.")
        } catch { self.error = error.localizedDescription }
    }

    /// Whether "copy to…" can do anything with this selection. Drive and Mega cannot copy a folder, and offering the
    /// action only to answer with a refusal afterwards is a worse way of saying so.
    func canCopy(_ files: [CloudFile]) -> Bool {
        guard let account, !files.isEmpty else { return false }
        return account.capabilities.allows(.copy, on: files)
    }

    /// Why `action` is not available for these items in the current account; shown as the disabled action's help.
    func limitation(_ action: ItemAction, for files: [CloudFile], account target: Account? = nil) -> String? {
        guard let account = target ?? account else { return nil }
        return account.limitation(action, for: files)
    }

    /// Asks for confirmation before a public link, unless the provider cannot make one for this kind of item.
    func requestPublicLink(_ file: CloudFile, account target: Account? = nil) {
        guard let account = target ?? account else { return }
        if let reason = account.limitation(.publicLink, for: [file]) { error = reason; return }
        pendingShare = (file, account)
    }

    func requestRelocation(_ files: [CloudFile], copy: Bool) {
        guard let account, !files.isEmpty else { return }
        if copy, let reason = account.limitation(.copy, for: files) { error = reason; return }
        relocation = Relocation(files: files, kind: copy ? .copy : .move, account: account, origin: path.isEmpty && collection != .files ? nil : folderID)
    }

    func requestCrossCloud(_ files: [CloudFile]) {
        guard let account, !files.isEmpty else { return }
        guard accounts.count > 1 else { error = L("Conecta otra cuenta para poder enviar archivos entre nubes."); return }
        crossCloud = CrossCloudRequest(files: files, source: account)
    }

    /// Queues one job per item; the queue stages each file locally and uploads it with checkpoints and verification.
    func enqueueCrossCloud(_ files: [CloudFile], from source: Account, to target: Account, parent: String, destinationPath: [CloudFile]) {
        let label = ([target.email] + destinationPath.map(\.name)).joined(separator: " / ")
        let batch = UUID()
        let jobs = files.map { file -> Transfer in
            var job = Transfer(batchID: batch, name: file.name, destination: label, accountID: source.id, direction: .transfer, localURL: URL(fileURLWithPath: "/"), parent: parent, file: file)
            job.localURL = queue.scratchDirectory(for: job.id)
            job.targetAccountID = target.id
            return job
        }
        do { try queue.add(jobs); info = L("\(jobs.count == 1 ? L("«\(files[0].name)»") : L("\(jobs.count) elementos")) en cola hacia \(accountTitle(target)). Sigue el progreso en Transferencias.") }
        catch { self.error = error.localizedDescription }
    }

    /// Checks cycles and name clashes first, then processes item by item and stops at the first failure.
    func relocate(_ request: Relocation, to destination: String, destinationPath: [CloudFile]) async {
        if case .transfer(let source) = request.kind {
            enqueueCrossCloud(request.files, from: source, to: request.account, parent: destination, destinationPath: destinationPath); return
        }
        let ids = Set(request.files.map(\.id))
        guard !ids.contains(destination), !destinationPath.contains(where: { ids.contains($0.id) }) else {
            error = L("Una carpeta no puede moverse ni copiarse dentro de sí misma."); return
        }
        var done = 0
        do {
            let api = try client(request.account)
            let siblings = try await api.list(parent: destination)
            let clashes = request.files.filter { file in siblings.contains { $0.id != file.id && $0.name.localizedCaseInsensitiveCompare(file.name) == .orderedSame } }
            guard clashes.isEmpty else {
                let names = clashes.map { "«\($0.name)»" }.joined(separator: ", ")
                throw CloudError.message(L("En la carpeta de destino ya existe \(names). Renombra antes de mover o copiar."))
            }
            if request.isMove, queue.hasActive(accountID: request.account.id) { throw CloudError.message(L("Pausa las transferencias de esta cuenta antes de mover sus archivos.")) }
            for file in request.files {
                if request.isMove {
                    try await api.move(file: file, to: destination)
                    try applyIdentityChange(api.identityChange(file: file, name: file.name, destination: destination), account: request.account, destinationPath: destinationPath)
                } else if request.account.cloud == .microsoft && !request.account.isDemo {
                    try await remoteCopies.start(file: file, destination: destination, api: api)
                } else { try await api.copy(file: file, to: destination) }
                done += 1
                if request.isMove {
                    for i in favorites.indices where favorites[i].accountID == request.account.id && favorites[i].file.id == file.id {
                        favorites[i].path = destinationPath; favorites[i].collection = .files
                    }
                }
            }
            if request.isMove { try LocalStore.save(favorites, to: favoritesURL) }
            let target = destinationPath.last?.name ?? L("Mis archivos")
            if !request.isMove, request.account.cloud == .microsoft, !request.account.isDemo {
                info = L("Copia enviada a OneDrive. Su estado se muestra en Transferencias hasta que el servidor confirme el resultado.")
                reload(fresh: true)
                return
            }
            // Whole sentences, so the participle agrees in each language instead of being spliced in Spanish.
            let name = request.files[0].name
            let summary = request.isMove
                ? (done == 1 ? L("«\(name)» movido a «\(target)».") : L("\(done) elementos movidos a «\(target)»."))
                : (done == 1 ? L("«\(name)» copiado a «\(target)».") : L("\(done) elementos copiados a «\(target)»."))
            info = summary + (!request.isMove && request.account.cloud == .microsoft ? L(" OneDrive puede tardar unos segundos en mostrar la copia.") : "")
        } catch {
            self.error = (done > 0 ? L("Se completaron \(done) de \(request.files.count). ") : L("")) + error.localizedDescription
        }
        reload(fresh: true)
    }

    /// What the Delete key does: bin from the tree, purge from the bin.
    func requestDelete(_ files: [CloudFile]) {
        if inTrash { requestPermanentDelete(files) } else { requestTrash(files) }
    }

    func requestTrash(_ files: [CloudFile]) {
        guard account != nil, !files.isEmpty else { return }
        pendingTrash = files
    }

    func requestPermanentDelete(_ files: [CloudFile]) {
        guard let account, !files.isEmpty else { return }
        if let reason = account.limitation(.permanentDelete, for: files) { error = reason; return }
        pendingPurge = files
    }

    func requestEmptyTrash() {
        guard let account, account.capabilities.emptyTrash else { return }
        pendingEmptyTrash = true
    }

    /// Deletes for good, one by one, stopping at the first failure so what remains is exactly what the list shows.
    func deletePermanently(_ files: [CloudFile]) async {
        guard let account else { return }
        var removed = 0
        do {
            let api = try client(account)
            for file in files {
                try await api.deletePermanently(file: file)
                removed += 1
                forgetLocally(file, account: account)
            }
            try LocalStore.save(favorites, to: favoritesURL)
            info = removed == 1 ? L("«\(files[0].name)» se ha eliminado definitivamente de \(account.cloud.title).") : L("\(removed) elementos eliminados definitivamente de \(account.cloud.title).")
        } catch {
            self.error = (removed > 0 ? L("Se eliminaron \(removed) de \(files.count) elementos. ") : L("")) + error.localizedDescription
        }
        reload(fresh: true)
    }

    /// Puts binned items back. Where they land is the provider's memory, not iCloudy's, and the message says so.
    func restore(_ files: [CloudFile]) async {
        guard let account else { return }
        var restored = 0
        do {
            let api = try client(account)
            for file in files {
                try await api.restore(file: file)
                restored += 1
            }
            info = restored == 1 ? L("«\(files[0].name)» ha vuelto a su carpeta en \(account.cloud.title).") : L("\(restored) elementos restaurados en \(account.cloud.title).")
        } catch {
            self.error = (restored > 0 ? L("Se restauraron \(restored) de \(files.count) elementos. ") : L("")) + error.localizedDescription
        }
        listings.removeAll(accountID: account.id)
        reload(fresh: true)
    }

    func emptyTrash() async {
        guard let account else { return }
        do {
            try await client(account).emptyTrash()
            for file in files { forgetLocally(file, account: account) }
            try LocalStore.save(favorites, to: favoritesURL)
            info = L("La papelera de \(account.cloud.title) se ha vaciado.")
        } catch { self.error = error.localizedDescription }
        reload(fresh: true)
        refreshStorage(account, force: true)
    }

    /// What the app itself knew about an item that no longer exists anywhere.
    private func forgetLocally(_ file: CloudFile, account: Account) {
        spotlight.forget(accountID: account.id, fileID: file.id)
        favorites.removeAll { $0.accountID == account.id && ($0.file.id == file.id || $0.path.contains { $0.id == file.id }) }
        offline.itemDeleted(file, accountID: account.id)
    }

    /// Sends the items to the trash one by one and stops at the first failure so the user sees exactly what remains.
    func trash(_ files: [CloudFile]) async {
        guard let account else { return }
        var moved = 0
        do {
            let api = try client(account)
            for file in files {
                try await api.trash(file: file)
                moved += 1
                spotlight.forget(accountID: account.id, fileID: file.id)
                offline.itemDeleted(file, accountID: account.id)
                favorites.removeAll { $0.accountID == account.id && ($0.file.id == file.id || $0.path.contains { $0.id == file.id }) }
            }
            try LocalStore.save(favorites, to: favoritesURL)
            if [.ftp, .sftp, .webdav].contains(account.cloud), !account.isDemo {
                info = L("\(moved) elementos eliminados del servidor de forma permanente.")
            } else if account.cloud == .volume {
                info = L("\(moved) elementos enviados a la papelera. Puedes restaurarlos desde el Finder.")
            } else if account.capabilities.trashListing {
                info = moved == 1 ? L("«\(files[0].name)» está en la papelera de \(account.cloud.title). Puedes restaurarlo desde la pestaña Papelera.") : L("\(moved) elementos enviados a la papelera de \(account.cloud.title). Puedes restaurarlos desde la pestaña Papelera.")
            } else {
            info = moved == 1 ? L("«\(files[0].name)» está en la papelera de \(account.cloud.title). Puedes restaurarlo desde su web.") : L("\(moved) elementos enviados a la papelera de \(account.cloud.title).")
            }
        } catch {
            self.error = (moved > 0 ? L("Se enviaron \(moved) de \(files.count) elementos. ") : L("")) + error.localizedDescription
        }
        reload(fresh: true)
    }

    func promptName(_ file: CloudFile? = nil) {
        guard let account, file != nil || canWrite else { return }
        editingFile = file; editName = file?.name ?? ""; editContext = (account, folderID); showNameDialog = true
    }

    func applyIdentityChange(_ change: RemoteIdentityChange, account: Account, destinationPath: [CloudFile]? = nil) throws {
        let previousParent = path.map(\.name)
        for i in favorites.indices where favorites[i].accountID == account.id {
            let old = favorites[i].file.id
            favorites[i].file = change.file(favorites[i].file)
            favorites[i].path = favorites[i].path.map(change.file)
            if let destinationPath {
                if old == change.oldID { favorites[i].path = destinationPath }
                else if let position = favorites[i].path.firstIndex(where: { $0.id == change.newID }) {
                    favorites[i].path = destinationPath + favorites[i].path[position...]
                }
            }
        }
        try LocalStore.save(favorites, to: favoritesURL)
        if selectedAccountID == account.id { path = path.map(change.file); files = files.map(change.file) }
        listings.removeAll(accountID: account.id)
        localCopies.remap(change, accountID: account.id)
        offlineFollow(change, account: account, destinationPath: destinationPath)
        spotlight.remap(change, accountID: account.id, accountLabel: accountTitle(account), oldParent: previousParent, newParent: destinationPath?.map(\.name))
        try mirrors.remap(change, accountID: account.id)
        try queue.remap(change, accountID: account.id)
    }

    func commitName() async {
        guard let (account, parent) = editContext else { return }
        let file = editingFile, name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = FileNames.problem(with: name, for: account.cloud) { error = problem; return }
        do {
            let api = try client(account)
            let siblings = try await api.list(parent: parent)
            guard !siblings.contains(where: { $0.id != file?.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw CloudError.message(L("Ya existe un elemento con ese nombre. Elige otro.")) }
            if let file {
                guard !queue.hasActive(accountID: account.id) else { throw CloudError.message(L("Pausa las transferencias de esta cuenta antes de renombrar sus archivos.")) }
                try await api.rename(file: file, name: name)
                try applyIdentityChange(api.identityChange(file: file, name: name), account: account)
            } else { _ = try await api.createFolder(name: name, parent: parent) }
            showNameDialog = false; reload(fresh: true)
        } catch { self.error = error.localizedDescription }
    }
}
