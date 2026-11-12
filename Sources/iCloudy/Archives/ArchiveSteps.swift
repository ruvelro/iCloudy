import AppKit

/// The second half of a compressed transfer, kept on the job so that it still happens if iCloudy is closed between
/// the transfer and it.
///
/// A download "as ZIP" brings the items to a staging folder and compresses them when the last job of its batch
/// completes; "download and extract" brings one archive and opens it into a folder of its own; "upload compressed"
/// uploads an archive made beforehand and only has to throw it away afterwards.
struct ArchiveStep: Codable, Equatable {
    enum Kind: String, Codable {
        /// Compress what the batch staged into `folder`, as `name`.
        case compress
        /// Extract the downloaded archive into a new folder inside `folder`, named `name`.
        case extract
        /// The uploaded archive was a temporary one of ours: delete it.
        case discard
    }
    var kind: Kind
    /// Where the result goes: a folder the person chose.
    var folder: URL?
    var bookmark: Data?
    /// The archive's file name for `compress`, the new folder's name for `extract`.
    var name: String = ""
}

/// Runs archive steps and keeps their staging folders.
@MainActor
final class ArchiveSteps {
    /// One folder per batch, in the app's cache.
    let root: URL
    weak var queue: TransferQueue?
    var report: ((_ message: String, _ isError: Bool) -> Void)?
    /// Records a result the person will want to find again: the archive made, the folder extracted.
    var reveal: ((URL) -> Void)?
    private var running: Set<UUID> = []

    static var defaultRoot: URL {
        let caches = Diagnostics.underTest ? FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-tests-\(ProcessInfo.processInfo.processIdentifier)")
                                           : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("iCloudy/Archives", isDirectory: true)
    }
    init(root: URL = ArchiveSteps.defaultRoot) { self.root = root }

    func staging(for batch: UUID) -> URL { root.appendingPathComponent(batch.uuidString, isDirectory: true) }

