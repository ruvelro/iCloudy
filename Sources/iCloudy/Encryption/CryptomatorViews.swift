import SwiftUI
import AppKit

/// The two actions a folder offers for vaults: open the one it is, or make a new one inside it.
struct CryptomatorFolderActions: View {
    @ObservedObject var model: AppModel
    let folder: CloudFile
    var body: some View {
        if model.canHostVault {
            Divider()
            Button("Abrir bóveda…") { model.requestVaultUnlock(folder) }
            Button("Crear bóveda cifrada…") { model.requestVaultCreation(in: folder) }
        }
    }
}

/// The unlocked vaults, under the accounts in the sidebar.
struct CryptomatorSidebarSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vaults: CryptomatorVaults
    var body: some View {
        if !vaults.unlocked.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("BÓVEDAS ABIERTAS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, Layout.sidebarInner).padding(.top, 8)
                ForEach(vaults.unlocked) { vault in
                    Button { model.select(vault.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.open.fill").font(.system(size: 16)).foregroundStyle(.green).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(vault.folder.name).fontWeight(.medium).lineLimit(1)
                                Text("\(model.accountTitle(vault.base)) · cifrada").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.padding(Layout.sidebarInner).contentShape(Rectangle())
                            .sidebarRow(selected: model.selectedAccountID == vault.id && !model.showGlobalSearch, tint: .green)
                    }.buttonStyle(.plain)
                        .help("Bóveda de Cryptomator en \(model.accountTitle(vault.base))")
                        .contextMenu {
                            Button("Bloquear") { model.lockVault(vault.id) }
                            if vaults.hasRememberedPassphrase(vault.id) {
                                Button("Olvidar la contraseña guardada") { vaults.forgetPassphrase(vault.id) }
                            }
                        }
                }
            }
        }
    }
}

/// A strip above the files: inside a vault it says so and offers to lock it; on a folder that is a locked vault it
/// offers to open it. Each pane shows its own: the strip used to follow the focus, so a vault open in the other pane
/// had no "Bloquear" until it was clicked.
struct CryptomatorBanner: View {
    @ObservedObject var model: AppModel
    let pane: Int
    var body: some View {
        let tab = model.tab(inPane: pane)
        if let account = model.account(of: tab), account.isCryptomatorVault {
            HStack {
                Label("Bóveda cifrada. Los nombres y el contenido se cifran en este Mac antes de llegar a la nube.", systemImage: "lock.shield")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Bloquear") { model.lockVault(account.id) }
            }.padding(.horizontal, Layout.margin).padding(.vertical, 10).background(Color.green.opacity(0.12))
        } else if model.folderIsLockedVault(in: tab) {
            HStack {
                Label("Esta carpeta es una bóveda de Cryptomator.", systemImage: "lock.fill").font(.caption)
                Spacer()
                // The unlock works on the focused pane's folder, so this pane takes the focus first.
                Button("Desbloquear…") { model.focusPane(pane); model.unlockCurrentFolder() }
            }.padding(.horizontal, Layout.margin).padding(.vertical, 10).background(Color.accentColor.opacity(0.1))
        }
    }
}

extension View {
    /// The passphrase sheets for unlocking and creating vaults.
    func cryptomatorSheets(model: AppModel) -> some View { modifier(CryptomatorSheets(model: model, vaults: model.cryptomator)) }
}

private struct CryptomatorSheets: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var vaults: CryptomatorVaults
    func body(content: Content) -> some View {
        content
            .sheet(item: $vaults.unlocking) { request in CryptomatorUnlockSheet(model: model, request: request) }
            .sheet(item: $vaults.creating) { request in CryptomatorCreateSheet(model: model, request: request) }
    }
}

