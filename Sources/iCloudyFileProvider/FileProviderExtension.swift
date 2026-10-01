// The framework's completion handlers and observers predate Swift concurrency and carry no Sendable annotations,
// although the File Provider documentation allows calling them from any queue.
@preconcurrency import FileProvider
import UniformTypeIdentifiers
import iCloudy

/// A completion handler or observer handed to the main actor. File Provider callbacks may be invoked from any thread,
/// once, which is the invariant that makes carrying one across isolation domains safe; the SDK simply does not say so
/// in its signatures yet.
struct FinderCallback<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The backend is created lazily, on the main actor, the only place it is ever touched. Keeping it in a main-actor
/// box leaves the extension itself with immutable, Sendable state, so the tasks it starts can capture it.
@MainActor
private final class BackendSlot {
    var backend: FileProviderBackend?
    /// The system creates the extension on a queue of its own choosing; nothing isolated is touched here.
    nonisolated init() {}
}

/// One connected account, shown by the Finder as a location. Each domain the app registers maps to one account;
/// the extension answers the Finder's questions by asking the same providers the app uses, through
/// `FileProviderBackend`, and keeps an index of what it has listed so an item can be named by identifier alone.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, Sendable {
    let domain: NSFileProviderDomain
    let index: FileProviderIndex
    private let slot: BackendSlot

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let manager = NSFileProviderManager(for: domain)
        let base = (try? manager?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        index = FileProviderIndex(url: base.deletingLastPathComponent().appendingPathComponent("iCloudy-index-\(domain.identifier.rawValue.hashValue).json"))
        slot = BackendSlot()
        super.init()
    }
    func invalidate() {}

    @MainActor private func backend() throws -> FileProviderBackend {
        if let backend = slot.backend { return backend }
        guard let created = FileProviderBackend(accountID: domain.identifier.rawValue) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        slot.backend = created
        return created
    }
    private func run(_ work: @escaping @MainActor @Sendable () async throws -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task { @MainActor in
            do { try await work() } catch { }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    static func identifier(_ id: NSFileProviderItemIdentifier) -> String {
        id == .rootContainer ? FPItem.rootID : id.rawValue
    }
    private func known(_ id: NSFileProviderItemIdentifier) -> FPItem? {
        if id == .rootContainer { return FileProviderItem.rootRecord }
        return index.item(id.rawValue)
    }

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer || identifier == .workingSet || identifier == .trashContainer {
            completionHandler(FileProviderItem(FileProviderItem.rootRecord), nil)
            return Progress()
        }
        if let item = index.item(identifier.rawValue) { completionHandler(FileProviderItem(item), nil); return Progress() }
        completionHandler(nil, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let item = index.item(itemIdentifier.rawValue), !item.isFolder else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return Progress()
        }
        let base = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        let destination = base.appendingPathComponent(UUID().uuidString)
        let reply = FinderCallback(completionHandler)
        return run { [self] in
            do {
                try await backend().download(item, to: destination)
                reply.value(destination, FileProviderItem(item), nil)
            } catch { reply.value(nil, nil, Self.translate(error)) }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let parent = Self.identifier(itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        let folder = itemTemplate.contentType == .folder
        let reply = FinderCallback(completionHandler)
        return run { [self] in
            do {
                let created: FPItem
                if folder { created = try await backend().createFolder(named: name, in: parent) }
                else {
                    guard let url else { throw NSFileProviderError(.noSuchItem) }
                    created = try await backend().upload(url, named: name, in: parent, replacing: nil)
                }
                index.remember([created])
                reply.value(FileProviderItem(created), [], false, nil)
            } catch { reply.value(nil, [], false, Self.translate(error)) }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let identifier = item.itemIdentifier.rawValue
        guard let original = index.item(identifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem)); return Progress()
        }
        let newName = item.filename, newParent = Self.identifier(item.parentItemIdentifier)
        let reply = FinderCallback(completionHandler)
        return run { [self] in
            var current = original
            do {
                let backend = try backend()
                if changedFields.contains(.filename), newName != current.name { current = try await backend.rename(current, to: newName) }
                if changedFields.contains(.parentItemIdentifier), newParent != current.parentID { current = try await backend.move(current, to: newParent) }
                if changedFields.contains(.contents), let newContents, !current.isFolder {
                    current = try await backend.upload(newContents, named: current.name, in: current.parentID, replacing: current.id)
                }
                index.forget(identifier)
                index.remember([current])
                reply.value(FileProviderItem(current), [], false, nil)
            } catch { reply.value(nil, [], false, Self.translate(error)) }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let item = index.item(identifier.rawValue) else { completionHandler(NSFileProviderError(.noSuchItem)); return Progress() }
        let key = identifier.rawValue, reply = FinderCallback(completionHandler)
        return run { [self] in
            do {
                try await backend().delete(item)
                index.forget(key)
                reply.value(nil)
            } catch { reply.value(Self.translate(error)) }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet || containerItemIdentifier == .trashContainer { return EmptyEnumerator() }
        return FolderEnumerator(extension: self, folder: Self.identifier(containerItemIdentifier))
    }

    static func translate(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if (error as? CancellationError) != nil { return NSFileProviderError(.cannotSynchronize) }
        let text = error.localizedDescription.lowercased()
        if text.contains("caducado") || text.contains("expired") || text.contains("vuelve a conectar") { return NSFileProviderError(.notAuthenticated) }
        if text.contains("no existe") || text.contains("no encuentra") || text.contains("ya no está") { return NSFileProviderError(.noSuchItem) }
        return NSFileProviderError(.serverUnreachable)
    }
}

/// A folder's contents, listed from the provider and remembered in the index.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private weak var owner: FileProviderExtension?
    private let folder: String
    private var task: Task<Void, Never>?
    init(extension owner: FileProviderExtension, folder: String) { self.owner = owner; self.folder = folder }
    func invalidate() { task?.cancel() }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let owner else { observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize)); return }
        let folder = folder, reply = FinderCallback(observer)
        task = Task { @MainActor in
            do {
                let items = try await owner.backendForEnumeration().list(folder: folder)
                owner.index.replaceChildren(of: folder, with: items)
                reply.value.didEnumerate(items.map(FileProviderItem.init))
                reply.value.finishEnumerating(upTo: nil)
            } catch { reply.value.finishEnumeratingWithError(FileProviderExtension.translate(error)) }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // The providers push no change feed; the Finder re-enumerates when it needs to.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data(String(Int(Date().timeIntervalSince1970)).utf8)))
    }
}

