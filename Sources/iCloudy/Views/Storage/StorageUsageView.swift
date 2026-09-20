import SwiftUI

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

/// How the space of an account is drawn in the sidebar. Both say the same thing; which one reads better is a matter
/// of taste, so it is a preference rather than a decision taken for everyone.
enum StorageStyle: String, CaseIterable, Identifiable {
    case pie, bar
    var id: String { rawValue }
    var title: String { self == .pie ? L("Gráfico circular") : L("Barra") }
    static func current(_ raw: String) -> StorageStyle { StorageStyle(rawValue: raw) ?? .pie }
}

struct StorageUsageView: View {
    let account: Account
    let state: StorageQuotaState?
    @AppStorage(Prefs.storageStyle) private var style = StorageStyle.pie.rawValue

    /// Every bar is exactly this wide. Letting it flex made each account's bar a different length depending on how
    /// long its figures happened to be, and a column of bars that do not line up is worse than no bars at all.
    private static let barWidth: CGFloat = 78

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
    private func pie(_ quota: StorageQuota) -> some View {
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
    }
    /// The same segments laid end to end. A quota the provider did not report leaves the rail empty rather than
    /// guessing at a length, which is the same promise the pie makes with its question mark.
    private func bar(_ quota: StorageQuota) -> some View {
        let full = (quota.fraction ?? 0) >= 0.9
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.22))
            if quota.fraction != nil {
                HStack(spacing: 0) {
                    ForEach(Array(quota.segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(color(for: segment.kind, full: full))
                            .frame(width: Self.barWidth * segment.fraction)
                    }
                }.clipShape(Capsule())
            }
        }
        .frame(width: Self.barWidth, height: 4)
        .accessibilityHidden(true)
    }
    var body: some View {
        Group {
            switch state {
            case .available(let quota):
                HStack(spacing: 6) {
                    if StorageStyle.current(style) == .bar { bar(quota) } else { pie(quota) }
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
