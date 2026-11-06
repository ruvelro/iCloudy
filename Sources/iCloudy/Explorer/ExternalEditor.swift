import Foundation
import AppKit
import CryptoKit

/// What a local file was at one moment: enough to tell a real save from an editor touching the file without changing
/// a byte, which several do when a document is merely opened.
struct LocalStamp: Equatable, Sendable {
    let size: Int64
    let modified: Date
    let digest: String

    static func of(_ url: URL) throws -> LocalStamp {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return LocalStamp(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                          digest: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// A file of the cloud open in another app, from a private copy that iCloudy watches.
struct EditSession: Identifiable, Equatable {
    enum State: Equatable {
        case downloading
        /// Open in the app; nothing saved since the last upload.
        case watching
        /// Saved in the app and not uploaded yet.
        case changed
        case uploading
        case failed(String)
    }
    let id: UUID
    let accountID: String
    /// The remote item as last seen. A re-upload compares the cloud against it to tell whether somebody else changed
    /// the file meanwhile.
    var file: CloudFile
    /// The folder changes go back to. nil when the file was opened from a list that is not a folder (Recientes,
    /// Compartido conmigo): the copy is still watched, but there is nowhere to upload it.
    let parentID: String?
    /// The folder as the transfers panel labels it.
    let destination: String
    /// The private copy the app edits.
    let localURL: URL
    var appName: String?
    var appPID: pid_t?
    /// The local copy as last uploaded (or downloaded): saves are measured against it.
    var baseline: LocalStamp?
    var state: State = .downloading
    /// The upload under way, and the copy of the file it reads, staged so the app can keep saving meanwhile.
    var transferID: UUID?
    var staged: (url: URL, stamp: LocalStamp)?
    /// The name of the copy kept beside the original when both had changed. Later saves go to that copy, never over
    /// the other person's version.
    var keptAs: String?
    var canUpload: Bool { parentID != nil }
    /// The name the next upload writes.
    var remoteName: String { keptAs ?? file.name }

    static func == (a: EditSession, b: EditSession) -> Bool {
        a.id == b.id && a.file == b.file && a.appName == b.appName && a.appPID == b.appPID && a.baseline == b.baseline
            && a.state == b.state && a.transferID == b.transferID && a.staged?.url == b.staged?.url && a.keptAs == b.keptAs
    }

    var stateTitle: String {
        let app = appName ?? L("otra aplicación")
        switch state {
        case .downloading: return L("Abriendo en \(app)…")
        case .watching: return L("Abierto en \(app)")
        case .changed: return L("Cambiado en \(app), sin subir")
        case .uploading: return L("Subiendo los cambios…")
        case .failed(let reason): return L("No se subieron los cambios: \(reason)")
        }
    }
}

/// Opens cloud files in other apps and brings their changes back.
///
/// Each file gets a private folder of its own under the caches, watched with FSEvents; a save is compared by content
/// with the copy last uploaded. Uploads go through the transfer queue like any other, with its checkpoints and its checks; this
/// type only says what to upload and where. It never deletes a remote file and never writes over a version it has
/// not seen: if the cloud changed meanwhile, both are kept.
@MainActor
@Observable
final class ExternalEditor {
    static let autoUploadKey = "autoUploadExternalEdits"
    private(set) var sessions: [EditSession] = []
    /// Where the private copies live. Tests point it at a folder of their own.
    @ObservationIgnored var root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iCloudy/Editing", isDirectory: true)
    /// Opens the copy in the app, the system's choice when nil, and answers the app that took it. Replaced in tests.
    @ObservationIgnored var launch: (URL, URL?) async throws -> NSRunningApplication? = { file, app in
        let configuration = NSWorkspace.OpenConfiguration()
        guard let app = app ?? NSWorkspace.shared.urlForApplication(toOpen: file) else {
            throw CloudError.message(L("Ninguna aplicación de este Mac abre «\(file.lastPathComponent)».") )
        }
        return try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }
    /// A save was noticed: the model uploads it, or waits for the person.
    @ObservationIgnored var didChange: ((EditSession.ID) -> Void)?
    /// How long a burst of events has to settle before the file is read: editors write in several steps.
    @ObservationIgnored var settle: Duration = .milliseconds(400)
    @ObservationIgnored private var watchers: [EditSession.ID: FolderWatcher] = [:]
    @ObservationIgnored private var pending: [EditSession.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var termination: NSObjectProtocol?

    var autoUpload: Bool { Prefs.bool(Self.autoUploadKey, default: false) }

    init() {
        termination = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.appQuit(pid) } }
        }
    }

    func session(_ id: EditSession.ID) -> EditSession? { sessions.first { $0.id == id } }
    func session(accountID: String, fileID: String) -> EditSession? {
        sessions.first { $0.accountID == accountID && $0.file.id == fileID }
    }
    func session(forTransfer id: UUID) -> EditSession? { sessions.first { $0.transferID == id } }

    func update(_ id: EditSession.ID, _ change: (inout EditSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
    }

    /// A new session and its private folder, before the download. The copy carries the file's own name, so the app
    /// shows it and so the upload writes that name back.
    func begin(file: CloudFile, accountID: String, parentID: String?, destination: String) throws -> EditSession {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = EditSession(id: UUID(), accountID: accountID, file: file, parentID: parentID, destination: destination,
                                  localURL: folder.appendingPathComponent(FileNames.safe(file.name)))
        sessions.append(session)
        return session
    }

    /// The copy is on disk: from now on its saves count.
    func ready(_ id: EditSession.ID) async throws {
        guard let url = session(id)?.localURL else { return }
        let stamp = try await blockingIO { try LocalStamp.of(url) }
        update(id) { $0.baseline = stamp; $0.state = .watching }
        watch(id)
    }

    func attach(_ id: EditSession.ID, app: NSRunningApplication?) {
        update(id) { $0.appName = app?.localizedName; $0.appPID = app?.processIdentifier }
    }

    private func watch(_ id: EditSession.ID) {
        guard let url = session(id)?.localURL else { return }
        watchers[id]?.stop()
        // The mirrors' FSEvents watcher, on the copy's own folder: it reports a save in place and an editor that
        // replaces the file whole (writing a temporary file and renaming it over the old one) alike.
        watchers[id] = FolderWatcher(url: url.deletingLastPathComponent(), latency: 0.2) { [weak self] in
            Task { @MainActor in self?.noticed(id) }
        }
    }

    /// Events come in bursts (write, rename, attributes); the file is read once they stop.
    private func noticed(_ id: EditSession.ID) {
        pending[id]?.cancel()
        pending[id] = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            await self?.check(id)
        }
    }

    /// Reads the copy and, if its content differs from what was last uploaded, marks the session changed.
    func check(_ id: EditSession.ID) async {
        guard let current = session(id), let baseline = current.baseline else { return }
        guard let stamp = try? await blockingIO({ [url = current.localURL] in try LocalStamp.of(url) }) else { return }
        guard stamp.digest != baseline.digest else { return }
        // Already uploading: the staged copy is what goes now, and this save is looked at again when it lands.
        guard current.state != .uploading, current.state != .changed else { return }
        update(id) { $0.state = .changed }
        didChange?(id)
    }

    /// Takes a copy of the file as it is now for the upload to read. The app may save again while the queue is
    /// reading; the queue then checks a file that does not move under it.
    func stage(_ id: EditSession.ID, as name: String) async throws -> URL {
        guard let current = session(id) else { throw CancellationError() }
        let folder = root.appendingPathComponent("upload-" + UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(FileNames.safe(name))
        let stamp = try await blockingIO { [source = current.localURL] in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: target)
            return try LocalStamp.of(target)
        }
        update(id) { $0.staged = (target, stamp) }
        return target
    }

    /// The upload landed: the staged copy becomes the new baseline, and a save made meanwhile is looked at again.
    func uploaded(_ id: EditSession.ID, remote: CloudFile?) {
        guard let current = session(id) else { return }
        removeStaged(current)
        update(id) {
            if let stamp = $0.staged?.stamp { $0.baseline = stamp }
            if let remote { $0.file = remote }
            $0.staged = nil; $0.transferID = nil; $0.state = .watching
        }
        if watchers[id] == nil { finishIfIdle(id) } else { Task { await check(id) } }
    }

    func uploadFailed(_ id: EditSession.ID, reason: String) {
        guard let current = session(id) else { return }
        removeStaged(current)
        update(id) { $0.staged = nil; $0.transferID = nil; $0.state = .failed(reason) }
    }

    private func removeStaged(_ session: EditSession) {
        if let staged = session.staged?.url { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
    }

    /// The app that had the file quit. Watching stops; a session with nothing left to upload is closed, one with a
    /// save not yet uploaded stays so the change can still go up.
    private func appQuit(_ pid: pid_t) {
        for session in sessions where session.appPID == pid {
            watchers[session.id]?.stop(); watchers[session.id] = nil
            pending[session.id]?.cancel(); pending[session.id] = nil
            finishIfIdle(session.id)
        }
    }

    private func finishIfIdle(_ id: EditSession.ID) {
        guard let current = session(id), current.state == .watching || current.state == .downloading else { return }
        close(id)
    }

    /// Stops watching and forgets the copy. An upload already in the queue keeps its own staged copy and finishes.
    func close(_ id: EditSession.ID) {
        watchers[id]?.stop(); watchers[id] = nil
        pending[id]?.cancel(); pending[id] = nil
        guard let current = session(id) else { return }
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: current.localURL.deletingLastPathComponent())
    }

    /// Folders left by an earlier run, except those a queued upload still reads.
    func removeLeftovers(protecting protected: [URL]) {
        let kept = Set(protected.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(child.standardizedFileURL.path) && !sessions.contains(where: { $0.localURL.deletingLastPathComponent().standardizedFileURL == child.standardizedFileURL }) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// The name of the copy kept beside a version somebody else changed: «Informe (mi versión).docx», numbered if
    /// that is taken too.
    static func keptName(for name: String, existing: [String]) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let proposed = L("\(base) (mi versión)") + (ext.isEmpty ? "" : "." + ext)
        return TransferQueue.unique(proposed, existing: existing)
    }

    /// True when the cloud still has the version the copy was made from. Checksums decide when both sides have one;
    /// otherwise size and modification date, to the second, which is as fine as every provider reports it.
    static func sameVersion(_ a: CloudFile, _ b: CloudFile) -> Bool {
        if let x = a.checksum, let y = b.checksum, x.algorithm == y.algorithm { return x.matches(y.value) }
        let dates: Bool = switch (a.modified, b.modified) {
        case (let x?, let y?): abs(x.timeIntervalSince(y)) < 1
        case (nil, nil): true
        default: false
        }
        return a.size == b.size && dates
    }
}