    /// Makes the staging folder of a batch, private to this user.
    func prepareStaging(for batch: UUID) throws -> URL {
        let folder = staging(for: batch)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Staging folders no job can still need: the batch was cleared from the panel, or the app quit halfway and the
    /// queue no longer knows it. Called at launch, and whenever the queue settles.
    func cleanStale() {
        guard let queue else { return }
        let needed = Set(queue.items.filter { $0.archive != nil && $0.state != .cancelled }.map { $0.batchID.uuidString }).union(running.map(\.uuidString))
        for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !needed.contains(child.lastPathComponent) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// Hooked to the queue's `didFinish`. A step runs once every job of its batch has completed; if one of them
    /// failed or was cancelled, the batch waits for the person to retry it.
    func handleFinished(_ transfer: Transfer) {
        guard let step = transfer.archive, let queue else { return }
        let batch = transfer.batchID
        let mates = queue.items.filter { $0.batchID == batch && $0.archive != nil }
        guard !running.contains(batch), mates.allSatisfy({ $0.state == .completed }) else { return }
        running.insert(batch)
        let staging = staging(for: batch)
        Task {
            defer { running.remove(batch) }
            do {
                switch step.kind {
                case .discard: break
                case .compress:
                    let target = try await Self.inFolder(step) { folder in
                        let target = FileNames.available(in: folder, name: step.name)
                        let items = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
                        let stem = (step.name as NSString).deletingPathExtension
                        try ZipArchive.compress(items: items, named: stem, to: target, staging: staging.appendingPathComponent(".gather", isDirectory: true))
                        return target
                    }
                    report?(L("«\(target.lastPathComponent)» está en \(target.deletingLastPathComponent().path)."), false)
                    reveal?(target)
                case .extract:
                    let archive = staging.appendingPathComponent(FileNames.safe(transfer.file?.name ?? transfer.name))
                    let (target, count) = try await Self.inFolder(step) { folder -> (URL, Int) in
                        let target = FileNames.available(in: folder, name: step.name)
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        do { return (target, try ZipArchive.extract(archive, to: target)) }
                        catch { try? FileManager.default.removeItem(at: target); throw error }
                    }
                    report?(L("\(count) archivos extraídos en «\(target.lastPathComponent)»."), false)
                    reveal?(target)
                }
                // The step is done: the jobs stop carrying it, so a later relaunch does not run it again.
                for mate in mates { queue.settleArchive(mate.id) }
                try? FileManager.default.removeItem(at: staging)
            } catch {
                // The staged bytes are kept: the cause may be a full disk or a folder that moved, and the batch can
                // be run again from the panel without downloading anything twice.
                report?(step.kind == .extract ? L("No se pudo descomprimir «\(transfer.name)»: \(error.localizedDescription)")
                                              : L("No se pudo crear «\(step.name)»: \(error.localizedDescription)"), true)
            }
        }
    }

    /// Runs `work` off the main thread with the chosen folder open, through its bookmark when there is one.
    private nonisolated static func inFolder<T: Sendable>(_ step: ArchiveStep, _ work: @escaping @Sendable (URL) throws -> T) async throws -> T {
        try await blockingIO {
            guard var folder = step.folder else { throw CloudError.message(L("Falta la carpeta de destino.")) }
            if let bookmark = step.bookmark {
                var stale = false
                folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            return try work(folder)
        }
    }

    /// Steps whose transfers completed in an earlier run that ended before the step did.
    func resumeInterrupted() {
        guard let queue else { return }
        var seen: Set<UUID> = []
        for job in queue.items where job.archive != nil && job.state == .completed && seen.insert(job.batchID).inserted { handleFinished(job) }
        cleanStale()
    }
}

extension AppModel {
    /// "Descargar como ZIP…": the selection comes down to a staging folder and leaves it as one archive.
    func saveCompressed(_ files: [CloudFile]) async {
        guard let account, browsable(account.id) != nil, !files.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("Guardar el ZIP aquí")
        panel.message = L("La selección se descarga y se comprime en un único archivo .zip en la carpeta que elijas.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        let stem = files.count == 1 ? (files[0].isFolder ? files[0].name : (files[0].name as NSString).deletingPathExtension) : L("Archivo")
        do {
            let batch = UUID()
            let staging = try archives.prepareStaging(for: batch)
            let step = ArchiveStep(kind: .compress, folder: folder, bookmark: try TransferQueue.bookmark(folder), name: FileNames.safe(stem) + ".zip")
            try queue.add(files.map { file in
                var job = Transfer(batchID: batch, name: file.name, destination: L("\(step.name) en \(folder.path)"), accountID: account.id, direction: .download, localURL: staging, file: file)
                job.archive = step
                return job
            })
        } catch { self.error = error.localizedDescription }
    }

    /// "Descargar y descomprimir…": one ZIP comes down and is opened into a folder named after it.
    func saveExtracted(_ file: CloudFile) async {
        guard let account, browsable(account.id) != nil, !file.isFolder else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("Descomprimir aquí")
        panel.message = L("El archivo se descarga y su contenido se extrae en una carpeta nueva dentro de la que elijas.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        do {
            let batch = UUID()
            let staging = try archives.prepareStaging(for: batch)
            let name = FileNames.safe((file.name as NSString).deletingPathExtension)
            var job = Transfer(batchID: batch, name: file.name, destination: L("«\(name)» en \(folder.path)"), accountID: account.id, direction: .download, localURL: staging, file: file)
            job.archive = ArchiveStep(kind: .extract, folder: folder, bookmark: try TransferQueue.bookmark(folder), name: name)
            try queue.add([job])
        } catch { self.error = error.localizedDescription }
    }

    /// "Subir comprimido…": what is chosen is compressed on the Mac and goes up as one .zip.
    func pickCompressedUpload() async {
        guard let account, canWrite else { return }
        let parent = folderID, destination = location
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = L("Comprimir y subir")
        panel.message = L("Lo que elijas se comprime en un único .zip, que es lo que se sube.")
        guard await panel.begin() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let stem = urls.count == 1 ? (urls[0].hasDirectoryPath ? urls[0].lastPathComponent : urls[0].deletingPathExtension().lastPathComponent) : L("Archivo")
        let name = FileNames.safe(stem) + ".zip"
        info = L("Comprimiendo «\(name)»…")
        do {
            let batch = UUID()
            let staging = try archives.prepareStaging(for: batch)
            let archive = staging.appendingPathComponent(name)
            try await blockingIO {
                let scopes = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (url, scoped) in scopes where scoped { url.stopAccessingSecurityScopedResource() } }
                try ZipArchive.compress(items: urls, named: stem, to: archive, staging: staging.appendingPathComponent(".gather", isDirectory: true))
            }
            var job = Transfer(batchID: batch, name: name, destination: destination, accountID: account.id, direction: .upload, localURL: archive, parent: parent)
            job.archive = ArchiveStep(kind: .discard)
            try queue.add([job])
            info = L("«\(name)» en cola para subir.")
        } catch { self.error = L("No se pudo comprimir: \(error.localizedDescription)") }
    }

    /// True for what "Descargar y descomprimir…" can open.
    static func isZip(_ file: CloudFile) -> Bool { !file.isFolder && (file.name as NSString).pathExtension.lowercased() == "zip" }
}
