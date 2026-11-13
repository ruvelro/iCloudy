import XCTest
import CryptoKit
@testable import iCloudy

/// Answers after a pause, and remembers how many downloads were open at the same moment.
final class SlowProtocol: URLProtocol {
    final class Meter: @unchecked Sendable {
        private let lock = NSLock(); private var open = 0, peak = 0, served: [String] = []
        func enter(_ path: String) { lock.withLock { open += 1; peak = max(peak, open); served.append(path) } }
        func leave() { lock.withLock { open -= 1 } }
        var most: Int { lock.withLock { peak } }
        var paths: [String] { lock.withLock { served } }
    }
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var meter = Meter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let media = request.url?.query?.contains("alt=media") == true
        let meter = Self.meter
        if media { meter.enter(request.url!.path) }
        let (status, data) = Self.handler!(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + (media ? 0.06 : 0)) { [self] in
            if media { meter.leave() }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// The files of a folder used to travel one after another, each waiting for the round trips of the one before.
@MainActor
final class ParallelTransferTests: XCTestCase {
    private func body(_ index: Int) -> Data { Data("contenido del archivo número \(index)".utf8) }
    private func md5(_ data: Data) -> String { UploadHasher.hex(Insecure.MD5.hash(data: data)) }

    /// A Drive folder "dir" with `count` files, f0…; `broken` answers 404 for its content.
    private func serveFolder(count: Int, broken: @escaping () -> Set<Int> = { [] }) {
        SlowProtocol.meter = SlowProtocol.Meter()
        SlowProtocol.handler = { [self] request in
            let path = request.url!.path, query = request.url!.query ?? ""
            if query.contains("alt=media") {
                let index = Int(path.split(separator: "/").last!.dropFirst())!
                return broken().contains(index) ? (404, Data(#"{"error":{"code":404,"message":"File not found"}}"#.utf8)) : (200, body(index))
            }
            let files = (0..<count).map { #"{"id":"f\#($0)","name":"archivo-\#($0).txt","mimeType":"text/plain","size":"\#(body($0).count)","md5Checksum":"\#(md5(body($0)))"}"# }
            return (200, Data(#"{"files":[\#(files.joined(separator: ","))]}"#.utf8))
        }
    }
    private func queue(filesPerJob: Int) -> (TransferQueue, URL) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SlowProtocol.self]
        let account = Account(id: "test", cloud: .google, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil)
        let api = CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-" + UUID().uuidString)
        let output = root.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("transfers.json"))
        queue.client = { _ in api }
        queue.retryDelay = 0.01
        var policy = TransferPolicy(); policy.filesPerJob = filesPerJob
        queue.policy = policy
        return (queue, output)
    }
    private func folderJob(into output: URL) -> Transfer {
        let folder = CloudFile(id: "dir", name: "Carpeta", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        return Transfer(name: folder.name, destination: output.path, accountID: "test", direction: .download, localURL: output, file: folder)
    }
    private func wait(_ queue: TransferQueue) async throws {
        for _ in 0..<800 {
            if !queue.isWorking, queue.items.allSatisfy(\.finished) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
    }

    func testTheFilesOfAFolderTravelSideBySideWithinTheWidth() async throws {
        serveFolder(count: 12)
        let (queue, output) = queue(filesPerJob: 4); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        try queue.add([folderJob(into: output)])
        try await wait(queue)
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(done.verifiedFiles, 12)
        XCTAssertEqual(SlowProtocol.meter.most, 4, "As many at once as the setting allows, and no more")
        let folder = output.appendingPathComponent("Carpeta")
        for index in 0..<12 { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("archivo-\(index).txt")), body(index)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 12, "No partial file is left")
        XCTAssertEqual(done.bytes, done.total)
    }

    func testAWidthOfOneIsTheOldOrder() async throws {
        serveFolder(count: 5)
        let (queue, output) = queue(filesPerJob: 1); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        try queue.add([folderJob(into: output)])
        try await wait(queue)
        XCTAssertEqual(queue.items.first?.state, .completed)
        XCTAssertEqual(SlowProtocol.meter.most, 1)
        XCTAssertEqual(SlowProtocol.meter.paths.map { String($0.split(separator: "/").last!) }, ["f0", "f1", "f2", "f3", "f4"])
    }

    func testOneFileFailingFailsTheFolderWithoutMarkingItComplete() async throws {
        var broken: Set<Int> = [7]
        serveFolder(count: 12) { broken }
        let (queue, output) = queue(filesPerJob: 4); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        try queue.add([folderJob(into: output)])
        try await wait(queue)
        var job = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertFalse(job.completedPaths.contains("."), "A folder with a file missing is not a finished folder")
        XCTAssertFalse(job.completedPaths.contains("./f7"))
        XCTAssertEqual(job.report["./f7"]?.outcome, .failed, "The failure lands on the file that failed, not on whichever the walk had reached")
        let arrived = job.completedPaths.count
        let before = SlowProtocol.meter.paths.count

        broken = []
        queue.retry(job.id)
        try await wait(queue)
        job = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(job.state, .completed, job.detail)
        XCTAssertEqual(SlowProtocol.meter.paths.count - before, 12 - arrived, "Only what had not arrived is asked for again")
        let folder = output.appendingPathComponent("Carpeta")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), (0..<12).map { "archivo-\($0).txt" }.sorted())
    }

    func testSessionsThatDoOneThingAtATimeKeepOneFile() {
        var policy = TransferPolicy(); policy.filesPerJob = 6
        func account(_ cloud: Cloud) -> Account { Account(id: cloud.rawValue, cloud: cloud, name: "", email: "", clientID: "", clientSecret: nil) }
        XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(.google)], uploading: false), 6)
        XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(.google), account(.box)], uploading: true), 6)
        for serial in [Cloud.ftp, .sftp, .mega, .o2] {
            XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(serial)], uploading: false), 1, serial.rawValue)
            XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(.google), account(serial)], uploading: true), 1, serial.rawValue)
        }
        XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(.dropbox)], uploading: true), 1, "Dropbox locks the namespace per commit")
        XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(.google), account(.dropbox)], uploading: true), 1)
        XCTAssertEqual(TransferScheduler.filesAtOnce(policy, accounts: [account(.dropbox)], uploading: false), 6, "Reading from it is another matter")
    }

    func testTheSettingIsReadWithinItsRange() {
        let defaults = UserDefaults(suiteName: "parallel-" + UUID().uuidString)!
        XCTAssertEqual(TransferPolicy.stored(in: defaults).filesPerJob, 4)
        defaults.set(99, forKey: Prefs.transferFilesPerJob)
        XCTAssertEqual(TransferPolicy.stored(in: defaults).filesPerJob, 8)
        defaults.set(0, forKey: Prefs.transferFilesPerJob)
        XCTAssertEqual(TransferPolicy.stored(in: defaults).filesPerJob, 1)
    }

    func testLanesHandOverInOrderAndACancelledWaitLeavesTheLine() async throws {
        let lanes = TransferLanes(2)
        try await lanes.acquire(); try await lanes.acquire()
        var order: [Int] = []
        let first = Task { try await lanes.acquire(); order.append(1) }
        let second = Task { try await lanes.acquire(); order.append(2) }
        let third = Task { try await lanes.acquire(); order.append(3) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(order, [], "Both lanes are taken")
        second.cancel()
        try await Task.sleep(for: .milliseconds(20))
        lanes.release(); lanes.release()
        try await first.value; try await third.value
        do { try await second.value; XCTFail("The cancelled wait never got a lane") } catch is CancellationError {}
        XCTAssertEqual(order, [1, 3])
    }

    func testS3PartsInFlightNeverHoldMoreThanTheirBudget() {
        XCTAssertEqual(S3Provider.partsAtOnce(partSize: 8 * 1024 * 1024), 4)
        XCTAssertEqual(S3Provider.partsAtOnce(partSize: 32 * 1024 * 1024), 2)
        XCTAssertEqual(S3Provider.partsAtOnce(partSize: 512 * 1024 * 1024), 1)
    }
}
