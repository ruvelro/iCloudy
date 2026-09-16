import SwiftUI

struct Relocation: Identifiable {
    enum Kind { case move, copy, transfer(from: Account) }
    let id = UUID()
    let files: [CloudFile]
    let kind: Kind
    /// Destination account: the same one for move and copy, another connected one for a transfer.
    let account: Account
    /// Folder the items are listed in when the request starts; nil for provider lists such as recents.
    let origin: String?
    var isMove: Bool { if case .move = kind { return true } else { return false } }
    var title: String {
        switch kind { case .move: return L("Mover a…"); case .copy: return L("Copiar a…"); case .transfer: return L("Enviar a otra nube…") }
    }
    var verb: String { switch kind { case .move: return "Mover"; case .copy: return "Copiar"; case .transfer: return "Enviar" } }
    var confirm: String { switch kind { case .move: return L("Mover aquí"); case .copy: return L("Copiar aquí"); case .transfer: return L("Enviar aquí") } }
}

/// Items chosen for a cross-cloud transfer, waiting for the user to pick the destination account.
struct CrossCloudRequest: Identifiable {
    let id = UUID()
    let files: [CloudFile]
    let source: Account
}

/// First step of a cross-cloud transfer: which connected account receives the copies.
struct CloudTargetPicker: View {
    @ObservedObject var model: AppModel
    let request: CrossCloudRequest
    @Environment(\.dismiss) private var dismiss
    private var candidates: [Account] { model.accounts.filter { $0.id != request.source.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enviar a otra nube").font(.title2)
            Text("\(request.files.count == 1 ? L("«\(request.files[0].name)»") : L("\(request.files.count) elementos")) se descargan por bloques y se suben a la cuenta elegida; no queda copia en el Mac. Los documentos de Google salen como Word, Excel o PowerPoint.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(candidates) { account in
                HStack(spacing: 10) {
                    AccountIcon(account: account, appearance: model.appearance(for: account))
                    VStack(alignment: .leading) {
                        Text(model.accountTitle(account)).fontWeight(.medium)
                        Text(account.email).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.contentShape(Rectangle()).onTapGesture {
                    dismiss()
                    // Let the first sheet close before presenting the folder picker.
                    Task { try? await Task.sleep(for: .milliseconds(350)); model.relocation = Relocation(files: request.files, kind: .transfer(from: request.source), account: account, origin: nil) }
                }
            }.frame(minHeight: 160)
            HStack { Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction); Spacer() }
        }.padding(24).frame(width: 480)
    }
}

/// Browses the folders of one account so the user can pick a destination for a move or a copy.
struct FolderPickerView: View {
    @ObservedObject var model: AppModel
    let request: Relocation
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CloudFile] = []
    @State private var folders: [CloudFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?

    private var destination: String { path.last?.id ?? "root" }
    private var movedIDs: Set<String> { Set(request.files.map(\.id)) }
    private var destinationIsValid: Bool {
        if request.isMove, request.origin == destination { return false }
        return !path.contains { movedIDs.contains($0.id) }
    }
    private var summary: String {
        let what = request.files.count == 1 ? L("«\(request.files[0].name)»") : L("\(request.files.count) elementos")
        return L("\(request.verb) \(what) a \(model.accountTitle(request.account)) · \(request.account.email)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.title2)
            Text(summary).foregroundStyle(.secondary).lineLimit(2)
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
                }.contentShape(Rectangle()).onTapGesture { open(folder) }
            }
            .frame(minHeight: 260)
            .overlay {
                if loading { ProgressView() }
                else if folders.isEmpty { Text("Sin subcarpetas. Puedes usar esta carpeta como destino.").foregroundStyle(.secondary).font(.callout) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            if !destinationIsValid {
                Text(request.isMove ? L("Elige una carpeta distinta de la actual y que no esté dentro de lo que mueves.") : L("Una carpeta no puede copiarse dentro de sí misma."))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.confirm) {
                    let target = destination, trail = path
                    dismiss()
                    Task { await model.relocate(request, to: target, destinationPath: trail) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!destinationIsValid || loading)
            }
        }
        .padding(24).frame(width: 560)
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
    }

    private func open(_ folder: CloudFile) { path.append(folder); load() }
    private func go(to count: Int) { path = Array(path.prefix(count)); load() }
    private func load() {
        loadTask?.cancel()
        loading = true; error = nil; folders = []
        let parent = destination
        loadTask = Task {
            do {
                let items = try await model.client(request.account).list(parent: parent)
                guard !Task.isCancelled, parent == destination else { return }
                // Items being moved cannot be their own destination; shortcuts to folders are not folders here.
                folders = items.filter { $0.isFolder && !movedIDs.contains($0.id) }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
