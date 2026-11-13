import XCTest
@testable import iCloudy

/// The same walk through a provider, against real accounts, for whoever has some to spare.
///
/// Everything else in this suite answers from stubs, which prove that iCloudy sends what it means to send and reads
/// what it expects to read. They cannot prove that a provider agrees. These tests can, and they are skipped unless
/// `ICLOUDY_LIVE_ACCOUNTS` names a JSON file describing the accounts to use (or `ICLOUDY_LIVE_ACCOUNTS_JSON` carries
/// its contents, for a CI secret). docs/PRUEBAS-REALES.md has the format and how to get each value.
///
/// Each account is only touched inside a folder this run creates, named with the date, which goes to the provider's
/// bin at the end (and is purged where the provider allows it). Use accounts made for testing all the same.
@MainActor
final class LiveAccountTests: XCTestCase {
    struct Entry: Codable {
        var cloud: String
        /// OAuth clouds: the client the refresh token was issued to.
        var clientID: String?
        var clientSecret: String?
        var refreshToken: String?
        /// pCloud: its tokens do not expire and have no refresh token; `apiHost` is api.pcloud.com or eapi.pcloud.com.
        var accessToken: String?
        var apiHost: String?
        /// WebDAV, FTP, SFTP: the address, and the credentials unless the address carries them. Mega: user and password.
        var url: String?
        var user: String?
        var password: String?
        /// WebDAV: "nextcloud" turns on its bin, versions and sharing.
        var flavor: String?
        /// S3: `service` is one of S3Service's raw values; `url` is the endpoint for a custom one.
        var accessKey: String?
        var secretKey: String?
        var region: String?
        var bucket: String?
        /// Shared drive (Google) or document library (SharePoint) to run inside, instead of the account's own files.
        var driveID: String?
        /// Folder to work under, by id. The account's root when missing.
        var folder: String?
        /// Megabytes of the large upload. 6 crosses a block boundary everywhere; Box only opens a session from 20.
        var largeMB: Int?
    }

    /// Writes a rotated refresh token back to the file, for the providers that retire the old one on every use.
    private final class LiveCredentials: CredentialStore {
        var stored: [String: Credential] = [:]
        var rotated: ((String) -> Void)?
        func read(_ key: String) throws -> Credential? { stored[key] }
        func save(_ credential: Credential, key: String) throws {
            let changed = stored[key]?.refreshToken != credential.refreshToken
            stored[key] = credential
            if changed, !credential.refreshToken.isEmpty { rotated?(credential.refreshToken) }
        }
    }

