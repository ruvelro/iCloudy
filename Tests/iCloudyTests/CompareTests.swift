import XCTest
import CryptoKit
@testable import iCloudy

/// A tree held in memory, standing in for a provider. Items are addressed by their path, which doubles as their id.
@MainActor
private final class TreeSource: InventorySource {
    let caseSensitive: Bool
    let hashesLocally: Bool
    private var tree: [String: [InventoryEntry]] = [:]
    var digests: [String: String] = [:]
    private(set) var listed: [String] = []
    private(set) var digestRequests: [String] = []

    init(caseSensitive: Bool = true, hashesLocally: Bool = false, _ files: [CloudFile]) {
        self.caseSensitive = caseSensitive; self.hashesLocally = hashesLocally
        for file in files {
            let parent = file.id.split(separator: "/").dropLast().joined(separator: "/")
            tree[parent, default: []].append(InventoryEntry(file: file))
        }
    }
    func children(of folder: InventoryEntry?) async throws -> [InventoryEntry] {
        let id = folder?.file?.id ?? ""
        listed.append(id)
        return tree[id] ?? []
    }
    func digest(of entry: InventoryEntry, algorithm: ContentHash.Algorithm) async throws -> String {
        let key = (entry.file?.id ?? "") + ":" + algorithm.rawValue
        digestRequests.append(key)
        guard let digest = digests[key] else { throw CloudError.message("unreadable") }
        return digest
    }
}

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func file(_ path: String, size: Int64? = 10, modified: Date? = base, checksum: ContentHash? = nil,
                  mime: String = "application/octet-stream") -> CloudFile {
    CloudFile(id: path, name: String(path.split(separator: "/").last ?? ""), mime: mime, size: size, modified: modified,
              webURL: nil, isFolder: false, checksum: checksum)
}
private func folder(_ path: String) -> CloudFile {
    CloudFile(id: path, name: String(path.split(separator: "/").last ?? ""), mime: "application/vnd.google-apps.folder",
              size: nil, modified: nil, webURL: nil, isFolder: true)
}
private func entry(_ path: String, size: Int64? = 10, modified: Date? = base, checksum: ContentHash? = nil,
                   mime: String = "application/octet-stream") -> InventoryEntry {
    InventoryEntry(file: file(path, size: size, modified: modified, checksum: checksum, mime: mime))
}

@MainActor
final class CompareTests: XCTestCase {
    // MARK: - Names

    func testNamesMatchAcrossUnicodeFormsAndAcrossCaseOnlyWhenOneSideFoldsIt() {
        let composed = "Canci\u{F3}n.txt", decomposed = "Cancio\u{301}n.txt"
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
        XCTAssertEqual(ComparisonKey.key(decomposed, caseSensitive: true), ComparisonKey.key(composed, caseSensitive: true))
        XCTAssertEqual(ComparisonKey.key("Informe.PDF", caseSensitive: false), ComparisonKey.key("informe.pdf", caseSensitive: false))
        XCTAssertNotEqual(ComparisonKey.key("Informe.PDF", caseSensitive: true), ComparisonKey.key("informe.pdf", caseSensitive: true))
        // Folding case must not undo the composition: an accented capital folds to the composed lower-case letter.
        XCTAssertEqual(ComparisonKey.key("\u{C1}rbol", caseSensitive: false), ComparisonKey.key("a\u{301}rbol", caseSensitive: false))

        XCTAssertFalse(ComparisonKey.caseSensitive(.microsoft))
        XCTAssertFalse(ComparisonKey.caseSensitive(.dropbox))
        XCTAssertFalse(ComparisonKey.caseSensitive(.box))
        XCTAssertTrue(ComparisonKey.caseSensitive(.google))
        XCTAssertTrue(ComparisonKey.caseSensitive(.sftp))

        let match = FolderComparison.match([entry(decomposed)], [entry(composed)], caseSensitive: true)
        XCTAssertEqual(match.pairs.count, 1)
        XCTAssertTrue(match.onlyA.isEmpty && match.onlyB.isEmpty)
    }

