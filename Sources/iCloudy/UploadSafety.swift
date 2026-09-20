import Foundation
import Darwin

/// A fresh lstat on every check: URL resource-value caches must not hide edits or path replacements.
struct UploadSourceStamp: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CloudError.message(L("Solo se admiten archivos regulares, sin enlaces simbólicos."))
        }
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
    }
    func validate(_ url: URL) throws {
        guard try self == UploadSourceStamp(url) else { throw CloudError.message(L("El archivo cambió durante la subida.")) }
    }
}

enum UploadIntegrity: String, Codable { case pending, verified, unavailable, failed }
extension UploadCheckpoint {
    /// Server commit and local verification are separate durable states. A crash or a failed hash can never become
    /// a successful, unverified retry. Explicitly cancelling and starting anew is required for an ambiguous commit.
    mutating func finish(remoteID: String?, save: (UploadCheckpoint) throws -> Void,
                         verify: () throws -> UploadVerification) throws -> UploadReceipt {
        complete = true; offset = total; self.remoteID = remoteID; integrity = .pending
        try save(self)
        let verification: UploadVerification
        do { verification = try verify() }
        catch { integrity = .failed; try save(self); throw error }
        integrity = verification == .verified ? .verified : .unavailable
        try save(self)
        return UploadReceipt(remoteID: remoteID, verification: verification)
    }
}
