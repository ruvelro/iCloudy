import Foundation

/// How one mirror or sync behaves beyond what it copies: what happens on a conflict, and the rest of its settings.
/// Every field has the value that reproduces what mirrors did before the setting existed.
struct MirrorOptions: Codable, Equatable, Sendable {
    /// nil is the mode's own default: keep both in two-way syncs, ask in one-way mirrors.
    var conflictPolicy: ConflictPolicy?
    /// One-way only, "espejo exacto": what is deleted at the source goes to the destination's trash too, as long as
    /// the mirror put it there and nobody changed it there since.
    var exact = false
    /// Two files are the same when their contents hash the same, where the provider lists a checksum to compare
    /// with; elsewhere size and date decide, as without this setting.
    var compareChecksums = false
    /// How often a verification pass looks at every mirrored file on both sides; nil never.
    var verifyEvery: TimeInterval?
    /// Uploads only: a file the cloud already holds with the same checksum is not sent again.
    var skipIdentical = false
    /// A run of its own every so often or once a day, besides what the folder's changes start.
    var schedule: SyncSchedule?

    init(conflictPolicy: ConflictPolicy? = nil, exact: Bool = false, compareChecksums: Bool = false, verifyEvery: TimeInterval? = nil,
         skipIdentical: Bool = false, schedule: SyncSchedule? = nil) {
        self.conflictPolicy = conflictPolicy; self.exact = exact; self.compareChecksums = compareChecksums; self.verifyEvery = verifyEvery
        self.skipIdentical = skipIdentical; self.schedule = schedule
    }
    enum CodingKeys: String, CodingKey { case conflictPolicy, exact, compareChecksums, verifyEvery, skipIdentical, schedule }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conflictPolicy = (try? values.decodeIfPresent(String.self, forKey: .conflictPolicy)).flatMap { $0.flatMap(ConflictPolicy.init(rawValue:)) }
        exact = try values.decodeIfPresent(Bool.self, forKey: .exact) ?? false
        compareChecksums = try values.decodeIfPresent(Bool.self, forKey: .compareChecksums) ?? false
        verifyEvery = try values.decodeIfPresent(TimeInterval.self, forKey: .verifyEvery)
        skipIdentical = try values.decodeIfPresent(Bool.self, forKey: .skipIdentical) ?? false
        // A kind of schedule added by a newer version is read as none.
        schedule = (try? values.decodeIfPresent(SyncSchedule.self, forKey: .schedule)) ?? nil
    }
}

extension FolderMirror {
    /// The sidebar's icon and the arrow before the remote location, by direction.
    var symbol: String {
        switch mode {
        case .upload: return "arrow.triangle.2.circlepath"
        case .twoWay: return "arrow.left.arrow.right"
        case .download: return "arrow.down.circle"
        case .cloudPair: return "cloud"
        }
    }
    /// The name the sidebar and the sheets give it: the local folder, or for a pair of clouds the first folder.
    var title: String { mode == .cloudPair ? (peerName ?? remoteName) : localURL.lastPathComponent }
    /// Changes travel both ways: two-way syncs and pairs of clouds.
    var isTwoWay: Bool { mode == .twoWay || mode == .cloudPair }
    var arrow: String {
        switch mode {
        case .upload: return "→"
        case .twoWay: return "⇄"
        case .download: return "←"
        case .cloudPair: return "⇄"
        }
    }
    /// The policy in force: the one chosen, or the mode's default.
    var conflictPolicy: ConflictPolicy {
        if let chosen = options.conflictPolicy { return chosen }
        return isTwoWay ? .keepBoth : .ask
    }
    /// The same policy in the terms of a one-way transfer, where "this side" is the source. A download mirror's
    /// source is the cloud, so the Mac winning is the destination winning. nil asks.
    var transferPolicy: ConflictPolicy? {
        let policy = conflictPolicy
        guard policy != .ask else { return nil }
        guard mode == .download else { return policy }
        switch policy {
        case .thisSideWins: return .otherSideWins
        case .otherSideWins: return .thisSideWins
        default: return policy
        }
    }
}

extension ConflictPolicy {
    /// The name of each policy for a mirror between this Mac and a cloud.
    var title: String {
        switch self {
        case .keepBoth: return L("Conservar las dos versiones")
        case .newestWins: return L("Gana la más reciente")
        case .thisSideWins: return L("Gana la del Mac")
        case .otherSideWins: return L("Gana la de la nube")
        case .ask: return L("Preguntar")
        }
    }
}
