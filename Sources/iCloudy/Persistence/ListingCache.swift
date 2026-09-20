import Foundation
import CryptoKit

/// Last known listing of each remote folder. A folder opens instantly from here while the provider is asked again in
/// the background; when the network is down the user still sees what was there. Metadata only, never contents.
@MainActor
final class ListingCache {
    let directory: URL
    /// Listings above this size are not cached: they are rare and would make the JSON slow to decode on the main actor.
    var maxItems = 5000
    var enabled = true {
        didSet { if !enabled { clear() } }
    }
    var maxTotalItems = 20_000
    var maxListings = 256
    var maxBytes = 10 * 1024 * 1024
    var maxAge: TimeInterval = 7 * 86400
    private var dates: [String: Date] = [:]
    private var memory: [String: [CloudFile]] = [:]
    /// Disk work happens one piece at a time, in the order it was asked for. Two quick refreshes of the same folder
    /// used to race, and the older listing could be the one that stayed on disk.
    private var lastWrite: Task<Void, Never>?
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) { await previous?.value; work() }
    }
    /// Lets tests wait for the disk to catch up.
    func settle() async { await lastWrite?.value }

    init(directory: URL = LocalStore.directory.appendingPathComponent("Listings", isDirectory: true)) {
        self.directory = directory
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description }
    private func accountDirectory(_ accountID: String) -> URL { directory.appendingPathComponent(Self.digest(accountID), isDirectory: true) }
    private func fileURL(_ accountID: String, _ parent: String) -> URL { accountDirectory(accountID).appendingPathComponent(Self.digest(parent) + ".json") }
    private func key(_ accountID: String, _ parent: String) -> String { accountID + "\u{1F}" + parent }

    func cached(accountID: String, parent: String) -> [CloudFile]? {
        guard enabled else { return nil }
        let key = key(accountID, parent)
        if let files = memory[key], let date = dates[key], Date().timeIntervalSince(date) <= maxAge { return files }
        memory[key] = nil; dates[key] = nil
        let url = fileURL(accountID, parent)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, Date().timeIntervalSince(date) <= maxAge,
              (values.fileSize ?? Int.max) <= maxBytes else { return nil }
        guard let files = try? LocalStore.read([CloudFile].self, from: fileURL(accountID, parent)) else { return nil }
        guard files.count <= min(maxItems, maxTotalItems) else { return nil }
        memory[key] = files; dates[key] = date
        pruneMemory()
        return files
    }
    func store(_ files: [CloudFile], accountID: String, parent: String) {
        guard enabled else { return }
        guard files.count <= min(maxItems, maxTotalItems),
              let encoded = try? JSONEncoder().encode(files), encoded.count <= maxBytes else { invalidate(accountID: accountID, parent: parent); return }
        memory[key(accountID, parent)] = files
        dates[key(accountID, parent)] = Date()
        pruneMemory()
        let url = fileURL(accountID, parent)
        let directory = directory, items = maxTotalItems, bytes = maxBytes, age = maxAge, listings = maxListings
        enqueue {
            try? LocalStore.save(files, to: url)
            Self.pruneDisk(directory, items: items, bytes: bytes, age: age, listings: listings)
        }
    }
    func invalidate(accountID: String, parent: String) {
        memory[key(accountID, parent)] = nil
        let url = fileURL(accountID, parent)
        enqueue { try? FileManager.default.removeItem(at: url) }
    }
    /// Disconnecting an account must leave no trace of its file names on disk.
    func removeAll(accountID: String) {
        memory = memory.filter { !$0.key.hasPrefix(accountID + "\u{1F}") }
        let directory = accountDirectory(accountID)
        enqueue { try? FileManager.default.removeItem(at: directory) }
    }
    func clear() {
        memory.removeAll(); dates.removeAll()
        let directory = directory
        enqueue { try? FileManager.default.removeItem(at: directory) }
    }
    private func pruneMemory() {
        var items = 0, bytes = 0
        for (position, key) in dates.keys.sorted(by: { dates[$0]! > dates[$1]! }).enumerated() {
            guard let files = memory[key] else { dates[key] = nil; continue }
            items += files.count; bytes += (try? JSONEncoder().encode(files).count) ?? maxBytes
            if position >= maxListings || items > maxTotalItems || bytes > maxBytes || Date().timeIntervalSince(dates[key]!) > maxAge {
                memory[key] = nil; dates[key] = nil
            }
        }
    }
    nonisolated private static func pruneDisk(_ directory: URL, items limit: Int, bytes budget: Int, age: TimeInterval, listings: Int) {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
        var entries: [(URL, Date, Int)] = []
        for case let url as URL in walker where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
            entries.append((url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        var items = 0, bytes = 0
        for (position, entry) in entries.sorted(by: { $0.1 > $1.1 }).enumerated() {
            let (url, date, size) = entry
            if position >= listings || Date().timeIntervalSince(date) > age || size > budget || bytes + size > budget {
                try? FileManager.default.removeItem(at: url); continue
            }
            guard let files = try? LocalStore.read([CloudFile].self, from: url), items + files.count <= limit else {
                try? FileManager.default.removeItem(at: url); continue
            }
            items += files.count; bytes += size
        }
    }

}