    private static func entries() throws -> (entries: [Entry], file: URL?) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ICLOUDY_LIVE_ACCOUNTS"], !path.isEmpty {
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return (try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)), file)
        }
        if let json = environment["ICLOUDY_LIVE_ACCOUNTS_JSON"], !json.isEmpty {
            return (try JSONDecoder().decode([Entry].self, from: Data(json.utf8)), nil)
        }
        throw XCTSkip("Sin cuentas reales configuradas (ICLOUDY_LIVE_ACCOUNTS)")
    }

    private func connect(_ entry: Entry, index: Int, file: URL?) async throws -> CloudAPI {
        guard let cloud = Cloud(rawValue: entry.cloud) else { throw CloudError.message("Nube desconocida en la configuración: \(entry.cloud)") }
        let store = LiveCredentials()
        var account: Account, credential: Credential
        switch cloud {
        case .google, .microsoft, .dropbox, .box:
            guard let clientID = entry.clientID, let refresh = entry.refreshToken else { throw CloudError.message("\(entry.cloud): faltan clientID y refreshToken") }
            account = Account(id: "\(entry.cloud):live-\(index)", cloud: cloud, name: "Pruebas", email: "pruebas", clientID: clientID, clientSecret: entry.clientSecret)
            // Expired on purpose: the first request trades the refresh token, which is itself part of what is tested.
            credential = Credential(accessToken: "", refreshToken: refresh, expires: .distantPast)
            if let file {
                store.rotated = { token in
                    guard var all = try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)), all.indices.contains(index) else { return }
                    all[index].refreshToken = token
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    try? encoder.encode(all).write(to: file, options: .atomic)
                }
            }
        case .pcloud:
            guard let token = entry.accessToken else { throw CloudError.message("pcloud: falta accessToken") }
            account = Account(id: "pcloud:live-\(index)", cloud: .pcloud, name: "Pruebas", email: "pruebas", clientID: entry.clientID ?? "", clientSecret: nil,
                              options: ["apiHost": entry.apiHost ?? PCloudRegion.unitedStates])
            credential = .permanent(accessToken: token)
        case .webdav:
            (account, credential) = try await WebDAVAuthentication().signInWebDAV(server: entry.url ?? "", username: entry.user ?? "", password: entry.password ?? "")
            if let flavor = entry.flavor { account.options["flavor"] = flavor }
        case .ftp:
            (account, credential) = try await FTPAuthentication().signInFTP(server: entry.url ?? "", username: entry.user ?? "", password: entry.password ?? "")
        case .sftp:
            (account, credential) = try await SFTPAuthentication().signInSFTP(server: entry.url ?? "", username: entry.user ?? "", password: entry.password ?? "")
        case .mega:
            (account, credential) = try await MegaAuthentication().signInMega(email: entry.user ?? "", password: entry.password ?? "")
        case .s3:
            let service = S3Service(rawValue: entry.url == nil ? "aws" : "custom") ?? .custom
            let form = S3SignIn(service: service, region: entry.region ?? "us-east-1", endpoint: entry.url ?? "",
                                accessKey: entry.accessKey ?? "", secretKey: entry.secretKey ?? "", bucket: entry.bucket ?? "")
            (account, credential) = try await S3Authentication().signIn(form)
        case .volume, .o2:
            throw XCTSkip("\(entry.cloud) no se prueba así: un volumen no necesita cuenta y O2 solo entra por su web")
        }
        store.stored[account.credentialKey] = credential
        if let drive = entry.driveID { account = Account.scoped(to: drive, named: "Unidad de pruebas", from: account) }
        return CloudAPI(account: account, credentials: store)
    }

    private func payload(_ count: Int, seed: Int) -> Data {
        // Built from an array: older compilers cannot choose between the two `withUnsafeMutableBytes` of Data.
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed) % 251) })
    }
    private func upload(_ data: Data, named name: String, to parent: String, replacing: String? = nil, api: CloudAPI) async throws -> UploadReceipt {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("live-" + UUID().uuidString + "-" + name)
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        return try await api.resumableUpload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: nil, save: { _ in }, progress: { _, _ in })
    }

    func testEveryConfiguredAccountWalksTheWholeProvider() async throws {
        let (entries, file) = try Self.entries()
        var failures: [String] = []
        for (index, entry) in entries.enumerated() {
            do { try await walk(try await connect(entry, index: index, file: file), entry: entry) }
            catch let skip as XCTSkip { print("· \(entry.cloud): \(skip.message ?? "omitida")") }
            catch { failures.append("\(entry.cloud) (#\(index)): \(error.localizedDescription)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// `ICLOUDY_LIVE_SIGNIN=google swift test --filter LiveAccountTests/testSignInAddsAnAccountToTheFile` opens the
    /// browser with the app's own sign-in, for the client in Configuration/OAuth.local.plist, and adds the account
    /// to the file `ICLOUDY_LIVE_ACCOUNTS` names. The refresh token goes to that file and nowhere else.
    func testSignInAddsAnAccountToTheFile() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["ICLOUDY_LIVE_SIGNIN"], let cloud = Cloud(rawValue: name) else {
            throw XCTSkip("Sin nube en la que iniciar sesión (ICLOUDY_LIVE_SIGNIN)")
        }
        guard let path = environment["ICLOUDY_LIVE_ACCOUNTS"], !path.isEmpty else {
            throw XCTSkip("Indica en ICLOUDY_LIVE_ACCOUNTS el archivo donde guardar la cuenta")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = environment["ICLOUDY_OAUTH_CONFIG"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent("Configuration/OAuth.local.plist")
        let configuration = try PropertyListDecoder().decode(OAuthConfiguration.self, from: Data(contentsOf: plist))
        let client: (id: String, secret: String)
        switch cloud {
        case .google: client = (configuration.googleClientID, configuration.googleDesktopClientSecret)
        case .microsoft: client = (configuration.microsoftClientID, "")
        case .dropbox: client = (configuration.dropboxAppKey, "")
        case .box: client = (configuration.boxClientID, configuration.boxClientSecret)
        case .pcloud: client = (configuration.pcloudClientID, configuration.pcloudClientSecret)
        default: throw XCTSkip("\(name) no entra por OAuth: escribe su entrada a mano")
        }
        guard !client.id.isEmpty else { throw CloudError.message("No hay cliente de \(name) en \(plist.path)") }
        let (account, credential) = try await OAuth().signIn(cloud: cloud, clientID: client.id, clientSecret: client.secret)
        var entry = Entry(cloud: name, clientID: client.id, clientSecret: client.secret.isEmpty ? nil : client.secret)
        if cloud == .pcloud { entry.accessToken = credential.accessToken; entry.apiHost = account.options["apiHost"] }
        else { entry.refreshToken = credential.refreshToken }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var all = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
        all.append(entry)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(all).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        print("· \(account.email) añadida a \(file.path)")
    }

    /// The walk is code too, and nobody would notice it broken until the day it is pointed at a real account. The
    /// demo store is a cloud with a bin and no network, which is enough to run every step that does not depend on
    /// a provider's own features.
    func testTheWalkItselfHoldsAgainstTheDemoStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-demo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = CloudAPI(account: .demo, demo: try DemoStore(directory: root))
        try await walk(api, entry: Entry(cloud: "google", largeMB: 1))
    }

    private func walk(_ api: CloudAPI, entry: Entry) async throws {
        let cloud = api.account.cloud, capabilities = api.account.capabilities
        let label = cloud.rawValue
        func check(_ condition: @autoclosure () throws -> Bool, _ what: String) throws {
            if try !condition() { throw CloudError.message(what) }
        }
        let root: String
        if let folder = entry.folder { root = folder } else { root = try await api.rootID() }
        _ = try await api.list(parent: root)

        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folderName = "iCloudy prueba " + formatter.string(from: Date())
        let folderID = try await api.createFolder(name: folderName, parent: root)
        var folder = CloudFile(id: folderID, name: folderName, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        var cleaned = false
        func cleanUp() async {
            guard !cleaned else { return }
            cleaned = true
            try? await api.trash(file: folder)
            // Out of the bin too where the provider lets a folder be purged, so repeated runs leave nothing behind.
            if capabilities.reversibleTrash, capabilities.allows(.permanentDelete, on: [folder]), capabilities.trashListing,
               let binned = try? await api.list(parent: Collection.trash.rootID).first(where: { $0.name == folderName }) {
                try? await api.deletePermanently(file: binned)
            }
        }
        do {
            let top = try await api.list(parent: root)
            if let listed = top.first(where: { $0.id == folderID }) { folder = listed }
            try check(top.contains { $0.id == folderID && $0.isFolder }, "la carpeta creada no aparece en el listado")

            // The feed position is taken before anything is written, to be asked about it afterwards.
            let position = try await api.changeCursor(for: folderID)

            // One file in a single request and one that takes several blocks.
            let small = Data("hola desde las pruebas de iCloudy — ñ, 你好".utf8)
            let large = payload((entry.largeMB ?? 6) * 1024 * 1024 + 13, seed: 7)
            let smallReceipt = try await upload(small, named: "pequeño.txt", to: folderID, api: api)
            let largeReceipt = try await upload(large, named: "grande.bin", to: folderID, api: api)
            if capabilities.checksum {
                try check(smallReceipt.verification == .verified, "la subida pequeña no quedó verificada")
                // A session that Dropbox had to be re-synchronised with ends unverified, and that is not a failure.
                print("· \(label): subida por bloques \(largeReceipt.verification)")
            }
            var listed = try await api.list(parent: folderID)
            try check(Set(listed.map(\.name)) == ["pequeño.txt", "grande.bin"], "el listado no trae los dos archivos: \(listed.map(\.name))")
            let smallFile = try XCTUnwrap(listed.first { $0.name == "pequeño.txt" }), largeFile = try XCTUnwrap(listed.first { $0.name == "grande.bin" })
            if let size = largeFile.size { try check(size == Int64(large.count), "el tamaño listado de grande.bin es \(size)") }

            // Downloads, checked the way the app checks them.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("live-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let smallCopy = scratch.appendingPathComponent("pequeño.txt")
            let verification = try await api.download(file: smallFile, to: smallCopy)
            try check(try Data(contentsOf: smallCopy) == small, "la descarga de pequeño.txt no devuelve lo subido")
            if capabilities.checksum, cloud != .s3 || smallFile.checksum != nil {
                try check(verification == .verified || smallFile.checksum == nil, "la descarga con suma no quedó verificada (\(verification))")
            }
            let largeCopy = scratch.appendingPathComponent("grande.bin")
            try await api.download(file: largeFile, to: largeCopy)
            try check(try Data(contentsOf: largeCopy) == large, "la descarga de grande.bin no devuelve lo subido")

            // A download continued from what an earlier attempt left: the first third is already on disk, as the
            // queue would have it after a cut, and only the rest is asked for. This is where a provider that
            // mishandles Range would show.
            if api.provider.resumesDownloads {
                let partial = scratch.appendingPathComponent(".icloudy-prueba.part")
                try large.prefix(large.count / 3).write(to: partial)
                if largeFile.checksum == nil, cloud == .s3 { DownloadResume.setValidator(nil, on: partial) }
                try await DownloadResume.$mode.withValue(.validated) { _ = try await api.download(file: largeFile, to: partial) }
                try check(try Data(contentsOf: partial) == large, "la descarga reanudada no reconstruye el archivo")
            }

            // Rename, move, copy.
            try await api.rename(file: smallFile, name: "renombrado.txt")
            let renamedID = try api.provider.identityChange(file: smallFile, name: "renombrado.txt", destination: nil).newID
            listed = try await api.list(parent: folderID)
            let renamed = try XCTUnwrap(listed.first { $0.name == "renombrado.txt" }, "el renombrado no aparece")
            try check(renamed.id == renamedID, "el id tras renombrar (\(renamed.id)) no es el que calcula iCloudy (\(renamedID))")
            let inner = try await api.createFolder(name: "dentro", parent: folderID)
            if capabilities.allows(.copy, on: [renamed]) {
                try await api.copy(file: renamed, to: inner)
                // OneDrive copies in the background; give it a moment before looking.
                var copied = false
                for _ in 0..<10 where !copied {
                    copied = try await api.list(parent: inner).contains { $0.name == "renombrado.txt" }
                    if !copied { try await Task.sleep(for: .seconds(1)) }
                }
                try check(copied, "la copia no aparece en la carpeta de destino")
            }
            if capabilities.move {
                try await api.move(file: largeFile, to: inner)
                let inside = try await api.list(parent: inner)
                try check(inside.contains { $0.name == "grande.bin" }, "lo movido no aparece en el destino")
                let outside = try await api.list(parent: folderID)
                try check(!outside.contains { $0.name == "grande.bin" }, "lo movido sigue en el origen")
            }

            // The feed has to have noticed all of that. Feeds lag, so it is asked a few times.
            if let position {
                var noticed = false
                var cursor = position
                let known = Set([folderID, inner] + listed.map(\.id))
                for _ in 0..<12 where !noticed {
                    let batch = try await api.changes(since: cursor, in: folderID)
                    noticed = batch.touches(root: folderID, known: known, rootAlias: cloud.rootAlias)
                    cursor = batch.cursor
                    if !noticed { try await Task.sleep(for: .seconds(5)) }
                }
                try check(noticed, "el registro de cambios no dijo nada de lo que se acaba de subir")
            }

            // chmod, where there is such a thing: a file made private and read back.
            if let sftp = api.provider as? SFTPProvider, let target = try await api.list(parent: inner).first(where: { !$0.isFolder }) {
                try await sftp.sftpSetPermissions(POSIXMode(bits: 0o600), on: target, recursive: false)
                let now = try await sftp.sftpPermissions(of: target)
                try check(now.octal == "600", "los permisos tras chmod 600 son \(now.octal)")
            }

            if capabilities.quota { _ = try await api.storageQuota() }
            if capabilities.search {
                // Indexes lag behind writes, so finding the new file is not demanded: the call has to work.
                _ = try await api.searchPage(term: "renombrado")
            }
            let trail = try await api.folderTrail(id: inner)
            try check(trail.last?.id == inner || trail.contains { $0.id == folderID } || trail.isEmpty == false, "las migas de la carpeta están vacías")

            // To the bin, and back out of the listing.
            try await api.trash(file: renamed)
            listed = try await api.list(parent: folderID)
            try check(!listed.contains { $0.name == "renombrado.txt" }, "lo enviado a la papelera sigue en la carpeta")
        } catch {
            await cleanUp()
            throw CloudError.message("[\(label)] \(error.localizedDescription)")
        }
        await cleanUp()
        let after = try await api.list(parent: root)
        XCTAssertFalse(after.contains { $0.id == folderID }, "[\(label)] la carpeta de pruebas sigue en su sitio")
    }
}
