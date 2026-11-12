import AppKit
import Combine

/// A remote file opened in its own application: a copy in iCloudy's cache that is watched, and uploaded over the
/// original every time the application saves it.
struct EditSession: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        /// The copy is being downloaded.
        case preparing
        /// Waiting for the application to save.
        case watching
        /// A save is on its way up.
        case uploading
        /// The last save could not be uploaded; the copy keeps it, and it can be tried again.
        case failed
    }
    var id = UUID()
    let accountID: String
    /// The remote file as it was when the copy last agreed with it. A save replaces this one.
    var file: CloudFile
    /// The folder the file lives in, which is where a save goes when the original is no longer there.
    var parent: String
    /// "cuenta / Carpeta", for the sidebar.
    let location: String
    var localPath: String
    /// The copy as it was when it last agreed with the remote file. A different stamp is a save to upload.
    var stamp: FileStamp?
    var state: State = .preparing
    var detail: String?
    var activeTransferID: UUID?
    /// What the running upload will leave the copy as, promoted to `stamp` when it completes.
    var pendingStamp: FileStamp?
    /// The name the running upload goes under: the file's own, or another when the original changed meanwhile.
    var pendingName: String?
    var lastUpload: Date?
    var localURL: URL { URL(fileURLWithPath: localPath) }
}

extension EditSession {
    enum CodingKeys: String, CodingKey { case id, accountID, file, parent, location, localPath, stamp, state, detail, activeTransferID, pendingStamp, pendingName, lastUpload }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        accountID = try values.decode(String.self, forKey: .accountID)
        file = try values.decode(CloudFile.self, forKey: .file)
        parent = try values.decode(String.self, forKey: .parent)
        location = try values.decodeIfPresent(String.self, forKey: .location) ?? ""
        localPath = try values.decode(String.self, forKey: .localPath)
        stamp = try values.decodeIfPresent(FileStamp.self, forKey: .stamp)
        // A state written by a newer version is read as waiting: the next look at the copy decides what to do.
        state = (try? values.decodeIfPresent(String.self, forKey: .state)).flatMap { $0.flatMap(State.init(rawValue:)) } ?? .watching
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        activeTransferID = try values.decodeIfPresent(UUID.self, forKey: .activeTransferID)
        pendingStamp = try values.decodeIfPresent(FileStamp.self, forKey: .pendingStamp)
        pendingName = try values.decodeIfPresent(String.self, forKey: .pendingName)
        lastUpload = try values.decodeIfPresent(Date.self, forKey: .lastUpload)
    }
}

/// Keeps the files being edited: downloads the copy, opens it, watches it and queues an upload for every save.
///
/// The uploads are ordinary jobs of the transfer queue, so they are checked, retried and listed like any other. A
/// save never overwrites somebody else's work: if the remote file changed since the copy was taken, the save goes
/// up beside it under a name that says so, and the session carries on with that new file.
@MainActor
final class EditSessions: ObservableObject {
    @Published private(set) var sessions: [EditSession] = []
    @Published var persistenceError: String?
    let storeURL: URL
    /// Where the copies live, one folder per session so that an application's own temporary files stay beside it.
    let root: URL
    weak var queue: TransferQueue? {
        didSet { subscription = queue?.stateChanges.sink { [weak self] _ in self?.noteFailures() } }
    }
    var client: ((String) throws -> CloudAPI)?
    /// Hands the copy to its application. A seam for tests, which must not open anything.
    var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Tests turn this off: FSEvents on a temporary folder would race the assertions.
    var watching = true
    /// Applications save in several steps (a temporary file, a rename, the attributes); this lets them finish.
    var debounce: Duration = .seconds(2)
    /// Reports something the person should read: a save that went up as a copy, an upload that failed.
    var notify: ((String) -> Void)?
    private var watchers: [UUID: FolderWatcher] = [:]
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    /// Sessions saved again while their upload was running.
    private var dirty: Set<UUID> = []
    private var subscription: AnyCancellable?

    static var defaultStore: URL {
        guard Diagnostics.underTest else { return LocalStore.directory.appendingPathComponent("editing.json") }
        return FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-tests-\(ProcessInfo.processInfo.processIdentifier)/editing-\(UUID().uuidString).json")
    }
    static var defaultRoot: URL {
        let caches = Diagnostics.underTest ? FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-tests-\(ProcessInfo.processInfo.processIdentifier)")
                                           : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("iCloudy/Editing", isDirectory: true)
    }

