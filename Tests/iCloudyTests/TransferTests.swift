import XCTest
@testable import iCloudy

@MainActor
final class TransferTests: XCTestCase {
    private func fixture() throws -> (URL, DemoStore, TransferQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        return (root, demo, queue)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
        throw CloudError.message("Test timeout")
    }
    private func upload(_ url: URL, batch: UUID = UUID()) -> Transfer {
        Transfer(batchID: batch, name: url.lastPathComponent, destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: url)
    }

    func testDemoUploadDownloadAndPersistentIndex() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("binary.dat")
        let content = Data(repeating: 123, count: 750_000)
        try content.write(to: source)
        try queue.add([upload(source)])
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .completed)
        let file = try XCTUnwrap(demo.list("root").first { $0.name == "binary.dat" })
        let output = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try queue.add([Transfer(name: file.name, destination: output.path, accountID: Account.demo.id, direction: .download, localURL: output, file: file)])
        try await wait { !queue.isWorking }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(file.name)), content)
        let recovered = try DemoStore(directory: demo.directory)
        XCTAssertTrue(try recovered.list("root").contains { $0.id == file.id })
        XCTAssertEqual(queue.items.last?.state, .completed)
    }

    func testPauseRecoveryResumesWithoutCreatingDuplicate() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(20)
        let source = root.appendingPathComponent("large.dat")
        try Data(repeating: 7, count: 4 * 1024 * 1024).write(to: source)
        let item = upload(source)
        try queue.add([item])
        try await wait { (queue.items.first?.bytes ?? 0) > 0 }
        queue.cancel(item.id, pause: true)
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .paused)
        XCTAssertGreaterThan(queue.items.first?.uploads["."]?.offset ?? 0, 0)
        let restored = TransferQueue(storeURL: queue.storeURL)
        restored.client = { _ in CloudAPI(account: .demo, demo: demo) }
        XCTAssertEqual(restored.items.first?.state, .paused)
        restored.retry(item.id)
        try await wait { !restored.isWorking }
        XCTAssertEqual(restored.items.first?.state, .completed)
        XCTAssertEqual(try demo.list("root").filter { $0.name == "large.dat" }.count, 1)
    }

    func testCancelledQueuedJobDoesNotRunAndActiveJobCanCancel() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(20)
        let first = root.appendingPathComponent("first.dat"), second = root.appendingPathComponent("second.dat")
        try Data(repeating: 1, count: 4 * 1024 * 1024).write(to: first)
        try Data("second".utf8).write(to: second)
        let a = upload(first), b = upload(second)
        try queue.add([a, b]); queue.cancel(b.id)
        try await wait { (queue.items.first?.bytes ?? 0) > 0 }
        queue.cancel(a.id)
        try await wait { !queue.isWorking }
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .cancelled })
        XCTAssertFalse(try demo.list("root").contains { $0.name == "first.dat" || $0.name == "second.dat" })
    }

    func testConflictCopyAppliesToBatchAndReplaceUpdatesSameID() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = try demo.add(name: "same.txt", parent: "root", content: Data("old".utf8))
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let a = first.appendingPathComponent("same.txt"), b = second.appendingPathComponent("same.txt")
        try Data("new".utf8).write(to: a); try Data("other".utf8).write(to: b)
        let batch = UUID()
        try queue.add([upload(a, batch: batch), upload(b, batch: batch)])
        try await wait { queue.conflict != nil }
        queue.resolve(.copy, applyToBatch: true)
        try await wait { !queue.isWorking }
        let names = try demo.list("root").map(\.name)
        XCTAssertTrue(names.contains("same (2).txt")); XCTAssertTrue(names.contains("same (3).txt"))
        try queue.add([upload(a)])
        try await wait { queue.conflict != nil }
        queue.resolve(.replace, applyToBatch: false)
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.last?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(existing)), Data("new".utf8))
    }

    func testSkipAndCancelledDownloadPreserveExistingDestination() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(demo.list("root").first { $0.name.hasSuffix(".bin") })
        let target = root.appendingPathComponent(file.name)
        try Data("original".utf8).write(to: target)
        let item = Transfer(name: file.name, destination: root.path, accountID: Account.demo.id, direction: .download, localURL: root, file: file)
        try queue.add([item]); try await wait { queue.conflict != nil }
        queue.resolve(.skip, applyToBatch: false); try await wait { !queue.isWorking }
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        demo.latency = .milliseconds(20)
        var next = item; next.id = UUID()
        try queue.add([next]); try await wait { queue.conflict != nil }
        queue.resolve(.replace, applyToBatch: false)
        try await wait { (queue.items.last?.bytes ?? 0) > 0 }
        queue.cancel(next.id); try await wait { !queue.isWorking }
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
    }

    func testAutomaticRetryAndManualRetryAfterOfflineFailure() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("retry.txt"); try Data("retry".utf8).write(to: source)
        demo.failNext = true
        try queue.add([upload(source)]); try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .completed)
        XCTAssertEqual(queue.items.first?.attempts, 1)
        let another = root.appendingPathComponent("offline.txt"); try Data("offline".utf8).write(to: another)
        demo.offline = true
        let item = upload(another)
        try queue.add([item]); try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.last?.state, .failed)
        XCTAssertEqual(queue.items.last?.attempts, 3)
        demo.offline = false; queue.retry(item.id); try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.last?.state, .completed)
    }

    func testFolderMergeKeepsUnrelatedFilesAndCreatesNestedStructure() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try demo.add(name: "Folder", parent: "root", folder: true)
        _ = try demo.add(name: "keep.txt", parent: folder, content: Data("keep".utf8))
        let local = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: local.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try Data("added".utf8).write(to: local.appendingPathComponent("Nested/new.txt"))
        try queue.add([upload(local)]); try await wait { queue.conflict != nil }
        queue.resolve(.replace, applyToBatch: true); try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .completed)
        let contents = try demo.list(folder)
        XCTAssertTrue(contents.contains { $0.name == "keep.txt" })
        let nested = try XCTUnwrap(contents.first { $0.name == "Nested" })
        XCTAssertTrue(try demo.list(nested.id).contains { $0.name == "new.txt" })
    }

    func testWaitingJobsCanBeReorderedAndPersistTheirOrder() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(50)
        var jobs: [Transfer] = []
        for name in ["a", "b", "c"] {
            let url = root.appendingPathComponent(name); try Data(repeating: 1, count: 512 * 1024).write(to: url); jobs.append(upload(url))
        }
        try queue.add(jobs)
        queue.pauseAll()
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.map(\.name), ["a", "b", "c"])
        queue.prioritize(jobs[2].id)
        XCTAssertEqual(queue.items.map(\.name), ["c", "a", "b"])
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(queue.items.map(\.name), ["a", "b", "c"], "SwiftUI onMove semantics: destination indexes the list before removal")
        XCTAssertEqual(TransferQueue(storeURL: queue.storeURL).items.map(\.name), ["a", "b", "c"], "Order is persisted")
        queue.retry(jobs[0].id)
        try await wait { queue.items.first?.state == .running }
        XCTAssertFalse(queue.isMovable(queue.items[0]), "The running job is pinned")
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(queue.items.first?.name, "a")
        queue.pauseAll(); try await wait { !queue.isWorking }
    }

    func testCancelBatchStopsOnlyTheMatesOfThatBatch() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(50)
        let batch = UUID(), other = UUID()
        var jobs: [Transfer] = []
        for (name, id) in [("a", batch), ("b", batch), ("c", other), ("d", batch)] {
            let url = root.appendingPathComponent(name); try Data(repeating: 1, count: 512 * 1024).write(to: url); jobs.append(upload(url, batch: id))
        }
        try queue.add(jobs)
        try await wait { queue.items.first?.state == .running }
        XCTAssertEqual(queue.pendingBatchMates(of: jobs[0].id), 2)
        XCTAssertEqual(queue.pendingBatchMates(of: jobs[2].id), 0)
        queue.cancelBatch(batch)
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.map(\.state), [.cancelled, .cancelled, .completed, .cancelled])
    }

    func testHistoryKeepsCompletedTransfersAcrossClearAndRestart() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = TransferHistory(storeURL: root.appendingPathComponent("history.json"))
        history.limit = 2
        queue.didFinish = { history.record($0) }
        let source = root.appendingPathComponent("hist.dat"); try Data(repeating: 9, count: 2048).write(to: source)
        try queue.add([upload(source)])
        try await wait { !queue.isWorking }
        let file = try XCTUnwrap(demo.list("root").first { $0.name == "hist.dat" })
        let output = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try queue.add([Transfer(name: file.name, destination: output.path, accountID: Account.demo.id, direction: .download, localURL: output, file: file)])
        try await wait { !queue.isWorking }
        let second = root.appendingPathComponent("hist2.dat"); try Data(repeating: 8, count: 1024).write(to: second)
        try queue.add([upload(second)])
        try await wait { !queue.isWorking }
        XCTAssertEqual(history.entries.count, 2, "The limit trims the oldest entry")
        XCTAssertEqual(history.entries.first?.direction, .upload, "Newest first")
        let download = try XCTUnwrap(history.entries.first { $0.direction == .download })
        XCTAssertEqual(download.localURL?.lastPathComponent, "hist.dat")
        XCTAssertEqual(download.bytes, 2048)
        queue.clearCompleted()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(TransferHistory(storeURL: history.storeURL).entries.map(\.id), history.entries.map(\.id), "Persisted independently of the queue")
        XCTAssertTrue(history.entries.allSatisfy { !$0.summary.isEmpty || $0.direction == .download })
    }

    func testEachKindOfFinishedTransferCanBeClearedOnItsOwn() async throws {
        // A failed transfer is never retried by itself, so without a way to clear it the panel fills with dead
        // entries and buries whatever is actually running.
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("bien.txt"); try Data("bien".utf8).write(to: good)
        try queue.add([upload(good)]); try await wait { !queue.isWorking }
        demo.offline = true
        let bad = root.appendingPathComponent("mal.txt"); try Data("mal".utf8).write(to: bad)
        try queue.add([upload(bad)]); try await wait { !queue.isWorking }
        demo.offline = false
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed])

        queue.clearCompleted()
        XCTAssertEqual(queue.items.map(\.name), ["mal.txt"], "Limpiar completadas deja la que falló a la vista")
        queue.clearFailed()
        XCTAssertTrue(queue.items.isEmpty, "Y ahora sí se puede quitar")

        // Two more, with names of their own so neither collides with what is already in the cloud, cleared in one go.
        let other = root.appendingPathComponent("otro.txt"); try Data("otro".utf8).write(to: other)
        try queue.add([upload(other)]); try await wait { !queue.isWorking }
        demo.offline = true
        let alsoBad = root.appendingPathComponent("tambien-mal.txt"); try Data("mal".utf8).write(to: alsoBad)
        try queue.add([upload(alsoBad)]); try await wait { !queue.isWorking }
        demo.offline = false
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed])
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testTheErrorTabIsClearedByHalvesOrWhole() async throws {
        // Fallidas y canceladas comparten pestaña, y cada filtro limpia lo suyo sin llevarse lo otro por delante.
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("bien.txt"); try Data("bien".utf8).write(to: good)
        try queue.add([upload(good)]); try await wait { !queue.isWorking }
        demo.offline = true
        let bad = root.appendingPathComponent("mal.txt"); try Data("mal".utf8).write(to: bad)
        try queue.add([upload(bad)]); try await wait { !queue.isWorking }
        demo.offline = false
        let stopped = upload(root.appendingPathComponent("parada.txt"))
        try Data("parada".utf8).write(to: stopped.localURL)
        try queue.add([stopped]); queue.cancel(stopped.id)
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed, .cancelled])

        queue.clearCancelled()
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed], "Limpiar las canceladas deja la que falló")
        queue.clearErrored()
        XCTAssertEqual(queue.items.map(\.state), [.completed], "Y el botón sin filtro se lleva las dos mitades")
    }

    func testClearingTheInProgressTabStopsEverythingAndLeavesNothingBehind() async throws {
        // Cancelar sin más dejaría las paradas en la pestaña de error, así que "limpiar" habría que pulsarlo dos
        // veces para que una sola lista desapareciera.
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(20)
        let done = root.appendingPathComponent("hecha.txt"); try Data("hecha".utf8).write(to: done)
        try queue.add([upload(done)]); try await wait { !queue.isWorking }
        var jobs: [Transfer] = []
        for name in ["a.dat", "b.dat", "c.dat"] {
            let url = root.appendingPathComponent(name); try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: url)
            jobs.append(upload(url))
        }
        try queue.add(jobs)
        try await wait { queue.items.contains { $0.state == .running } }
        queue.cancel(jobs[2].id, pause: true)

        XCTAssertEqual(queue.cancelActive(), 3, "Lo que corre, lo que espera y lo que está en pausa")
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.map(\.name), ["hecha.txt"], "Sólo sobrevive lo que ya había terminado")
        XCTAssertEqual(TransferQueue(storeURL: queue.storeURL).items.map(\.name), ["hecha.txt"], "Y así queda en disco")
    }

    func testDraggingAWaitingJobCountsOnlyTheJobsThatTabShows() async throws {
        // La pestaña "En curso" no enseña las terminadas, así que sus índices no son los de la cola entera.
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let done = root.appendingPathComponent("hecha.txt"); try Data("hecha".utf8).write(to: done)
        try queue.add([upload(done)]); try await wait { !queue.isWorking }
        demo.latency = .milliseconds(50)
        var jobs: [Transfer] = []
        for name in ["a", "b", "c"] {
            let url = root.appendingPathComponent(name); try Data(repeating: 1, count: 512 * 1024).write(to: url)
            jobs.append(upload(url))
        }
        try queue.add(jobs)
        queue.pauseAll(); try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.map(\.name), ["hecha.txt", "a", "b", "c"])

        queue.moveActive(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.name), ["hecha.txt", "c", "a", "b"], "El tercero de la pestaña es «c», no «b»")
        queue.moveActive(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(queue.items.map(\.name), ["hecha.txt", "a", "b", "c"], "Y el final de la pestaña es el final de la cola")
        queue.moveActive(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(queue.items.map(\.name), ["hecha.txt", "a", "b", "c"], "Un índice que la pestaña no tiene no mueve nada")
    }

    func testTodaysHistoryCanBeClearedWithoutLosingTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("history.json")
        let job = Transfer(name: "x", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: root)
        let today = HistoryEntry(transfer: job)
        let older = HistoryEntry(transfer: job, finishedAt: Date(timeIntervalSinceNow: -60 * 60 * 30))
        try LocalStore.save([today, older], to: store)
        let history = TransferHistory(storeURL: store)
        XCTAssertEqual(history.entries.count, 2)

        history.clearToday()
        XCTAssertEqual(history.entries.map(\.id), [older.id], "Sólo se va lo de hoy")
        XCTAssertEqual(TransferHistory(storeURL: store).entries.map(\.id), [older.id], "Y el recorte se guarda")
    }

    func testLosingTheNetworkPausesAndRecoveringResumesWithoutUserAction() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(30)
        var jobs: [Transfer] = []
        for name in ["a", "b"] { let url = root.appendingPathComponent(name); try Data(repeating: 1, count: 4 * 1024 * 1024).write(to: url); jobs.append(upload(url)) }
        try queue.add(jobs)
        try await wait { (queue.items.first?.bytes ?? 0) > 0 }
        queue.setOnline(false)
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.map(\.state), [.paused, .paused])
        XCTAssertTrue(queue.items.allSatisfy { $0.status.contains("Sin conexión") })
        let late = root.appendingPathComponent("c"); try Data(repeating: 1, count: 1024).write(to: late)
        try queue.add([upload(late)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(queue.items.last?.state, .queued, "Nothing starts while offline")
        XCTAssertFalse(queue.isWorking)
        queue.setOnline(true)
        try await wait { queue.items.allSatisfy { $0.state == .completed } }
        XCTAssertEqual(try demo.list("root").filter { ["a", "b", "c"].contains($0.name) }.count, 3)
    }

    func testManualPauseIsNotResumedByTheNetwork() async throws {
        let (root, demo, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        demo.latency = .milliseconds(30)
        let url = root.appendingPathComponent("manual"); try Data(repeating: 1, count: 512 * 1024).write(to: url)
        let job = upload(url)
        try queue.add([job])
        queue.cancel(job.id, pause: true)
        try await wait { !queue.isWorking }
        queue.setOnline(false); queue.setOnline(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(queue.items.first?.state, .paused, "Only network-paused jobs resume automatically")
        XCTAssertEqual(queue.items.first?.status, "En pausa · Reanudar para continuar")
    }

    func testCrossCloudTransferStagesEachFileAndRebuildsTheTreeOnTheOtherAccount() async throws {
        let (root, demoA, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let demoB = try DemoStore(directory: root.appendingPathComponent("cloudB")); demoB.latency = .milliseconds(1)
        let other = Account(id: "demo:other", cloud: .microsoft, name: "B", email: "b@example.com", clientID: "", clientSecret: nil)
        queue.client = { id in id == Account.demo.id ? CloudAPI(account: .demo, demo: demoA) : CloudAPI(account: other, demo: demoB) }
        queue.scratchRoot = root.appendingPathComponent("scratch")
        let folder = try demoA.add(name: "Viaje", parent: "root", folder: true)
        _ = try demoA.add(name: "foto.bin", parent: folder, content: Data(repeating: 3, count: 300_000))
        let nested = try demoA.add(name: "Notas", parent: folder, folder: true)
        _ = try demoA.add(name: "dia1.txt", parent: nested, content: Data("hola".utf8))
        let source = try XCTUnwrap(demoA.list("root").first { $0.id == folder })
        var job = Transfer(batchID: UUID(), name: source.name, destination: "B", accountID: Account.demo.id, direction: .transfer, localURL: URL(fileURLWithPath: "/"), parent: "root", file: source)
        job.localURL = queue.scratchDirectory(for: job.id); job.targetAccountID = other.id
        try queue.add([job])
        XCTAssertTrue(queue.hasActive(accountID: other.id), "The destination account is busy too")
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        let copied = try XCTUnwrap(demoB.list("root").first { $0.name == "Viaje" })
        let photo = try XCTUnwrap(demoB.list(copied.id).first { $0.name == "foto.bin" })
        XCTAssertEqual(try Data(contentsOf: demoB.directory.appendingPathComponent(photo.id)), Data(repeating: 3, count: 300_000))
        let notes = try XCTUnwrap(demoB.list(copied.id).first { $0.name == "Notas" })
        XCTAssertEqual(try demoB.list(notes.id).map(\.name), ["dia1.txt"])
        XCTAssertTrue(try demoA.list(folder).contains { $0.name == "foto.bin" }, "The source is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.localURL.path), "Staging folder removed after completion")
        XCTAssertEqual(queue.items.first?.verifiedFiles, 2)
        XCTAssertFalse(queue.hasActive(accountID: other.id))
    }

    func testRecoveryPausesRunningJobsAndCorruptionIsNotOverwritten() throws {
        let (root, _, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var item = upload(root.appendingPathComponent("test")); item.state = .running
        try LocalStore.save([item], to: queue.storeURL)
        let recovered = TransferQueue(storeURL: queue.storeURL)
        XCTAssertEqual(recovered.items.first?.state, .paused)
        let corrupt = Data("not-json".utf8); try corrupt.write(to: queue.storeURL)
        let broken = TransferQueue(storeURL: queue.storeURL)
        XCTAssertNotNil(broken.persistenceError)
        XCTAssertThrowsError(try broken.add([item]))
        XCTAssertEqual(try Data(contentsOf: queue.storeURL), corrupt)
    }

    func testDemoRenameAndFavoriteSerializationKeepIdentity() throws {
        let (root, demo, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(demo.list("root").first { $0.isFolder })
        try demo.rename(file.id, name: "Renamed")
        XCTAssertTrue(try demo.list("root").contains { $0.id == file.id && $0.name == "Renamed" })
        let favorite = Favorite(accountID: Account.demo.id, file: file, path: [])
        let url = root.appendingPathComponent("favorites.json")
        try LocalStore.save([favorite], to: url)
        XCTAssertEqual(try LocalStore.read([Favorite].self, from: url)?.first?.id, favorite.id)
    }
}
