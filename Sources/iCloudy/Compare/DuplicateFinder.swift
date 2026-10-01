import Foundation

/// A file found while looking for duplicates, with where it was found.
struct DuplicateCandidate: Identifiable, Hashable {
    /// The account (or this Mac) and the item, so a file reached from two overlapping folders counts once.
    let id: String
    /// Which of the searched folders it was found under.
    let rootIndex: Int
    let entry: InventoryEntry
    /// The folder that holds it; nil is the searched folder itself.
    let parent: InventoryEntry?
    /// Relative to the searched folder.
    let path: String
    let hashesLocally: Bool
}

struct DuplicateGroup: Identifiable {
    enum Tier: Hashable {
        /// Same digest: the same bytes, whatever the names.
        case content([ContentHash.Algorithm])
        /// Same name and size, with no digest that could confirm or rule it out. Shown apart and never pre-selected.
        case nameAndSize
    }
    let id: String
    let tier: Tier
    let size: Int64
    var members: [DuplicateCandidate]
    /// What deleting every copy but one would free.
    var wasted: Int64 { size * Int64(max(0, members.count - 1)) }
    var isConfirmed: Bool { if case .content = tier { return true } else { return false } }
}

struct DuplicateReport {
    var groups: [DuplicateGroup] = []
    var files = 0
    /// Left out: Google documents have no size or checksum, empty files are all alike, and some providers list no size.
    var googleDocuments = 0
    var emptyFiles = 0
    var unsized = 0
    /// Local files that could not be read to hash them.
    var unreadable = 0
    /// The search stopped at the file limit; what was found up to there is still shown.
    var truncated = false
    var wasted: Int64 { groups.filter(\.isConfirmed).reduce(0) { $0 + $1.wasted } }
    var possibleWasted: Int64 { groups.filter { !$0.isConfirmed }.reduce(0) { $0 + $1.wasted } }
}

/// The pure part of finding duplicates: which files need hashing, how they group, and what a deletion must leave.
enum DuplicateGrouping {
    /// Only files with a size can be duplicates of anything; an empty file is identical to every other empty file,
    /// which says nothing.
    static func eligible(_ candidate: DuplicateCandidate) -> Bool {
        !candidate.entry.isFolder && !candidate.entry.isGoogleDocument && (candidate.entry.size ?? 0) > 0
    }

    static func sizeBuckets(_ candidates: [DuplicateCandidate]) -> [Int64: [DuplicateCandidate]] {
        Dictionary(grouping: candidates.filter(eligible)) { $0.entry.size ?? 0 }
    }

    /// Which local files to hash, and in which algorithms. Nothing is read unless another file has the same size,
    /// and then in the algorithms the clouds in that size list, so a Mac file can be matched against a Drive MD5 or a
    /// Dropbox content hash. Files only on this Mac are compared among themselves with SHA-256.
    static func hashPlan(_ candidates: [DuplicateCandidate]) -> [String: Set<ContentHash.Algorithm>] {
        var plan: [String: Set<ContentHash.Algorithm>] = [:]
        for bucket in sizeBuckets(candidates).values where bucket.count > 1 {
            let local = bucket.filter(\.hashesLocally)
            guard !local.isEmpty else { continue }
            let listed = Set(bucket.compactMap { $0.entry.checksum?.algorithm })
            let algorithms: Set<ContentHash.Algorithm> = listed.isEmpty ? (local.count > 1 ? [.sha256] : []) : listed
            for candidate in local {
                let needed = algorithms.subtracting(candidate.entry.checksum.map { [$0.algorithm] } ?? [])
                if !needed.isEmpty { plan[candidate.id] = needed }
            }
        }
        return plan
    }

    /// One spelling per digest: QuickXorHash is listed in Base64, the rest in hexadecimal of either case.
    static func key(_ algorithm: ContentHash.Algorithm, _ value: String) -> String {
        if algorithm == .quickXor, let data = Data(base64Encoded: value) { return "quickXor:" + UploadHasher.hex(data) }
        return algorithm.rawValue + ":" + value.lowercased()
    }

