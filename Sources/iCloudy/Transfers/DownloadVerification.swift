import Foundation

/// What a finished download could be checked against. A failed check never returns: it throws, and the bytes are gone.
enum DownloadVerification: String, Codable {
    /// The provider's checksum matched a hash of the bytes on disk, and so did the listed size.
    case verified
    /// No checksum to compare: only the byte count was checked, when the provider listed one.
    case unavailable
    /// A Google document converted on the way out. Drive lists neither size nor checksum for what it generates.
    case exported
}

/// The durable per-file state of a download job, kept beside the upload checkpoints of the same job.
enum DownloadIntegrity: String, Codable {
    case verified, unavailable, exported
    /// The check failed and the downloaded copy was discarded; nothing was put in place.
    case failed
    init(_ verification: DownloadVerification) {
        switch verification {
        case .verified: self = .verified
        case .unavailable: self = .unavailable
        case .exported: self = .exported
        }
    }
}

/// A download whose bytes do not match what the provider listed.
enum DownloadIntegrityError: LocalizedError, Equatable {
    case sizeMismatch(name: String, expected: Int64, actual: Int64)
    case checksumMismatch(name: String)
    /// The item is no longer what was listed, so the mismatch says nothing about corruption. `current` is the new
    /// description, or nil when the item is gone.
    case changedRemotely(name: String, current: CloudFile?)
    /// Only a change with a new description to retry with is worth repeating; a corrupt copy would come back the same.
    var retryable: Bool {
        if case .changedRemotely(_, let current) = self { return current != nil }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .sizeMismatch(let name, let expected, let actual):
            return L("«\(name)» llegó con \(actual) bytes, pero el proveedor anuncia \(expected). La copia descargada se ha descartado.")
        case .checksumMismatch(let name):
            return L("La suma de verificación de «\(name)» no coincide con la que informa el proveedor. La copia descargada se ha descartado.")
        case .changedRemotely(let name, let current):
            return current == nil ? L("«\(name)» se borró o se movió mientras se descargaba.")
                                  : L("«\(name)» cambió en la nube mientras se descargaba. Se volverá a descargar la versión nueva.")
        }
    }
}

extension CloudAPI {
    /// Checks a downloaded file against the size and checksum the provider listed, in one streaming pass. On a
    /// mismatch the file is deleted, and the item is asked for again once so that a file someone changed while it
    /// travelled is reported as such instead of as corruption.
    func verifyDownload(_ file: CloudFile, at url: URL, exported: Bool, checksum: Bool) async throws -> DownloadVerification {
        // Drive generates an export on the fly: there is no listed size or checksum for that rendition.
        if exported || file.isGoogleDocument { return .exported }
        guard demo != nil || provider.canVerifyDownload(of: file) else { return .unavailable }
        let local = url
        let size = try await blockingIO { Int64(truncatingIfNeeded: (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0) }
        var problem: DownloadIntegrityError?
        var verification = DownloadVerification.unavailable
        if let expected = file.size, expected != size {
            problem = .sizeMismatch(name: file.name, expected: expected, actual: size)
        } else if checksum, let listed = file.checksum {
            let algorithm = listed.algorithm
            let (digest, _) = try await blockingIO { try ContentHasher.digest(of: local, algorithm: algorithm) }
            if listed.matches(digest) { verification = .verified } else { problem = .checksumMismatch(name: file.name) }
        }
        guard let problem else { return verification }
        try? FileManager.default.removeItem(at: url)
        throw try await reconcile(problem, file: file)
    }

    /// Decides whether a mismatch is corruption or a remote change. Errors other than "not found" propagate: a retry
    /// downloads and checks again, which is better than guessing.
    private func reconcile(_ problem: DownloadIntegrityError, file: CloudFile) async throws -> DownloadIntegrityError {
        let current: CloudFile?
        do { current = try await currentMetadata(of: file) }
        catch let error as ServiceError where error.status == 404 || (error.status == 409 && error.code?.contains("not_found") == true) {
            return .changedRemotely(name: file.name, current: nil)
        }
        guard let current else { return problem }
        return Self.changed(file, current) ? .changedRemotely(name: file.name, current: current) : problem
    }

    /// Only what both descriptions carry is compared: a field one of them lacks is not evidence of a change.
    nonisolated static func changed(_ listed: CloudFile, _ current: CloudFile) -> Bool {
        if let a = listed.size, let b = current.size, a != b { return true }
        if let a = listed.modified, let b = current.modified, a != b { return true }
        if let a = listed.checksum, let b = current.checksum, a.algorithm == b.algorithm, !a.matches(b.value) { return true }
        return false
    }

    func currentMetadata(of file: CloudFile) async throws -> CloudFile? {
        if let demo { return demo.file(file.id) }
        return try await provider.currentMetadata(of: file)
    }
}
