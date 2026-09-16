import Foundation
import CoreFoundation
import SwiftUI

struct StorageQuota: Equatable {
    let used: Int64
    let total: Int64?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
    var summary: String {
        let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .decimal)
        guard let total else { return "\(usedText) usados · total no disponible" }
        return "\(usedText) de \(ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal))"
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
        guard let used else { throw CloudError.message("El proveedor no ha informado del espacio utilizado.") }
        return StorageQuota(used: used, total: total)
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
        let endpoint = account.cloud == .google
            ? "https://www.googleapis.com/drive/v3/about?fields=storageQuota"
            : "https://graph.microsoft.com/v1.0/me/drive?$select=quota"
        return try StorageQuota.parse(await json(URL(string: endpoint)!), cloud: account.cloud)
    }
}

private struct UsageSlice: Shape {
    let fraction: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + fraction * 360), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct StorageUsageView: View {
    let account: Account
    let state: StorageQuotaState?

    private var explanation: String {
        if account.isDemo { return "Demo local: capacidad simulada de 5 GB; no es el espacio del Mac." }
        if account.cloud == .google {
            return "Almacenamiento de Google en todos sus servicios (Drive, Gmail, Fotos…). En organizaciones con almacenamiento compartido, puede corresponder a toda la organización."
        }
        return "Cuota comunicada por Microsoft. En OneDrive personal puede incluir almacenamiento compartido entre varios servicios."
    }
    var body: some View {
        Group {
            switch state {
            case .available(let quota):
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.18))
                        if let fraction = quota.fraction {
                            UsageSlice(fraction: fraction).fill(fraction >= 0.9 ? Color.orange : Color.accentColor)
                        } else {
                            Text("?").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 19, height: 19).accessibilityHidden(true)
                    Text(quota.summary).fixedSize(horizontal: false, vertical: true)
                }
                .help(explanation + "\n" + quota.summary)
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
