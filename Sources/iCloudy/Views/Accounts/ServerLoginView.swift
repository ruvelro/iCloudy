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
    @State private var ftpSecurity = FTPSecurityChoice.plain
    /// The three ways an FTP server can be reached, and the scheme each one is stored under.
    enum FTPSecurityChoice: Hashable {
        case plain, explicitTLS, implicitTLS
        var scheme: String {
            switch self { case .plain: return "ftp://"; case .explicitTLS: return "ftpes://"; case .implicitTLS: return "ftps://" }
        }
        init(scheme stored: String) {
            self = stored.hasPrefix("ftpes://") ? .explicitTLS : stored.hasPrefix("ftps://") ? .implicitTLS : .plain
        }
    }
    /// The private key chosen for SFTP, read when it was picked, and its passphrase.
    @State private var keyText: String?
    @State private var keyName = ""
    @State private var passphrase = ""
    @State private var nextcloud = false
    @State private var showAdvanced = false

    /// WebDAV and FTP need a full server address; Mega has only one.
    private var needsServer: Bool { cloud != .mega }
    private var icon: String {
        switch cloud {
        case .webdav: return "server.rack"
        case .mega: return "lock.icloud"
        case .sftp: return "lock.rectangle.stack"
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
        case .sftp: return L("Para servidores SSH y NAS con SFTP, en el puerto 22 salvo que indiques otro. Todo va cifrado. La clave del servidor se guarda al conectar y se comprueba en cada sesión; si cambia, iCloudy lo dirá antes de enviar nada.")
        default: return L("Para servidores FTP propios y NAS. iCloudy usa siempre modo pasivo. Sin FTPS, la contraseña y los archivos viajan sin cifrar.")
        }
    }
    private var address: String {
        let clean = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if cloud == .sftp { return "sftp://" + clean.replacingOccurrences(of: "sftp://", with: "") }
        guard cloud == .ftp else { return server }
        return ftpSecurity.scheme + clean.replacingOccurrences(of: "ftpes://", with: "")
            .replacingOccurrences(of: "ftps://", with: "").replacingOccurrences(of: "ftp://", with: "")
    }

    /// Reconnecting is about a session, not about an address: the server and the user are already known, and asking
    /// for them again from memory is a poor way of asking somebody for a password.
    private func prefillForReconnect() {
        guard server.isEmpty, username.isEmpty, let account = model.reconnecting, account.cloud == cloud else { return }
        username = Self.storedUser(of: account)
        guard needsServer, let stored = account.serverURL else { return }
        ftpSecurity = FTPSecurityChoice(scheme: stored)
        nextcloud = account.flavor == "nextcloud"
        switch cloud {
        case .ftp: server = stored.replacingOccurrences(of: "ftpes://", with: "").replacingOccurrences(of: "ftps://", with: "").replacingOccurrences(of: "ftp://", with: "")
        case .sftp: server = stored.replacingOccurrences(of: "sftp://", with: "")
        default: server = stored
        }
    }
    /// The user name an account was connected with. Mega keeps it as the e-mail; the self-hosted ones put it after
    /// the "#" of their identifier and before the "@" of the label.
    static func storedUser(of account: Account) -> String {
        if account.cloud == .mega { return account.email }
        if let marker = account.id.lastIndex(of: "#") { return String(account.id[account.id.index(after: marker)...]) }
        return account.email.split(separator: "@").dropLast().joined(separator: "@")
    }

    /// Opens the person's ~/.ssh, hidden as it is. Under the sandbox the home folder is the container's, so the real
    /// one is asked of the system. The file is read right away; nothing keeps a path to it.
    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L("Elige la clave privada (el archivo sin «.pub»).")
        if let home = getpwuid(getuid())?.pointee.pw_dir { panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".ssh") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 64_000 else { throw SSHPrivateKey.Problem.notOpenSSH }
            let text = try String(contentsOf: url, encoding: .utf8)
            // Checked now for its shape, so a public key or a certificate is refused before connecting.
            if let problem = Result(catching: { try SSHPrivateKey.parse(text, passphrase: "") }).failure as? SSHPrivateKey.Problem,
               [.notOpenSSH, .legacyPEM, .damaged].contains(problem) { throw problem }
            keyText = text; keyName = url.lastPathComponent; model.connectionError = nil
        } catch { model.connectionError = error.localizedDescription }
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
                Picker("Seguridad", selection: $ftpSecurity) {
                    Text("Sin cifrar").tag(FTPSecurityChoice.plain)
                    Text("FTPS explícito (puerto 21)").tag(FTPSecurityChoice.explicitTLS)
                    Text("FTPS implícito (puerto 990)").tag(FTPSecurityChoice.implicitTLS)
                }.pickerStyle(.segmented).labelsHidden()
                if ftpSecurity == .plain {
                    Label("Sin cifrar: usa esta opción solo en tu red local.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if ftpSecurity == .explicitTLS {
                    Text("La variante más común: la conexión empieza en claro y se cifra con AUTH TLS antes de enviar la contraseña.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if needsServer { TextField(placeholder, text: $server).textFieldStyle(.roundedBorder) }
            TextField(needsServer ? "Usuario" : "Correo de la cuenta", text: $username).textFieldStyle(.roundedBorder)
                .onAppear(perform: prefillForReconnect)
            SecureField(cloud == .sftp ? (keyText == nil ? "Contraseña" : "Contraseña (si el servidor la pide además)") : needsServer ? "Contraseña o contraseña de aplicación" : "Contraseña", text: $password).textFieldStyle(.roundedBorder)
            if cloud == .sftp {
                HStack {
                    Button(keyText == nil ? "Usar una clave privada…" : "Cambiar de clave…") { pickKey() }
                    if keyText != nil {
                        Label(keyName, systemImage: "key.fill").lineLimit(1).font(.callout)
                        Button("Quitar") { keyText = nil; keyName = ""; passphrase = "" }.buttonStyle(.link)
                    }
                }
                if keyText != nil {
                    SecureField("Frase de la clave, si tiene", text: $passphrase).textFieldStyle(.roundedBorder)
                    Text("Ed25519, ECDSA o RSA en el formato de OpenSSH. La clave y su frase se guardan en el Llavero de este Mac y solo sirven para firmar el inicio de sesión: nunca se envían al servidor.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
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
                                                  flavor: cloud == .webdav && nextcloud ? "nextcloud" : nil,
                                                  key: cloud == .sftp ? keyText.map { SFTPKeyMaterial(key: $0, passphrase: passphrase) } : nil)
                        password = ""; passphrase = ""
                        if model.connectionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connecting || (needsServer && server.isEmpty) || username.isEmpty || (password.isEmpty && keyText == nil))
            }
        }.padding(24).frame(width: 470)
    }
}
