import Foundation
import UniformTypeIdentifiers
#if canImport(FileProvider)
import FileProvider
#endif

/// One item as the Finder extension sees it: enough to draw a row and to find its way back to the provider.
/// `CloudFile` carries no parent, and the extension is asked about items by identifier alone, so the parent is
/// remembered here from the listing that produced the item.
public struct FPItem: Codable, Hashable, Sendable {
    public let id: String
    public let parentID: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64?
    public let modified: Date?
    /// Uniform type identifier, e.g. `public.jpeg`; `public.folder` for folders.
    public let contentType: String
    public init(id: String, parentID: String, name: String, isFolder: Bool, size: Int64?, modified: Date?, contentType: String) {
        self.id = id; self.parentID = parentID; self.name = name; self.isFolder = isFolder; self.size = size; self.modified = modified; self.contentType = contentType
    }
    init(_ file: CloudFile, parent: String) {
        let type = file.isFolder ? UTType.folder : (UTType(mimeType: file.mime) ?? UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
        self.init(id: file.id, parentID: parent, name: file.name, isFolder: file.isFolder, size: file.size, modified: file.modified, contentType: type.identifier)
    }
    func cloudFile() -> CloudFile {
        CloudFile(id: id, name: name, mime: isFolder ? "application/vnd.google-apps.folder" : (UTType(contentType)?.preferredMIMEType ?? "application/octet-stream"),
                  size: size, modified: modified, webURL: nil, isFolder: isFolder)
    }
    /// The alias the providers understand for the top of an account.
    public static let rootID = "root"
}

/// Items the extension has seen, by identifier, written to disk so a relaunch of the extension process still
/// knows where every item lives. The Finder asks for items one at a time and expects an answer without a listing.
public final class FileProviderIndex: @unchecked Sendable {
    private let url: URL
    private var items: [String: FPItem]
    private let lock = NSLock()
    public init(url: URL) {
        self.url = url
        items = (try? JSONDecoder().decode([String: FPItem].self, from: Data(contentsOf: url))) ?? [:]
    }
    public func item(_ id: String) -> FPItem? { lock.withLock { items[id] } }
    public func remember(_ fresh: [FPItem]) {
        lock.withLock { for item in fresh { items[item.id] = item } }
        persist()
    }
    /// Replaces the known children of a folder with a new listing, so items gone from the cloud go from here too.
    public func replaceChildren(of parent: String, with fresh: [FPItem]) {
        lock.withLock {
            items = items.filter { $0.value.parentID != parent }
            for item in fresh { items[item.id] = item }
        }
        persist()
    }
    public func forget(_ id: String) {
        lock.withLock { items[id] = nil; items = items.filter { !$0.value.parentID.hasPrefix(id) || $0.value.parentID != id } }
        persist()
    }
    public func children(of parent: String) -> [FPItem] { lock.withLock { items.values.filter { $0.parentID == parent } } }
    private func persist() {
        let snapshot = lock.withLock { items }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}

/// What the app and the extension share, and where. Both live in different sandboxes, so the only ground they have
/// in common is an App Group container; its identifier comes from the bundle, where the build script writes it
/// once a Team ID exists. Without one, nothing is exported and the extension has nothing to show.
public enum FileProviderShared {
    public static var groupIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "iCloudyAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    public static func containerURL() -> URL? {
        guard let group = groupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("FileProvider", isDirectory: true)
    }
    /// The accounts the extension may present: identity and address only, never a secret. Credentials stay in the
    /// Keychain, which the two processes share through their keychain access group.
    struct ExportedAccount: Codable, Equatable {
        let id: String, cloud: String, name: String, email: String, serverURL: String?, options: [String: String]
    }
    static func export(_ accounts: [Account]) {
        guard let container = containerURL() else { return }
        let exported = accounts.filter { !$0.isDemo }.map { ExportedAccount(id: $0.id, cloud: $0.cloud.rawValue, name: $0.name, email: $0.email, serverURL: $0.serverURL, options: $0.options) }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(exported) { try? data.write(to: container.appendingPathComponent("accounts.json"), options: .atomic) }
    }
    static func importAccounts() -> [Account] {
        guard let container = containerURL(), let data = try? Data(contentsOf: container.appendingPathComponent("accounts.json")),
              let exported = try? JSONDecoder().decode([ExportedAccount].self, from: data) else { return [] }
        return exported.compactMap { record in
            guard let cloud = Cloud(rawValue: record.cloud) else { return nil }
            return Account(id: record.id, cloud: cloud, name: record.name, email: record.email, clientID: "", clientSecret: nil,
                           serverURL: record.serverURL, bookmark: nil, options: record.options)
        }
    }
    /// Identifier and display name of every domain the Finder should show for these accounts.
    static func domains(for accounts: [Account]) -> [(id: String, name: String)] {
        accounts.filter { !$0.isDemo && $0.cloud != .volume }.map { ($0.id, $0.cloud.title + " · " + $0.email) }
    }
}

/// The extension's door into the providers. It runs on the main actor like every provider does; the extension
/// hops onto it from the Finder's callbacks.
@MainActor
public final class FileProviderBackend {
    private let api: CloudAPI
    public let accountID: String
    public init?(accountID: String) {
        guard let account = FileProviderShared.importAccounts().first(where: { $0.id == accountID }) else { return nil }
        self.accountID = accountID
        api = CloudAPI(account: account)
    }
    init(api: CloudAPI) { self.api = api; accountID = api.account.id }

