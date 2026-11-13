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
    @Bindable var model: AppModel
    /// The favourite being dragged to a new place, if any.
    @State private var dragging: Favorite.ID?

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
            ForEach(Array(model.favorites.enumerated()), id: \.element.id) { index, favorite in
                // A tap rather than a Button, for the same reason as the clouds: a button keeps the mouse from the
                // moment it is pressed, and the drag that reorders the list would never start.
                row(favorite)
                    .sidebarRow(selected: false)
                    .onTapGesture { model.openFavorite(favorite) }
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in model.openFavorite(favorite); return .handled }
                    .help(model.accounts.first { $0.id == favorite.accountID }?.email ?? L("Cuenta desconectada"))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(index < 9 ? L("Abre este favorito. Atajo: Control \(index + 1).") : L("Abre este favorito."))
                    .accessibilityAction { model.openFavorite(favorite) }
                    .onDrag {
                        dragging = favorite.id
                        return NSItemProvider(object: favorite.id as NSString)
                    }
                    .onDrop(of: [.text], delegate: FavoriteReorder(target: favorite.id, dragging: $dragging, store: model.favoriteStore))
                    .contextMenu {
                        Button("Abrir") { model.openFavorite(favorite) }
                        Divider()
                        Button("Mover arriba") { model.favoriteStore.move(favorite.id, by: -1) }
                            .disabled(!model.favoriteStore.canMove(favorite.id, by: -1))
                        Button("Mover abajo") { model.favoriteStore.move(favorite.id, by: 1) }
                            .disabled(!model.favoriteStore.canMove(favorite.id, by: 1))
                        Divider()
                        Button("Quitar de favoritos") {
                            model.favoriteStore.remove(accountID: favorite.accountID, fileID: favorite.file.id, inside: false)
                        }
                    }
            }
            RecentLocationsList(model: model, store: model.recents)
        }
    }
}

/// Moves the dragged favourite as it passes over the others, so the list shows where it will land.
struct FavoriteReorder: DropDelegate {
    let target: Favorite.ID
    @Binding var dragging: Favorite.ID?
    let store: FavoritesStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(Motion.quick) { store.move(dragging, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
