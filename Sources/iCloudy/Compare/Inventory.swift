import Foundation

/// One item on either side of a comparison, in a cloud or on this Mac, reduced to what comparing needs.
struct InventoryEntry: Identifiable, Hashable {
    enum Location: Hashable { case cloud(CloudFile), local(URL) }
    let name: String
    let isFolder: Bool
    /// nil when the provider does not say, and always for a Google document, whose listed size means nothing.
    let size: Int64?
    let modified: Date?
    let checksum: ContentHash?
    let isGoogleDocument: Bool
    let location: Location

    var id: String {
        switch location {
        case .cloud(let file): return "cloud:" + file.id
        case .local(let url): return "local:" + url.standardizedFileURL.path
        }
    }
    var file: CloudFile? { if case .cloud(let file) = location { return file } else { return nil } }
    var url: URL? { if case .local(let url) = location { return url } else { return nil } }

    init(file: CloudFile) {
        name = file.name; isFolder = file.isFolder
        size = file.isFolder || file.isGoogleDocument ? nil : file.size
        modified = file.modified; checksum = file.checksum; isGoogleDocument = file.isGoogleDocument
        location = .cloud(file)
    }
    init(url: URL, isFolder: Bool, size: Int64?, modified: Date?) {
        name = url.lastPathComponent; self.isFolder = isFolder
        self.size = isFolder ? nil : size
        self.modified = modified; checksum = nil; isGoogleDocument = false
        location = .local(url)
    }
}

/// Where a comparison or a duplicate search reads its tree from. Every listing goes through here, so pacing and
/// retries live in one place and tests can stand in a tree of their own. Sendable because every source is a
/// main-actor class: the engine lists both sides at once with `async let`, which hands the source to a child task.
@MainActor
protocol InventorySource: AnyObject, Sendable {
    /// Whether two names that differ only in case are two different items on this side.
    var caseSensitive: Bool { get }
    /// True when this side can hash its own bytes in any algorithm: a Mac folder, or a volume account.
    var hashesLocally: Bool { get }
    /// Children of `folder`, or of the root when it is nil.
    func children(of folder: InventoryEntry?) async throws -> [InventoryEntry]
    /// Digest of a file's bytes in `algorithm`. Only asked of sources that hash locally.
    func digest(of entry: InventoryEntry, algorithm: ContentHash.Algorithm) async throws -> String
}

/// Spaces listing requests to one account. A recursive walk of a large tree is thousands of calls in a row, and a
/// provider that sees them arrive back to back starts answering 429; spacing them costs less than the back-off.
/// Requests reserve their slot before sleeping, so two walks of the same account share the budget.
@MainActor
final class ListingPacer {
    let interval: Duration
    private var next: ContinuousClock.Instant?
    private static var shared: [String: ListingPacer] = [:]

    init(interval: Duration) { self.interval = interval }

    /// One pacer per account, whichever window or side is walking it.
    static func shared(for accountID: String, interval: Duration = .milliseconds(100)) -> ListingPacer {
        if let pacer = shared[accountID] { return pacer }
        let pacer = ListingPacer(interval: interval)
        shared[accountID] = pacer
        return pacer
    }

    func wait() async throws {
        let clock = ContinuousClock(), now = clock.now
        let slot = max(now, next ?? now)
        next = slot.advanced(by: interval)
        if slot > now { try await Task.sleep(until: slot, clock: clock) }
    }
}

/// Repeats a listing that failed for a reason worth waiting out: a rate limit, a 5xx or a dropped connection. The
/// providers already repeat each request a few times; this covers the walk as a whole, so the hundredth folder of a
/// long comparison does not throw away the ninety-nine before it over one bad minute.
@MainActor
enum ListingRetry {
    static func run<T>(attempts: Int = 3, base: Double = 2,
                       sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                       _ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await work() }
            catch {
                guard attempt < attempts, !(error is CancellationError),
                      TransferQueue.outcome(for: error, attempts: 0, online: true) == .retry else { throw error }
                try await sleep(TransferQueue.retryWait(after: error, attempt: attempt, base: base))
                attempt += 1
            }
        }
    }
}

/// A folder of a connected account. Volume accounts are folders of this Mac under the hood, so they hash locally.
@MainActor
final class CloudInventorySource: InventorySource {
    let api: CloudAPI
    let rootID: String
    private let pacer: ListingPacer

    init(api: CloudAPI, rootID: String, pacer: ListingPacer? = nil) {
        self.api = api; self.rootID = rootID
        self.pacer = pacer ?? (api.demo != nil ? ListingPacer(interval: .zero) : ListingPacer.shared(for: api.account.id))
    }

    private var volume: VolumeProvider? { api.demo == nil ? api.provider as? VolumeProvider : nil }

    var caseSensitive: Bool {
        if let volume, let root = try? volume.volumeRoot() { return LocalInventorySource.caseSensitive(root) }
        return ComparisonKey.caseSensitive(api.account.cloud)
    }
    var hashesLocally: Bool { volume != nil }

    func children(of folder: InventoryEntry?) async throws -> [InventoryEntry] {
        let parent = folder?.file?.id ?? rootID
        return try await ListingRetry.run {
            try await pacer.wait()
            return try await api.list(parent: parent).map(InventoryEntry.init(file:))
        }
    }

    func digest(of entry: InventoryEntry, algorithm: ContentHash.Algorithm) async throws -> String {
        guard let volume, let file = entry.file else { throw CloudError.message(L("Esta cuenta no permite calcular el hash de sus archivos.")) }
        let url = try volume.volumeURL(file.id)
        return try await blockingIO { try ContentHasher.digest(of: url, algorithm: algorithm).digest }
    }
}

/// A folder of this Mac, chosen in an open panel. Finder bookkeeping files are left out: they exist on one side only
/// by nature and would bury the real differences.
@MainActor
final class LocalInventorySource: InventorySource {
    let root: URL
    let caseSensitive: Bool
    let hashesLocally = true
    private let scoped: Bool

    init(root: URL) {
        self.root = root
        scoped = root.startAccessingSecurityScopedResource()
        caseSensitive = Self.caseSensitive(root)
    }
    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }

    nonisolated static func caseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
    }

    nonisolated static func ignored(_ name: String) -> Bool {
        [".DS_Store", ".localized", "Icon\r"].contains(name) || name.hasPrefix("._")
    }

    func children(of folder: InventoryEntry?) async throws -> [InventoryEntry] {
        let directory = folder?.url ?? root
        return try await blockingIO { try Self.list(directory) }
    }

    nonisolated static func list(_ directory: URL) throws -> [InventoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: []).compactMap { url in
            guard !ignored(url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            // A link points somewhere else; following it could walk out of the folder or round in a circle.
            if values.isSymbolicLink == true { return nil }
            guard values.isDirectory == true || values.isRegularFile == true else { return nil }
            return InventoryEntry(url: url, isFolder: values.isDirectory == true, size: values.fileSize.map(Int64.init), modified: values.contentModificationDate)
        }
    }

    func digest(of entry: InventoryEntry, algorithm: ContentHash.Algorithm) async throws -> String {
        guard let url = entry.url else { throw CloudError.message(L("Ese elemento no está en este Mac.")) }
        return try await blockingIO { try ContentHasher.digest(of: url, algorithm: algorithm).digest }
    }
}
