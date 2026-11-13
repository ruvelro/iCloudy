import SwiftUI

/// Browses one connected account to pick a folder, or a file when `allowsFiles`, as the end of a saved job or of a
/// pair of clouds.
struct RemoteItemChooser: View {
    let model: AppModel
    let title: LocalizedStringKey
    var allowsFiles = false
    var excluding: String?
    let onChoose: (JobEndpoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: String?
    @State private var path: [CloudFile] = []
    @State private var items: [CloudFile] = []
    @State private var selected: CloudFile?
    @State private var loading = false
    @State private var error: String?

    private var account: Account? { model.accounts.first { $0.id == accountID } }
    private var candidates: [Account] { model.accounts.filter { $0.id != excluding } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3)
            Picker("Cuenta", selection: $accountID) {
                ForEach(candidates) { Text(verbatim: model.accountTitle($0) + " · " + $0.email).tag(Optional($0.id)) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("Mis archivos") { go(to: 0) }.buttonStyle(.link)
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, folder in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(folder.name) { go(to: index + 1) }.buttonStyle(.link)
                    }
                }
            }
            List(items, selection: Binding(get: { selected?.id }, set: { id in selected = items.first { $0.id == id } })) { item in
                HStack {
                    Image(systemName: item.isFolder ? "folder.fill" : "doc").foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    if item.isFolder { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if item.isFolder { path.append(item); load() } }
                .tag(item.id)
            }
            .frame(minHeight: 240)
            .overlay { if loading { ProgressView() } }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if allowsFiles, let selected {
                    Button("Elegir «\(selected.name)»") { choose(selected) }
                }
                Button("Elegir esta carpeta") { choose(nil) }.keyboardShortcut(.defaultAction).disabled(account == nil)
            }
        }
        .padding(20).frame(width: 540)
        .onAppear { accountID = accountID ?? candidates.first?.id; load() }
        .onChange(of: accountID) { path = []; load() }
    }

    private func choose(_ item: CloudFile?) {
        guard let account else { return }
        let trail = [account.email] + path.map(\.name) + (item.map { [$0.name] } ?? [])
        let folder = path.last
        let id = item?.id ?? folder?.id ?? "root"
        let name = item?.name ?? folder?.name ?? model.accountTitle(account)
        onChoose(.remote(accountID: account.id, itemID: id, name: name, isFolder: item?.isFolder ?? true, location: trail.joined(separator: " / ")))
        dismiss()
    }
    private func go(to count: Int) { path = Array(path.prefix(count)); load() }
    private func load() {
        guard let account else { items = []; return }
        let parent = path.last?.id ?? "root"
        loading = true; error = nil; selected = nil
        Task {
            do {
                let listed = try await model.client(account).list(parent: parent)
                items = listed.filter { allowsFiles || $0.isFolder }
            } catch { self.error = error.localizedDescription; items = [] }
            loading = false
        }
    }
}
