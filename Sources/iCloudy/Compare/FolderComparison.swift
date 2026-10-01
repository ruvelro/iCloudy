import Foundation

/// How a name is compared across two providers. macOS hands out names in decomposed Unicode (NFD) from older
/// volumes and from many apps, while the clouds keep whatever they were sent, so "Canción" can arrive spelled two
/// ways that look identical and compare different. Case is a provider matter: OneDrive, Dropbox, Box and a default
/// APFS volume treat "Informe" and "informe" as one name; Drive, Mega and a Unix server keep both.
enum ComparisonKey {
    static func key(_ name: String, caseSensitive: Bool) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        return caseSensitive ? composed : composed.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// Whether the provider keeps two items whose names differ only in case. WebDAV and O2 depend on the server
    /// behind them; both are taken as sensitive, which at worst reports a pair as one item on each side.
    static func caseSensitive(_ cloud: Cloud) -> Bool {
        switch cloud {
        case .microsoft, .dropbox, .box: return false
        case .volume: return false
        case .google, .mega, .webdav, .ftp, .sftp, .o2: return true
        }
    }
}

enum ComparisonSide: Hashable { case a, b }

enum IdentityEvidence: Hashable {
    /// Both sides gave the same digest in one algorithm, listed by the provider or computed here.
    case hash(ContentHash.Algorithm)
    /// Same size and the same modification date, with no digest both sides share. Very likely the same file.
    case sizeAndDate
}

enum DifferenceReason: Hashable { case size, hash, kind }

enum UnconfirmedReason: Hashable {
    /// A Google document has neither size nor checksum: nothing to compare it with.
    case googleDocument
    /// Same size, different dates, and no digest to settle it. A copy made by an app that does not keep dates looks
    /// exactly like this, so it is not called different.
    case sameSizeDifferentDate
    /// The provider did not list a size.
    case unknownSize
}

enum ComparisonStatus: Hashable {
    case onlyInA, onlyInB
    case identical(IdentityEvidence)
    case different(DifferenceReason, newer: ComparisonSide?)
    case unconfirmed(UnconfirmedReason)

    var group: ComparisonGroup {
        switch self {
        case .onlyInA: return .onlyInA
        case .onlyInB: return .onlyInB
        case .identical: return .identical
        case .different: return .different
        case .unconfirmed: return .unconfirmed
        }
    }
}

enum ComparisonGroup: String, CaseIterable, Identifiable {
    case onlyInA, onlyInB, different, unconfirmed, identical
    var id: String { rawValue }
}

/// One line of a comparison: a file or folder present on one side, or a pair of files under the same name.
struct ComparisonRow: Identifiable {
    let id: Int
    /// Relative to the compared folders, spelled as on side A when it has the item.
    let path: String
    let a: InventoryEntry?
    let b: InventoryEntry?
    /// The folder that holds the item on each side; nil is that side's compared folder. A copy lands there.
    let parentA: InventoryEntry?
    let parentB: InventoryEntry?
    let status: ComparisonStatus
    /// The two names match only once case is ignored.
    var caseDiffers = false
    /// Folder the row lives in, relative to the compared folders; empty at the top.
    var directory: String { path.split(separator: "/").dropLast().joined(separator: "/") }
}

/// The pure part of comparing one folder with another: pairing names, and deciding what each pair is.
enum FolderComparison {
    /// Dates within this many seconds count as the same: FAT and FTP keep two-second or one-second stamps, and
    /// several providers drop the fraction.
    static let dateTolerance: TimeInterval = 2

    struct Match {
        var pairs: [(a: InventoryEntry, b: InventoryEntry)] = []
        var onlyA: [InventoryEntry] = []
        var onlyB: [InventoryEntry] = []
    }

