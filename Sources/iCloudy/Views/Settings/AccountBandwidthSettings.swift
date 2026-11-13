import SwiftUI

/// Each account's own speed limit, on top of the queue's. Handy for a server on a slow line that should not take
/// the whole connection while the other clouds keep their pace.
struct AccountBandwidthSettings: View {
    let model: AppModel
    @State private var limits: [String: AccountBandwidth] = AccountBandwidth.stored()

    var body: some View {
        Section("Velocidad por cuenta") {
            ForEach(model.accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.accountTitle(account) + " · " + account.email).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 14) {
                        field("Subida", value: binding(account.id, \.upload))
                        field("Descarga", value: binding(account.id, \.download))
                    }
                }
            }
            Text("Se suma al límite de toda la cola: una transferencia va a la velocidad del más estricto. Una copia entre nubes cuenta como descarga de una cuenta y subida a la otra. También frena las sincronizaciones en ambos sentidos.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: limits) {
            AccountBandwidth.store(limits)
            model.applyTransferPolicy()
        }
    }

    private func binding(_ account: String, _ path: WritableKeyPath<AccountBandwidth, Int64?>) -> Binding<Int64?> {
        Binding(get: { limits[account]?[keyPath: path] },
                set: { var limit = limits[account] ?? AccountBandwidth(); limit[keyPath: path] = $0; limits[account] = limit })
    }

    /// A limit in KB/s, off until ticked.
    private func field(_ title: LocalizedStringKey, value: Binding<Int64?>) -> some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? 1_000_000 : nil }))
            TextField("KB/s", value: Binding(get: { Int((value.wrappedValue ?? 0) / 1000) },
                                             set: { value.wrappedValue = Int64(min(max($0, 32), 10_000_000)) * 1000 }), format: .number)
                .frame(width: 70).multilineTextAlignment(.trailing).labelsHidden().disabled(value.wrappedValue == nil)
            Text(verbatim: "KB/s").foregroundStyle(.secondary)
        }
    }
}
