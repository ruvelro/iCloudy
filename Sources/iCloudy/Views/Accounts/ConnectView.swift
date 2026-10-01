import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

struct ConnectView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Añade tu nube", systemImage: "cloud").font(.title.weight(.semibold))
                Text("Elige tu proveedor y autoriza el acceso a tus archivos. Puedes añadir tantas cuentas como necesites.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("SERVICIOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    providerButton(.google, title: "Continuar con Google", subtitle: "Google Drive", icon: "externaldrive")
                    providerButton(.microsoft, title: "Continuar con Microsoft", subtitle: "OneDrive · Outlook, Hotmail o Microsoft 365", icon: "cloud.fill")
                    providerButton(.dropbox, title: "Continuar con Dropbox", subtitle: "Dropbox personal o de equipo", icon: "shippingbox")
                    providerButton(.box, title: "Continuar con Box", subtitle: "Box personal o de empresa", icon: "square.stack.3d.up")
                    providerButton(.pcloud, title: "Continuar con pCloud", subtitle: "Cuentas de pCloud en Europa o en Estados Unidos", icon: "cloud.circle")
                    providerButton(.mega, title: "Conectar Mega", subtitle: "Cifrado de extremo a extremo, con correo y contraseña", icon: "lock.icloud")
                    providerButton(.o2, title: "Conectar O2 Cloud", subtitle: "Inicias sesión en las páginas de O2, con tu móvil o tu NIF", icon: "antenna.radiowaves.left.and.right")
                }.disabled(model.connecting)
                Text("TU PROPIO SERVIDOR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    providerButton(.webdav, title: "Conectar WebDAV", subtitle: "Nextcloud, ownCloud, Synology y otros NAS", icon: "server.rack")
                    providerButton(.sftp, title: "Conectar SFTP", subtitle: "Servidores SSH y NAS, cifrado y con la clave del servidor comprobada", icon: "lock.rectangle.stack")
                    providerButton(.ftp, title: "Conectar FTP", subtitle: "FTP, FTPS explícito e implícito, con usuario y contraseña", icon: "arrow.up.arrow.down.square")
                    providerButton(.volume, title: "Conectar un volumen o carpeta", subtitle: "SMB, AFP, NFS, discos externos y carpetas del Mac", icon: "externaldrive.connected.to.line.below")
                }.disabled(model.connecting)
                Text("ALMACENAMIENTO DE OBJETOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                providerButton(.s3, title: "Conectar S3", subtitle: "Amazon S3, Backblaze B2, Wasabi, Cloudflare R2, MinIO y compatibles", icon: "cylinder.split.1x2")
                    .disabled(model.connecting)
                Button("Conectar a un servidor en el Finder…") { model.openFinderConnect() }
                    .buttonStyle(.link).font(.caption)
                    .help("Monta el recurso de red y vuelve aquí para elegir su carpeta")
                Text("AVANZADOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button {
                    model.connectionError = nil; model.showAdvanced = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.2.badge.gearshape").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unidad compartida o biblioteca").font(.headline)
                            Text("Unidades compartidas de Google y bibliotecas de SharePoint").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                }.buttonStyle(.plain).disabled(model.driveHosts.isEmpty || model.connecting)
                if model.driveHosts.isEmpty {
                    Text("Conecta antes una cuenta de Google o de Microsoft.").font(.caption2).foregroundStyle(.secondary)
                }
                Button("Probar demo local sin iniciar sesión") { model.enableDemo() }.disabled(model.connecting)
                if let error = model.connectionError, model.serverLogin == nil {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if model.connecting { HStack { ProgressView().controlSize(.small); Text("Esperando el inicio de sesión en el navegador…").font(.caption) } }
                Text("Con Google, Microsoft, Dropbox y Box tu contraseña se introduce únicamente en la web del proveedor. Las credenciales de un servidor propio las escribes aquí y se guardan en el Llavero de este Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancelar") { model.oauth.cancel(); model.showConnect = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }.padding(30)
        }.frame(width: 470, height: 640).interactiveDismissDisabled(model.connecting)
            .onAppear { model.connectionError = nil }
            .sheet(item: $model.serverLogin) { cloud in
                if cloud == .s3 { S3LoginView(model: model) } else { ServerLoginView(model: model, cloud: cloud) }
            }
            .sheet(isPresented: $model.showAdvanced) { AdvancedDriveView(model: model) }
            .sheet(item: $model.o2Login) { request in O2WebLoginView(model: model, request: request) }
    }

    private func providerButton(_ cloud: Cloud, title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String) -> some View {
        Button {
            // A self-hosted provider needs an address and credentials before anything can be attempted.
            if cloud == .volume { Task { await model.connectVolume() } }
            else if cloud.usesWebLogin { model.connectionError = nil; model.o2Login = O2LoginRequest(host: "cloud.o2online.es") }
            else if cloud.usesPasswordLogin { model.connectionError = nil; model.serverLogin = cloud }
            else { Task { await model.connect(cloud: cloud) } }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint(cloud)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if cloud.isExperimental {
                            Text("Experimental").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: cloud.isSelfHosted || cloud.usesPasswordLogin ? "chevron.right" : "arrow.up.right").foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }.buttonStyle(.plain)
    }
    private func tint(_ cloud: Cloud) -> Color {
        switch cloud {
        case .google: return .green
        case .microsoft: return .blue
        case .dropbox: return .indigo
        case .box: return .cyan
        case .webdav: return .gray
        case .ftp: return .orange
        case .sftp: return .teal
        case .volume: return .brown
        case .mega: return .red
        case .o2: return .mint
        case .pcloud: return .teal
        case .s3: return .orange
        }
    }
}
