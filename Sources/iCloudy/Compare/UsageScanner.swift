import Foundation

/// One folder or file of a tree that was measured, with everything below it added up.
struct UsageNode: Identifiable, Equatable {
    let id: String
    let name: String
    let isFolder: Bool
    /// The bytes of the item, or of everything inside it.
    var size: Int64
    /// Files inside, the item itself when it is one.
    var files: Int
    /// Files whose provider gave no size (Google documents, mostly): they are counted, never weighed.
    var unsized: Int
    /// Largest first. Empty for a file.
    var children: [UsageNode]
    /// Where the item is, to show it in the explorer or in the Finder.
    let entry: InventoryEntry?

    static func == (left: UsageNode, right: UsageNode) -> Bool { left.id == right.id && left.size == right.size && left.files == right.files }

    /// The node reached by following `path`, a list of child ids from this one down.
    func descendant(_ path: [String]) -> UsageNode? {
        var node = self
        for id in path {
            guard let next = node.children.first(where: { $0.id == id }) else { return nil }
            node = next
        }
        return node
    }
    /// The largest files anywhere below, largest first.
    func largestFiles(limit: Int) -> [(node: UsageNode, trail: [String])] {
        var found: [(UsageNode, [String])] = []
        func visit(_ node: UsageNode, _ trail: [String]) {
            for child in node.children {
                if child.isFolder { visit(child, trail + [child.name]) } else { found.append((child, trail)) }
            }
        }
        visit(self, [])
        return Array(found.sorted { $0.0.size > $1.0.size }.prefix(limit)).map { (node: $0.0, trail: $0.1) }
    }
}

/// Measures a tree: lists every folder below a starting point and adds up what it finds.
///
/// It reads what the providers list and nothing else, so it costs one listing per folder, paced and retried like a
/// comparison. The walk stops at a number of items that no screen could usefully show, and says that it did.
@MainActor
enum UsageScanner {
    struct Progress: Equatable { var folders = 0, files = 0; var bytes: Int64 = 0 }
    static let itemLimit = 200_000

    struct Result { var root: UsageNode; var truncated: Bool; var progress: Progress }

    static func scan(_ source: InventorySource, name: String, limit: Int = itemLimit, progress: ((Progress) -> Void)? = nil) async throws -> Result {
        var seen = Progress()
        var truncated = false
        func measure(_ entry: InventoryEntry?, name: String, id: String) async throws -> UsageNode {
            try Task.checkCancellation()
            var node = UsageNode(id: id, name: name, isFolder: true, size: 0, files: 0, unsized: 0, children: [], entry: entry)
            guard seen.folders + seen.files < limit else { truncated = true; return node }
            let listed = try await source.children(of: entry)
            seen.folders += 1
            for child in listed {
                if child.isFolder {
                    let below = try await measure(child, name: child.name, id: child.id)
                    node.size += below.size; node.files += below.files; node.unsized += below.unsized
                    node.children.append(below)
                } else {
                    guard seen.folders + seen.files < limit else { truncated = true; break }
                    seen.files += 1; seen.bytes += child.size ?? 0
                    node.size += child.size ?? 0; node.files += 1; node.unsized += child.size == nil ? 1 : 0
                    node.children.append(UsageNode(id: child.id, name: child.name, isFolder: false, size: child.size ?? 0, files: 1,
                                                   unsized: child.size == nil ? 1 : 0, children: [], entry: child))
                }
            }
            node.children.sort { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            progress?(seen)
            return node
        }
        let root = try await measure(nil, name: name, id: "root")
        return Result(root: root, truncated: truncated, progress: seen)
    }
}
