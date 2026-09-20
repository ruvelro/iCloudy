import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Address and credentials for a server the user runs: WebDAV or FTP. Both store the password in the Keychain and
/// send it only to that host.
struct ServerLoginView: View {
    @ObservedObject var model: AppModel
    let cloud: Cloud
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var secureFTP = false
    @State private var nextcloud = false
    @State private var showAdvanced = false

    /// WebDAV and FTP need a full server address; Mega has only one.
    private var needsServer: Bool { cloud != .mega }
    private var icon: String {
        switch cloud {
        case .webdav: return "server.rack"
        case .mega: return "lock.icloud"
        default: return "arrow.up.arrow.down.square"
        }
    }
    private var placeholder: String {
        cloud == .webdav ? "https://nube.ejemplo.com/remote.php/dav/files/ana" : "servidor.ejemplo.com/carpeta"
    }
    private var explanation: String {
        switch cloud {
        case .webdav: return L("Para Nextcloud, ownCloud, Synology, otros NAS y cualquier servidor WebDAV. La dirección es la ruta WebDAV completa.")
        case .mega: return L("Tu contraseña no sale de este Mac: se usa para derivar las claves con las que Mega cifra los nombres y el contenido.")
        default: return L("Para servidores FTP propios y NAS. iCloudy usa siempre modo pasivo. Sin FTPS, la contraseña y los archivos viajan sin cifrar.")
        }
    }
    private var address: String {
        guard cloud == .ftp else { return server }
        let clean = server.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ftps://", with: "").replacingOccurrences(of: "ftp://", with: "")
        return (secureFTP ? "ftps://" : "ftp://") + clean
    }

    /// Reconnecting is about a session, not about an address: the server and the user are already known, and asking
    /// for them again from memory is a poor way of asking somebody for a password.
    private func prefillForReconnect() {
        guard server.isEmpty, username.isEmpty, let account = model.reconnecting, account.cloud == cloud else { return }
        username = Self.storedUser(of: account)
        guard needsServer, let stored = account.serverURL else { return }
        secureFTP = stored.hasPrefix("ftps://")
        nextcloud = account.flavor == "nextcloud"
        server = cloud == .ftp ? stored.replacingOccurrences(of: "ftps://", with: "").replacingOccurrences(of: "ftp://", with: "") : stored
    }
    /// The user name an account was connected with. Mega keeps it as the e-mail; the self-hosted ones put it after
    /// the "#" of their identifier and before the "@" of the label.
    static func storedUser(of account: Account) -> String {
        if account.cloud == .mega { return account.email }
        if let marker = account.id.lastIndex(of: "#") { return String(account.id[account.id.index(after: marker)...]) }
        return account.email.split(separator: "@").dropLast().joined(separator: "@")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(cloud.title, systemImage: icon).font(.title2)
                if cloud.isExperimental {
                    Text("Experimental").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cloud.isExperimental {
                Label("Mega no publica su API ni se compromete a mantenerla. Puede dejar de funcionar sin aviso.", systemImage: "flask")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if cloud == .ftp {
                Picker("Seguridad", selection: $secureFTP) {
                    Text("FTP sin cifrar").tag(false)
                    Text("FTPS implícito (puerto 990)").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if !secureFTP {
                    Label("Sin cifrar: usa esta opción solo en tu red local.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if needsServer { TextField(placeholder, text: $server).textFieldStyle(.roundedBorder) }
            TextField(needsServer ? "Usuario" : "Correo de la cuenta", text: $username).textFieldStyle(.roundedBorder)
                .onAppear(perform: prefillForReconnect)
            SecureField(needsServer ? "Contraseña o contraseña de aplicación" : "Contraseña", text: $password).textFieldStyle(.roundedBorder)
            Text(needsServer
                 ? "Si tu servidor usa verificación en dos pasos, crea una contraseña de aplicación en su configuración."
                 : "Si la cuenta tiene verificación en dos pasos, escribe la contraseña, un espacio y el código de seis dígitos.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cloud == .webdav {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    Toggle("Servidor Nextcloud u ownCloud", isOn: $nextcloud)
                    Text("Habilita «Crear enlace público» usando su API de compartición, que WebDAV por sí solo no tiene. Déjalo desactivado si no sabes qué servidor es.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Avanzado").font(.caption)
                }
            }
            if let error = model.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancelar") { model.serverLogin = nil; model.reconnecting = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                Button("Conectar") {
                    Task {
                        await model.connectServer(cloud: cloud, server: address, username: username, password: password,
                                                  flavor: cloud == .webdav && nextcloud ? "nextcloud" : nil)
                        password = ""
                        if model.connectionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connecting || (needsServer && server.isEmpty) || username.isEmpty || password.isEmpty)
            }
        }.padding(24).frame(width: 470)
    }
}
