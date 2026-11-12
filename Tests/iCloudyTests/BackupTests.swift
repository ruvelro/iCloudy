import XCTest
@testable import iCloudy

/// Scheduled copies between accounts: when they are due, what a run decides, and a whole run against the demo.
@MainActor
final class BackupTests: XCTestCase {
    // MARK: - Schedule

    private var calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Madrid")!; return c }()
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testAManualPlanIsNeverDueAndAnHourlyOneCountsFromItsLastRun() {
        XCTAssertFalse(BackupSchedule(kind: .manual).isDue(lastRun: nil, now: date(12, 10)))
        let hourly = BackupSchedule(kind: .hourly, every: 6)
        XCTAssertTrue(hourly.isDue(lastRun: nil, now: date(12, 10)))
        XCTAssertFalse(hourly.isDue(lastRun: date(12, 6), now: date(12, 11, 59)))
        XCTAssertTrue(hourly.isDue(lastRun: date(12, 6), now: date(12, 12)))
    }

    func testADailyPlanOwesTheMostRecentMomentItNamed() {
        let daily = BackupSchedule(kind: .daily, minutes: 3 * 60)
        XCTAssertEqual(daily.previous(before: date(12, 10), calendar: calendar), date(12, 3))
        XCTAssertEqual(daily.previous(before: date(12, 2), calendar: calendar), date(11, 3), "Before today's hour, the last one was yesterday's")
        XCTAssertTrue(daily.isDue(lastRun: date(11, 3, 5), now: date(12, 3, 1), calendar: calendar))
        XCTAssertFalse(daily.isDue(lastRun: date(12, 3, 1), now: date(12, 23), calendar: calendar), "Once a day is once")
        XCTAssertTrue(daily.isDue(lastRun: date(10, 3, 1), now: date(12, 9), calendar: calendar), "A Mac that was asleep at three catches up when it wakes")
    }

    func testAWeeklyPlanWaitsForItsDay() {
        // 12 November 2026 is a Thursday; weekday 2 is Monday.
        let weekly = BackupSchedule(kind: .weekly, minutes: 8 * 60, weekday: 2)
        XCTAssertEqual(weekly.previous(before: date(12, 10), calendar: calendar), date(9, 8))
        XCTAssertFalse(weekly.isDue(lastRun: date(9, 8, 30), now: date(15, 23), calendar: calendar))
        XCTAssertTrue(weekly.isDue(lastRun: date(9, 8, 30), now: date(16, 8, 1), calendar: calendar))
    }

    func testUnknownSchedulesAndOlderPlansDecode() throws {
        let json = #"[{"sourceAccountID":"a","sourceFolderID":"f","targetAccountID":"b","targetFolderID":"g","schedule":{"kind":"lunar"}}]"#
        let plan = try XCTUnwrap(JSONDecoder().decode([BackupPlan].self, from: Data(json.utf8)).first)
        XCTAssertEqual(plan.schedule.kind, .manual, "A schedule this version does not know never runs unasked")
        XCTAssertTrue(plan.keepsVersions); XCTAssertFalse(plan.removesDeleted)
    }

    // MARK: - Planner