    func testDriveTwinsPairOnceAndTheRestStaysOnItsOwnSide() {
        // Drive keeps "a.txt" and "A.txt" side by side, and even two items called exactly the same.
        let left = [entry("a.txt"), entry("A.txt")], right = [entry("a.txt")]
        let sensitive = FolderComparison.match(left, right, caseSensitive: true)
        XCTAssertEqual(sensitive.pairs.map(\.a.name), ["a.txt"])
        XCTAssertEqual(sensitive.onlyA.map(\.name), ["A.txt"])
        let folded = FolderComparison.match(left, right, caseSensitive: false)
        XCTAssertEqual(folded.pairs.map { $0.a.name + "=" + $0.b.name }, ["a.txt=a.txt"], "La grafía exacta gana")
        XCTAssertEqual(folded.onlyA.map(\.name), ["A.txt"])

        // A file pairs with the file of the same name, not with the folder that shares it.
        let mixed = FolderComparison.match([InventoryEntry(file: folder("x")), entry("x")], [entry("x")], caseSensitive: true)
        XCTAssertEqual(mixed.pairs.count, 1)
        XCTAssertFalse(mixed.pairs[0].a.isFolder)
        XCTAssertEqual(mixed.onlyA.map(\.isFolder), [true])
    }

    // MARK: - Classification

    private func classify(_ a: InventoryEntry, _ b: InventoryEntry, hashesA: Bool = false, hashesB: Bool = false,
                          digests: [ComparisonSide: String] = [:]) async throws -> (ComparisonStatus, [ComparisonSide]) {
        var asked: [ComparisonSide] = []
        let status = try await FolderComparison.classify(a, b, hashesA: hashesA, hashesB: hashesB) { side, _ in
            asked.append(side)
            return digests[side]
        }
        return (status, asked)
    }

    func testHashTiersDecideBeforeSizeAndDate() async throws {
        let md5 = ContentHash(algorithm: .md5, value: "ABCDEF"), other = ContentHash(algorithm: .md5, value: "123456")
        var (status, _) = try await classify(entry("x", checksum: md5), entry("x", checksum: ContentHash(algorithm: .md5, value: "abcdef")))
        XCTAssertEqual(status, .identical(.hash(.md5)), "El hexadecimal no distingue mayúsculas")

        (status, _) = try await classify(entry("x", modified: base.addingTimeInterval(3600), checksum: md5), entry("x", checksum: other))
        XCTAssertEqual(status, .different(.hash, newer: .a))

        (status, _) = try await classify(entry("x", size: 10), entry("x", size: 11, modified: base.addingTimeInterval(60)))
        XCTAssertEqual(status, .different(.size, newer: .b))

        // Drive's MD5 against Box's SHA-1: nothing to compare, so size and date speak.
        let sha1 = ContentHash(algorithm: .sha1, value: "aa")
        (status, _) = try await classify(entry("x", checksum: md5), entry("x", modified: base.addingTimeInterval(1), checksum: sha1))
        XCTAssertEqual(status, .identical(.sizeAndDate))
        (status, _) = try await classify(entry("x", checksum: md5), entry("x", modified: base.addingTimeInterval(3600), checksum: sha1))
        XCTAssertEqual(status, .unconfirmed(.sameSizeDifferentDate), "Una copia que no conserva la fecha no es «distinta»")

        (status, _) = try await classify(entry("x", size: nil), entry("x", size: nil))
        XCTAssertEqual(status, .unconfirmed(.unknownSize))
        (status, _) = try await classify(InventoryEntry(file: folder("x")), entry("x"))
        XCTAssertEqual(status, .different(.kind, newer: nil))
    }

    func testGoogleDocumentsAreNeverMatchedByHash() async throws {
        let document = entry("Informe", size: 0, mime: "application/vnd.google-apps.document")
        XCTAssertNil(document.size, "Lo que Drive lista como tamaño de un documento suyo no significa nada")
        let (status, asked) = try await classify(document, entry("Informe", size: 0), hashesB: true)
        XCTAssertEqual(status, .unconfirmed(.googleDocument))
        XCTAssertTrue(asked.isEmpty)
    }

