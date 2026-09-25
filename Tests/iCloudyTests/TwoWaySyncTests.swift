import XCTest
@testable import iCloudy

/// Two-way sync is a three-way comparison against a baseline. The planner is pure, so every case is a table entry
/// here; the engine then runs end to end against the demo store, which behaves like a cloud with a bin.
@MainActor
final class TwoWaySyncTests: XCTestCase {
    private func stamp(_ size: Int64, _ t: TimeInterval = 100) -> FileStamp { FileStamp(size: size, modified: Date(timeIntervalSince1970: t)) }
    private func remote(_ id: String, size: Int64 = 1, t: TimeInterval = 100, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: String(id.split(separator: "/").last ?? "x"), mime: folder ? "application/vnd.google-apps.folder" : "text/plain",
                  size: folder ? nil : size, modified: folder ? nil : Date(timeIntervalSince1970: t), webURL: nil, isFolder: folder)
    }
    private func agreed(_ local: FileStamp, _ file: CloudFile) -> SyncEntry {
        SyncEntry(local: local, remoteID: file.id, remoteSize: file.size, remoteModified: file.modified, isFolder: false)
    }

    // MARK: - Planner

    func testUnchangedSidesProduceNothingAndOneSidedChangesTravelToTheOther() throws {
        let a = remote("a"), b = remote("b"), c = remote("c")
        let baseline = ["a.txt": agreed(stamp(1), a), "b.txt": agreed(stamp(1), b), "c.txt": agreed(stamp(1), c)]
        let plan = try TwoWayPlanner.plan(local: ["a.txt": stamp(1), "b.txt": stamp(2, 200), "c.txt": stamp(1), "nuevo.txt": stamp(3)],
                                          remote: ["a.txt": a, "b.txt": b, "c.txt": remote("c", size: 9, t: 300), "remoto.txt": remote("r")],
                                          baseline: baseline)
        XCTAssertEqual(Set(plan), [.upload("b.txt", replacing: "b"), .upload("nuevo.txt", replacing: nil),
                                   .download("c.txt", remote("c", size: 9, t: 300)), .download("remoto.txt", remote("r"))])
    }

    func testADeletionOnOneSideIsCarriedOnlyWhenTheOtherSideDidNotChange() throws {
        let a = remote("a"), b = remote("b"), c = remote("c"), d = remote("d")
        let baseline = ["a.txt": agreed(stamp(1), a), "b.txt": agreed(stamp(1), b), "c.txt": agreed(stamp(1), c), "d.txt": agreed(stamp(1), d)]
        // a: deleted locally, untouched remotely → delete remotely. b: deleted remotely, untouched locally → local to trash.
        // c: deleted locally but edited remotely → the edit wins and comes back down. d: gone on both sides → forgotten.
        let plan = try TwoWayPlanner.plan(local: ["b.txt": stamp(1)], remote: ["a.txt": a, "c.txt": remote("c", size: 5, t: 500)], baseline: baseline)
        XCTAssertEqual(Set(plan), [.deleteRemote("a.txt", a), .deleteLocal("b.txt"), .download("c.txt", remote("c", size: 5, t: 500)), .forget("d.txt")])
    }

    func testBothSidesChangedIsAConflictExceptOnAFirstSyncOfEqualFiles() throws {
        let plan = try TwoWayPlanner.plan(local: ["x.txt": stamp(7), "y.txt": stamp(7)], remote: ["x.txt": remote("x", size: 7), "y.txt": remote("y", size: 8)], baseline: [:])
        XCTAssertEqual(Set(plan), [.adopt("x.txt", remote("x", size: 7)), .conflict("y.txt", remote("y", size: 8))])
        let later = try TwoWayPlanner.plan(local: ["x.txt": stamp(7, 900)], remote: ["x.txt": remote("x", size: 7, t: 950)], baseline: ["x.txt": agreed(stamp(7), remote("x", size: 7))])
        XCTAssertEqual(later, [.conflict("x.txt", remote("x", size: 7, t: 950))], "Con baseline, dos cambios son un conflicto aunque midan lo mismo")
    }

    func testFoldersAreCreatedParentsFirstAndDeletedChildrenFirstWithTheirContents() throws {
        let plan = try TwoWayPlanner.plan(local: ["Fotos": stamp(-1, 0), "Fotos/2026": stamp(-1, 0), "Fotos/2026/a.jpg": stamp(1)], remote: [:], baseline: [:])
        XCTAssertEqual(plan, [.createRemoteFolder("Fotos"), .createRemoteFolder("Fotos/2026"), .upload("Fotos/2026/a.jpg", replacing: nil)])

        let folder = remote("F", folder: true), file = remote("F/a")
        let baseline: [String: SyncEntry] = ["Docs": SyncEntry(local: stamp(-1, 0), remoteID: "F", isFolder: true), "Docs/a.txt": agreed(stamp(1), file)]
        let gone = try TwoWayPlanner.plan(local: [:], remote: ["Docs": folder, "Docs/a.txt": file], baseline: baseline)
        XCTAssertEqual(gone, [.deleteRemote("Docs", folder)], "La carpeta borrada en el Mac se borra entera en la nube, sin un borrado por archivo")
        let edited = try TwoWayPlanner.plan(local: [:], remote: ["Docs": folder, "Docs/a.txt": remote("F/a", size: 4, t: 400)], baseline: baseline)
        XCTAssertEqual(Set(edited), [.createLocalFolder("Docs"), .download("Docs/a.txt", remote("F/a", size: 4, t: 400))], "Si algo cambió dentro, la carpeta vuelve en vez de borrarse")
    }

    func testWipingMostOfASideIsRefusedUntilAllowed() throws {
        var baseline: [String: SyncEntry] = [:], remote: [String: CloudFile] = [:]
        for i in 0..<12 { let f = self.remote("f\(i)"); baseline["f\(i).txt"] = agreed(stamp(1), f); remote["f\(i).txt"] = f }
        XCTAssertThrowsError(try TwoWayPlanner.plan(local: [:], remote: remote, baseline: baseline)) { error in
            XCTAssertTrue(error is MassDeletionRefused, "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("12"), error.localizedDescription)
        }
        let allowed = try TwoWayPlanner.plan(local: [:], remote: remote, baseline: baseline, allowMassDeletion: true)
        XCTAssertEqual(allowed.count, 12)
        // A handful of deletions in a big folder is ordinary work, not a wipe.
        var big = remote; for i in 100..<140 { big["g\(i).txt"] = self.remote("g\(i)") }
        var bigBaseline = baseline; for i in 100..<140 { bigBaseline["g\(i).txt"] = agreed(stamp(1), self.remote("g\(i)")) }
        var local: [String: FileStamp] = [:]; for i in 100..<140 { local["g\(i).txt"] = stamp(1) }
        XCTAssertEqual(try TwoWayPlanner.plan(local: local, remote: big, baseline: bigBaseline).count, 12)
    }

    func testConflictCopiesAreNamedAfterTheMacAndKeepTheirExtension() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = TwoWaySyncEngine.conflictName(for: "Docs/informe.final.pdf", host: "iMac de Ana", date: date)
        XCTAssertTrue(name.hasPrefix("Docs/informe.final (conflicto iMac de Ana "), name)
        XCTAssertTrue(name.hasSuffix(").pdf"), name)
        XCTAssertTrue(TwoWaySyncEngine.conflictName(for: "LEEME", host: "Mac", date: date).hasSuffix(")"), "Sin extensión no se inventa una")
    }

    // MARK: - Engine, end to end against the demo

    private func makeDemo() throws -> (CloudAPI, DemoStore, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bisync-" + UUID().uuidString)
        let local = base.appendingPathComponent("local"), store = base.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: store)
        demo.latency = .zero
        return (CloudAPI(account: .demo, demo: demo), demo, local, base)
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheEngineBringsBothSidesTogetherAndKeepsGoingFromItsBaseline() async throws {
        let (api, demo, local, base) = try makeDemo()
        defer { try? FileManager.default.removeItem(at: base) }
        let remoteRoot = try demo.add(name: "Sync", parent: "root", folder: true)
        try write("hola", to: local.appendingPathComponent("local.txt"))
        try write("dentro", to: local.appendingPathComponent("Carpeta/anidado.txt"))
        _ = try demo.add(name: "remoto.txt", parent: remoteRoot, content: Data("desde la nube".utf8))

        var saved: [[String: SyncEntry]] = []
        let engine = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: [:])
        engine.trashLocally = { try FileManager.default.removeItem(at: $0) }
        engine.persist = { saved.append($0) }
        var report = try await engine.run()
        XCTAssertEqual(report.uploaded, 2); XCTAssertEqual(report.downloaded, 1); XCTAssertEqual(report.conflicts, 0)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("remoto.txt"), encoding: .utf8), "desde la nube")
        let remoteNames = try await api.list(parent: remoteRoot).map(\.name).sorted()
        XCTAssertEqual(remoteNames, ["Carpeta", "local.txt", "remoto.txt"])
        XCTAssertEqual(Set(engine.baseline.keys), ["local.txt", "Carpeta", "Carpeta/anidado.txt", "remoto.txt"])
        XCTAssertFalse(saved.isEmpty, "La baseline se escribe paso a paso, no solo al final")

        // Nothing changed: a second run moves nothing.
        report = try await TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: engine.baseline).run()
        XCTAssertTrue(report.isEmpty, "\(report)")

        // Edit remotely, delete locally, add locally: each travels the right way.
        let listed = try await api.list(parent: remoteRoot)
        let remoteFile = try XCTUnwrap(listed.first { $0.name == "remoto.txt" })
        let edited = local.appendingPathComponent("edit.tmp"); try write("editado en la nube", to: edited)
        _ = try await api.resumableUpload(local: edited, parent: remoteRoot, name: "remoto.txt", replacing: remoteFile.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        try FileManager.default.removeItem(at: edited)
        try FileManager.default.removeItem(at: local.appendingPathComponent("local.txt"))
        try write("otro", to: local.appendingPathComponent("otro.txt"))
        let second = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: engine.baseline)
        second.trashLocally = { try FileManager.default.removeItem(at: $0) }
        report = try await second.run()
        XCTAssertEqual(report.downloaded, 1); XCTAssertEqual(report.deletedRemote, 1); XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("remoto.txt"), encoding: .utf8), "editado en la nube")
        let afterNames = try await api.list(parent: remoteRoot).map(\.name).sorted()
        XCTAssertEqual(afterNames, ["Carpeta", "otro.txt", "remoto.txt"], "local.txt se fue a la papelera de la nube")
        XCTAssertFalse(try demo.list(Collection.trash.rootID).isEmpty, "Y está en la papelera, no borrado sin más")

        // Delete remotely: the local copy goes.
        let afterSecond = try await api.list(parent: remoteRoot)
        let remoteOther = try XCTUnwrap(afterSecond.first { $0.name == "otro.txt" })
        try await api.trash(file: remoteOther)
        let third = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: second.baseline)
        third.trashLocally = { try FileManager.default.removeItem(at: $0) }
        report = try await third.run()
        XCTAssertEqual(report.deletedLocal, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("otro.txt").path))
        XCTAssertNil(third.baseline["otro.txt"])
    }

    func testAConflictKeepsBothVersionsOnBothSides() async throws {
        let (api, demo, local, base) = try makeDemo()
        defer { try? FileManager.default.removeItem(at: base) }
        let remoteRoot = try demo.add(name: "Sync", parent: "root", folder: true)
        try write("v1", to: local.appendingPathComponent("nota.txt"))
        let first = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: [:])
        _ = try await first.run()

        // Both sides edit the same file before the next run.
        try await Task.sleep(for: .milliseconds(20))
        try write("v2 local", to: local.appendingPathComponent("nota.txt"))
        let remoteListing = try await api.list(parent: remoteRoot)
        let remoteFile = try XCTUnwrap(remoteListing.first)
        let staged = base.appendingPathComponent("staged.txt"); try write("v2 nube", to: staged)
        _ = try await api.resumableUpload(local: staged, parent: remoteRoot, name: "nota.txt", replacing: remoteFile.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })

        let second = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: first.baseline)
        let report = try await second.run()
        XCTAssertEqual(report.conflicts, 1)
        let localNames = try FileManager.default.contentsOfDirectory(atPath: local.path).sorted()
        XCTAssertEqual(localNames.count, 2, "\(localNames)")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("nota.txt"), encoding: .utf8), "v2 nube", "El original toma la versión de la nube")
        let copy = try XCTUnwrap(localNames.first { $0.contains("conflicto") })
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent(copy), encoding: .utf8), "v2 local", "La copia local sobrevive con su nombre de conflicto")
        let remoteNames = try await api.list(parent: remoteRoot).map(\.name).sorted()
        XCTAssertEqual(remoteNames, localNames, "Las dos versiones están también en la nube")
        let again = try await TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: remoteRoot, baseline: second.baseline).run()
        XCTAssertTrue(again.isEmpty, "Tras resolver, los dos lados coinciden: \(again)")
    }

    func testOlderMirrorRecordsDecodeAsOneWayMirrors() throws {
        let json = #"[{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/","stamps":{}}]"#
        let decoded = try JSONDecoder().decode([FolderMirror].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.mode, .upload)
        XCTAssertTrue(decoded.first?.baseline.isEmpty == true)
    }
}
