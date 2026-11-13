import Foundation

/// What a mirror, a sync or a saved job does when both sides have a different version of the same file.
///
/// "This side" and "the other side" are the two ends as the person set them up: the Mac and the cloud for a mirror or
/// a two-way sync, the first and the second folder for a pair of clouds, the source and the destination for a job.
enum ConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Both versions survive, one of them under another name.
    case keepBoth
    /// The version modified last replaces the other one.
    case newestWins
    case thisSideWins
    case otherSideWins
    /// The person decides, file by file.
    case ask
    var id: String { rawValue }
}

/// How a job meets what is already at the destination and what it leaves out. Mirrors and saved jobs set it;
/// ordinary transfers have none, and ask about every clash as they always have.
struct TransferOptions: Codable, Equatable, Sendable {
    /// nil asks, as an ordinary transfer does.
    var conflictPolicy: ConflictPolicy?
    /// What the job never copies. A mirror answers for its own uploads through the queue instead, so a rule changed
    /// while it runs applies at once.
    var exclusions: SyncExclusions?
    /// An upload whose destination already holds a file of the same name, size and checksum is not sent again.
    var skipIdentical = false
    /// A download writes the contents of the remote folder straight into `localURL` instead of into a new folder
    /// inside it: a mirror's folder is the copy of the remote one, not its parent.
    var contentsOnly = false

    init(conflictPolicy: ConflictPolicy? = nil, exclusions: SyncExclusions? = nil, skipIdentical: Bool = false, contentsOnly: Bool = false) {
        self.conflictPolicy = conflictPolicy; self.exclusions = exclusions; self.skipIdentical = skipIdentical; self.contentsOnly = contentsOnly
    }
    enum CodingKeys: String, CodingKey { case conflictPolicy, exclusions, skipIdentical, contentsOnly }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A policy added by a newer version is read as none: the job then asks, which loses nothing.
        conflictPolicy = (try? values.decodeIfPresent(String.self, forKey: .conflictPolicy)).flatMap { $0.flatMap(ConflictPolicy.init(rawValue:)) }
        exclusions = try? values.decodeIfPresent(SyncExclusions.self, forKey: .exclusions)
        skipIdentical = try values.decodeIfPresent(Bool.self, forKey: .skipIdentical) ?? false
        contentsOnly = try values.decodeIfPresent(Bool.self, forKey: .contentsOnly) ?? false
    }
}

extension ConflictPolicy {
    /// The answer the policy gives to a clash met while walking a one-way transfer, from its source to its
    /// destination: nil when the person has to be asked. `incoming` is the source's date, `existing` the destination's;
    /// a date that is not known makes "newest" fall back to asking.
    func choice(incoming: Date?, existing: Date?, canReplace: Bool) -> ConflictChoice? {
        switch self {
        case .ask: return nil
        case .keepBoth: return .copy
        case .thisSideWins: return canReplace ? .replace : .copy
        case .otherSideWins: return .skip
        case .newestWins:
            guard let incoming, let existing else { return nil }
            if incoming > existing { return canReplace ? .replace : .copy }
            return .skip
        }
    }
}
