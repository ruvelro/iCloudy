import Foundation
import CryptoKit

extension CloudAPI {
    /// The checkpoint is committed before sending bytes. Recovery asks the server for its authoritative offset.
    /// Returns whether the provider's checksum matched a hash computed from the very bytes that were sent.
    @discardableResult
    func resumableUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        if let demo {
            let id = try await demo.upload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: checkpoint, save: save, progress: progress)
            return UploadReceipt(remoteID: id, verification: .verified)
        }
        // Once Mega committed a new node, retry only its pending retirement step. The local source
        // (or a cross-cloud staging file) may no longer exist, and uploading again would duplicate it.
        if let receipt = try await provider.resumeCommittedUpload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: checkpoint, save: save, progress: progress) { return receipt }
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw CloudError.message(L("Solo se admiten archivos regulares, sin enlaces simbólicos.")) }
        let total = Int64(attributes.fileSize ?? 0)
        var cursor = try UploadCheckpoint.resuming(checkpoint, for: local, total: total, modified: attributes.contentModificationDate)
        let source = cursor.sourceStamp!
        if cursor.complete {
            guard cursor.integrity != .pending, cursor.integrity != .failed,
                  cursor.integrity != nil || !provider.requiresVerifiedLegacyCheckpoint else {
                throw CloudError.message(L("La integridad de esta subida falló o quedó sin confirmar. Revisa la copia remota y cancela esta operación antes de volver a subir el archivo."))
            }
            progress(total, total)
            return UploadReceipt(remoteID: cursor.remoteID, verification: cursor.integrity == .verified ? .verified : .unavailable)
        }
        try save(cursor)
        let persistCheckpoint: (UploadCheckpoint) throws -> Void = { checkpoint in
            var durable = checkpoint
            if durable.complete, durable.integrity == nil { durable.integrity = .pending }
            try save(durable)
        }
        let receipt = try await provider.uploadFile(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: persistCheckpoint, progress: progress)
        do { try source.validate(local) }
        catch { cursor.complete = true; cursor.integrity = .failed; try save(cursor); throw error }
        cursor.remoteID = receipt.remoteID
        cursor.integrity = receipt.verification == .verified ? .verified : .unavailable
        try save(cursor)
        return receipt
    }

}
