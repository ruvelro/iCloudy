import SwiftUI

/// «Ir a la carpeta…» (⇧⌘G): a path typed by hand, in the focused account or in the one named in front of it.
struct GoToFolderView: View {
    @Bindable var model: AppModel
    @State private var accountID: String = ""
    @State private var text = ""
    @State private var problem: String?
    @State private var working = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ir a la carpeta").font(.title2)
            Picker("Cuenta", selection: $accountID) {
                ForEach(model.accounts) { account in
                    Text(model.accountTitle(account) + " · " + account.email).tag(account.id)
                }
            }
            TextField("Carpeta/Subcarpeta", text: $text)
                .textFieldStyle(.roundedBorder).focused($fieldFocused)
                .onSubmit(go)
                .accessibilityHint("Escribe la ruta desde el principio de la cuenta. Para otra cuenta, pon su nombre delante, como «Dropbox:/Fotos».")
            Text("Escribe la ruta desde el principio de la cuenta. Para otra cuenta, pon su nombre delante, como «Dropbox:/Fotos». Si la ruta acaba en un archivo, se abre su carpeta con el archivo seleccionado.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancelar") { model.ui.showGoToFolder = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Ir", action: go).keyboardShortcut(.defaultAction)
                    .disabled(working || model.accounts.isEmpty)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear {
            accountID = model.account.map(\.id) ?? model.accounts.first?.id ?? ""
            text = model.pathText(for: model.workspace.current)
            fieldFocused = true
        }
    }

    private func go() {
        let account = model.accounts.first { $0.id == accountID }
        working = true; problem = nil
        Task {
            do {
                try await model.goToFolder(text, defaultAccount: account)
                model.ui.showGoToFolder = false
            } catch { problem = error.localizedDescription }
            working = false
        }
    }
}

/// The breadcrumbs' other face: the same path as text, to be typed over. Return goes there, Escape gives the crumbs
/// back. Reached from the pencil at the end of the crumbs or with ⌘L.
struct EditablePathBar: View {
    let model: AppModel
    let pane: Int
    let done: () -> Void
    @State private var text = ""
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            TextField("Ruta", text: $text)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit(go)
                .onExitCommand(perform: done)
                .accessibilityLabel("Ruta de la carpeta")
                .accessibilityHint("Escribe una ruta y pulsa Intro para ir. Escape vuelve a las migas.")
            if working { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 8).frame(height: Layout.controlHeight)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2))
        .onAppear {
            text = model.pathText(for: model.tab(inPane: pane))
            focused = true
        }
        .onChange(of: focused) { _, now in if !now, !working { done() } }
    }

    private func go() {
        let account = model.account(of: model.tab(inPane: pane))
        working = true
        Task {
            model.focusPane(pane)
            do { try await model.goToFolder(text, defaultAccount: account); done() }
            catch { model.error = error.localizedDescription }
            working = false
        }
    }
}