/// The working set and the trash: nothing to list, and the Finder must not wait for it.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) { observer.finishEnumerating(upTo: nil) }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) { observer.finishEnumeratingChanges(upTo: anchor, moreComing: false) }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) { completionHandler(NSFileProviderSyncAnchor(Data("0".utf8))) }
}

extension FileProviderExtension {
    @MainActor func backendForEnumeration() throws -> FileProviderBackend { try backend() }
}

/// `FPItem` in the shape the Finder wants.
final class FileProviderItem: NSObject, NSFileProviderItem {
    static let rootRecord = FPItem(id: FPItem.rootID, parentID: FPItem.rootID, name: "iCloudy", isFolder: true, size: nil, modified: nil, contentType: UTType.folder.identifier)
    let record: FPItem
    init(_ record: FPItem) { self.record = record }
    var itemIdentifier: NSFileProviderItemIdentifier { record.id == FPItem.rootID ? .rootContainer : NSFileProviderItemIdentifier(record.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { record.parentID == FPItem.rootID ? .rootContainer : NSFileProviderItemIdentifier(record.parentID) }
    var filename: String { record.name }
    var contentType: UTType { UTType(record.contentType) ?? (record.isFolder ? .folder : .data) }
    var documentSize: NSNumber? { record.size.map(NSNumber.init(value:)) }
    var contentModificationDate: Date? { record.modified }
    var creationDate: Date? { record.modified }
    var capabilities: NSFileProviderItemCapabilities {
        record.isFolder ? [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsAddingSubItems, .allowsContentEnumerating]
                        : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }
    var itemVersion: NSFileProviderItemVersion {
        let stamp = Data(("\(record.size ?? -1)|\(record.modified?.timeIntervalSince1970 ?? 0)").utf8)
        return NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: Data(record.name.utf8))
    }
}
