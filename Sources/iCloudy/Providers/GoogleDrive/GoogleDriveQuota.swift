import Foundation

extension GoogleDriveProvider {
    nonisolated static func parseQuota(_ response: [String: Any]) throws -> StorageQuota {
        let quota = response["storageQuota"] as? [String: Any] ?? [:]
        let total = ResponseBytes.value(quota["limit"])
        let used = ResponseBytes.value(quota["usage"])
        guard let used else { throw CloudError.message(L("El proveedor no ha informado del espacio utilizado.")) }
        return StorageQuota(used: used, total: total, trash: ResponseBytes.value(quota["usageInDriveTrash"]), files: ResponseBytes.value(quota["usageInDrive"]))
    }
}