    func testTheMacSideIsHashedInTheProviderAlgorithmAndOnlyWhenSizesAgree() async throws {
        let listed = ContentHash(algorithm: .dropbox, value: "feed")
        var (status, asked) = try await classify(entry("x"), entry("x", checksum: listed), hashesA: true, digests: [.a: "FEED"])
        XCTAssertEqual(status, .identical(.hash(.dropbox)))
        XCTAssertEqual(asked, [.a])

        (status, asked) = try await classify(entry("x", size: 1), entry("x", size: 2, checksum: listed), hashesA: true, digests: [.a: "feed"])
        XCTAssertEqual(status, .different(.size, newer: nil))
        XCTAssertTrue(asked.isEmpty, "Con tamaños distintos no se lee ni un byte")

        (status, _) = try await classify(entry("x"), entry("x", modified: base.addingTimeInterval(-7200), checksum: listed), hashesA: true, digests: [.a: "beef"])
        XCTAssertEqual(status, .different(.hash, newer: .a))

        // An unreadable file leaves the decision to size and date.
        (status, _) = try await classify(entry("x"), entry("x", checksum: listed), hashesA: true)
        XCTAssertEqual(status, .identical(.sizeAndDate))

        // A Mac folder against a volume account: both hash, SHA-256 on each.
        (status, asked) = try await classify(entry("x"), entry("x", modified: nil), hashesA: true, hashesB: true, digests: [.a: "1", .b: "1"])
        XCTAssertEqual(status, .identical(.hash(.sha256)))
        XCTAssertEqual(asked, [.a, .b])
    }

