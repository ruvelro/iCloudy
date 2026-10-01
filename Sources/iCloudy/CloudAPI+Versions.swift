import Foundation

/// The version history of a file, behind the same facade as everything else. The demo has no history to show.
extension CloudAPI {
    func versions(of file: CloudFile) async throws -> [FileVersion] {
        if demo != nil { throw CloudError.message(account.versionsUnavailable) }
        if let reason = account.versionsLimitation(for: file) { throw CloudError.message(reason) }
        return try await provider.versions(of: file)
    }
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        if demo != nil { throw CloudError.message(account.versionsUnavailable) }
        if let reason = account.versionLimitation(.restore, version: version, of: file) { throw CloudError.message(reason) }
        try await provider.restoreVersion(version, of: file)
    }
    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws {
        if demo != nil { throw CloudError.message(account.versionsUnavailable) }
        if let reason = account.versionLimitation(.delete, version: version, of: file) { throw CloudError.message(reason) }
        try await provider.deleteVersion(version, of: file)
    }

    /// Downloads the version a `VersionedFile` item stands for, and checks it the way `download` checks a file: the
    /// listed size, then the version's own checksum. A mismatch is not reconciled against the current metadata, as
    /// an ordinary download's is, because a version does not change; it is reported as the corruption it is.
    func downloadVersion(_ file: CloudFile, reference: (file: CloudFile, versionID: String), to destination: URL, exportMime: String?,
                         maxBytes: Int64?, checksum: Bool, progress: @escaping (Int64, Int64) -> Void) async throws -> DownloadVerification {
        let request = try await provider.versionContentRequest(for: reference.file, version: reference.versionID, exportMime: exportMime)
        try await provider.downloadHTTP(request, to: destination, maxBytes: maxBytes, progress: progress)
        if let maxBytes, Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > maxBytes {
            try? FileManager.default.removeItem(at: destination)
            throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
        }
        if exportMime != nil || file.isGoogleDocument { return .exported }
        guard provider.canVerifyDownload(of: file) else { return .unavailable }
        return try await Self.checkVersion(file, at: destination, checksum: checksum)
    }

    /// Size first, then the checksum when there is one; the copy is deleted before the error leaves.
    nonisolated static func checkVersion(_ file: CloudFile, at url: URL, checksum: Bool) async throws -> DownloadVerification {
        let size = try await blockingIO { Int64(truncatingIfNeeded: (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) }
        var problem: DownloadIntegrityError?
        var verification = DownloadVerification.unavailable
        if let expected = file.size, expected != size {
            problem = .sizeMismatch(name: file.name, expected: expected, actual: size)
        } else if checksum, let listed = file.checksum {
            let algorithm = listed.algorithm
            let (digest, _) = try await blockingIO { try ContentHasher.digest(of: url, algorithm: algorithm) }
            if listed.matches(digest) { verification = .verified } else { problem = .checksumMismatch(name: file.name) }
        }
        guard let problem else { return verification }
        try? FileManager.default.removeItem(at: url)
        throw problem
    }
}

extension CloudProvider {
    /// Restores by writing the version's bytes back as new content, for providers that have no call to do it on the
    /// server. The bytes go through a private temporary file, are checked against the version before anything is
    /// sent, and are uploaded over the current file with the same verified upload the queue uses.
    func restoreByUpload(_ version: FileVersion, of file: CloudFile, parent: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-version-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("contenido")
        try await downloadHTTP(try await versionContentRequest(for: file, version: version.id, exportMime: nil), to: local, maxBytes: nil) { _, _ in }
        let expected = CloudFile(id: file.id, name: file.name, mime: file.mime, size: version.size, modified: version.modified, webURL: nil,
                                 isFolder: false, checksum: version.checksum)
        _ = try await CloudAPI.checkVersion(expected, at: local, checksum: true)
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var cursor = UploadCheckpoint(total: Int64(attributes.fileSize ?? 0), modified: attributes.contentModificationDate)
        cursor.sourceStamp = try UploadSourceStamp(local)
        _ = try await uploadFile(local: local, parent: parent, name: file.name, replacing: file.id, cursor: &cursor, save: { _ in }, progress: { _, _ in })
    }
}