    /// Pairs the children of two folders by name. Drive lets one folder hold two items with the same name, so a
    /// name can match more than once: an exact spelling wins, then an item of the same kind, and whatever is left
    /// over is reported on its own side rather than guessed at.
    static func match(_ left: [InventoryEntry], _ right: [InventoryEntry], caseSensitive: Bool) -> Match {
        var buckets: [String: [InventoryEntry]] = [:]
        for entry in right { buckets[ComparisonKey.key(entry.name, caseSensitive: caseSensitive), default: []].append(entry) }
        var result = Match()
        var unmatched = Array(left.indices)
        // Three passes, from the most to the least certain, so an early loose pairing never takes a partner that a
        // later item would have matched exactly.
        let rules: [(InventoryEntry, InventoryEntry) -> Bool] = [
            { $0.name.precomposedStringWithCanonicalMapping == $1.name.precomposedStringWithCanonicalMapping && $0.isFolder == $1.isFolder },
            { $0.isFolder == $1.isFolder },
            { _, _ in true },
        ]
        for rule in rules {
            unmatched = unmatched.filter { index in
                let entry = left[index], key = ComparisonKey.key(entry.name, caseSensitive: caseSensitive)
                guard var candidates = buckets[key], let found = candidates.firstIndex(where: { rule(entry, $0) }) else { return true }
                result.pairs.append((entry, candidates.remove(at: found)))
                buckets[key] = candidates
                return false
            }
        }
        result.onlyA = unmatched.map { left[$0] }
        result.onlyB = buckets.values.flatMap { $0 }
        let order: (InventoryEntry, InventoryEntry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.pairs.sort { order($0.a, $1.a) }
        result.onlyA.sort(by: order); result.onlyB.sort(by: order)
        return result
    }

    /// Decides what two files under the same name are. A digest beats everything; when the provider lists one and the
    /// other side is a folder of this Mac, the Mac's copy is hashed in the provider's algorithm, and only when the
    /// sizes already agree. `digest` returns nil when a file cannot be read, which leaves size and date to decide.
    static func classify(_ a: InventoryEntry, _ b: InventoryEntry, hashesA: Bool, hashesB: Bool,
                         digest: (ComparisonSide, ContentHash.Algorithm) async throws -> String?) async throws -> ComparisonStatus {
        if a.isFolder != b.isFolder { return .different(.kind, newer: nil) }
        if a.isGoogleDocument || b.isGoogleDocument { return .unconfirmed(.googleDocument) }
        if let left = a.size, let right = b.size, left != right { return .different(.size, newer: newer(a, b)) }
        if let left = a.checksum, let right = b.checksum, left.algorithm == right.algorithm {
            return left.matches(right.value) ? .identical(.hash(left.algorithm)) : .different(.hash, newer: newer(a, b))
        }
        guard a.size != nil, b.size != nil else { return .unconfirmed(.unknownSize) }
        if let listed = b.checksum, hashesA, let computed = try await digest(.a, listed.algorithm) {
            return listed.matches(computed) ? .identical(.hash(listed.algorithm)) : .different(.hash, newer: newer(a, b))
        }
        if let listed = a.checksum, hashesB, let computed = try await digest(.b, listed.algorithm) {
            return listed.matches(computed) ? .identical(.hash(listed.algorithm)) : .different(.hash, newer: newer(a, b))
        }
        if a.checksum == nil, b.checksum == nil, hashesA, hashesB,
           let left = try await digest(.a, .sha256), let right = try await digest(.b, .sha256) {
            return left == right ? .identical(.hash(.sha256)) : .different(.hash, newer: newer(a, b))
        }
        if let left = a.modified, let right = b.modified, abs(left.timeIntervalSince(right)) <= dateTolerance { return .identical(.sizeAndDate) }
        return .unconfirmed(.sameSizeDifferentDate)
    }

    /// The side modified later, when both dates are known and far enough apart to mean something.
    static func newer(_ a: InventoryEntry, _ b: InventoryEntry) -> ComparisonSide? {
        guard let left = a.modified, let right = b.modified, abs(left.timeIntervalSince(right)) > dateTolerance else { return nil }
        return left > right ? .a : .b
    }
}

/// Everything a comparison has found so far, with a ceiling on how much of it is kept. Identical files are the
/// bulk of any large tree and the least interesting part, so past a limit they are counted and not stored.
struct ComparisonResult {
    let rowLimit: Int
    let identicalLimit: Int
    private(set) var rows: [ComparisonRow] = []
    private(set) var counts: [ComparisonGroup: Int] = [:]
    private(set) var bytes: [ComparisonGroup: Int64] = [:]
    /// Rows counted in the totals but not kept.
    private(set) var omitted = 0
    /// Rows that involve a Google document, which has no size or checksum to compare.
    private(set) var googleDocuments = 0
    private var storedIdentical = 0

    init(rowLimit: Int = 100_000, identicalLimit: Int = 20_000) {
        self.rowLimit = rowLimit; self.identicalLimit = identicalLimit
    }

    /// Adds a batch and returns the rows that were kept, in order, so a view can append them without filtering
    /// everything again.
    @discardableResult
    mutating func add(_ batch: [ComparisonRow]) -> [ComparisonRow] {
        var kept: [ComparisonRow] = []
        for row in batch {
            let group = row.status.group
            counts[group, default: 0] += 1
            bytes[group, default: 0] += (row.a?.size ?? row.b?.size ?? 0)
            if row.a?.isGoogleDocument == true || row.b?.isGoogleDocument == true { googleDocuments += 1 }
            if rows.count >= rowLimit || (group == .identical && storedIdentical >= identicalLimit) { omitted += 1; continue }
            if group == .identical { storedIdentical += 1 }
            rows.append(row); kept.append(row)
        }
        return kept
    }
    func count(_ group: ComparisonGroup) -> Int { counts[group] ?? 0 }
    var total: Int { counts.values.reduce(0, +) }
}

extension ContentHash.Algorithm {
    /// Names of algorithms, which are the same in every language.
    var title: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .quickXor: return "QuickXorHash"
        case .dropbox: return "content_hash"
        }
    }
}

extension ComparisonGroup {
    var title: String {
        switch self {
        case .onlyInA: return L("Solo en A")
        case .onlyInB: return L("Solo en B")
        case .different: return L("Distintos")
        case .unconfirmed: return L("Sin confirmar")
        case .identical: return L("Idénticos")
        }
    }
    var symbol: String {
        switch self {
        case .onlyInA: return "arrow.left.circle"
        case .onlyInB: return "arrow.right.circle"
        case .different: return "exclamationmark.triangle"
        case .unconfirmed: return "questionmark.circle"
        case .identical: return "checkmark.circle"
        }
    }
}

extension ComparisonStatus {
    var title: String {
        switch self {
        case .onlyInA: return L("Solo en A")
        case .onlyInB: return L("Solo en B")
        case .identical(.hash(let algorithm)): return L("Idéntico · \(algorithm.title)")
        case .identical(.sizeAndDate): return L("Probablemente idéntico · mismo tamaño y fecha")
        case .different(.kind, _): return L("Carpeta en un lado y archivo en el otro")
        case .different(let reason, let newer):
            let what = reason == .size ? L("Tamaño distinto") : L("Contenido distinto")
            switch newer {
            case .a: return what + " · " + L("más reciente en A")
            case .b: return what + " · " + L("más reciente en B")
            case nil: return what
            }
        case .unconfirmed(.googleDocument): return L("Documento de Google: sin tamaño ni hash que comparar")
        case .unconfirmed(.sameSizeDifferentDate): return L("Mismo tamaño y fecha distinta; sin hash que lo confirme")
        case .unconfirmed(.unknownSize): return L("El proveedor no informa del tamaño")
        }
    }
}
