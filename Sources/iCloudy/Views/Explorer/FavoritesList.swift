import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// The favourites half of the sidebar.
///
/// The old list marked every row with the same star, which said "this is a favourite" — something the list already
/// said by existing. What it never said is which cloud the item lives in, and that is exactly what you need when six
/// of them are connected, so the star gives way to the account's own icon.
struct FavoritesList: View {
    @ObservedObject var model: AppModel

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "star").font(.title2).foregroundStyle(.tertiary)
            Text("Sin favoritos").font(.callout).foregroundStyle(.secondary)
            Text("Marca una carpeta o un archivo con la estrella y aparecerá aquí, sea de la nube que sea.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }.padding(.horizontal, 10).padding(.top, 28)
    }
    @ViewBuilder private func row(_ favorite: Favorite) -> some View {
        let account = model.accounts.first { $0.id == favorite.accountID }
        HStack(spacing: 9) {
            if let account {
                AccountIcon(account: account, appearance: model.appearance(for: account), size: 18)
            } else {
                Image(systemName: "questionmark.circle").frame(width: 18).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(favorite.file.name).lineLimit(1)
                Text(account.map { model.accountTitle($0) } ?? L("Cuenta desconectada"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !favorite.file.isFolder { FileIcon(file: favorite.file, size: 11) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    var body: some View {
        VStack(spacing: 3) {
            if model.favorites.isEmpty { empty }
            ForEach(model.favorites) { favorite in
                Button { model.openFavorite(favorite) } label: { row(favorite) }
                    .buttonStyle(.plain)
                    .sidebarRow(selected: false)
                    .help(model.accounts.first { $0.id == favorite.accountID }?.email ?? L("Cuenta desconectada"))
            }
        }
    }
}
