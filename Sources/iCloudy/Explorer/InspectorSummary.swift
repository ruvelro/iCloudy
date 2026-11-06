import AppKit

/// What the inspector (⌘I) shows for the focused tab's selection, worked out here so it can be tested without a window.
struct InspectorSummary: Equatable {
    struct Item: Equatable {
        let file: CloudFile
        let accountID: String
        let accountTitle: String
        let kind: String
        /// «Cuenta:/Carpeta/archivo», which Go to Folder reads back.
        let address: String
        let checksum: ContentHash?
        let local: LocalCopyStatus
        let offline: OfflineStatus?
        let editing: String?
        /// The provider keeps versions of files, so the inspector asks how many.
        let hasVersions: Bool
        /// The provider lists the public links of an item, so the inspector asks whether there are any.
        let listsLinks: Bool
    }
    struct Totals: Equatable {
        let count: Int
        let folders: Int
        let files: Int
        /// Bytes of the files whose size the provider listed; folders have none.
        let bytes: Int64
        /// Files listed without a size, which the total leaves out.
        let unknownSizes: Int
    }
    enum Content: Equatable {
        case nothing
        case single(Item)
        case many(Totals)
    }
    let content: Content

    static func totals(_ files: [CloudFile]) -> Totals {
        let plain = files.filter { !$0.isFolder }
        return Totals(count: files.count, folders: files.count - plain.count, files: plain.count,
                      bytes: plain.reduce(0) { $0 + ($1.size ?? 0) }, unknownSizes: plain.filter { $0.size == nil }.count)
    }
}

extension AppModel {
    /// The inspector's figures for what the focused tab has selected among the rows it shows.
    func inspectorSummary() -> InspectorSummary {
        let tab = workspace.current
        let files = Self.selected(tab.selection, among: tab.visibleFiles)
        guard !files.isEmpty else { return InspectorSummary(content: .nothing) }
        guard files.count == 1, let file = files.first, let account = account(of: tab) else {
            return InspectorSummary(content: .many(InspectorSummary.totals(files)))
        }
        let capabilities = account.capabilities
        let item = InspectorSummary.Item(
            file: file, accountID: account.id, accountTitle: accountTitle(account) + " · " + account.email,
            kind: file.kindDescription, address: addressText(accountID: account.id, path: tab.path, file: file),
            checksum: file.checksum, local: localStatus(file, in: tab), offline: offlineStatus(file, in: tab),
            editing: editor.session(accountID: account.id, fileID: file.id)?.stateTitle,
            hasVersions: capabilities.versions && !file.isFolder && account.versionsLimitation(for: file) == nil,
            listsLinks: capabilities.links.manage && account.limitation(.publicLink, for: [file]) == nil)
        return InspectorSummary(content: .single(item))
    }

    /// How many earlier versions the provider keeps of the file, for the inspector. Nil when it cannot say.
    func versionCount(of file: CloudFile, accountID: String) async -> Int? {
        guard let account = browsable(accountID), let api = try? client(account) else { return nil }
        return try? await api.versions(of: file).count
    }

    /// How many public links the item has, for the inspector. Nil when the provider cannot list them.
    func publicLinkCount(of file: CloudFile, accountID: String) async -> Int? {
        guard let account = browsable(accountID), let api = try? client(account) else { return nil }
        return try? await api.publicLinks(for: file).count
    }

    /// «Copiar ruta»: the item's place as Go to Folder reads it.
    func copyPath(_ file: CloudFile) {
        let tab = workspace.current
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addressText(accountID: tab.accountID, path: tab.path, file: file), forType: .string)
    }
}