    func testARealMacFileMatchesTheMD5ADriveWouldList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-md5-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("contenido de prueba".utf8)
        try bytes.write(to: root.appendingPathComponent("nota.txt"))
        let local = LocalInventorySource(root: root)
        let mac = try await local.children(of: nil)
        XCTAssertEqual(mac.map(\.name), ["nota.txt"])
        let md5 = UploadHasher.hex(Insecure.MD5.hash(data: bytes))
        let drive = entry("nota.txt", size: Int64(bytes.count), modified: base, checksum: ContentHash(algorithm: .md5, value: md5))
        let status = try await FolderComparison.classify(mac[0], drive, hashesA: true, hashesB: false) { _, algorithm in
            try await local.digest(of: mac[0], algorithm: algorithm)
        }
        XCTAssertEqual(status, .identical(.hash(.md5)))
    }

    // MARK: - Walking two trees

    func testTheWalkDescendsOnlyIntoSharedFoldersAndRemembersWhereACopyLands() async throws {
        let md5 = ContentHash(algorithm: .md5, value: "aa")
        let drive = TreeSource(caseSensitive: true, [
            folder("Fotos"), file("Fotos/a.jpg"), file("Fotos/b.jpg", size: 20),
            folder("Docs"), file("Docs/x.txt", checksum: md5),
            folder("Solo"), folder("Solo/hondo"), file("Solo/hondo/z.txt"),
            file("Informe.pdf"),
        ])
        let onedrive = TreeSource(caseSensitive: false, [
            folder("Fotos"), file("Fotos/a.jpg"), file("Fotos/b.jpg", size: 21, modified: base.addingTimeInterval(600)), file("Fotos/c.jpg"),
            folder("docs"), file("docs/x.txt", checksum: md5),
            folder("Extra"),
            file("INFORME.pdf"),
        ])
        let engine = ComparisonEngine(a: drive, b: onedrive)
        var result = ComparisonResult(), batches = 0
        try await engine.run(progress: { _ in }, emit: { result.add($0); batches += 1 })

        let byPath = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.path, $0) })
        XCTAssertEqual(byPath["Solo"]?.status, .onlyInA)
        XCTAssertEqual(byPath["Solo"]?.a?.isFolder, true)
        XCTAssertFalse(drive.listed.contains("Solo"), "Una carpeta que solo está en un lado no se lista")
        XCTAssertNil(byPath["Solo/hondo/z.txt"])
        XCTAssertEqual(byPath["Extra"]?.status, .onlyInB)
        XCTAssertEqual(byPath["Docs/x.txt"]?.status, .identical(.hash(.md5)), "OneDrive no distingue mayúsculas: Docs y docs son la misma carpeta")
        XCTAssertEqual(byPath["Fotos/a.jpg"]?.status, .identical(.sizeAndDate))
        XCTAssertEqual(byPath["Fotos/b.jpg"]?.status, .different(.size, newer: .b))
        XCTAssertEqual(byPath["Informe.pdf"]?.caseDiffers, true)

        let onlyB = try XCTUnwrap(byPath["Fotos/c.jpg"])
        XCTAssertEqual(onlyB.status, .onlyInB)
        XCTAssertEqual(onlyB.parentA?.file?.id, "Fotos", "Copiarlo de B a A lo deja en la carpeta Fotos de A")
        XCTAssertEqual(onlyB.parentB?.file?.id, "Fotos")
        XCTAssertNil(byPath["Informe.pdf"]?.parentB, "La raíz de la comparación es nil")
        XCTAssertEqual(batches, 3, "Raíz, Docs y Fotos: un lote por pareja de carpetas")
        XCTAssertEqual(result.count(.identical), 3)
        XCTAssertEqual(result.count(.onlyInA), 1)
        XCTAssertEqual(result.count(.onlyInB), 2)
        XCTAssertEqual(result.count(.different), 1)
    }

    func testBothSidesCaseSensitiveKeepTwinsApart() async throws {
        let a = TreeSource(caseSensitive: true, [file("Nota.txt")]), b = TreeSource(caseSensitive: true, [file("nota.txt")])
        var result = ComparisonResult()
        try await ComparisonEngine(a: a, b: b).run(progress: { _ in }, emit: { result.add($0) })
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(Set(result.rows.map(\.status)), [.onlyInA, .onlyInB])
    }

    func testTurningLocalHashingOffReadsNothing() async throws {
        let mac = TreeSource(caseSensitive: false, hashesLocally: true, [file("x")])
        mac.digests = ["x:md5": "aa"]
        let drive = TreeSource([file("x", modified: base.addingTimeInterval(3600), checksum: ContentHash(algorithm: .md5, value: "aa"))])
        let engine = ComparisonEngine(a: mac, b: drive)
        engine.hashLocally = false
        var result = ComparisonResult()
        try await engine.run(progress: { _ in }, emit: { result.add($0) })
        XCTAssertEqual(result.rows.first?.status, .unconfirmed(.sameSizeDifferentDate))
        XCTAssertTrue(mac.digestRequests.isEmpty)

        engine.hashLocally = true
        result = ComparisonResult()
        try await engine.run(progress: { _ in }, emit: { result.add($0) })
        XCTAssertEqual(result.rows.first?.status, .identical(.hash(.md5)))
        XCTAssertEqual(mac.digestRequests, ["x:md5"])
    }

    func testACancelledComparisonStopsBeforeListing() async throws {
        let a = TreeSource([file("x")]), b = TreeSource([file("x")])
        let engine = ComparisonEngine(a: a, b: b)
        let task = Task { @MainActor in try await engine.run(progress: { _ in }, emit: { _ in }) }
        task.cancel()
        do { try await task.value; XCTFail("Debía cancelarse") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(a.listed.isEmpty)
    }

    func testAMacFolderAgainstTheDemoCloud() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-demo-" + UUID().uuidString)
        let local = root.appendingPathComponent("mac"), store = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = try DemoStore(directory: store)
        demo.latency = .zero
        let top = try demo.add(name: "Comparar", parent: "root", folder: true)
        let song = try demo.add(name: "Canci\u{F3}n.txt", parent: top, content: Data("la la".utf8))
        _ = try demo.add(name: "solo-nube.txt", parent: top, content: Data("nube".utf8))
        _ = try demo.add(name: "distinto.txt", parent: top, content: Data("corto".utf8))

        // The Mac side spells the accent decomposed, as files copied from older volumes do.
        let macSong = local.appendingPathComponent("Cancio\u{301}n.txt")
        try Data("la la".utf8).write(to: macSong)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(demo.file(song)?.modified)], ofItemAtPath: macSong.path)
        try Data("algo más largo".utf8).write(to: local.appendingPathComponent("distinto.txt"))
        try Data("mac".utf8).write(to: local.appendingPathComponent("solo-mac.txt"))
        try Data().write(to: local.appendingPathComponent(".DS_Store"))

        let api = CloudAPI(account: .demo, demo: demo)
        let engine = ComparisonEngine(a: LocalInventorySource(root: local), b: CloudInventorySource(api: api, rootID: top))
        var result = ComparisonResult()
        try await engine.run(progress: { _ in }, emit: { result.add($0) })
        let statuses = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.path.precomposedStringWithCanonicalMapping, $0.status) })
        XCTAssertEqual(statuses["Canci\u{F3}n.txt"], .identical(.sizeAndDate))
        XCTAssertEqual(statuses["distinto.txt"]?.group, .different)
        XCTAssertEqual(statuses["solo-mac.txt"], .onlyInA)
        XCTAssertEqual(statuses["solo-nube.txt"], .onlyInB)
        XCTAssertNil(statuses[".DS_Store"], "Los archivos del Finder no son diferencias")
        XCTAssertEqual(result.total, 4)
    }

    func testTheResultKeepsCountsButCapsWhatItStores() {
        var result = ComparisonResult(rowLimit: 3, identicalLimit: 1)
        let rows = (1...5).map { index in
            ComparisonRow(id: index, path: "f\(index)", a: entry("f\(index)"), b: entry("f\(index)"), parentA: nil, parentB: nil,
                          status: index <= 2 ? .identical(.sizeAndDate) : .different(.size, newer: nil))
        }
        let kept = result.add(rows)
        XCTAssertEqual(kept.map(\.id), [1, 3, 4])
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.omitted, 2)
        XCTAssertEqual(result.count(.identical), 2)
        XCTAssertEqual(result.count(.different), 3)
        XCTAssertEqual(result.bytes[.different], 30)
    }

    // MARK: - Duplicates

    private func candidate(_ path: String, root: Int = 0, size: Int64? = 100, modified: Date? = base, checksum: ContentHash? = nil,
                           local: Bool = false, mime: String = "application/octet-stream") -> DuplicateCandidate {
        let item = local ? InventoryEntry(url: URL(fileURLWithPath: "/tmp/" + path), isFolder: false, size: size, modified: modified)
                         : entry(path, size: size, modified: modified, checksum: checksum, mime: mime)
        return DuplicateCandidate(id: "\(root)|" + item.id, rootIndex: root, entry: item, parent: nil, path: path, hashesLocally: local)
    }

    func testOnlyMacFilesSharingASizeAreHashedAndInTheAlgorithmsTheCloudsList() {
        let md5 = ContentHash(algorithm: .md5, value: "aa"), box = ContentHash(algorithm: .dropbox, value: "bb")
        let mac = candidate("mac.jpg", local: true), alone = candidate("solo.jpg", size: 7, local: true)
        let pair = [candidate("x.bin", size: 5, local: true), candidate("y.bin", size: 5, local: true)]
        let plan = DuplicateGrouping.hashPlan([candidate("drive.jpg", checksum: md5), candidate("dropbox.jpg", root: 1, checksum: box), mac, alone] + pair)
        XCTAssertEqual(plan[mac.id], [.md5, .dropbox])
        XCTAssertNil(plan[alone.id], "Un tamaño que nadie más tiene no se lee")
        XCTAssertEqual(plan[pair[0].id], [.sha256])
        XCTAssertEqual(plan[pair[1].id], [.sha256])
    }

    func testGroupsByHashAcrossAccountsAndLabelsTheWeakerTierApart() {
        let md5 = ContentHash(algorithm: .md5, value: "AA")
        let a = candidate("Fotos/a.jpg", checksum: md5)
        let b = candidate("Copia de a.jpg", modified: base.addingTimeInterval(60), checksum: ContentHash(algorithm: .md5, value: "aa"))
        let mac = candidate("Escritorio/a.jpg", root: 1, modified: base.addingTimeInterval(120), local: true)
        let quick1 = candidate("q1", size: 40, checksum: ContentHash(algorithm: .quickXor, value: Data([1, 2, 3]).base64EncodedString()))
        let quick2 = candidate("q2", root: 2, size: 40, checksum: ContentHash(algorithm: .quickXor, value: Data([1, 2, 3]).base64EncodedString()))
        let webdav = candidate("foto.png", root: 2, size: 50)
        let boxed = candidate("FOTO.png", root: 3, size: 50, checksum: ContentHash(algorithm: .sha1, value: "cc"))
        let distinct1 = candidate("b.txt", size: 30, checksum: ContentHash(algorithm: .md5, value: "01"))
        let distinct2 = candidate("otra/b.txt", size: 30, checksum: ContentHash(algorithm: .md5, value: "02"))
        let document = candidate("Doc", size: nil, mime: "application/vnd.google-apps.document")
        let empty1 = candidate("vacío1", size: 0), empty2 = candidate("vacío2", size: 0)
        let report = DuplicateGrouping.group([a, b, mac, quick1, quick2, webdav, boxed, distinct1, distinct2, document, empty1, empty2],
                                             digests: [mac.id: [.md5: "aA"]])

        XCTAssertEqual(report.groups.count, 3)
        let first = report.groups[0]
        XCTAssertEqual(first.tier, .content([.md5]))
        XCTAssertEqual(Set(first.members.map(\.id)), [a.id, b.id, mac.id])
        XCTAssertEqual(first.wasted, 200)
        XCTAssertEqual(report.groups[1].tier, .content([.quickXor]))
        let weak = report.groups[2]
        XCTAssertEqual(weak.tier, .nameAndSize)
        XCTAssertEqual(Set(weak.members.map(\.id)), [webdav.id, boxed.id])
        XCTAssertEqual(report.wasted, 240)
        XCTAssertEqual(report.possibleWasted, 50)
        XCTAssertFalse(report.groups.contains { $0.members.contains { $0.id == distinct1.id } }, "Mismo nombre y MD5 distinto: no son duplicados")
        XCTAssertEqual(report.googleDocuments, 1)
        XCTAssertEqual(report.emptyFiles, 2)

        // Keep the oldest of each confirmed group; the weaker tier is never pre-selected.
        let suggested = DuplicateGrouping.suggestedSelection(report.groups)
        XCTAssertEqual(suggested, [b.id, mac.id, quick2.id])
        XCTAssertTrue(DuplicateGrouping.leavesACopy(suggested, in: report.groups))
        XCTAssertFalse(DuplicateGrouping.leavesACopy(suggested.union([a.id]), in: report.groups))

        let after = DuplicateGrouping.removing([b.id, quick2.id], from: report)
        XCTAssertEqual(after.groups.count, 2, "Un grupo con una sola copia deja de serlo")
        XCTAssertEqual(after.groups[0].members.count, 2)
        XCTAssertEqual(after.wasted, 100)
    }

    func testTheScannerFindsMacDuplicatesOnceEvenThroughOverlappingFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [("a/uno.txt", "dup"), ("b/dos.txt", "dup"), ("c.txt", "dif"), ("d/vacío.txt", "")] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let scanner = DuplicateScanner()
        var last = DuplicateScanner.Progress()
        let report = try await scanner.run([.init(key: "local", source: LocalInventorySource(root: root)),
                                            .init(key: "local", source: LocalInventorySource(root: root.appendingPathComponent("a")))],
                                           progress: { last = $0 })
        XCTAssertEqual(report.files, 4, "uno.txt se alcanza dos veces y cuenta una")
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].tier, .content([.sha256]))
        XCTAssertEqual(report.groups[0].members.map(\.path), ["a/uno.txt", "b/dos.txt"])
        XCTAssertEqual(report.wasted, 3)
        XCTAssertEqual(report.emptyFiles, 1)
        XCTAssertEqual(last.toHash, 3, "Los tres archivos de 3 bytes, y ninguno más")
        XCTAssertFalse(report.truncated)

        let capped = DuplicateScanner(fileLimit: 2)
        let partial = try await capped.run([.init(key: "local", source: LocalInventorySource(root: root))], progress: { _ in })
        XCTAssertTrue(partial.truncated)
        XCTAssertEqual(partial.files, 2)
    }

    // MARK: - Pacing and retries

    func testListingsAreRetriedOnlyForTransientFailures() async throws {
        var calls = 0, waits: [Double] = []
        let value = try await ListingRetry.run(sleep: { waits.append($0) }) { () async throws -> Int in
            calls += 1
            if calls < 3 { throw ServiceError(status: 503) }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(waits, [2, 4])

        calls = 0; waits = []
        do {
            _ = try await ListingRetry.run(sleep: { waits.append($0) }) { () async throws -> Int in calls += 1; throw ServiceError(status: 404) }
            XCTFail("Un 404 no se repite")
        } catch { XCTAssertEqual((error as? ServiceError)?.status, 404) }
        XCTAssertEqual(calls, 1)

        calls = 0
        do {
            _ = try await ListingRetry.run(sleep: { _ in }) { () async throws -> Int in calls += 1; throw ServiceError(status: 429, retryAfter: 1) }
            XCTFail("Se rinde tras los reintentos")
        } catch { XCTAssertEqual((error as? ServiceError)?.status, 429) }
        XCTAssertEqual(calls, 4)
    }

    func testThePacerSpacesRequestsToOneAccount() async throws {
        let pacer = ListingPacer(interval: .milliseconds(40))
        let start = ContinuousClock.now
        for _ in 0..<3 { try await pacer.wait() }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(80))
        XCTAssertTrue(ListingPacer.shared(for: "cuenta") === ListingPacer.shared(for: "cuenta"))
    }
}
