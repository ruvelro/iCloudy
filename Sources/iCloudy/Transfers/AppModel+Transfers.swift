import AppKit
import SwiftUI
import Combine

extension AppModel {
    func pickUpload() async {
        guard let account, canWrite else { return }
        let parent = folderID, destination = location
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.prompt = L("Subir")
        if await panel.begin() == .OK { planUploads(panel.urls, target: (account, parent, destination)) }
    }

    /// `seeds` are the plan's per-item reports, in the order of the file URLs among `urls`.
    @discardableResult func enqueueUploads(_ urls: [URL], target: (Account, String, String)? = nil, seeds: [[String: FileRecord]]? = nil) -> Bool {
        guard let account = target?.0 ?? account, target != nil || canWrite else {
            if !canWrite { error = L("Abre una carpeta de «Mis archivos» para subir aquí. Recientes y Compartido conmigo son listas, no carpetas.") }
            return false
        }
        let batch = UUID()
        do {
            let jobs = try urls.filter(\.isFileURL).enumerated().map { index, url -> Transfer in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var job = Transfer(batchID: batch, name: url.lastPathComponent, destination: target?.2 ?? location, accountID: account.id, direction: .upload, localURL: url, bookmark: try TransferQueue.bookmark(url), parent: target?.1 ?? folderID)
                job.seed(seeds?.indices.contains(index) == true ? seeds?[index] : nil)
                return job
            }
            try queue.add(jobs)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func save(_ file: CloudFile, export: (mime: String, ext: String)? = nil) async { await saveMany([file], export: export) }

    func saveMany(_ files: [CloudFile], export: (mime: String, ext: String)? = nil, targetAccount: Account? = nil) async {
        guard let account = targetAccount ?? account, accounts.contains(where: { $0.id == account.id }), !files.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = L("Guardar aquí")
        panel.message = L("Los documentos de Google dentro de carpetas se guardan como enlaces. Si hay nombres repetidos, podrás decidir qué hacer.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        planDownloads(files, account: account, folder: folder, export: export) { [weak self] seeds in
            guard let self else { return }
            do {
                let bookmark = try TransferQueue.bookmark(folder), batch = UUID()
                try queue.add(files.enumerated().map { index, file in
                    var job = Transfer(batchID: batch, name: file.name, destination: folder.path, accountID: account.id, direction: .download, localURL: folder, bookmark: bookmark, file: file, exportMime: export?.mime, exportExtension: export?.ext)
                    job.seed(seeds?.indices.contains(index) == true ? seeds?[index] : nil)
                    return job
                })
            } catch { self.error = error.localizedDescription }
        }
    }
}
