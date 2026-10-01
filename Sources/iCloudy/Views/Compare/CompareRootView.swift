import SwiftUI
import AppKit

/// The window behind «Comparar…» and «Buscar duplicados…»: two tools over the same kind of input, folders of any
/// account or of this Mac, so they share one window and switch with a control at the top.
struct CompareRootView: View {
    @ObservedObject var center: CompareCenter
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("Herramienta", selection: $center.mode) {
                Text("Comparar carpetas").tag(CompareCenter.Mode.compare)
                Text("Buscar duplicados").tag(CompareCenter.Mode.duplicates)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 380)
            .padding(.top, 14).padding(.bottom, 4)
            switch center.mode {
            case .compare: CompareView(center: center, model: model)
            case .duplicates: DuplicatesView(center: center, model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

/// Chooses a folder: one of a connected account, browsed in a sheet, or one of this Mac, in an open panel.
struct FolderLocationMenu: View {
    @ObservedObject var model: AppModel
    let title: LocalizedStringKey
    let onPick: (FolderLocation) -> Void
    @State private var browsing: Account?
    var body: some View {
        Menu(title) {
            Section("Cuentas") {
                ForEach(model.accounts) { account in
                    Button(model.accountTitle(account) + " · " + account.email) { browsing = account }
                }
            }
            Divider()
            Button("Carpeta del Mac…") {
                Task { if let location = await CompareCenter.shared.pickLocalFolder() { onPick(location) } }
            }
        }
        .fixedSize()
        .sheet(item: $browsing) { account in CompareFolderBrowser(model: model, account: account, onPick: onPick) }
    }
}

/// The icon of where a folder lives: the account's own, or a Mac.
struct FolderLocationIcon: View {
    @ObservedObject var model: AppModel
    let location: FolderLocation
    var size: CGFloat = 20
    var body: some View {
        if let account = model.accounts.first(where: { $0.id == location.accountID }) {
            AccountIcon(account: account, appearance: model.appearance(for: account), size: size)
        } else {
            Image(systemName: location.localURL != nil ? "laptopcomputer" : "exclamationmark.icloud")
                .font(.system(size: size * 0.6)).frame(width: size, height: size).foregroundStyle(.secondary)
        }
    }
}

/// Browses the folders of one account to pick one to compare or search. Unlike the move and copy picker it has no
/// selection to protect: any folder, the top of the account included, is a valid answer.
struct CompareFolderBrowser: View {
    @ObservedObject var model: AppModel
    let account: Account
    let onPick: (FolderLocation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CloudFile] = []
    @State private var folders: [CloudFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Elegir carpeta").font(.title2)
            Text(model.accountTitle(account) + " · " + account.email).foregroundStyle(.secondary).lineLimit(1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("Mis archivos") { go(to: 0) }.buttonStyle(.link)
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, folder in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(folder.name) { go(to: index + 1) }.buttonStyle(.link)
                    }
                }
            }
            List(folders) { folder in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(folder.name).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.contentShape(Rectangle()).onTapGesture { path.append(folder); load() }
            }
            .frame(minHeight: 260)
            .overlay {
                if loading { ProgressView() }
                else if folders.isEmpty { Text("Sin subcarpetas.").foregroundStyle(.secondary).font(.callout) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Usar esta carpeta") {
                    onPick(FolderLocation(place: .cloud(accountID: account.id, folder: path.last), trail: path.map(\.name)))
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
    }

    private func go(to count: Int) { path = Array(path.prefix(count)); load() }
    private func load() {
        loadTask?.cancel()
        loading = true; error = nil; folders = []
        let parent = path.last?.id ?? Collection.files.rootID
        loadTask = Task {
            do {
                let items = try await model.client(account).list(parent: parent)
                guard !Task.isCancelled, parent == (path.last?.id ?? Collection.files.rootID) else { return }
                folders = items.filter(\.isFolder)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// Bytes the way the Finder writes them.
func byteText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
