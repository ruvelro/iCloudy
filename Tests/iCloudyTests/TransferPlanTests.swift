import XCTest
@testable import iCloudy

/// The plan is computed from listings before anything moves. These feed it listings by hand and check what it
/// concludes: conflicts, things that will not travel as they are, and whether the room is there.
@MainActor
final class TransferPlanTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ id: String, _ name: String, size: Int64? = 10, mime: String = "application/octet-stream") -> CloudFile {
        CloudFile(id: id, name: name, mime: mime, size: size, modified: nil, webURL: nil, isFolder: false)
    }
    private func folder(_ id: String, _ name: String) -> CloudFile {
        CloudFile(id: id, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    /// A remote tree as a dictionary of listings.
    private func lister(_ tree: [String: [CloudFile]], calls: Counter? = nil) -> (String) async throws -> [CloudFile] {
        { id in calls?.value += 1; return tree[id] ?? [] }
    }
    private final class Counter { var value = 0 }

    // MARK: - Uploads

    func testUploadPlanFindsConflictsUnsupportedItemsAndCountsEverything() async throws {
        let source = root.appendingPathComponent("Proyecto", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("datos"), withIntermediateDirectories: true)
        for index in 0..<24 { try Data(repeating: 1, count: 100).write(to: source.appendingPathComponent("datos/f\(index).bin")) }
        try Data(repeating: 2, count: 5000).write(to: source.appendingPathComponent("CON.txt"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("atajo"), withDestinationURL: source.appendingPathComponent("CON.txt"))
        let existing = [folder("r1", "proyecto"), file("r2", "otro.txt")]
        var seen: [PlanProgress] = []
        let plan = try await TransferPlanner.uploads([source], to: .microsoft, existing: existing, quota: StorageQuota(used: 900, total: 1000),
                                                     progress: { seen.append($0) })
        XCTAssertEqual(plan.files, 25); XCTAssertEqual(plan.folders, 2)
        XCTAssertEqual(plan.bytes, 24 * 100 + 5000); XCTAssertEqual(plan.largestFile, 5000)
        XCTAssertEqual(plan.conflicts, ["Proyecto"], "Names are compared the way providers do, without case")
        XCTAssertEqual(Set(plan.issues.map(\.path)), ["Proyecto/atajo", "Proyecto/CON.txt"])
        XCTAssertTrue(plan.issues.allSatisfy(\.blocking))
        XCTAssertTrue(plan.issues.contains { if case .invalidName(let reason) = $0.kind { return reason.contains("reservado") } else { return false } })
        XCTAssertEqual(plan.destinationFree, 100)
        XCTAssertTrue(plan.destinationShort); XCTAssertFalse(plan.localShort, "An upload needs no room on the Mac")
        XCTAssertTrue(plan.isLarge); XCTAssertTrue(plan.needsReview)
        XCTAssertEqual(plan.seeds.count, 1)
        XCTAssertEqual(plan.seeds[0]["./datos/f3.bin"], FileRecord(path: "Proyecto/datos/f3.bin", outcome: .pending, bytes: 100))
        XCTAssertNil(plan.seeds[0]["./atajo"], "A link is never uploaded, so it is not planned as a file")
        XCTAssertEqual(seen.last, PlanProgress(files: 25, folders: 2, bytes: 7400), "Progress ends on the totals")
    }

    func testASmallSelectionIsNotWorthAPlan() throws {
        let a = root.appendingPathComponent("a.txt"); try Data("a".utf8).write(to: a)
        XCTAssertTrue(TransferPlanner.trivial([a]))
        XCTAssertFalse(TransferPlanner.trivial([root]), "A folder always needs counting")
        XCTAssertTrue(TransferPlanner.trivial([file("1", "x")]))
        XCTAssertFalse(TransferPlanner.trivial([file("1", "x", size: TransferPlan.byteThreshold + 1)]))
        XCTAssertFalse(TransferPlanner.trivial((0...TransferPlan.fileThreshold).map { file("\($0)", "f\($0)") }))
        XCTAssertFalse(TransferPlanner.trivial([folder("1", "x")]))
    }

    // MARK: - Downloads

    func testDownloadPlanLooksAtWhatIsAlreadyOnTheMacAndAtTheRoomForIt() async throws {
        let existing = root.appendingPathComponent("Fotos", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data().write(to: existing.appendingPathComponent("playa.jpg"))
        let tree = ["f": [file("p", "playa.jpg", size: 400), file("m", "monte.jpg", size: 600), folder("s", "Notas")],
                    "s": [file("d", "Acta", size: nil, mime: "application/vnd.google-apps.document")]]
        let plan = try await TransferPlanner.downloads([folder("f", "Fotos")], into: root, exporting: false, list: lister(tree), localFree: 500)
        XCTAssertEqual(plan.files, 3); XCTAssertEqual(plan.folders, 2)
        XCTAssertEqual(plan.bytes, 1000); XCTAssertEqual(plan.unknownSizes, 1)
        XCTAssertEqual(plan.conflicts, ["Fotos", "Fotos/playa.jpg"], "A folder that exists merges, and its clashes ask too")
        XCTAssertEqual(plan.issues, [PlanIssue(path: "Fotos/Notas/Acta", kind: .linked)])
        XCTAssertEqual(plan.localNeed, 1000)
        XCTAssertTrue(plan.localShort, "A download needs room for all of it")
        XCTAssertEqual(Set(plan.seeds[0].keys), ["./p", "./m", "./s/d"], "Keyed by ids, like the download walk")
        XCTAssertTrue(plan.needsReview, "Not large, but it will not fit")
    }

    // MARK: - Cross-cloud

    func testCrossCloudPlanStagesOneFileAtATimeAndKnowsWhatGoogleCannotExport() async throws {
        let tree = ["v": [file("1", "grande.mov", size: 3000), file("2", "pequeño.txt", size: 20),
                          file("3", "Presupuesto", size: nil, mime: "application/vnd.google-apps.spreadsheet"),
                          file("4", "Encuesta", size: nil, mime: "application/vnd.google-apps.form"),
                          file("5", "a:b.txt", size: 5)]]
        let plan = try await TransferPlanner.crossCloud([folder("v", "Viaje"), file("x", "suelto.txt")], to: .microsoft,
                                                        existing: [file("e", "SUELTO.TXT")], list: lister(tree),
                                                        quota: StorageQuota(used: 0, total: 1_000_000), localFree: 2000)
        XCTAssertEqual(plan.largestFile, 3000)
        XCTAssertEqual(plan.localNeed, 3000, "Only the largest file is ever staged")
        XCTAssertTrue(plan.localShort)
        XCTAssertFalse(plan.destinationShort)
        XCTAssertEqual(plan.conflicts, ["suelto.txt"])
        XCTAssertTrue(plan.issues.contains(PlanIssue(path: "Viaje/Presupuesto", kind: .exported("xlsx"))))
        XCTAssertTrue(plan.issues.contains(PlanIssue(path: "Viaje/Encuesta", kind: .omitted)))
        XCTAssertTrue(plan.issues.contains { $0.path == "Viaje/a:b.txt" && $0.blocking })
        XCTAssertEqual(plan.seeds.count, 2, "One seed per job")
        XCTAssertEqual(plan.seeds[1], [".": FileRecord(path: "suelto.txt", outcome: .pending, bytes: 10)])
    }

    // MARK: - Cancelling

    func testEnumerationStopsWhenCancelled() async throws {
        let calls = Counter(), top = folder("a", "A"), into = root!, child = folder("b", "B")
        let task = Task { () -> TransferPlan in
            try await TransferPlanner.downloads([top], into: into, exporting: false, list: { _ in
                calls.value += 1
                try await Task.sleep(for: .seconds(5))
                return [child]
            }, localFree: nil)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled plan does not finish") } catch is CancellationError {}
        XCTAssertEqual(calls.value, 1)
    }

    func testTheCoordinatorOnlyAsksAboutPlansWorthAsking() async throws {
        let planner = TransferPlanCoordinator(); planner.revealDelay = .seconds(10)
        var started: [TransferPlan?] = []
        // Small: starts by itself, without ever showing the sheet.
        planner.begin(title: "x", compute: { _ in var plan = TransferPlan(kind: .upload); plan.files = 2; return plan }, start: { started.append($0) })
        for _ in 0..<100 where started.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(started.count, 1); XCTAssertEqual(started.first??.files, 2)
        XCTAssertNil(planner.session)
        // Large: waits for an answer.
        planner.begin(title: "y", compute: { _ in var plan = TransferPlan(kind: .upload); plan.files = 500; return plan }, start: { started.append($0) })
        for _ in 0..<100 where planner.session?.plan == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(planner.session?.shown, true)
        XCTAssertEqual(started.count, 1, "Nothing starts before Empezar")
        planner.confirm(dontAskAgain: false)
        XCTAssertEqual(started.count, 2); XCTAssertEqual(started.last??.files, 500)
        // Cancelled while counting: nothing starts at all.
        planner.begin(title: "z", compute: { progress in
            progress(PlanProgress(files: 7))
            try await Task.sleep(for: .seconds(5)); return TransferPlan(kind: .upload)
        }, start: { started.append($0) })
        for _ in 0..<100 where planner.session?.progress.files != 7 { try await Task.sleep(for: .milliseconds(5)) }
        planner.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(planner.session); XCTAssertEqual(started.count, 2)
    }

    // MARK: - Seeds match the queue's keys

    func testAPlannedUploadEndsWithEveryPlannedFileAccountedFor() async throws {
        let source = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("2024"), withIntermediateDirectories: true)
        for name in ["a.jpg", "2024/b.jpg", "2024/c.jpg"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let plan = try await TransferPlanner.uploads([source], to: .google, existing: try demo.list("root"), quota: nil)
        var job = Transfer(name: "Album", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: source)
        job.seed(plan.seeds[0])
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        try queue.add([job])
        for _ in 0..<500 where queue.isWorking || queue.items.first?.finished != true { try await Task.sleep(for: .milliseconds(10)) }
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(Set(done.report.keys), Set(plan.seeds[0].keys), "The run fills in the very lines the plan wrote")
        XCTAssertTrue(done.report.values.allSatisfy { $0.outcome == .verified }, "\(done.report)")
    }

    func testAPlannedDownloadEndsWithEveryPlannedFileAccountedFor() async throws {
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let top = try demo.add(name: "Docs", parent: "root", folder: true)
        _ = try demo.add(name: "uno.txt", parent: top, content: Data("1".utf8))
        let inner = try demo.add(name: "Dentro", parent: top, folder: true)
        _ = try demo.add(name: "dos.txt", parent: inner, content: Data("22".utf8))
        let source = try XCTUnwrap(demo.list("root").first { $0.id == top })
        let output = root.appendingPathComponent("salida", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let plan = try await TransferPlanner.downloads([source], into: output, exporting: false, list: { try demo.list($0) }, localFree: nil)
        var job = Transfer(name: "Docs", destination: output.path, accountID: Account.demo.id, direction: .download, localURL: output, file: source)
        job.seed(plan.seeds[0])
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        try queue.add([job])
        for _ in 0..<500 where queue.isWorking || queue.items.first?.finished != true { try await Task.sleep(for: .milliseconds(10)) }
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(Set(done.report.keys), Set(plan.seeds[0].keys))
        XCTAssertEqual(Set(done.report.values.map(\.path)), ["Docs/uno.txt", "Docs/Dentro/dos.txt"])
        XCTAssertTrue(done.report.values.allSatisfy(\.outcome.isCopied), "\(done.report)")
    }
}
