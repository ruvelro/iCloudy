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
    /// The policy in force: the one chosen, or the mode's default.
    var conflictPolicy: ConflictPolicy {
        if let chosen = options.conflictPolicy { return chosen }
        return mode == .twoWay ? .keepBoth : .ask
    }
    /// The same policy in the terms of a one-way transfer, where "this side" is the source. nil asks.
    var transferPolicy: ConflictPolicy? {
        let policy = conflictPolicy
        return policy == .ask ? nil : policy
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
