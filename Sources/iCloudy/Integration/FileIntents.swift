import AppIntents
import Foundation

// More file actions for Shortcuts: upload into a folder, create one, move or rename, send to the trash (asking
// first), search with results the shortcut can use, sync one mirror and make a link that expires. They share their
// work with the command line and AppleScript through `AppModel+Automation.swift`.

/// A file or folder found by a search, which the shortcut can show, filter or hand to "Abrir en iCloudy".
struct CloudItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Elemento de iCloudy"
    static let defaultQuery = CloudItemQuery()
    /// Account id and item id, joined by a separator neither contains.
    let id: String
    let name: String
    let accountTitle: String
    let isFolder: Bool
    let size: Int64?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(accountTitle)", image: .init(systemName: isFolder ? "folder" : "doc"))
    }
    static let separator = "\u{1F}"
    var parts: (accountID: String, fileID: String)? {
        let pieces = id.components(separatedBy: Self.separator)
        return pieces.count == 2 ? (pieces[0], pieces[1]) : nil
    }

    @MainActor init(_ hit: SearchHit, model: AppModel) {
        id = hit.accountID + Self.separator + hit.file.id
        name = hit.file.name
        isFolder = hit.file.isFolder
        size = hit.file.size
        accountTitle = model.accounts.first { $0.id == hit.accountID }.map(model.accountTitle) ?? hit.accountID
        CloudItemQuery.remember(hit)
    }
}

/// Items are known by the searches that returned them: there is no lookup by id across providers.
struct CloudItemQuery: EntityQuery {
    @MainActor private static var seen: [String: SearchHit] = [:]
    @MainActor static func remember(_ hit: SearchHit) {
        if seen.count > 2_000 { seen.removeAll() }
        seen[hit.accountID + CloudItemEntity.separator + hit.file.id] = hit
    }
    @MainActor static func hit(_ id: String) -> SearchHit? { seen[id] }
    @MainActor func entities(for identifiers: [CloudItemEntity.ID]) async throws -> [CloudItemEntity] {
        let model = try await ColdStart.model()
        return identifiers.compactMap { Self.seen[$0].map { CloudItemEntity($0, model: model) } }
    }
}

/// A folder mirror or a two-way sync, by its local folder and its place in the cloud.
struct MirrorEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reflejo de iCloudy"
    static let defaultQuery = MirrorQuery()
    let id: UUID
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    init(_ mirror: FolderMirror) {
        id = mirror.id
        title = mirror.localURL.lastPathComponent + " → " + mirror.remoteName
    }
}

struct MirrorQuery: EntityQuery {
    @MainActor func entities(for identifiers: [MirrorEntity.ID]) async throws -> [MirrorEntity] {
        try await ColdStart.model().mirrors.mirrors.filter { identifiers.contains($0.id) }.map(MirrorEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [MirrorEntity] {
        try await ColdStart.model().mirrors.mirrors.map(MirrorEntity.init)
    }
}

/// What a shortcut hands over as a file may be only bytes, with no URL; it is written to iCloudy's own cache first.
@MainActor
enum IntentFiles {
    static func urls(_ files: [IntentFile]) throws -> [URL] {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Shortcuts", isDirectory: true)
        return try files.map { file in
            if let url = file.fileURL { return url }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = FileNames.available(in: folder, name: FileNames.safe(file.filename.isEmpty ? "Archivo" : file.filename))
            try file.data.write(to: url, options: .atomic)
            return url
        }
    }
}

struct UploadToFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Subir archivos a una carpeta de iCloudy"
    static let description = IntentDescription("Pone en cola la subida de los archivos a una carpeta de una cuenta. La subida sigue en iCloudy, con verificación, aunque el atajo termine.")
    static let openAppWhenRun = false

    @Parameter(title: "Archivos") var files: [IntentFile]
    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Carpeta", description: "Ruta desde el principio de la cuenta. Vacía para el principio.", default: "")
    var path: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let account = try model.connectedAccount(account)
        let urls = try IntentFiles.urls(files)
        guard !urls.isEmpty else { throw CloudError.message(L("No se ha recibido ningún archivo que subir.")) }
        let count = try await model.automationUpload(urls, to: account, path: path)
        return .result(dialog: IntentDialog(stringLiteral: L("\(count) archivos en cola hacia \(model.accountTitle(account)).")))
    }
}

struct CreateFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Crear una carpeta en iCloudy"
    static let description = IntentDescription("Crea una carpeta dentro de otra y devuelve su ruta.")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Dentro de", description: "Ruta desde el principio de la cuenta. Vacía para el principio.", default: "")
    var path: String
    @Parameter(title: "Nombre") var name: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = try await ColdStart.model()
        let created = try await model.automationCreateFolder(try model.connectedAccount(account), in: path, name: name)
        return .result(value: created, dialog: IntentDialog(stringLiteral: L("Carpeta «\(name)» creada.")))
    }
}

