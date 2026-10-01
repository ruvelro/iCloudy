import Foundation

struct StorageQuota: Equatable {
    let used: Int64
    let total: Int64?
    /// Bytes sitting in the provider's trash (Drive `usageInDriveTrash`, Graph `deleted`), when reported.
    let trash: Int64?
    /// Bytes used by the files themselves (Drive `usageInDrive`); the remainder of `used` belongs to other services.
    let files: Int64?
    init(used: Int64, total: Int64?, trash: Int64? = nil, files: Int64? = nil) {
        self.used = used; self.total = total; self.trash = trash; self.files = files
    }

    enum Segment { case files, trash, other }
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
    /// Pie segments in drawing order. Missing breakdown data collapses into a single `files` segment.
    var segments: [(kind: Segment, fraction: Double)] {
        guard let total, total > 0 else { return [] }
        let trashBytes = min(trash ?? 0, used)
        let fileBytes = max(0, (files ?? used) - trashBytes)
        let otherBytes = max(0, used - (files ?? used))
        let scale = { (bytes: Int64) in min(1, Double(bytes) / Double(total)) }
        return [(Segment.files, scale(fileBytes)), (.trash, scale(trashBytes)), (.other, scale(otherBytes))].filter { $0.1 > 0 }.map { (kind: $0.0, fraction: $0.1) }
    }
    var summary: String {
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .decimal)
        guard let total else { return L("\(usedText) usados · total no disponible") }
        return L("\(usedText) de \(ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal))")
    }
    /// One line per known component, for the tooltip.
    var breakdown: String {
        var lines: [String] = []
        if let files { lines.append(L("Archivos: \(ByteCountFormatter.string(fromByteCount: max(0, files - (trash ?? 0)), countStyle: .decimal))")) }
        if let trash { lines.append(L("Papelera: \(ByteCountFormatter.string(fromByteCount: trash, countStyle: .decimal))")) }
        if let files, used > files { lines.append(L("Otros servicios: \(ByteCountFormatter.string(fromByteCount: used - files, countStyle: .decimal))")) }
        return lines.joined(separator: " · ")
    }

}

enum StorageQuotaState {
    case loading
    case available(StorageQuota)
    case unavailable(String)
}

