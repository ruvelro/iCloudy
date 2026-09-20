import Foundation

enum DownloadBudget {
    static func check(_ bytes: Int64, maximum: Int64?) throws {
        guard bytes >= 0, maximum.map({ $0 >= 0 && bytes <= $0 }) ?? true else {
            throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
        }
    }
}