private struct CryptomatorUnlockSheet: View {
    @ObservedObject var model: AppModel
    let request: CryptomatorVaults.Request
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var remember = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Desbloquear «\(request.folder.name)»", systemImage: "lock.fill").font(.title2)
            Text("Escribe la contraseña de la bóveda. Se descifra en este Mac: ni la contraseña ni las claves salen de él.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Contraseña", text: $passphrase).textFieldStyle(.roundedBorder).onSubmit(unlock)
            Toggle("Recordar la contraseña en el Llavero de este Mac", isOn: $remember)
            if remember {
                Text("Cualquiera que use esta sesión del Mac podrá abrir la bóveda sin escribirla. Solo se guarda en este Mac y solo se puede leer con el Mac desbloqueado.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Desbloquear", action: unlock).keyboardShortcut(.defaultAction).disabled(passphrase.isEmpty || working)
            }
        }.padding(24).frame(width: 440)
    }

    private func unlock() {
        guard !passphrase.isEmpty, !working else { return }
        working = true; problem = nil
        Task {
            problem = await model.unlockVault(request, passphrase: passphrase, remember: remember)
            working = false
            if problem == nil { dismiss() }
        }
    }
}

private struct CryptomatorCreateSheet: View {
    @ObservedObject var model: AppModel
    let request: CryptomatorVaults.Request
    @Environment(\.dismiss) private var dismiss
    @State private var name = L("Bóveda")
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var understood = false
    @State private var remember = false
    @State private var working = false
    @State private var problem: String?

    private var ready: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && passphrase.count >= CryptomatorVaults.minimumPassphraseLength
            && passphrase == confirmation && understood && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nueva bóveda cifrada", systemImage: "lock.shield").font(.title2)
            Text("Se crea una carpeta en «\(request.folder.name)» que guarda los archivos cifrados en este Mac antes de subirlos. Es compatible con Cryptomator, así que se puede abrir con su aplicación en otros dispositivos.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Nombre de la carpeta", text: $name).textFieldStyle(.roundedBorder)
            SecureField("Contraseña (al menos \(CryptomatorVaults.minimumPassphraseLength) caracteres)", text: $passphrase).textFieldStyle(.roundedBorder)
            SecureField("Repite la contraseña", text: $confirmation).textFieldStyle(.roundedBorder).onSubmit(create)
            if !confirmation.isEmpty, passphrase != confirmation {
                Text("Las contraseñas no coinciden.").font(.caption).foregroundStyle(.orange)
            }
            Toggle(isOn: $understood) {
                Text("Entiendo que si pierdo la contraseña no hay forma de recuperar los archivos: ni iCloudy, ni Cryptomator, ni la nube pueden abrir la bóveda sin ella.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Recordar la contraseña en el Llavero de este Mac", isOn: $remember)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Crear bóveda", action: create).keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }.padding(24).frame(width: 480)
    }

    private func create() {
        guard ready else { return }
        working = true; problem = nil
        Task {
            problem = await model.createVault(request, name: name, passphrase: passphrase, remember: remember)
            working = false
            if problem == nil { dismiss() }
        }
    }
}

/// The "Cifrado" tab of Configuración.
struct CryptomatorSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vaults: CryptomatorVaults
    @AppStorage(CryptomatorVaults.idlePreference) private var idleMinutes = CryptomatorVaults.defaultIdleMinutes

    var body: some View {
        Form {
            Section {
                Picker("Bloquear las bóvedas sin uso tras", selection: $idleMinutes) {
                    Text("5 minutos").tag(5)
                    Text("15 minutos").tag(15)
                    Text("30 minutos").tag(30)
                    Text("1 hora").tag(60)
                    Text("Nunca").tag(0)
                }
                Text("Una bóveda con transferencias en curso no se bloquea sola. Al salir de iCloudy se bloquean todas, y las claves no se guardan nunca en disco.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Bóvedas abiertas") {
                    HStack {
                        Text("\(vaults.unlocked.count)")
                        Button("Bloquear todas") { for vault in vaults.unlocked { model.lockVault(vault.id) } }.disabled(vaults.unlocked.isEmpty)
                    }
                }
                Text("Las bóvedas usan el formato 8 de Cryptomator. Se crean con «Crear bóveda cifrada…» en el menú de una carpeta y se abren con «Abrir bóveda…».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }
}
