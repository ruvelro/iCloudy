import AppIntents
import Foundation

// Actions on files for the Shortcuts app: list a folder, download a file, make a public link and copy between clouds.
// A file is named by its account and its path from the top of that account, "Fotos/2024/playa.jpg", the way a person
// would say it; each step is looked up by name, ignoring case.

struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cuenta de iCloudy"
    static let defaultQuery = AccountQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    @MainActor init(_ account: Account, model: AppModel) {
        id = account.id
        title = model.accountTitle(account) + " · " + account.email
    }
}

struct AccountQuery: EntityQuery {
    @MainActor func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        let model = try await ColdStart.model()
        return model.accounts.filter { identifiers.contains($0.id) }.map { AccountEntity($0, model: model) }
    }
    @MainActor func suggestedEntities() async throws -> [AccountEntity] {
        let model = try await ColdStart.model()
        return model.accounts.filter { !$0.isDemo }.map { AccountEntity($0, model: model) }
    }
}

/// An item found by path, with the folders above it, which is what a cross-cloud copy labels its destination with.
struct ResolvedPath {
    let file: CloudFile?
    let folderID: String
    let trail: [CloudFile]
}

extension AppModel {
    func connectedAccount(_ entity: AccountEntity) throws -> Account {
        guard let account = accounts.first(where: { $0.id == entity.id }) else {
            throw CloudError.message(L("Esa cuenta ya no está conectada en iCloudy."))
        }
        return account
    }

    /// Walks `path` from the top of the account. An empty path is the top itself, which has no item of its own.
    func resolve(path: String, in account: Account) async throws -> ResolvedPath {
        let api = try client(account)
        var folder = try await api.rootID()
        var trail: [CloudFile] = []
        let parts = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var found: CloudFile?
        for (index, part) in parts.enumerated() {
            let children = try await api.list(parent: folder)
            guard let match = children.first(where: { $0.name == part }) ?? children.first(where: { $0.name.localizedCaseInsensitiveCompare(part) == .orderedSame }) else {
                throw CloudError.message(L("No se encontró «\(part)» en \(([accountTitle(account)] + trail.map(\.name)).joined(separator: " / ")).") )
            }
            found = match
            if index < parts.count - 1 {
                guard match.isFolder else { throw CloudError.message(L("«\(match.name)» no es una carpeta.")) }
                folder = match.id; trail.append(match)
            }
        }
        if let found, found.isFolder { return ResolvedPath(file: found, folderID: found.id, trail: trail + [found]) }
        return ResolvedPath(file: found, folderID: folder, trail: trail)
    }
}

struct ListFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Listar una carpeta de iCloudy"
    static let description = IntentDescription("Devuelve los nombres de lo que hay en una carpeta de una cuenta. Las carpetas terminan en «/».")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Carpeta", description: "Ruta desde el principio de la cuenta, por ejemplo «Documentos/Facturas». Vacía para el principio.", default: "")
    var path: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let model = try await ColdStart.model()
        let account = try model.connectedAccount(account)
        let place = try await model.resolve(path: path, in: account)
        if let file = place.file, !file.isFolder { throw CloudError.message(L("«\(file.name)» es un archivo, no una carpeta.")) }
        let names = try await model.client(account).list(parent: place.folderID).map { $0.isFolder ? $0.name + "/" : $0.name }
        return .result(value: names, dialog: IntentDialog(stringLiteral: L("\(names.count) elementos.")))
    }
}

struct DownloadFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Descargar un archivo de iCloudy"
    static let description = IntentDescription("Descarga un archivo de una cuenta y lo devuelve al atajo, que puede guardarlo, enviarlo o abrirlo. Los documentos de Google llegan como archivos de Office.")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Archivo", description: "Ruta desde el principio de la cuenta, por ejemplo «Documentos/informe.pdf».")
    var path: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let model = try await ColdStart.model()
        let account = try model.connectedAccount(account)
        guard let file = try await model.resolve(path: path, in: account).file, !file.isFolder else {
            throw CloudError.message(L("Indica un archivo, no una carpeta."))
        }
        let url = try await model.downloadForDrag(file, account: account, name: AppModel.dragName(file), progress: Progress())
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent))
    }
}

struct CreatePublicLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Crear un enlace público con iCloudy"
    static let description = IntentDescription("Crea un enlace de solo lectura a un archivo o carpeta y lo devuelve. Cualquiera que tenga el enlace podrá verlo.")
    static let openAppWhenRun = false

    @Parameter(title: "Cuenta") var account: AccountEntity
    @Parameter(title: "Elemento", description: "Ruta desde el principio de la cuenta.")
    var path: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let model = try await ColdStart.model()
        let account = try model.connectedAccount(account)
        guard let file = try await model.resolve(path: path, in: account).file else { throw CloudError.message(L("Indica un archivo o una carpeta.")) }
        if let reason = account.limitation(.publicLink, for: [file]) { throw CloudError.message(reason) }
        let link = try await model.client(account).publicLink(for: file)
        return .result(value: link, dialog: IntentDialog(stringLiteral: L("Enlace público de «\(file.name)» creado.")))
    }
}

struct CopyBetweenCloudsIntent: AppIntent {
    static let title: LocalizedStringResource = "Copiar entre nubes con iCloudy"
    static let description = IntentDescription("Pone en cola la copia de un archivo o carpeta de una cuenta a una carpeta de otra. La copia sigue en iCloudy, con verificación, aunque el atajo termine.")
    static let openAppWhenRun = false

    @Parameter(title: "Desde la cuenta") var source: AccountEntity
    @Parameter(title: "Elemento", description: "Ruta desde el principio de la cuenta de origen.")
    var path: String
    @Parameter(title: "A la cuenta") var target: AccountEntity
    @Parameter(title: "Carpeta de destino", description: "Ruta desde el principio de la cuenta de destino. Vacía para el principio.", default: "")
    var destination: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        let from = try model.connectedAccount(source), to = try model.connectedAccount(target)
        guard from.id != to.id else { throw CloudError.message(L("Elige dos cuentas distintas. Dentro de una misma cuenta, usa Mover o Copiar en iCloudy.")) }
        guard let file = try await model.resolve(path: path, in: from).file else { throw CloudError.message(L("Indica un archivo o una carpeta.")) }
        let place = try await model.resolve(path: destination, in: to)
        if let folder = place.file, !folder.isFolder { throw CloudError.message(L("«\(folder.name)» es un archivo, no una carpeta.")) }
        let jobs = model.enqueueCrossCloud([file], from: from, to: to, parent: place.folderID, destinationPath: place.trail, seeds: nil)
        guard !jobs.isEmpty else { throw CloudError.message(model.error ?? L("La cola no aceptó la copia.")) }
        return .result(dialog: IntentDialog(stringLiteral: L("«\(file.name)» en cola hacia \(model.accountTitle(to)).")))
    }
}