    init(storeURL: URL = EditSessions.defaultStore, root: URL = EditSessions.defaultRoot) {
        self.storeURL = storeURL; self.root = root
        do { sessions = try LocalStore.read([EditSession].self, from: storeURL) ?? [] }
        catch { persistenceError = L("No se pudieron leer los archivos en edición: \(error.localizedDescription)") }
        // A download cut by quitting left nothing worth keeping.
        for session in sessions where session.state == .preparing { try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent()) }
        sessions.removeAll { $0.state == .preparing }
    }

    /// Called once the queue and the accounts exist: watches every copy again and uploads what was saved while
    /// iCloudy was closed.
    func start() {
        for session in sessions { watch(session); schedule(session.id, immediate: true) }
    }

    func session(for file: CloudFile, accountID: String) -> EditSession? {
        sessions.first { $0.accountID == accountID && $0.file.id == file.id }
    }

    /// Downloads `file` to a copy of its own and opens it. A file already being edited is simply opened again.
    func begin(_ file: CloudFile, account: Account, parent: String, location: String) async throws {
        if let existing = session(for: file, accountID: account.id) {
            guard existing.state != .preparing else { return }
            if !open(existing.localURL) { throw CloudError.message(L("No hay ninguna aplicación que abra «\(file.name)».")) }
            return
        }
        guard let client else { throw CloudError.message(L("Vuelve a conectar la cuenta de este archivo.")) }
        let api = try client(account.id)
        var session = EditSession(accountID: account.id, file: file, parent: parent, location: location, localPath: "")
        let folder = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent(FileNames.safe(file.name))
        session.localPath = copy.path
        sessions.append(session)
        let id = session.id
        do {
            try await api.download(file: file, to: copy)
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: folder); return }
            sessions[index].stamp = try Self.stamp(of: copy)
            sessions[index].state = .watching
            try persist()
            watch(sessions[index])
            if !open(copy) {
                notify?(L("«\(file.name)» está listo para editar, pero ninguna aplicación lo abre. Ábrelo desde el Finder con la que prefieras."))
            }
        } catch {
            sessions.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// True when the copy holds a save that has not reached the cloud.
    func hasUnsavedChanges(_ id: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        if session.state == .uploading || session.state == .failed { return true }
        return (try? Self.stamp(of: session.localURL)) != session.stamp
    }

    /// Stops watching and deletes the copy. An upload already in the queue is left to finish: it reads the copy
    /// through the queue's own staging only until then, so the folder goes once it is over.
    func end(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        watchers.removeValue(forKey: id)?.stop()
        scheduled.removeValue(forKey: id)?.cancel(); dirty.remove(id)
        if let active = session.activeTransferID, let job = queue?.items.first(where: { $0.id == active }), !job.finished { queue?.cancel(active) }
        try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent())
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }

    func removeAll(accountID: String) { for session in sessions where session.accountID == accountID { end(session.id) } }

    /// The file was renamed or moved from iCloudy while it was being edited: the next save follows it.
    func remap(_ change: RemoteIdentityChange, accountID: String) {
        var changed = false
        for index in sessions.indices where sessions[index].accountID == accountID {
            let file = change.file(sessions[index].file), parent = change.id(sessions[index].parent)
            if file != sessions[index].file || parent != sessions[index].parent { sessions[index].file = file; sessions[index].parent = parent; changed = true }
        }
        if changed { try? persist() }
    }

    /// Looks at the copy now: "Subir ahora" in the sidebar, and what a retry after a failure does.
    func uploadNow(_ id: UUID) { schedule(id, immediate: true) }

    /// Every copy is looked at when iCloudy comes to the front, in case an event was missed while it was not.
    func checkAll() { for session in sessions where session.state != .preparing { schedule(session.id, immediate: true) } }

    func status(of session: EditSession) -> String {
        switch session.state {
        case .preparing: return L("Descargando…")
        case .uploading: return L("Subiendo los cambios…")
        case .failed: return session.detail.map { L("Error: \($0)") } ?? L("No se pudieron subir los cambios")
        case .watching:
            if let detail = session.detail { return detail }
            guard let last = session.lastUpload else { return L("Esperando a que guardes") }
            let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
            return L("Cambios subidos \(formatter.localizedString(for: last, relativeTo: Date()))")
        }
    }

    // MARK: - Watching and uploading

    private func watch(_ session: EditSession) {
        guard watching, watchers[session.id] == nil else { return }
        let id = session.id
        watchers[id] = FolderWatcher(url: session.localURL.deletingLastPathComponent(), latency: 1) { [weak self] in
            Task { @MainActor in self?.schedule(id, immediate: false) }
        }
    }
    private func schedule(_ id: UUID, immediate: Bool) {
        scheduled[id]?.cancel()
        let delay = immediate ? Duration.zero : debounce
        scheduled[id] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            self.scheduled[id] = nil
            await self.check(id)
        }
    }

    /// Compares the copy with what last agreed with the cloud and, if it was saved since, sends it up.
    func check(_ id: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].state != .preparing else { return }
        let session = sessions[index]
        if let active = session.activeTransferID, let job = queue?.items.first(where: { $0.id == active }), !job.finished {
            // Saved again while the last save was still going up: look again when that one is over.
            if job.state == .paused { queue?.retry(active) }
            dirty.insert(id); return
        }
        guard let current = try? Self.stamp(of: session.localURL) else {
            // Some applications replace the file by moving the old one away first; a moment later it is back.
            if session.state != .failed { fail(id, L("La copia de «\(session.file.name)» ya no está donde iCloudy la dejó.")) }
            return
        }
        guard current != session.stamp else {
            if session.state == .failed, session.activeTransferID == nil { update(id) { $0.state = .watching; $0.detail = nil } }
            return
        }
        do { try await upload(id, stamp: current) }
        catch { fail(id, error.localizedDescription) }
    }

    private func upload(_ id: UUID, stamp: FileStamp) async throws {
        guard let session = sessions.first(where: { $0.id == id }), let queue, let client else { return }
        let api = try client(session.accountID)
        // Whoever else may have touched the file since the copy was taken is asked about before anything is replaced.
        let remote: CloudFile?
        if let described = try await api.currentMetadata(of: session.file) { remote = described }
        else { remote = try await api.list(parent: session.parent).first { $0.id == session.file.id } }
        guard sessions.contains(where: { $0.id == id }) else { return }
        var job = Transfer(name: session.file.name, destination: session.location, accountID: session.accountID, direction: .upload,
                           localURL: session.localURL, parent: session.parent)
        var name = session.file.name
        var note: String?
        if let remote, !CloudAPI.changed(session.file, remote) {
            // The file is the one the copy came from: the save takes its place.
            job.replacements["."] = remote.id
        } else if remote != nil {
            name = Self.conflictName(session.file.name, host: Host.current().localizedName ?? "Mac")
            note = L("«\(session.file.name)» cambió en la nube mientras lo editabas. Tus cambios se han subido aparte, como «\(name)», y el original sigue como estaba.")
        } else {
            note = L("«\(session.file.name)» ya no estaba en la nube. Tus cambios se han subido como un archivo nuevo.")
        }
        // The name is decided here, so the queue does not stop to ask about a file it is meant to replace.
        job.names["."] = name
        try queue.add([job])
        update(id) { $0.state = .uploading; $0.detail = nil; $0.activeTransferID = job.id; $0.pendingStamp = stamp; $0.pendingName = name }
        if let note { notify?(note) }
    }

    /// Hooked to the queue's `didFinish`: the copy and the cloud agree again, on whatever the upload left there.
    func handleFinished(_ transfer: Transfer) {
        guard let index = sessions.firstIndex(where: { $0.activeTransferID == transfer.id }) else { return }
        let id = sessions[index].id, name = sessions[index].pendingName ?? sessions[index].file.name
        let previous = sessions[index].file, parent = sessions[index].parent, accountID = sessions[index].accountID
        sessions[index].stamp = sessions[index].pendingStamp ?? sessions[index].stamp
        sessions[index].pendingStamp = nil; sessions[index].pendingName = nil; sessions[index].activeTransferID = nil
        sessions[index].state = .watching; sessions[index].detail = nil; sessions[index].lastUpload = Date()
        do { try persist() } catch { persistenceError = error.localizedDescription }
        Task { [weak self] in
            // What the provider now lists for the file is what the next save has to find unchanged.
            guard let self, let api = try? self.client?(accountID), let listed = try? await api.list(parent: parent) else { return }
            let now = listed.first { $0.id == previous.id && $0.name == name } ?? listed.first { $0.name == name && !$0.isFolder }
            if let now { self.update(id) { $0.file = now } }
            if self.dirty.remove(id) != nil { self.schedule(id, immediate: true) }
        }
    }

    private func noteFailures() {
        guard let queue else { return }
        for session in sessions {
            guard let active = session.activeTransferID, let job = queue.items.first(where: { $0.id == active }), [.failed, .cancelled].contains(job.state) else { continue }
            dirty.remove(session.id)
            update(session.id) { $0.activeTransferID = nil; $0.pendingStamp = nil; $0.pendingName = nil; $0.state = .failed
                                 $0.detail = job.state == .failed ? job.detail : L("Subida cancelada") }
        }
    }

    private func fail(_ id: UUID, _ message: String) {
        update(id) { $0.state = .failed; $0.detail = message }
    }
    private func update(_ id: UUID, _ change: (inout EditSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        do { try persist() } catch { persistenceError = error.localizedDescription }
    }
    private func persist() throws {
        do { try LocalStore.save(sessions.filter { $0.state != .preparing }, to: storeURL); persistenceError = nil }
        catch { persistenceError = L("No se pudieron guardar los archivos en edición: \(error.localizedDescription)"); throw error }
    }

    nonisolated static func stamp(of url: URL) throws -> FileStamp {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileNoSuchFile) }
        return FileStamp(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
    }
    /// "informe (editado en MacBook 2026-11-12 18.30).docx": the same shape as a sync conflict, and as easy to find.
    nonisolated static func conflictName(_ name: String, host: String, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        return url.deletingPathExtension().lastPathComponent + " (editado en " + host + " " + formatter.string(from: date) + ")" + (ext.isEmpty ? "" : "." + ext)
    }
}
