import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

struct ExplorerView: View {
    @ObservedObject var model: AppModel
    @State var selected: Set<CloudFile.ID> = []
    @State var dropTarget = false
    /// The transfers drawer starts closed and opens itself when something is transferring.
    @State var showTransfers = false
    @State var confirmDisconnect = false
    @State var disconnectTarget: Account?
    @State var previewFollow: Task<Void, Never>?
    @State var sidebarVisible = true
    /// Which half of the sidebar is showing. Favourites used to live under every account, so reaching them on a Mac
    /// with six clouds connected meant scrolling past all of them.
    @State var sidebarTab = SidebarTab.clouds
    @FocusState var gridFocused: Bool
    /// Where a run of files starts when one is taken with Shift held down.
    @State var anchor: CloudFile.ID?

    var body: some View {
        navigation
        .sheet(isPresented: $model.showConnect) { ConnectView(model: model) }
        .sheet(item: $model.appearanceAccount) { account in AccountAppearanceEditor(model: model, account: account) }
        .sheet(isPresented: $model.showNameDialog) {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.editingFile == nil ? L("Nueva carpeta") : L("Renombrar")).font(.title2)
                TextField("Nombre", text: $model.editName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancelar") { model.showNameDialog = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Guardar") { Task { await model.commitName() } }.keyboardShortcut(.defaultAction).disabled(model.editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 390)
        }
        .sheet(item: $model.relocation) { request in FolderPickerView(model: model, request: request) }
        .sheet(item: $model.crossCloud) { request in CloudTargetPicker(model: model, request: request) }
        .sheet(item: $model.sharing) { request in SharingView(model: model, request: request) }
        .sheet(item: $model.publicLinkManager) { request in PublicLinksView(model: model, request: request) }
        .sheet(item: $model.linkInventory) { account in LinkInventoryView(model: model, account: account) }
        .sheet(item: $model.versionHistory) { request in VersionsView(model: model, request: request) }
        .sheet(item: Binding(get: { model.queue.conflict }, set: { _ in })) { request in
            ConflictView(queue: model.queue, request: request)
        }
        .onChange(of: model.folderID) { selected.removeAll() }
        .onChange(of: model.selectedAccountID) { selected.removeAll() }
        .onChange(of: selected) {
            guard model.preview.isVisible, Prefs.bool(Prefs.previewFollowsSelection, default: true) else { return }
            // Follow the selection like Quick Look, but wait for the arrow keys to settle: each preview is a download.
            previewFollow?.cancel()
            if selected.count == 1 {
                previewFollow = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    previewSelection()
                }
            } else { model.preview.close() }
        }
        .onDisappear { model.preview.close() }
        .alert(model.alertTitle, isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.dismissAlert() } })) {
            Button("Aceptar") { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .confirmationDialog("¿Crear un enlace público?", isPresented: Binding(get: { model.pendingShare != nil }, set: { if !$0 { model.pendingShare = nil } }), titleVisibility: .visible) {
            Button("Crear y copiar enlace") {
                if let pending = model.pendingShare { Task { await model.createPublicLink(pending.file, account: pending.account) } }
                model.pendingShare = nil
            }
            Button("Cancelar", role: .cancel) { model.pendingShare = nil }
        } message: {
            Text("Cualquier persona con el enlace podrá ver «\(model.pendingShare?.file.name ?? "")» sin iniciar sesión. El permiso queda en \(model.pendingShare?.account.cloud.title ?? L("la nube")) hasta que lo revoques desde su web.")
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }), titleVisibility: .visible) {
            Button(model.account?.capabilities.reversibleTrash == false ? "Eliminar definitivamente" : "Enviar a la papelera", role: .destructive) {
                if let files = model.pendingTrash { Task { await model.trash(files) } }
                model.pendingTrash = nil
            }
            Button("Cancelar", role: .cancel) { model.pendingTrash = nil }
        } message: {
            Text(model.account?.capabilities.reversibleTrash == false
                 ? L("Este servidor no tiene papelera: lo que elimines se borra de forma definitiva, con todo el contenido de las carpetas. iCloudy no puede deshacerlo.")
                 : model.account?.cloud == .volume ? L("Los elementos van a la papelera del Mac y se pueden restaurar desde el Finder.")
                 : model.account?.capabilities.trashListing == true ? L("Los elementos van a la papelera de \(model.account?.cloud.title ?? L("la nube")), con todo el contenido de las carpetas. Desde la pestaña Papelera se pueden restaurar o eliminar definitivamente.")
                 : L("Los elementos van a la papelera de \(model.account?.cloud.title ?? L("la nube")) y se pueden restaurar desde su web. Las carpetas se envían con todo su contenido."))
        }
        .confirmationDialog(purgeTitle, isPresented: Binding(get: { model.pendingPurge != nil }, set: { if !$0 { model.pendingPurge = nil } }), titleVisibility: .visible) {
            Button("Eliminar definitivamente", role: .destructive) {
                if let files = model.pendingPurge { Task { await model.deletePermanently(files) } }
                model.pendingPurge = nil
            }
            Button("Cancelar", role: .cancel) { model.pendingPurge = nil }
        } message: {
            Text("Se borra de \(model.account?.cloud.title ?? L("la nube")) sin pasar por la papelera, con todo el contenido de las carpetas. Ni iCloudy ni el proveedor pueden deshacerlo.")
        }
        .confirmationDialog("¿Vaciar la papelera?", isPresented: $model.pendingEmptyTrash, titleVisibility: .visible) {
            Button("Vaciar papelera", role: .destructive) {
                model.pendingEmptyTrash = false
                Task { await model.emptyTrash() }
            }
            Button("Cancelar", role: .cancel) { model.pendingEmptyTrash = false }
        } message: {
            Text("Todo lo que hay en la papelera de \(model.account?.cloud.title ?? L("la nube")) se elimina de forma definitiva, también lo que otras aplicaciones hayan enviado ahí. No se puede deshacer.")
        }
        .confirmationDialog("¿Desconectar esta cuenta?", isPresented: $confirmDisconnect, titleVisibility: .visible, presenting: disconnectTarget) { account in
            Button("Desconectar", role: .destructive) { model.disconnect(account) }
            Button("Cancelar", role: .cancel) {}
        } message: { account in
            Text("\(account.cloud.title) · \(account.email)\nSe eliminará la sesión local, sin borrar archivos de la nube ni descargas. Los favoritos y las transferencias pausadas se conservan para cuando vuelvas a conectar esta cuenta. No se revoca el permiso en el proveedor.")
                + Text(model.offlineDisconnectNote(account))
        }
    }

    /// The files between two of them, in the order the list shows. Shift picking a run had no equivalent in the
    /// grid at all, so taking twenty files meant twenty Command-clicks.
    static func range(from: CloudFile.ID, to: CloudFile.ID, in files: [CloudFile]) -> Set<CloudFile.ID> {
        guard let first = files.firstIndex(where: { $0.id == from }), let last = files.firstIndex(where: { $0.id == to }) else { return [to] }
        return Set(files[min(first, last)...max(first, last)].map(\.id))
    }

}
