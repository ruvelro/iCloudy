import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Address and credentials for a server the user runs: WebDAV or FTP. Both store the password in the Keychain and
/// send it only to that host.
struct ServerLoginView: View {
    @Bindable var model: AppModel
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
    /// The questions a sign-in asks halfway: the SSH host key on a first connection, Mega's second-factor code.
    @State private var prompts = LoginPrompts.shared
    @State private var typedCode = ""

    /// The values typed for the preset's placeholders: the kDrive id, the address of the person's own server.
    @State private var presetValues: [ServerPreset.Placeholder: String] = [:]
    /// Nextcloud signs in through its own page in the browser unless the person asks for the manual form.
    @State private var manualNextcloud = false
    @State private var browserLogin: Task<Void, Never>?
    /// The server answers through the browser: only its address is asked for here.
    private var usesBrowserLogin: Bool { cloud == .webdav && (preset?.flavor ?? (nextcloud ? "nextcloud" : nil)) == "nextcloud" && !manualNextcloud }
    /// The installation to send the person to: the preset's server, or whatever address was typed.
    private var nextcloudServer: String { preset == nil ? server : (presetValues[.server] ?? "") }

    /// The service chosen under «Más servidores», when it is one for this protocol.
    private var preset: ServerPreset? { model.ui.serverPreset.flatMap { $0.cloud == cloud && $0.s3Service == nil ? $0 : nil } }
    /// WebDAV and FTP need a full server address; Mega has only one, and a preset knows it already.
    private var needsServer: Bool { cloud != .mega && preset == nil }
    static func symbol(for cloud: Cloud) -> String {
        switch cloud {
        case .webdav: return "server.rack"
        case .mega: return "lock.icloud"
        case .sftp: return "lock.rectangle.stack"
        case .s3: return "cylinder.split.1x2"
        default: return "arrow.up.arrow.down.square"
        }
    }
    private var icon: String { Self.symbol(for: cloud) }
    private var placeholder: String {
        cloud == .webdav ? "https://nube.ejemplo.com/remote.php/dav/files/ana" : "servidor.ejemplo.com/carpeta"
    }
    private var explanation: String {
        switch cloud {
        case .webdav: return L("Para Nextcloud, ownCloud, Synology, otros NAS y cualquier servidor WebDAV. La dirección es la ruta WebDAV completa.")
        case .mega: return L("Tu contraseña no sale de este Mac: se usa para derivar las claves con las que Mega cifra los nombres y el contenido.")
        case .sftp: return L("Para servidores SSH y NAS con SFTP, en el puerto 22 salvo que indiques otro. Todo va cifrado. Al conectar verás la huella de la clave del servidor para confirmarla; se guarda en el Llavero y se comprueba en cada sesión, y si cambia, iCloudy lo dirá antes de enviar nada.")
        default: return L("Para servidores FTP propios y NAS. iCloudy usa siempre modo pasivo. Sin FTPS, la contraseña y los archivos viajan sin cifrar.")
        }
    }
    private var address: String {
        if let preset { return preset.address(user: username, values: presetValues) ?? "" }
        let clean = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if cloud == .sftp { return "sftp://" + clean.replacingOccurrences(of: "sftp://", with: "") }
        guard cloud == .ftp else { return server }
        return ftpSecurity.scheme + clean.replacingOccurrences(of: "ftpes://", with: "")
            .replacingOccurrences(of: "ftps://", with: "").replacingOccurrences(of: "ftp://", with: "")
    }

