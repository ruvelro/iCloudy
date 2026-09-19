import Foundation
import CryptoKit

/// Last known listing of each remote folder. A folder opens instantly from here while the provider is asked again in
/// the background; when the network is down the user still sees what was there. Metadata only, never contents.
@MainActor
final class ListingCache {
    let directory: URL
    /// Listings above this size are not cached: they are rare and would make the JSON slow to decode on the main actor.
    var maxItems = 5000
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
        if let files = memory[key(accountID, parent)] { return files }
        guard let files = try? LocalStore.read([CloudFile].self, from: fileURL(accountID, parent)) else { return nil }
        memory[key(accountID, parent)] = files
        return files
    }
    func store(_ files: [CloudFile], accountID: String, parent: String) {
        guard files.count <= maxItems else { invalidate(accountID: accountID, parent: parent); return }
        memory[key(accountID, parent)] = files
        let url = fileURL(accountID, parent)
        enqueue { try? LocalStore.save(files, to: url) }
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
}
