import SwiftUI

struct Relocation: Identifiable {
    let id = UUID()
    let files: [CloudFile]
    let copy: Bool
    let account: Account
    /// Folder the items are listed in when the request starts; nil for provider lists such as recents.
    let origin: String?
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
        if !request.copy, request.origin == destination { return false }
        return !path.contains { movedIDs.contains($0.id) }
    }
    private var summary: String {
        let what = request.files.count == 1 ? "«\(request.files[0].name)»" : "\(request.files.count) elementos"
        return "\(request.copy ? "Copiar" : "Mover") \(what) en \(model.accountTitle(request.account)) · \(request.account.email)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.copy ? "Copiar a…" : "Mover a…").font(.title2)
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
                Text(request.copy ? "Una carpeta no puede copiarse dentro de sí misma." : "Elige una carpeta distinta de la actual y que no esté dentro de lo que mueves.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.copy ? "Copiar aquí" : "Mover aquí") {
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
