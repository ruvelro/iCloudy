import Foundation

/// Walks two trees side by side, one folder pair at a time, and hands out rows as each pair is settled. A folder that
/// exists on one side only becomes a single row and is never descended into: what it holds is all missing from the
/// other side anyway, copying it copies the whole folder, and the walk saves every listing below it. The pending
/// folders form a stack, so memory follows the depth of the tree rather than its width.
@MainActor
final class ComparisonEngine {
    struct Progress: Equatable {
        var folders = 0
        var items = 0
        var hashed = 0
        var current = ""
    }

    let a: InventorySource
    let b: InventorySource
    /// Off, nothing is read from disk: files are compared on what the providers list.
    var hashLocally = true
    private var nextID = 0

    init(a: InventorySource, b: InventorySource) { self.a = a; self.b = b }

    func run(progress: (Progress) -> Void, emit: ([ComparisonRow]) -> Void) async throws {
        // A name that one side folds and the other keeps apart is one name for the purpose of copying across.
        let caseSensitive = a.caseSensitive && b.caseSensitive
        let hashesA = hashLocally && a.hashesLocally, hashesB = hashLocally && b.hashesLocally
        var state = Progress()
        var pending: [(a: InventoryEntry?, b: InventoryEntry?, path: String)] = [(nil, nil, "")]
        while let (folderA, folderB, prefix) = pending.popLast() {
            try Task.checkCancellation()
            state.current = prefix
            progress(state)
            async let listedA = a.children(of: folderA)
            async let listedB = b.children(of: folderB)
            let (left, right) = try await (listedA, listedB)
            state.folders += 1
            state.items += left.count + right.count
            let match = FolderComparison.match(left, right, caseSensitive: caseSensitive)
            var rows: [ComparisonRow] = [], below: [(a: InventoryEntry?, b: InventoryEntry?, path: String)] = []
            for (x, y) in match.pairs {
                let path = Self.join(prefix, x.name)
                if x.isFolder && y.isFolder { below.append((x, y, path)); continue }
                let differs = x.name.precomposedStringWithCanonicalMapping != y.name.precomposedStringWithCanonicalMapping
                let status = try await FolderComparison.classify(x, y, hashesA: hashesA, hashesB: hashesB) { side, algorithm in
                    state.hashed += 1
                    state.current = path
                    progress(state)
                    do { return try await (side == .a ? a : b).digest(of: side == .a ? x : y, algorithm: algorithm) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return nil }
                }
                rows.append(row(path, x, y, folderA, folderB, status, caseDiffers: differs))
            }
            for x in match.onlyA { rows.append(row(Self.join(prefix, x.name), x, nil, folderA, folderB, .onlyInA)) }
            for y in match.onlyB { rows.append(row(Self.join(prefix, y.name), nil, y, folderA, folderB, .onlyInB)) }
            try Task.checkCancellation()
            emit(rows.sorted { left, right in
                let order = left.path.localizedStandardCompare(right.path)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            })
            // Reversed, so the stack visits subfolders in name order.
            pending.append(contentsOf: below.reversed())
        }
        state.current = ""
        progress(state)
    }

    private func row(_ path: String, _ x: InventoryEntry?, _ y: InventoryEntry?, _ parentA: InventoryEntry?, _ parentB: InventoryEntry?,
                     _ status: ComparisonStatus, caseDiffers: Bool = false) -> ComparisonRow {
        nextID += 1
        return ComparisonRow(id: nextID, path: path, a: x, b: y, parentA: parentA, parentB: parentB, status: status, caseDiffers: caseDiffers)
    }

    static func join(_ prefix: String, _ name: String) -> String { prefix.isEmpty ? name : prefix + "/" + name }
}