    private func file(_ id: String, _ name: String, size: Int64 = 10, t: TimeInterval = 100, mime: String = "text/plain") -> CloudFile {
        CloudFile(id: id, name: name, mime: mime, size: mime.hasPrefix("application/vnd.google-apps.") ? nil : size, modified: Date(timeIntervalSince1970: t), webURL: nil, isFolder: false)
    }
    private func folder(_ id: String, _ name: String) -> CloudFile {
        CloudFile(id: id, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    private func plan(keepsVersions: Bool = false, removesDeleted: Bool = false, baseline: [String: String] = [:]) -> BackupPlan {
        var plan = BackupPlan(sourceAccountID: "a", sourceFolderID: "src", sourceName: "A / Fotos", targetAccountID: "b", targetFolderID: "dst", targetName: "B / Copia")
        plan.keepsVersions = keepsVersions; plan.removesDeleted = removesDeleted; plan.baseline = baseline
        return plan
    }

    func testAFirstRunSendsEverythingIntoTheDestinationFolder() throws {
        let source = [BackupNode(path: "a.txt", file: file("1", "a.txt"), key: "./1"),
                      BackupNode(path: "Sub", file: folder("2", "Sub"), key: "./2"),
                      BackupNode(path: "Sub/b.txt", file: file("3", "b.txt", size: 30), key: "./2/3")]
        let outcome = try BackupPlanner.plan(source: source, target: [], plan: plan(), targetCloud: .box, canMove: true)
        XCTAssertEqual(outcome.copies, 2); XCTAssertEqual(outcome.bytes, 40)
        XCTAssertEqual(outcome.folders, [".": "dst"], "Only the root exists yet; Sub will be created by the copy")
        XCTAssertEqual(outcome.names, [".": "Fotos", "./1": "a.txt", "./2": "Sub", "./2/3": "b.txt"], "Every name is decided, so the queue never stops to ask")
        XCTAssertTrue(outcome.completed.isEmpty)
        XCTAssertEqual(Set(outcome.signatures.keys), ["a.txt", "Sub/b.txt"])
    }

    func testWhatDidNotChangeIsNotEvenListedAgain() throws {
        let a = file("1", "a.txt"), b = file("3", "b.txt", size: 30), c = file("5", "c.txt")
        let source = [BackupNode(path: "a.txt", file: a, key: "./1"), BackupNode(path: "Sub", file: folder("2", "Sub"), key: "./2"),
                      BackupNode(path: "Sub/b.txt", file: b, key: "./2/3"), BackupNode(path: "Otra", file: folder("4", "Otra"), key: "./4"),
                      BackupNode(path: "Otra/c.txt", file: c, key: "./4/5")]
        let target = [BackupNode(path: "a.txt", file: file("x1", "a.txt")), BackupNode(path: "Sub", file: folder("x2", "Sub")),
                      BackupNode(path: "Sub/b.txt", file: file("x3", "b.txt", size: 30)), BackupNode(path: "Otra", file: folder("x4", "Otra")),
                      BackupNode(path: "Otra/c.txt", file: file("x5", "c.txt"))]
        let baseline = ["a.txt": SyncEntry.signature(a), "Sub/b.txt": SyncEntry.signature(b), "Otra/c.txt": "viejo"]
        let outcome = try BackupPlanner.plan(source: source, target: target, plan: plan(baseline: baseline), targetCloud: .box, canMove: true)
        XCTAssertEqual(outcome.copies, 0); XCTAssertEqual(outcome.replaces, 1)
        XCTAssertEqual(outcome.completed, ["./1", "./2", "./2/3"], "The unchanged folder is skipped whole; the one with a change is walked")
        XCTAssertEqual(outcome.replacements, ["./4/5": "x5"], "Without versions the new file takes the place of its copy")
        XCTAssertEqual(outcome.folders, [".": "dst", "./2": "x2", "./4": "x4"])
        XCTAssertTrue(outcome.retire.isEmpty)
    }

    func testWithVersionsTheOldCopyStepsAsideInsteadOfBeingOverwritten() throws {
        let changed = file("1", "informe.txt", size: 99, t: 500)
        let old = BackupNode(path: "informe.txt", file: file("x1", "informe.txt"))
        let outcome = try BackupPlanner.plan(source: [BackupNode(path: "informe.txt", file: changed, key: "./1")], target: [old],
                                             plan: plan(keepsVersions: true, baseline: ["informe.txt": "viejo"]), targetCloud: .box, canMove: true)
        XCTAssertEqual(outcome.retire, [old]); XCTAssertTrue(outcome.replacements.isEmpty)
        let cannotMove = try BackupPlanner.plan(source: [BackupNode(path: "informe.txt", file: changed, key: "./1")], target: [old],
                                                plan: plan(keepsVersions: true, baseline: ["informe.txt": "viejo"]), targetCloud: .ftp, canMove: false)
        XCTAssertEqual(cannotMove.replacements, ["./1": "x1"], "Where nothing can be moved aside, the change overwrites")
    }

    func testACopyThatShrankAtTheDestinationIsSentAgain() throws {
        let a = file("1", "a.txt", size: 10)
        let outcome = try BackupPlanner.plan(source: [BackupNode(path: "a.txt", file: a, key: "./1")], target: [BackupNode(path: "a.txt", file: file("x1", "a.txt", size: 4))],
                                             plan: plan(baseline: ["a.txt": SyncEntry.signature(a)]), targetCloud: .box, canMove: true)
        XCTAssertEqual(outcome.replaces, 1, "The source did not change, but the copy is not the copy any more")
    }

    func testGoogleDocumentsTravelUnderTheirExportNameAndWhatCannotTravelIsSkipped() throws {
        let doc = file("1", "Informe", mime: "application/vnd.google-apps.document"), form = file("2", "Encuesta", mime: "application/vnd.google-apps.form")
        let source = [BackupNode(path: "Informe", file: doc, key: "./1"), BackupNode(path: "Encuesta", file: form, key: "./2"),
                      BackupNode(path: "CON", file: file("3", "CON"), key: "./3"), BackupNode(path: "doble.txt", file: file("4", "doble.txt"), key: "./4"),
                      BackupNode(path: "doble.txt", file: file("5", "doble.txt"), key: "./5")]
        let outcome = try BackupPlanner.plan(source: source, target: [], plan: plan(), targetCloud: .microsoft, canMove: true)
        XCTAssertEqual(outcome.names["./1"], "Informe.docx")
        XCTAssertEqual(outcome.copies, 2, "The document and the first of the two files that share a name")
        XCTAssertEqual(outcome.skipped, 3, "A form cannot be exported, OneDrive refuses CON, and a second 'doble.txt' would overwrite the first")
        XCTAssertEqual(outcome.completed, ["./2", "./3", "./5"])
    }

    func testOnlyWhatThisPlanCopiedIsEverRemoved() throws {
        let a = file("1", "a.txt")
        let target = [BackupNode(path: "a.txt", file: file("x1", "a.txt")), BackupNode(path: "borrado.txt", file: file("x2", "borrado.txt")),
                      BackupNode(path: "ajeno.txt", file: file("x3", "ajeno.txt"))]
        let baseline = ["a.txt": SyncEntry.signature(a), "borrado.txt": "s"]
        let source = [BackupNode(path: "a.txt", file: a, key: "./1")]
        let kept = try BackupPlanner.plan(source: source, target: target, plan: plan(baseline: baseline), targetCloud: .box, canMove: true)
        XCTAssertTrue(kept.nothingToDo, "By default the destination only grows")
        let outcome = try BackupPlanner.plan(source: source, target: target, plan: plan(removesDeleted: true, baseline: baseline), targetCloud: .box, canMove: true)
        XCTAssertEqual(outcome.removals, 1)
        XCTAssertEqual(outcome.retire.map(\.path), ["borrado.txt"], "'ajeno.txt' was never copied by this plan and is not its to remove")
    }

    func testEmptyingMostOfTheCopyIsRefusedUntilAllowed() throws {
        var baseline: [String: String] = [:], target: [BackupNode] = []
        for index in 0..<12 { baseline["f\(index).txt"] = "s"; target.append(BackupNode(path: "f\(index).txt", file: file("x\(index)", "f\(index).txt"))) }
        XCTAssertThrowsError(try BackupPlanner.plan(source: [], target: target, plan: plan(removesDeleted: true, baseline: baseline), targetCloud: .box, canMove: true)) {
            XCTAssertEqual(($0 as? BackupRemovalRefused)?.count, 12)
        }
        let allowed = try BackupPlanner.plan(source: [], target: target, plan: plan(removesDeleted: true, baseline: baseline), targetCloud: .box, canMove: true, allowMassRemoval: true)
        XCTAssertEqual(allowed.removals, 12)
    }

    // MARK: - A whole run, against the demo

    private var root: URL!
    private var demo: DemoStore!
    private var queue: TransferQueue!
    private var manager: BackupManager!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func setUpRun() throws -> BackupPlan {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        demo = try DemoStore(directory: root.appendingPathComponent("demo"))
        let demo = demo!
        queue = TransferQueue(storeURL: root.appendingPathComponent("transfers.json"))
        queue.scratchRoot = root.appendingPathComponent("scratch")
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        manager = BackupManager(storeURL: root.appendingPathComponent("backups.json"))
        manager.queue = queue
        manager.now = { [unowned self] in self.clock }
        queue.didFinish = { [weak manager] in manager?.handleFinished($0) }
        let source = try demo.add(name: "Trabajo", parent: "root", folder: true)
        let sub = try demo.add(name: "2026", parent: source, folder: true)
        _ = try demo.add(name: "informe.txt", parent: source, content: Data("versión uno".utf8))
        _ = try demo.add(name: "acta.txt", parent: sub, content: Data("acta".utf8))
        let target = try demo.add(name: "Copia", parent: "root", folder: true)
        var plan = BackupPlan(sourceAccountID: Account.demo.id, sourceFolderID: source, sourceName: "Demo / Trabajo",
                              targetAccountID: Account.demo.id, targetFolderID: target, targetName: "Demo / Copia")
        plan.schedule = BackupSchedule(kind: .manual)
        try manager.add(plan)
        return plan
    }
    private func runToTheEnd(_ id: UUID) async throws {
        await manager.run(id)
        for _ in 0..<600 {
            if !queue.isWorking, !queue.items.contains(where: { [.queued, .running].contains($0.state) }), manager.plans.first?.activeTransferID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))
    }
    private func names(in id: String) throws -> [String] { try demo.list(id).map(\.name).sorted() }
    private func text(_ id: String) throws -> String { String(decoding: try Data(contentsOf: root.appendingPathComponent("demo/\(id)")), as: UTF8.self) }
    private func child(_ name: String, of id: String) throws -> CloudFile { try XCTUnwrap(demo.list(id).first { $0.name == name }, name) }

    func testARunCopiesTheTreeAndTheNextOneOnlyWhatChangedKeepingTheOldVersion() async throws {
        let plan = try setUpRun()
        try await runToTheEnd(plan.id)
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        XCTAssertEqual(try names(in: plan.targetFolderID), ["2026", "informe.txt"], "The contents go into the destination, not into a folder inside it")
        XCTAssertEqual(try names(in: try child("2026", of: plan.targetFolderID).id), ["acta.txt"])
        var saved = try XCTUnwrap(manager.plans.first)
        XCTAssertEqual(Set(saved.baseline.keys), ["informe.txt", "2026/acta.txt"])
        XCTAssertNotNil(saved.lastRun); XCTAssertNil(saved.lastError)

        // Nothing changed: the second run plans nothing and queues nothing.
        try await runToTheEnd(plan.id)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(manager.plans.first?.lastSummary, "sin cambios")

        // The report is edited at the source and a new file appears.
        let report = try child("informe.txt", of: plan.sourceFolderID)
        let edited = root.appendingPathComponent("editado.txt"); try Data("versión dos, más larga".utf8).write(to: edited)
        _ = try await demo.upload(local: edited, parent: plan.sourceFolderID, name: "informe.txt", replacing: report.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        _ = try demo.add(name: "nuevo.txt", parent: plan.sourceFolderID, content: Data("nuevo".utf8))
        try await runToTheEnd(plan.id)
        XCTAssertEqual(queue.items.last?.state, .completed, queue.items.last?.detail ?? "")
        XCTAssertEqual(try text(try child("informe.txt", of: plan.targetFolderID).id), "versión dos, más larga")
        XCTAssertEqual(try text(try child("nuevo.txt", of: plan.targetFolderID).id), "nuevo")
        let versions = try child(BackupPlan.versionsFolder, of: plan.targetFolderID)
        let dated = try XCTUnwrap(demo.list(versions.id).first)
        XCTAssertEqual(try text(try child("informe.txt", of: dated.id).id), "versión uno", "What the run replaced is kept as it was")
        saved = try XCTUnwrap(manager.plans.first)
        XCTAssertEqual(saved.lastSummary, "1 nuevos, 1 actualizados")
        XCTAssertEqual(try names(in: try child("2026", of: plan.targetFolderID).id), ["acta.txt"], "The folder that did not change was left alone")
    }

    func testTheVersionsFolderIsNeverCopiedBackOrRemovedAndOldOnesArePruned() async throws {
        let plan = try setUpRun()
        try await runToTheEnd(plan.id)
        let versions = try demo.add(name: BackupPlan.versionsFolder, parent: plan.targetFolderID, folder: true)
        _ = try demo.add(name: "2020-01-01 03.00", parent: versions, folder: true)
        _ = try demo.add(name: "2099-01-01 03.00", parent: versions, folder: true)
        _ = try demo.add(name: "Notas mías", parent: versions, folder: true)
        manager.setOptions(keepsVersions: true, removesDeleted: true, retentionDays: 30, for: plan.id)
        let current = try XCTUnwrap(manager.plans.first)
        await manager.prune(current, api: CloudAPI(account: .demo, demo: demo))
        XCTAssertEqual(try names(in: versions), ["2099-01-01 03.00", "Notas mías"], "Only dated folders older than the plan keeps them go to the bin")
        try await runToTheEnd(plan.id)
        XCTAssertTrue(try names(in: plan.targetFolderID).contains(BackupPlan.versionsFolder), "A run with removals on does not take the versions for something deleted at the source")
    }

    func testAFileDeletedAtTheSourceLeavesTheCopyOnlyWhenAskedTo() async throws {
        let plan = try setUpRun()
        try await runToTheEnd(plan.id)
        try demo.deletePermanently(try child("informe.txt", of: plan.sourceFolderID).id)
        try await runToTheEnd(plan.id)
        XCTAssertTrue(try names(in: plan.targetFolderID).contains("informe.txt"), "By default nothing is ever taken out of the copy")
        manager.setOptions(keepsVersions: true, removesDeleted: true, retentionDays: nil, for: plan.id)
        try await runToTheEnd(plan.id)
        XCTAssertFalse(try names(in: plan.targetFolderID).contains("informe.txt"))
        let versions = try child(BackupPlan.versionsFolder, of: plan.targetFolderID)
        let dated = try XCTUnwrap(demo.list(versions.id).first)
        XCTAssertEqual(try text(try child("informe.txt", of: dated.id).id), "versión uno", "It is kept among the earlier versions")
        XCTAssertEqual(manager.plans.first?.baseline.keys.sorted(), ["2026/acta.txt"])
    }

    func testThePlanSurvivesBeingReadBackAndAPausedOneDoesNotRun() async throws {
        let plan = try setUpRun()
        manager.setPaused(true, for: plan.id)
        manager.runNow(plan.id)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(queue.items.isEmpty)
        let again = BackupManager(storeURL: root.appendingPathComponent("backups.json"))
        XCTAssertEqual(again.plans.map(\.id), [plan.id]); XCTAssertEqual(again.plans.first?.paused, true)
        XCTAssertThrowsError(try again.add(plan), "The same folder to the same place twice")
    }
}
