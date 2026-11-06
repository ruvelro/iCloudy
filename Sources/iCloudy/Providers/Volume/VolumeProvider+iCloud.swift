import Foundation

/// Where an item of iCloud Drive is: only in iCloud, on its way down, here and current, or here with changes on their
/// way up. Read from the file system's own resource values, never guessed.
enum UbiquityState: String, Hashable, Sendable {
    case cloudOnly, downloading, downloaded, uploading
    var symbol: String {
        switch self {
        case .cloudOnly: return "icloud"
        case .downloading: return "icloud.and.arrow.down"
        case .downloaded: return "checkmark.icloud"
        case .uploading: return "icloud.and.arrow.up"
        }
    }
    var help: String {
        switch self {
        case .cloudOnly: return L("Solo en iCloud: se descarga al abrirlo o copiarlo.")
        case .downloading: return L("Descargándose de iCloud.")
        case .downloaded: return L("Descargado en este Mac.")
        case .uploading: return L("Subiéndose a iCloud.")
        }
    }
}

extension Account {
    /// iCloud Drive is a volume account with this flavour: the same provider, a folder picked once, and the extra
    /// care that items which may be only in iCloud need. `Account.capabilities` sets what differs.
    static let iCloudFlavor = "icloud"
    var isICloudDrive: Bool { cloud == .volume && flavor == Account.iCloudFlavor }
}

/// iCloud Drive through the folder macOS keeps for it, `~/Library/Mobile Documents/com~apple~CloudDocs`. Since macOS
/// 14 a file iCloud has not downloaded is a *dataless* file: listed with its real name and size, but with no bytes on
/// disk until something reads it. Reading it blindly would block on the download with no progress and no way to stop
/// it, so before a preview, a download or a copy the provider asks iCloud for the file and waits, cancellably, and then
/// reads it under file coordination, as Apple asks of anyone touching ubiquitous items.
///
/// "Keep downloaded", the Finder's pin, has no public API an app can call, so it is not offered; downloading now and
/// removing the download (evicting, leaving the file in iCloud) are.
extension VolumeProvider {
    nonisolated static let ubiquityKeys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                                .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey,
                                                                .ubiquitousItemDownloadingErrorKey]

    /// The state of one item, or nil when it is not in iCloud at all.
    nonisolated static func ubiquity(of url: URL) -> UbiquityState? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: ubiquityKeys), values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current), .some(.downloaded): return .downloaded
        default: return .cloudOnly
        }
    }

    /// The listing with each file's state filled in, read off the main actor.
    func annotateUbiquity(_ files: [CloudFile]) async throws -> [CloudFile] {
        guard account.capabilities.ubiquitousItems else { return files }
        return try await blockingIO {
            files.map { file in
                guard !file.isFolder else { return file }
                var annotated = file
                annotated.ubiquity = Self.ubiquity(of: URL(fileURLWithPath: file.id))
                return annotated
            }
        }
    }

    /// Asks iCloud for the item and waits until its bytes are here. Cancelling the task stops the wait (iCloud may
    /// finish the download anyway, which costs nothing but the bytes). `interval` is how often the state is read.
    func ensureDownloaded(_ url: URL, interval: Duration = .milliseconds(250)) async throws {
        guard account.capabilities.ubiquitousItems, let state = Self.ubiquity(of: url), state == .cloudOnly || state == .downloading else { return }
        try await blockingIO { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        while true {
            try Task.checkCancellation()
            var probe = url
            probe.removeAllCachedResourceValues()
            let values = try probe.resourceValues(forKeys: Self.ubiquityKeys)
            if let error = values.ubiquitousItemDownloadingError {
                throw CloudError.message(L("iCloud no pudo descargar «\(url.lastPathComponent)»: \(error.localizedDescription)"))
            }
            if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded { return }
            try await Task.sleep(for: interval)
        }
    }

    /// Downloads an item (a folder with everything in it) so that it is on this Mac, without waiting for it.
    func startUbiquitousDownload(_ file: CloudFile) async throws {
        let url = try volumeURL(file.id)
        try await blockingIO { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }

    /// Removes the local copy of an item that is safely in iCloud. iCloud refuses while there are changes still to
    /// upload, and says so.
    func evictUbiquitousItem(_ file: CloudFile) async throws {
        let url = try volumeURL(file.id)
        if Self.ubiquity(of: url) == .uploading {
            throw CloudError.message(L("«\(file.name)» todavía se está subiendo a iCloud. Espera a que termine para quitar la descarga."))
        }
        do { try await blockingIO { try FileManager.default.evictUbiquitousItem(at: url) } }
        catch { throw CloudError.message(L("iCloud no quitó la descarga de «\(file.name)»: \(error.localizedDescription)")) }
    }

    /// Copies an item that is in iCloud to `destination`, under a coordinated read so that iCloud is not halfway
    /// through replacing it. The same checks as any volume read: inside the account's folder, no symbolic links.
    func coordinatedRead(_ source: URL, to destination: URL, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        let root = try volumeRoot()
        let relay: @MainActor @Sendable (Int64, Int64) -> Void = { done, total in progress(done, total) }
        try await blockingIO {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var failure: Error?
            coordinator.coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { coordinated in
                do {
                    let path = try VolumePath(root: root, url: coordinated)
                    let input = try path.openFile(O_RDONLY)
                    defer { try? input.close() }
                    let stamp = try UploadSourceStamp(coordinated)
                    try DownloadBudget.check(stamp.size, maximum: maxBytes)
                    let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw VolumePath.error() }
                    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var written: Int64 = 0
                    do {
                        defer { try? output.close() }
                        while true {
                            try Task.checkCancellation()
                            let chunk = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                            if chunk.isEmpty { break }
                            try DownloadBudget.check(written + Int64(chunk.count), maximum: maxBytes)
                            try output.write(contentsOf: chunk)
                            written += Int64(chunk.count)
                            let done = written, total = max(stamp.size, written)
                            Task { @MainActor in relay(done, total) }
                        }
                        try stamp.validate(coordinated)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        throw error
                    }
                } catch { failure = error }
            }
            if let coordinationError { throw coordinationError }
            if let failure { throw failure }
        }
    }
}
