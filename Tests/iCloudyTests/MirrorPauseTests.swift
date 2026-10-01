import XCTest
@testable import iCloudy

/// Pausing a mirror survives a relaunch, notes what changes meanwhile and applies it all on resume.
@MainActor
final class MirrorPauseTests: XCTestCase {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out"); throw CloudError.message("timeout")
    }
    private struct Setup {
        let root: URL, local: URL, demo: DemoStore, queue: TransferQueue, remote: CloudFile
    }
    private func setup() throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("Docs")
        try write("a", to: local.appendingPathComponent("a.txt"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let id = try demo.add(name: "Destino", parent: "root", folder: true)
        return Setup(root: root, local: local, demo: demo, queue: queue, remote: try XCTUnwrap(demo.list("root").first { $0.id == id }))
    }
    private func manager(_ s: Setup) -> MirrorManager {
        let manager = MirrorManager(storeURL: s.root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = s.queue
        s.queue.didFinish = { [weak manager] in manager?.handleFinished($0) }
        return manager
    }

    func testPauseSurvivesARelaunchAndResumeAppliesWhatChangedMeanwhile() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        let first = manager(s)
        try first.add(local: s.local, account: .demo, folder: s.remote, path: [])
        try await wait { first.mirrors.first?.lastSync != nil }
        let id = first.mirrors[0].id
        first.setPaused(true, for: id)
        XCTAssertEqual(first.status(of: first.mirrors[0]), "En pausa")

        // What FSEvents would hand over: one real change, one excluded file and one path outside the folder.
        try write("nuevo", to: s.local.appendingPathComponent("b.txt"))
        first.noteChanges([s.local.appendingPathComponent("b.txt").path, s.local.appendingPathComponent(".DS_Store").path, s.root.appendingPathComponent("fuera.txt").path], for: id)
        XCTAssertEqual(first.mirrors[0].changesWhilePaused, ["b.txt"])
        XCTAssertEqual(first.status(of: first.mirrors[0]), "En pausa · 1 cambios esperando")
        XCTAssertEqual(try s.demo.list(s.remote.id).map(\.name), ["a.txt"], "En pausa no se planifica nada")

        // Relaunch: still paused, still counting, and "sync now" does nothing.
        let restored = manager(s)
        XCTAssertTrue(restored.mirrors[0].paused)
        XCTAssertEqual(restored.mirrors[0].changesWhilePaused, ["b.txt"])
        restored.start()
        restored.syncNow(id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(s.queue.items.count, 1, "Ni el arranque ni «Sincronizar ahora» encolan nada")
        // A change FSEvents never reported (the app was closed) is caught as well on resume.
        try write("cambiado", to: s.local.appendingPathComponent("a.txt"))

        let before = restored.mirrors[0].lastSync
        restored.setPaused(false, for: id)
        XCTAssertTrue(restored.mirrors[0].changesWhilePaused.isEmpty)
        try await wait { restored.mirrors[0].lastSync != before }
        XCTAssertEqual(try s.demo.list(s.remote.id).map(\.name).sorted(), ["a.txt", "b.txt"])
        let a = try XCTUnwrap(s.demo.list(s.remote.id).first { $0.name == "a.txt" })
        XCTAssertEqual(try String(contentsOf: s.demo.directory.appendingPathComponent(a.id), encoding: .utf8), "cambiado")
        XCTAssertFalse(manager(s).mirrors[0].paused, "La reanudación también se guarda")
    }

    func testPausingHoldsTheMirrorsQueuedUploadAndResumingFinishesIt() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        s.queue.setOnline(false)
        let manager = manager(s)
        try manager.add(local: s.local, account: .demo, folder: s.remote, path: [])
        try await wait { manager.mirrors.first?.activeTransferID != nil }
        let id = manager.mirrors[0].id, job = try XCTUnwrap(manager.mirrors[0].activeTransferID)
        manager.setPaused(true, for: id)
        XCTAssertEqual(s.queue.items.first { $0.id == job }?.state, .paused)
        // The network returning revives what it paused, not what the person paused.
        s.queue.setOnline(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(s.queue.items.first { $0.id == job }?.state, .paused)
        XCTAssertNil(manager.mirrors[0].lastSync)

        manager.setPaused(false, for: id)
        try await wait { manager.mirrors[0].lastSync != nil }
        XCTAssertEqual(s.queue.items.count, 1, "Se reanuda el mismo trabajo, no se planifica otro")
        XCTAssertEqual(s.queue.items.first?.state, .completed)
    }

    func testATwoWayRunStopsBetweenStepsAndTheNextRunCarriesOn() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = base.appendingPathComponent("local")
        let demo = try DemoStore(directory: base.appendingPathComponent("demo")); demo.latency = .zero
        let api = CloudAPI(account: .demo, demo: demo)
        let root = try demo.add(name: "Sync", parent: "root", folder: true)
        for name in ["1.txt", "2.txt", "3.txt"] { try write(name, to: local.appendingPathComponent(name)) }

        var saved: [String: SyncEntry] = [:]
        let engine = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: [:])
        var asked = 0
        engine.shouldStop = { asked += 1; return asked > 1 }
        engine.persist = { saved = $0 }
        do { _ = try await engine.run(); XCTFail("Debía detenerse") } catch { XCTAssertTrue(error is SyncPaused, "\(error)") }
        XCTAssertEqual(saved.count, 1, "El paso hecho queda en la línea base")
        XCTAssertEqual(try demo.list(root).count, 1)

        let next = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: saved)
        let report = try await next.run()
        XCTAssertEqual(report.uploaded, 2, "Solo lo que faltaba")
        XCTAssertEqual(report.downloaded, 0, "Lo subido antes de la pausa no se toma por un cambio remoto")
        XCTAssertEqual(try demo.list(root).map(\.name).sorted(), ["1.txt", "2.txt", "3.txt"])
    }

    func testOlderRecordsAreNotPaused() throws {
        let json = #"[{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/"}]"#
        let decoded = try XCTUnwrap(JSONDecoder().decode([FolderMirror].self, from: Data(json.utf8)).first)
        XCTAssertFalse(decoded.paused)
        XCTAssertTrue(decoded.changesWhilePaused.isEmpty)
        XCTAssertEqual(decoded.exclusions, SyncExclusions(), "Los reflejos anteriores reciben las exclusiones por omisión")
    }
}