    /// Reconnecting is about a session, not about an address: the server and the user are already known, and asking
    /// for them again from memory is a poor way of asking somebody for a password.
    private func prefillForReconnect() {
        guard server.isEmpty, username.isEmpty, let account = model.ui.reconnecting, account.cloud == cloud else { return }
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
            keyText = text; keyName = url.lastPathComponent; model.ui.connectionError = nil
        } catch { model.ui.connectionError = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let preset { Label { Text(verbatim: preset.title) } icon: { Image(systemName: icon) }.font(.title2) }
                else { Label(cloud.title, systemImage: icon).font(.title2) }
                if cloud.isExperimental {
                    Text("Experimental").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                }
            }
            if let preset {
                Text(verbatim: preset.notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Instrucciones de \(preset.title)", destination: preset.docs).font(.caption)
                ForEach(preset.extraPlaceholders, id: \.self) { placeholder in
                    TextField(placeholder == .drive ? "ID del kDrive, por ejemplo 123456" : "Dirección del servidor, por ejemplo nube.ejemplo.com",
                              text: Binding(get: { presetValues[placeholder] ?? "" }, set: { presetValues[placeholder] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
            if usesBrowserLogin {
                Text("Se abrirá tu Nextcloud en el navegador. Inicia sesión allí, también con verificación en dos pasos, y concede el acceso: iCloudy recibe una contraseña de aplicación propia, que puedes revocar desde la seguridad de tu cuenta.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .onAppear(perform: prefillForReconnect)
                Button("Usar usuario y contraseña") { manualNextcloud = true }.buttonStyle(.link).font(.caption)
            } else {
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
                 : "Si la cuenta tiene verificación en dos pasos, iCloudy te pedirá el código después de comprobar la contraseña.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if cloud == .webdav, preset == nil {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    Toggle("Servidor Nextcloud u ownCloud", isOn: $nextcloud)
                    Text("Habilita «Crear enlace público» usando su API de compartición, que WebDAV por sí solo no tiene. Déjalo desactivado si no sabes qué servidor es.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Avanzado").font(.caption)
                }
            }
            if preset != nil, !usesBrowserLogin, !address.isEmpty {
                Text(verbatim: address).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = model.ui.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancelar") { browserLogin?.cancel(); model.ui.serverLogin = nil; model.ui.reconnecting = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.ui.connecting { ProgressView().controlSize(.small) }
                if usesBrowserLogin {
                    Button("Iniciar sesión en el navegador") {
                        browserLogin = Task {
                            await model.connectNextcloud(server: nextcloudServer)
                            if model.ui.connectionError == nil, model.ui.serverLogin == nil { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.ui.connecting || nextcloudServer.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                Button("Conectar") {
                    Task {
                        await model.connectServer(cloud: cloud, server: address, username: username, password: password,
                                                  flavor: preset?.flavor ?? (cloud == .webdav && nextcloud ? "nextcloud" : nil),
                                                  key: cloud == .sftp ? keyText.map { SFTPKeyMaterial(key: $0, passphrase: passphrase) } : nil)
                        password = ""; passphrase = ""
                        if model.ui.connectionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.ui.connecting || (needsServer && server.isEmpty) || (preset != nil && address.isEmpty) || username.isEmpty || (password.isEmpty && keyText == nil))
                }
            }
        }.padding(24).frame(width: 470)
        .alert("¿Confías en este servidor?", isPresented: Binding(get: { prompts.hostKey != nil }, set: { if !$0 { prompts.answerHostKey(false) } }),
               presenting: prompts.hostKey) { _ in
            Button("Confiar y conectar") { prompts.answerHostKey(true) }
            Button("Cancelar", role: .cancel) { prompts.answerHostKey(false) }
        } message: { question in
            Text("Es la primera vez que iCloudy se conecta a \(question.server). El servidor se identifica con esta clave \(question.keyType):\n\n\(question.fingerprint)\n\nCompárala con la huella que da el propio servidor (por ejemplo, «ssh-keygen -lf» sobre su clave pública) y confía solo si coincide. Hasta que no aceptes, no se envía la contraseña ni la clave.")
        }
        .alert("Verificación en dos pasos", isPresented: Binding(get: { prompts.code != nil }, set: { if !$0 { prompts.answerCode(nil) } }),
               presenting: prompts.code) { _ in
            TextField("Código de seis dígitos", text: $typedCode)
            Button("Continuar") { prompts.answerCode(typedCode); typedCode = "" }
            Button("Cancelar", role: .cancel) { prompts.answerCode(nil); typedCode = "" }
        } message: { question in
            // Two Texts rather than one with a conditional: a conditional of literals is a String, shown verbatim.
            if question.retry {
                Text("\(question.service) no aceptó el código. Escribe el que muestra ahora tu aplicación de autenticación.")
            } else {
                Text("Escribe el código que muestra tu aplicación de autenticación para \(question.service).")
            }
        }
        // A form closed halfway leaves no sign-in waiting for an answer nobody can give.
        .onDisappear { prompts.answerHostKey(false); prompts.answerCode(nil); browserLogin?.cancel() }
    }
}
