import SwiftUI

/// The last folders visited, under the favourites: the account's icon, the folder and where it is.
struct RecentLocationsList: View {
    let model: AppModel
    @Bindable var store: RecentLocationsStore

    var body: some View {
        if !store.items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Divider().padding(.vertical, 8)
                HStack {
                    Text("RECIENTES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { store.clear() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Borrar la lista de carpetas recientes").accessibilityLabel("Borrar la lista de carpetas recientes")
                }.padding(.horizontal, 8)
                ForEach(store.items) { recent in
                    Button { model.openRecent(recent) } label: { row(recent) }
                        .buttonStyle(.plain)
                        .focusable()
                        .sidebarRow(selected: false)
                        .help(model.addressText(accountID: recent.accountID, path: recent.path))
                        .contextMenu {
                            Button("Quitar de recientes") { store.remove(recent.id) }
                        }
                }
            }
        }
    }

    @ViewBuilder private func row(_ recent: RecentLocation) -> some View {
        let account = model.accounts.first { $0.id == recent.accountID }
        HStack(spacing: 9) {
            if let account {
                AccountIcon(account: account, appearance: model.appearance(for: account), size: 18)
            } else {
                Image(systemName: "questionmark.circle").frame(width: 18).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.recentTitle(recent)).lineLimit(1)
                Text(location(recent, account: account)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Abre esta carpeta")
    }

    /// Where the folder is: the account, and the folders above it.
    private func location(_ recent: RecentLocation, account: Account?) -> String {
        let accountName = account.map { model.accountTitle($0) } ?? L("Cuenta desconectada")
        return ([accountName] + recent.path.dropLast().map(\.name)).joined(separator: " › ")
    }
}
