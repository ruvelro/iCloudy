import AppKit
import UniformTypeIdentifiers

extension AppModel {
    /// Why this item cannot be opened in another app from the focused tab, or nil when it can.
    func openWithLimitation(_ file: CloudFile) -> String? {
        if file.isFolder { return L("Las carpetas no se abren con otra aplicación.") }
        if file.isGoogleDocument { return L("Los documentos de Google se editan en su web. Usa «Abrir en navegador».") }
        if inTrash { return L("Restaura el archivo antes de abrirlo.") }
        return nil
    }

    /// The apps of this Mac that say they open this kind of file, the default one first.
    func applications(toOpen file: CloudFile) -> [URL] {
        let ext = (file.name as NSString).pathExtension
        guard let type = ext.isEmpty ? UTType(mimeType: file.mime) : UTType(filenameExtension: ext) else { return [] }
        let all = NSWorkspace.shared.urlsForApplications(toOpen: type)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: type)
        return (preferred.map { [$0] } ?? []) + all.filter { $0 != preferred }
    }

    /// Asks for an app in /Applications, for «Abrir con › Otra…».
    func chooseApplication() async -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.prompt = L("Abrir")
        return await panel.begin() == .OK ? panel.url : nil
    }

    /// Downloads a private copy of the file, opens it in `application` (the system's choice when nil) and watches it.
    /// Saves come back through `uploadEdits`, by hand or by themselves with the setting on. Opened again while it is
    /// already open, the same copy is handed to the app instead of a second one.
    @discardableResult
    func openWith(_ file: CloudFile, application: URL? = nil) async -> EditSession.ID? {
        guard let account else { return nil }
        if let reason = openWithLimitation(file) { error = reason; return nil }
        if let open = editor.session(accountID: account.id, fileID: file.id) {
            do { editor.attach(open.id, app: try await editor.launch(open.localURL, application)) }
            catch { self.error = error.localizedDescription }
            return open.id
        }
        let tab = workspace.current
        // Only a real folder has somewhere for the changes to go back to.
        let parent = tab.collection == .files ? tab.folderID : nil
        let session: EditSession
        do { session = try editor.begin(file: file, accountID: account.id, parentID: parent, destination: location) }
        catch { self.error = error.localizedDescription; return nil }
        do {
            // Through the facade, so the copy is checked against the listed size and checksum before any app sees it.
            try await client(account).download(file: file, to: session.localURL)
            try await editor.ready(session.id)
            editor.attach(session.id, app: try await editor.launch(session.localURL, application))
            noteForSpotlight(file, account: account)
            if parent == nil {
                info = L("«\(file.name)» se ha abierto desde una lista que no es una carpeta: los cambios no se pueden subir desde aquí. Ábrelo desde su carpeta para poder subirlos.")
            }
            return session.id
        } catch {
            editor.close(session.id)
            if !(error is CancellationError) { self.error = L("No se pudo abrir «\(file.name)»: \(error.localizedDescription)") }
            return nil
        }
    }

    /// Queues the saved copy for upload to the folder it came from. If the cloud's version changed since the copy was
    /// made, the copy goes up beside it under another name and both are kept; otherwise it replaces the original.
    func uploadEdits(_ id: EditSession.ID) async {
        guard let session = editor.session(id), session.state != .uploading else { return }
        guard let parent = session.parentID, let account = browsable(session.accountID) else {
            editor.uploadFailed(id, reason: L("Este archivo se abrió desde una lista que no es una carpeta.")); return
        }
        editor.update(id) { $0.state = .uploading }
        do {
            let api = try client(account)
            let siblings = try await api.list(parent: parent)
            let current = siblings.first { $0.id == session.file.id }
                ?? siblings.first { $0.name.localizedCaseInsensitiveCompare(session.remoteName) == .orderedSame }
            let changedElsewhere = current.map { !ExternalEditor.sameVersion($0, session.file) } ?? false
            let name = changedElsewhere ? ExternalEditor.keptName(for: session.remoteName, existing: siblings.map(\.name)) : session.remoteName
            let staged = try await editor.stage(id, as: name)
            var job = Transfer(name: name, destination: session.destination, accountID: account.id, direction: .upload,
                               localURL: staged, bookmark: try TransferQueue.bookmark(staged), parent: parent)
            // Replacing is what the person asked for when nobody else touched the file; when somebody did, nothing is
            // replaced at all.
            job.batchChoice = changedElsewhere ? .copy : .replace
            try queue.add([job])
            editor.update(id) { $0.transferID = job.id; if changedElsewhere { $0.keptAs = name } }
            if changedElsewhere {
                info = L("«\(session.file.name)» ha cambiado en \(accountTitle(account)) mientras lo editabas. Tus cambios se suben como «\(name)» y la otra versión se queda como está.")
            }
        } catch {
            editor.uploadFailed(id, reason: error.localizedDescription)
        }
    }

    /// Stops watching and forgets the private copy; whatever was not uploaded is lost, which the button says.
    func stopEditing(_ id: EditSession.ID) { editor.close(id) }

    /// The queue finished an upload of an edited file: the session learns what the cloud now has.
    func editingTransferFinished(_ transfer: Transfer) {
        guard let session = editor.session(forTransfer: transfer.id), let parent = session.parentID,
              let account = browsable(session.accountID) else { return }
        let written = transfer.names["."] ?? transfer.name
        if session.keptAs != nil { editor.update(session.id) { $0.keptAs = written } }
        Task {
            let remote = try? await client(account).list(parent: parent).first { $0.name == written }
            editor.uploaded(session.id, remote: remote)
        }
    }

    /// A failed or cancelled upload leaves the change where it was, to try again.
    func editingQueueChanged() {
        for session in editor.sessions {
            guard let id = session.transferID, let job = queue.items.first(where: { $0.id == id }),
                  [.failed, .cancelled].contains(job.state) else { continue }
            editor.uploadFailed(session.id, reason: job.state == .cancelled ? L("La subida se canceló.") : job.detail)
        }
    }
}