struct MoveItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Mover o renombrar en iCloudy"
    static let description = IntentDescription("Mueve un archivo o carpeta a otra carpeta de la misma cuenta, le cambia el nombre, o las dos cosas. Nunca sustituye algo que ya exista con ese nombre.")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Elemento", description: "Ruta desde el principio de la cuenta.") var path: String
    @Parameter(title: "A la carpeta", description: "Ruta de la carpeta de destino. Vacía para dejarlo donde está.", default: "")
    var destination: String
    @Parameter(title: "Nombre nuevo", description: "Vacío para conservar el nombre.", default: "")
    var newName: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        try await model.automationMove(try model.connectedAccount(account), path: path, to: destination.isEmpty ? nil : destination,
                                       rename: newName.isEmpty ? nil : newName)
        return .result(dialog: IntentDialog(stringLiteral: L("Hecho.")))
    }
}

struct TrashItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Enviar a la papelera en iCloudy"
    static let description = IntentDescription("Envía un archivo o carpeta a la papelera de la nube, después de pedir confirmación. Donde la nube no tiene papelera (WebDAV, FTP, SFTP, S3, Azure), lo dice y lo elimina definitivamente solo si se confirma.")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Elemento", description: "Ruta desde el principio de la cuenta.") var path: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let account = try model.connectedAccount(account)
        let (file, reversible) = try await model.automationTrashTarget(account, path: path)
        // Always asked, also when the shortcut runs on its own: an automation that deletes without asking is how
        // files get lost.
        let question = reversible
            ? L("¿Enviar «\(file.name)» a la papelera de \(model.accountTitle(account))?")
            : L("\(model.accountTitle(account)) no tiene papelera: «\(file.name)» se eliminará definitivamente. ¿Continuar?")
        guard try await $path.requestConfirmation(for: path, dialog: IntentDialog(stringLiteral: question)) else {
            return .result(dialog: IntentDialog(stringLiteral: L("No se ha tocado nada.")))
        }
        try await model.automationTrash(account, file: file)
        return .result(dialog: IntentDialog(stringLiteral: reversible ? L("«\(file.name)» está en la papelera.") : L("«\(file.name)» se ha eliminado.")))
    }
}

struct SearchItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Buscar archivos con iCloudy"
    static let description = IntentDescription("Busca el término en las cuentas conectadas (o en una) y devuelve los elementos encontrados, sin abrir la ventana. Las nubes sin búsqueda propia se recorren carpeta a carpeta.")
    static let openAppWhenRun = false

    @Parameter(title: "Texto que buscar") var query: String
    @Parameter(title: "Solo en la cuenta") var account: AccountEntity?
    @Parameter(title: "Como máximo", default: 50, inclusiveRange: (1, 500)) var limit: Int

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[CloudItemEntity]> & ProvidesDialog {
        let model = try await ColdStart.model()
        let only = try account.map { try model.connectedAccount($0) }
        let hits = await model.automationSearch(query, in: only, limit: limit)
        return .result(value: hits.map { CloudItemEntity($0, model: model) }, dialog: IntentDialog(stringLiteral: L("\(hits.count) resultados.")))
    }
}

struct OpenItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir en iCloudy"
    static let description = IntentDescription("Abre iCloudy en la carpeta que contiene un elemento encontrado por «Buscar archivos con iCloudy», con el elemento seleccionado.")
    static let openAppWhenRun = true

    @Parameter(title: "Elemento") var item: CloudItemEntity

    @MainActor func perform() async throws -> some IntentResult {
        let model = try await ColdStart.model()
        guard let hit = CloudItemQuery.hit(item.id), model.accounts.contains(where: { $0.id == hit.accountID }) else {
            throw CloudError.message(L("Ese resultado ya no está disponible en iCloudy. Vuelve a conectar la cuenta o búscalo de nuevo."))
        }
        guard let parent = hit.parentID else { throw CloudError.message(L("No se sabe en qué carpeta está «\(hit.file.name)».")) }
        model.openFolder(accountID: hit.accountID, folderID: parent)
        return .result()
    }
}

struct SyncMirrorIntent: AppIntent {
    static let title: LocalizedStringResource = "Sincronizar un reflejo de iCloudy"
    static let description = IntentDescription("Comprueba ahora una carpeta reflejada o sincronizada y transfiere lo que haya cambiado.")
    static let openAppWhenRun = false

    @Parameter(title: "Reflejo") var mirror: MirrorEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        guard let found = model.mirrors.mirrors.first(where: { $0.id == mirror.id }) else {
            throw CloudError.message(L("Ese reflejo ya no existe en iCloudy."))
        }
        guard !found.paused else { throw CloudError.message(L("Ese reflejo está en pausa. Reanúdalo en iCloudy para sincronizarlo.")) }
        model.mirrors.syncNow(found.id)
        return .result(dialog: IntentDialog(stringLiteral: L("Sincronizando «\(found.localURL.lastPathComponent)».")))
    }
}

struct ExpiringLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Crear un enlace con caducidad en iCloudy"
    static let description = IntentDescription("Crea un enlace de solo lectura que deja de funcionar pasados los días indicados, y lo devuelve. En S3 y Azure es un enlace firmado de hasta 7 días; en el resto, donde la nube admite caducidad.")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Elemento", description: "Ruta desde el principio de la cuenta.") var path: String
    @Parameter(title: "Días", default: 1, inclusiveRange: (1, 365)) var days: Int

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let model = try await ColdStart.model()
        let link = try await model.automationExpiringLink(try model.connectedAccount(account), path: path, lifetime: days * 24 * 3600)
        return .result(value: link, dialog: IntentDialog(stringLiteral: L("Enlace creado. Caduca en \(days) días.")))
    }
}