    static func group(_ candidates: [DuplicateCandidate], digests: [String: [ContentHash.Algorithm: String]]) -> DuplicateReport {
        var report = DuplicateReport()
        report.files = candidates.count
        for candidate in candidates where !candidate.entry.isFolder {
            if candidate.entry.isGoogleDocument { report.googleDocuments += 1 }
            else if candidate.entry.size == 0 { report.emptyFiles += 1 }
            else if candidate.entry.size == nil { report.unsized += 1 }
        }
        var groups: [DuplicateGroup] = []
        for (size, unsorted) in sizeBuckets(candidates) where unsorted.count > 1 {
            let bucket = unsorted.sorted { $0.id < $1.id }
            // Union-find over digests: two files that share any digest, in any algorithm, are the same bytes.
            var root = Array(bucket.indices)
            func find(_ index: Int) -> Int {
                var current = index
                while root[current] != current { root[current] = root[root[current]]; current = root[current] }
                return current
            }
            var owner: [String: Int] = [:], sharedBy: [String: Int] = [:]
            var keys = [[(algorithm: ContentHash.Algorithm, key: String)]](repeating: [], count: bucket.count)
            for (index, candidate) in bucket.enumerated() {
                if let listed = candidate.entry.checksum { keys[index].append((listed.algorithm, key(listed.algorithm, listed.value))) }
                for (algorithm, value) in digests[candidate.id] ?? [:] { keys[index].append((algorithm, key(algorithm, value))) }
                for entry in keys[index] {
                    sharedBy[entry.key, default: 0] += 1
                    if let other = owner[entry.key] { root[find(index)] = find(other) } else { owner[entry.key] = index }
                }
            }
            let algorithms = keys.map { Set($0.map(\.algorithm)) }
            var loose: [Int] = []
            for members in Dictionary(grouping: bucket.indices, by: find).values {
                guard members.count > 1 else { loose.append(members[0]); continue }
                // A key shared by two files joined them, and a key can only be shared inside its own group.
                let used = Set(members.flatMap { keys[$0].filter { sharedBy[$0.key, default: 0] > 1 }.map(\.algorithm) })
                let tier = DuplicateGroup.Tier.content(used.sorted { $0.rawValue < $1.rawValue })
                groups.append(DuplicateGroup(id: "hash|" + bucket[members.min()!].id, tier: tier, size: size, members: members.map { bucket[$0] }))
            }
            // What no digest joined can still share a name. If every one of them was hashed in some common algorithm
            // and still nothing matched, they are known to differ and are not offered at all.
            for members in Dictionary(grouping: loose, by: { ComparisonKey.key(bucket[$0].entry.name, caseSensitive: false) }).values where members.count > 1 {
                let common = members.dropFirst().reduce(algorithms[members[0]]) { $0.intersection(algorithms[$1]) }
                guard common.isEmpty else { continue }
                groups.append(DuplicateGroup(id: "name|" + bucket[members.min()!].id, tier: .nameAndSize, size: size, members: members.map { bucket[$0] }))
            }
        }
        report.groups = groups.map { group in
            var sorted = group
            sorted.members.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending || ($0.path == $1.path && $0.rootIndex < $1.rootIndex) }
            return sorted
        }.sorted { $0.isConfirmed != $1.isConfirmed ? $0.isConfirmed : ($0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.id < $1.id) }
        return report
    }

    /// Every confirmed copy but one, keeping the oldest (the likely original) and, among equals, the shortest path.
    /// Possible duplicates are left for the person to decide.
    static func suggestedSelection(_ groups: [DuplicateGroup]) -> Set<String> {
        var selection: Set<String> = []
        for group in groups where group.isConfirmed {
            let keep = group.members.min { left, right in
                let a = left.entry.modified ?? .distantFuture, b = right.entry.modified ?? .distantFuture
                if a != b { return a < b }
                if left.path.count != right.path.count { return left.path.count < right.path.count }
                return left.id < right.id
            }
            for member in group.members where member.id != keep?.id { selection.insert(member.id) }
        }
        return selection
    }

    /// True when every group still keeps at least one copy that is not selected. Deleting is refused otherwise.
    static func leavesACopy(_ selection: Set<String>, in groups: [DuplicateGroup]) -> Bool {
        groups.allSatisfy { group in group.members.contains { !selection.contains($0.id) } }
    }

    /// The report once some of its files are gone: they leave their groups, and a group with one file left is no
    /// longer a group.
    static func removing(_ ids: Set<String>, from report: DuplicateReport) -> DuplicateReport {
        var updated = report
        updated.groups = report.groups.compactMap { group in
            var remaining = group
            remaining.members.removeAll { ids.contains($0.id) }
            return remaining.members.count > 1 ? remaining : nil
        }
        return updated
    }
}

