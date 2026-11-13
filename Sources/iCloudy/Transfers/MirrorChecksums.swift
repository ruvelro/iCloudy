import Foundation

/// Comparing files by what is in them, where the provider lists a checksum. Size and date say a file may have
/// changed; a checksum says whether it did, so a file touched without being edited (a copy that kept no dates, an
/// app that rewrites what it opens) is not sent again or taken for a conflict.
enum ContentComparison {
    struct Result: Sendable {
        var identical: Set<String> = []
        var different: Set<String> = []
    }

    /// Hashes, off the main thread, each candidate that has a local file of the listed size and a listed checksum,
    /// in that checksum's algorithm only. Anything else is left out of both sets: unknown.
    static func compare(_ candidates: [String], root: URL, local: [String: FileStamp], remote: [String: CloudFile]) async throws -> Result {
        var work: [(path: String, url: URL, checksum: ContentHash)] = []
        for path in candidates {
            guard let l = local[path], l.size != -1, let r = remote[path], !r.isFolder, let checksum = r.checksum, r.size == nil || r.size == l.size else { continue }
            work.append((path, root.appendingPathComponent(path), checksum))
        }
        guard !work.isEmpty else { return Result() }
        let items = work
        return try await blockingIO {
            var result = Result()
            for item in items {
                try Task.checkCancellation()
                // A dataless iCloud Drive file has no bytes here: hashing it would download it, silently and
                // without a way to stop it. It stays unknown, and size and date decide.
                guard hasBytesHere(item.url) else { continue }
                guard let digest = try? ContentHasher.digest(of: item.url, algorithm: item.checksum.algorithm).digest else { continue }
                if item.checksum.matches(digest) { result.identical.insert(item.path) } else { result.different.insert(item.path) }
            }
            return result
        }
    }

    /// False for an iCloud Drive file whose bytes are only in iCloud (or still on their way), which reading would
    /// download.
    nonisolated static func hasBytesHere(_ url: URL) -> Bool {
        switch VolumeProvider.ubiquity(of: url) {
        case .none, .some(.downloaded), .some(.uploading): return true
        case .some(.cloudOnly), .some(.downloading): return false
        }
    }

    /// The paths worth hashing for a two-way or download plan: a file on both sides, of the same size, that size and
    /// date alone would call changed or that has no baseline to go by.
    static func candidates(local: [String: FileStamp], remote: [String: CloudFile], baseline: [String: SyncEntry]) -> [String] {
        local.compactMap { path, l in
            guard l.size != -1, let r = remote[path], !r.isFolder, r.checksum != nil, r.size == nil || r.size == l.size else { return nil }
            guard let b = baseline[path] else { return path }
            return b.local != l || b.remoteSignature != SyncEntry.signature(r) ? path : nil
        }
    }
}
