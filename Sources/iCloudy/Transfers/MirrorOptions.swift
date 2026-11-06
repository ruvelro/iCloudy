import Foundation

/// How one mirror or sync behaves beyond what it copies: what happens on a conflict, and the rest of its settings.
/// Every field has the value that reproduces what mirrors did before the setting existed.
struct MirrorOptions: Codable, Equatable, Sendable {
    /// nil is the mode's own default: keep both in two-way syncs, ask in one-way mirrors.
    var conflictPolicy: ConflictPolicy?

    init(conflictPolicy: ConflictPolicy? = nil) {
        self.conflictPolicy = conflictPolicy
    }
    enum CodingKeys: String, CodingKey { case conflictPolicy }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conflictPolicy = (try? values.decodeIfPresent(String.self, forKey: .conflictPolicy)).flatMap { $0.flatMap(ConflictPolicy.init(rawValue:)) }
    }
}

extension FolderMirror {
    /// The sidebar's icon and the arrow before the remote location, by direction.
    var symbol: String {
        switch mode {
        case .upload: return "arrow.triangle.2.circlepath"
        case .twoWay: return "arrow.left.arrow.right"
        case .download: return "arrow.down.circle"
        }
    }
    var arrow: String {
        switch mode {
        case .upload: return "→"
        case .twoWay: return "⇄"
        case .download: return "←"
        }
    }
    /// The policy in force: the one chosen, or the mode's default.
    var conflictPolicy: ConflictPolicy {
        if let chosen = options.conflictPolicy { return chosen }
        return mode == .twoWay ? .keepBoth : .ask
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