/// Walks one or several folders in full and groups what it finds. Unlike the comparison, every folder has to be
/// listed: a duplicate can be anywhere. Past `fileLimit` files the walk stops and says so, so that a search over a
/// whole account cannot take the memory of the Mac with it.
@MainActor
final class DuplicateScanner {
    struct Root {
        /// The account id, or "local" for folders of this Mac: an item reached twice under one key counts once.
        let key: String
        let source: InventorySource
    }
    struct Progress: Equatable {
        var folders = 0
        var files = 0
        var hashed = 0
        var toHash = 0
        var current = ""
    }

    let fileLimit: Int
    var hashLocally = true

    init(fileLimit: Int = 200_000) { self.fileLimit = fileLimit }

    func run(_ roots: [Root], progress: (Progress) -> Void) async throws -> DuplicateReport {
        var state = Progress(), seen: Set<String> = [], candidates: [DuplicateCandidate] = [], truncated = false
        walk: for (index, root) in roots.enumerated() {
            var pending: [(folder: InventoryEntry?, path: String)] = [(nil, "")]
            while let (folder, prefix) = pending.popLast() {
                try Task.checkCancellation()
                state.current = prefix
                progress(state)
                let children = try await root.source.children(of: folder)
                state.folders += 1
                for child in children {
                    let path = ComparisonEngine.join(prefix, child.name)
                    if child.isFolder { pending.append((child, path)); continue }
                    let id = root.key + "|" + child.id
                    guard seen.insert(id).inserted else { continue }
                    guard candidates.count < fileLimit else { truncated = true; break walk }
                    candidates.append(DuplicateCandidate(id: id, rootIndex: index, entry: child, parent: folder, path: path, hashesLocally: root.source.hashesLocally))
                    state.files += 1
                }
            }
        }
        var digests: [String: [ContentHash.Algorithm: String]] = [:], unreadable = 0
        if hashLocally {
            let plan = DuplicateGrouping.hashPlan(candidates)
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            state.toHash = plan.values.reduce(0) { $0 + $1.count }
            for (id, algorithms) in plan.sorted(by: { $0.key < $1.key }) {
                guard let candidate = byID[id] else { continue }
                for algorithm in algorithms.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try Task.checkCancellation()
                    state.current = candidate.path
                    progress(state)
                    do { digests[id, default: [:]][algorithm] = try await roots[candidate.rootIndex].source.digest(of: candidate.entry, algorithm: algorithm) }
                    catch is CancellationError { throw CancellationError() }
                    catch { unreadable += 1 }
                    state.hashed += 1
                }
            }
        }
        var report = DuplicateGrouping.group(candidates, digests: digests)
        report.truncated = truncated
        report.unreadable = unreadable
        state.current = ""
        progress(state)
        return report
    }
}
