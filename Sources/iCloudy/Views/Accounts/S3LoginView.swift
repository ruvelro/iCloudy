import SwiftUI
import AppKit

/// Keys and place of an S3 account: the service (or an endpoint for anything else that speaks S3), its region, the
/// access key and its secret, and optionally one bucket. The secret goes to the Keychain and only ever signs requests.
struct S3LoginView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var form = S3SignIn(service: .aws, region: S3Service.aws.defaultRegion)
    @State private var showAdvanced = false
    /// Profiles read from an AWS credentials file, while the person picks one.
    @State private var profiles: [AWSProfile] = []

    private var explanation: LocalizedStringKey {
        switch form.service {
        case .aws: return "Usa una clave de acceso de IAM con permiso sobre los buckets que quieras ver. La región es la del bucket; si te equivocas, iCloudy la corrige al conectar."
        case .backblaze: return "Crea una clave de aplicación en Backblaze. La región aparece en la dirección S3 del bucket, por ejemplo eu-central-003."
        case .wasabi: return "Usa una clave de acceso de Wasabi y la región donde creaste el bucket."
        case .cloudflare: return "Crea un token de API de R2 con acceso S3. El ID de cuenta está en el panel de R2, en la dirección del servicio."
        case .scaleway: return "Usa una clave de API de Scaleway con permiso sobre Object Storage."
        case .digitalocean: return "Crea una clave de acceso de Spaces en el panel de DigitalOcean."
        case .custom: return "Para MinIO, Garage, Ceph y otros servidores compatibles con S3. Escribe la dirección completa del servicio, con su puerto."
        }
    }
    /// What a valid form has, before anything is sent.
    private var complete: Bool {
        let filled = !form.accessKey.isEmpty && !form.secretKey.isEmpty
        switch form.service {
        case .custom: return filled && !form.endpoint.isEmpty
        case .cloudflare: return filled && !form.accountID.isEmpty
        case .backblaze: return filled && !form.region.isEmpty
        default: return filled
        }
    }

    /// Reconnecting is about the keys: the service, region and bucket are known, and the access key is in the id.
    private func prefillForReconnect() {
        guard form.accessKey.isEmpty, let account = model.reconnecting, account.cloud == .s3, let location = try? S3Location(account: account) else { return }
        form.service = location.service
        form.region = location.region
        form.bucket = location.bucket ?? ""
        form.addressing = location.addressing
        if let marker = account.id.lastIndex(of: "#") { form.accessKey = String(account.id[account.id.index(after: marker)...]) }
        if location.service == .custom { form.endpoint = location.endpoint.url?.absoluteString ?? "" }
        if location.service == .cloudflare { form.accountID = location.endpoint.host?.components(separatedBy: ".").first ?? "" }
        showAdvanced = location.addressing != .automatic
    }

    /// Reads `~/.aws/credentials` or `~/.aws/config`, chosen by the person: under the sandbox only a file picked in the
    /// panel can be read. The keys go into the form and from there to the Keychain, never anywhere else.
    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.message = L("Elige el archivo credentials (o config) de tu carpeta .aws.")
        if let home = getpwuid(getuid())?.pointee.pw_dir { panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".aws") }
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let found = AWSProfiles.parse(text)
        model.connectionError = nil
        guard !found.isEmpty else { model.connectionError = L("Ese archivo no tiene perfiles de AWS."); return }
        profiles = found
        use(found.first { $0.name == "default" && $0.hasKeys } ?? found.first(where: \.hasKeys) ?? found[0])
    }
    private func use(_ profile: AWSProfile) {
        if let why = profile.indirection, !profile.hasKeys {
            model.connectionError = L("El perfil «\(profile.name)» \(why). iCloudy necesita las claves escritas en el archivo.")
            return
        }
        guard profile.hasKeys else { model.connectionError = L("El perfil «\(profile.name)» no tiene claves de acceso."); return }
        form.adopt(profile)
        model.connectionError = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("S3", systemImage: "cylinder.split.1x2").font(.title2)
            Picker("Servicio", selection: $form.service) {
                ForEach(S3Service.allCases) { service in Text(service.title).tag(service) }
            }
            .onChange(of: form.service) { _, service in
                // The region of one service means nothing to another.
                form.region = service.regions.isEmpty && service != .custom && service != .cloudflare ? "" : service.defaultRegion
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch form.service {
            case .custom:
                TextField("https://minio.ejemplo.com:9000", text: $form.endpoint).textFieldStyle(.roundedBorder)
                TextField("Región (us-east-1 si el servidor no usa regiones)", text: $form.region).textFieldStyle(.roundedBorder)
            case .cloudflare:
                TextField("ID de cuenta de Cloudflare", text: $form.accountID).textFieldStyle(.roundedBorder)
            case .backblaze:
                TextField("Región, por ejemplo eu-central-003", text: $form.region).textFieldStyle(.roundedBorder)
            default:
                Picker("Región", selection: $form.region) {
                    ForEach(form.service.regions, id: \.self) { region in Text(verbatim: region).tag(region) }
                }
            }
            HStack {
                Button("Importar de ~/.aws…") { importProfiles() }
                if profiles.count > 1 {
                    Menu("Perfil") {
                        ForEach(profiles) { profile in
                            Button(profile.name) { use(profile) }.disabled(!profile.hasKeys)
                        }
                    }.fixedSize()
                }
                Spacer()
            }
            TextField("ID de clave de acceso", text: $form.accessKey).textFieldStyle(.roundedBorder)
                .onAppear(perform: prefillForReconnect)
            SecureField("Clave secreta", text: $form.secretKey).textFieldStyle(.roundedBorder)
            SecureField("Token de sesión (solo con credenciales temporales)", text: $form.sessionToken).textFieldStyle(.roundedBorder)
            if let expires = form.sessionExpires, !form.sessionToken.isEmpty {
                Text("Estas credenciales caducan el \(expires.formatted(date: .abbreviated, time: .shortened)); después habrá que volver a conectar la cuenta.")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Bucket (opcional)", text: $form.bucket).textFieldStyle(.roundedBorder)
            Text("Si lo dejas vacío, se muestran todos los buckets que la clave puede listar. Escríbelo si la clave solo tiene acceso a uno.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showAdvanced) {
                Picker("Direccionamiento", selection: $form.addressing) {
                    Text("Automático").tag(S3Addressing.automatic)
                    Text("Estilo ruta (servidor/bucket)").tag(S3Addressing.path)
                    Text("Subdominio (bucket.servidor)").tag(S3Addressing.virtual)
                }
                Text("En automático, los servidores propios y R2 usan el estilo ruta, y el resto el subdominio salvo que el nombre del bucket no lo permita.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Avanzado").font(.caption)
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
                        await model.connectS3(form)
                        form.secretKey = ""; form.sessionToken = ""
                        if model.connectionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.connecting || !complete)
            }
        }.padding(24).frame(width: 470)
    }
}

/// The confirmation for an S3 link, which is a presigned URL: it lives as long as is chosen here, at most a week, and
/// cannot be withdrawn before then without retiring the access key that signed it.
struct TemporaryLinkDialog: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.confirmationDialog("¿Crear un enlace temporal?", isPresented: Binding(get: { model.pendingTemporaryLink != nil },
                                                                                        set: { if !$0 { model.pendingTemporaryLink = nil } }),
                                   titleVisibility: .visible) {
            Button("Válido durante 1 hora") { create(3600) }
            Button("Válido durante 1 día") { create(24 * 3600) }
            Button("Válido durante 7 días") { create(7 * 24 * 3600) }
            Button("Cancelar", role: .cancel) { model.pendingTemporaryLink = nil }
        } message: {
            Text("Cualquier persona con el enlace podrá descargar «\(model.pendingTemporaryLink?.file.name ?? "")» hasta que caduque. No se puede revocar antes salvo desactivando la clave de acceso.")
        }
    }
    private func create(_ lifetime: Int) {
        if let pending = model.pendingTemporaryLink { Task { await model.createTemporaryLink(pending.file, account: pending.account, lifetime: lifetime) } }
        model.pendingTemporaryLink = nil
    }
}
