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
    /// The same file with the same bytes, as far as metadata can say: only the change time differs, which is what
    /// fixing permissions or ownership moves. An edit that put the modification time back also moves only the change
    /// time, which is why this is trusted only where no byte has been sent.
    func sameContent(as other: UploadSourceStamp) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
}

/// A partly sent upload whose source is no longer the file it started from. The bytes already at the provider belong
/// to the earlier version, so carrying on would publish a mix of the two; starting from zero is the only way forward,
/// and the transfers panel offers it.
struct UploadSourceChanged: LocalizedError {
    let name: String
    var errorDescription: String? {
        L("«\(name)» ha cambiado desde que empezó a subirse, o han cambiado sus permisos o su propietario. Lo ya enviado es de la versión anterior y no se mezcla con la nueva: usa «Empezar de cero» para subirlo entero.")
    }
}

extension UploadCheckpoint {
    /// The checkpoint an upload of `local`, as the file is right now, carries on from.
    ///
    /// A checkpoint that has sent nothing yet and whose file differs only in its change time (a permission fixed
    /// after "could not be read", a new owner) is replaced by a fresh one, upload session included: a session the
    /// server may have fed with bytes whose receipt was never saved is not continued. Any other difference, or any
    /// difference at all once bytes were sent, change time included, is refused: that is A03's protection against
    /// mixing two versions, and the person decides whether to start over.
    static func resuming(_ saved: UploadCheckpoint?, for local: URL, total: Int64, modified: Date?) throws -> UploadCheckpoint {
        let stamp = try UploadSourceStamp(local)
        var fresh = UploadCheckpoint(total: total, modified: modified)
        fresh.sourceStamp = stamp
        guard var cursor = saved else { return fresh }
        let unchanged = cursor.total == total && cursor.modified == modified && (cursor.sourceStamp.map { $0 == stamp } ?? true)
        if cursor.complete {
            // What was committed is judged by its integrity record; a source that changed since cannot be vouched for.
            guard cursor.total == total, cursor.modified == modified else { throw CloudError.message(L("El origen ha cambiado. Cancela esta operación y vuelve a subirlo.")) }
            if let original = cursor.sourceStamp { try original.validate(local) }
            cursor.sourceStamp = stamp
            return cursor
        }
        if unchanged { cursor.sourceStamp = stamp; return cursor }
        let sameContent = cursor.total == total && cursor.modified == modified && (cursor.sourceStamp.map { $0.sameContent(as: stamp) } ?? true)
        guard cursor.offset == 0, sameContent else { throw UploadSourceChanged(name: local.lastPathComponent) }
        return fresh
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
