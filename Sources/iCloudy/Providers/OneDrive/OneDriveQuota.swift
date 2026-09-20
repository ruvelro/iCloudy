import Foundation

extension OneDriveProvider {
    nonisolated static func parseQuota(_ response: [String: Any]) throws -> StorageQuota {
        let quota = response["quota"] as? [String: Any] ?? [:]
        let total = ResponseBytes.value(quota["total"])
        var used = ResponseBytes.value(quota["used"])
        if used == nil, let total, let remaining = ResponseBytes.value(quota["remaining"]), remaining <= total { used = total - remaining }
        guard let used else { throw CloudError.message(L("El proveedor no ha informado del espacio utilizado.")) }
        return StorageQuota(used: used, total: total, trash: ResponseBytes.value(quota["deleted"]))
    }
}
