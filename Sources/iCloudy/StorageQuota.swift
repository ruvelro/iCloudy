import Foundation
import CoreFoundation
import SwiftUI

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
        if let files { lines.append(L("Archivos: ") + ByteCountFormatter.string(fromByteCount: max(0, files - (trash ?? 0)), countStyle: .decimal)) }
        if let trash { lines.append(L("Papelera: ") + ByteCountFormatter.string(fromByteCount: trash, countStyle: .decimal)) }
        if let files, used > files { lines.append(L("Otros servicios: ") + ByteCountFormatter.string(fromByteCount: used - files, countStyle: .decimal)) }
        return lines.joined(separator: " · ")
    }
    static func parse(_ response: [String: Any], cloud: Cloud) throws -> StorageQuota {
        let quota = response[cloud == .google ? "storageQuota" : "quota"] as? [String: Any] ?? [:]
        func bytes(_ key: String) -> Int64? {
            let value: Int64?
            if let string = quota[key] as? String { value = Int64(string) }
            else if let number = quota[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                value = Int64(number.stringValue)
            } else { value = nil }
            return value.flatMap { $0 >= 0 ? $0 : nil }
        }
        let total = bytes(cloud == .google ? "limit" : "total")
        var used = bytes(cloud == .google ? "usage" : "used")
        // Some Graph responses provide only remaining and total.
        if used == nil, cloud == .microsoft, let total, let remaining = bytes("remaining"), remaining <= total {
            used = total - remaining
        }
        guard let used else { throw CloudError.message(L("El proveedor no ha informado del espacio utilizado.")) }
        return StorageQuota(used: used, total: total, trash: bytes(cloud == .google ? "usageInDriveTrash" : "deleted"), files: cloud == .google ? bytes("usageInDrive") : nil)
    }
}

enum StorageQuotaState {
    case loading
    case available(StorageQuota)
    case unavailable(String)
}

extension CloudAPI {
    func storageQuota() async throws -> StorageQuota {
        if let demo { return try demo.storageQuota() }
        let endpoint: String
        switch account.cloud {
        case .google: endpoint = "https://www.googleapis.com/drive/v3/about?fields=storageQuota"
        case .microsoft: endpoint = "\(graphDrive)?$select=quota"
        case .dropbox: return try await dropboxQuota()
        case .box: return try await boxQuota()
        case .webdav: return try await webdavQuota()
        case .ftp: throw CloudError.message(L("FTP no informa del espacio disponible."))
        case .volume: return try await volumeQuota()
        case .mega: return try await megaQuota()
        }
        return try StorageQuota.parse(await json(URL(string: endpoint)!), cloud: account.cloud)
    }
}

private struct UsageSlice: Shape {
    let start: Double
    let end: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90 + start * 360), endAngle: .degrees(-90 + end * 360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct StorageUsageView: View {
    let account: Account
    let state: StorageQuotaState?

    private var explanation: String {
        if account.isDemo { return L("Demo local: capacidad simulada de 5 GB; no es el espacio del Mac.") }
        if account.cloud == .google {
            return L("Almacenamiento de Google en todos sus servicios (Drive, Gmail, Fotos…). En organizaciones con almacenamiento compartido, puede corresponder a toda la organización.")
        }
        return L("Cuota comunicada por Microsoft. En OneDrive personal puede incluir almacenamiento compartido entre varios servicios.")
    }
    private func cumulative(_ segments: [(kind: StorageQuota.Segment, fraction: Double)]) -> [(kind: StorageQuota.Segment, start: Double, end: Double)] {
        var position = 0.0
        return segments.map { segment in
            let start = position; position = min(1, position + segment.fraction)
            return (segment.kind, start, position)
        }
    }
    private func color(for kind: StorageQuota.Segment, full: Bool) -> Color {
        switch kind {
        case .files: return full ? .orange : .accentColor
        case .trash: return .red.opacity(0.75)
        case .other: return (full ? Color.orange : Color.accentColor).opacity(0.45)
        }
    }
    var body: some View {
        Group {
            switch state {
            case .available(let quota):
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.18))
                        if let fraction = quota.fraction {
                            // Files, then trash, then other services, drawn clockwise from the top.
                            ForEach(Array(cumulative(quota.segments).enumerated()), id: \.offset) { _, slice in
                                UsageSlice(start: slice.start, end: slice.end).fill(color(for: slice.kind, full: fraction >= 0.9))
                            }
                        } else {
                            Text("?").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 19, height: 19).accessibilityHidden(true)
                    Text(quota.summary).fixedSize(horizontal: false, vertical: true)
                }
                .help(explanation + "\n" + quota.summary + (quota.breakdown.isEmpty ? "" : "\n" + quota.breakdown))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Almacenamiento: " + quota.summary)
            case .unavailable(let message):
                Label("Espacio no disponible", systemImage: "questionmark.circle")
                    .help(message + "\nUsa «Actualizar espacio» en el menú de la cuenta para reintentar.")
            case .loading, nil:
                Label("Consultando espacio…", systemImage: "chart.pie")
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}