    public func list(folder: String) async throws -> [FPItem] {
        try await api.list(parent: folder).map { FPItem($0, parent: folder) }
    }
    public func download(_ item: FPItem, to destination: URL) async throws {
        try await api.download(file: item.cloudFile(), to: destination)
    }
    public func createFolder(named name: String, in parent: String) async throws -> FPItem {
        let id = try await api.createFolder(name: name, parent: parent)
        return FPItem(id: id, parentID: parent, name: name, isFolder: true, size: nil, modified: Date(), contentType: UTType.folder.identifier)
    }
    public func upload(_ local: URL, named name: String, in parent: String, replacing: String?) async throws -> FPItem {
        let receipt = try await api.resumableUpload(local: local, parent: parent, name: name, replacing: replacing, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        let values = try? local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        guard let remoteID = receipt.remoteID else { throw CloudError.message(L("El proveedor no devolvió el identificador del archivo subido.")) }
        return FPItem(id: remoteID, parentID: parent, name: name, isFolder: false, size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate ?? Date(), contentType: type.identifier)
    }
    public func rename(_ item: FPItem, to name: String) async throws -> FPItem {
        let file = item.cloudFile()
        try await api.rename(file: file, name: name)
        let change = try api.provider.identityChange(file: file, name: name, destination: nil)
        return FPItem(id: change.newID, parentID: item.parentID, name: name, isFolder: item.isFolder, size: item.size, modified: item.modified, contentType: item.contentType)
    }
    public func move(_ item: FPItem, to parent: String) async throws -> FPItem {
        let file = item.cloudFile()
        try await api.move(file: file, to: parent)
        let change = try api.provider.identityChange(file: file, name: item.name, destination: parent)
        return FPItem(id: change.newID, parentID: parent, name: item.name, isFolder: item.isFolder, size: item.size, modified: item.modified, contentType: item.contentType)
    }
    public func delete(_ item: FPItem) async throws {
        try await api.trash(file: item.cloudFile())
    }
}

#if canImport(FileProvider)
/// App side: keeps the Finder's list of domains equal to the list of connected accounts while the person wants
/// the integration on. Nothing happens unless the extension is inside the bundle, which only the build with a Team
/// ID produces.
@MainActor
enum FileProviderDomains {
    static var extensionPresent: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("iCloudyFileProvider.appex").path)
    }
    /// Which domains to add and which to remove to go from `current` to what `accounts` and `enabled` call for.
    static func changes(current: [String], accounts: [Account], enabled: Bool) -> (add: [(id: String, name: String)], remove: [String]) {
        let wanted = enabled ? FileProviderShared.domains(for: accounts) : []
        let wantedIDs = Set(wanted.map(\.id))
        return (wanted.filter { !current.contains($0.id) }, current.filter { !wantedIDs.contains($0) })
    }
    static func sync(accounts: [Account], enabled: Bool) async {
        guard extensionPresent, FileProviderShared.groupIdentifier != nil else { return }
        FileProviderShared.export(accounts)
        let current = (try? await NSFileProviderManager.domains()) ?? []
        let plan = changes(current: current.map(\.identifier.rawValue), accounts: accounts, enabled: enabled)
        for domain in plan.add {
            try? await NSFileProviderManager.add(NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(domain.id), displayName: domain.name))
        }
        for id in plan.remove {
            if let domain = current.first(where: { $0.identifier.rawValue == id }) { try? await NSFileProviderManager.remove(domain) }
        }
    }
}
#endif

extension AppModel {
    /// True only in a build that carries the extension, which is the signed one.
    var finderIntegrationAvailable: Bool {
        #if canImport(FileProvider)
        return FileProviderDomains.extensionPresent && FileProviderShared.groupIdentifier != nil
        #else
        return false
        #endif
    }
    func syncFinderDomains() {
        #if canImport(FileProvider)
        guard finderIntegrationAvailable else { return }
        let accounts = self.accounts
        Task { await FileProviderDomains.sync(accounts: accounts, enabled: Prefs.bool(Prefs.finderIntegration, default: false)) }
        #endif
    }
}
