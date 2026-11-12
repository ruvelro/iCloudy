import XCTest
import CryptoKit
@testable import iCloudy

/// Serves a body in two acts: some of its bytes, then a lost connection. `StubProtocol` can only answer whole.
final class CuttingProtocol: URLProtocol {
    struct Answer { var status = 200; var headers: [String: String] = [:]; var body = Data(); var cutAfter: Int? }
    nonisolated(unsafe) static var handler: ((URLRequest) -> Answer)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let answer = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!, cacheStoragePolicy: .notAllowed)
        if let cut = answer.cutAfter {
            client?.urlProtocol(self, didLoad: answer.body.prefix(cut))
            // A real connection delivers what it has before it dies; failing in the same breath drops the bytes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// A download that lost its connection used to start again from the first byte, however much had arrived.
@MainActor
final class ResumableDownloadTests: XCTestCase {
    private let content = Data((0..<4000).map { UInt8($0 % 251) })
    /// The stand-in server answers on URLSession's threads; what it saw is read back on the main actor.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock(); private var seen: [URLRequest] = []
        func add(_ request: URLRequest) -> Int { lock.withLock { seen.append(request); return seen.count } }
        var all: [URLRequest] { lock.withLock { seen } }
    }
    private var recorder = Recorder()
    private var requests: [URLRequest] { recorder.all }

    override func setUp() async throws { recorder = Recorder() }

    private func client(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CuttingProtocol.self]
        var account = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil)
        if cloud == .webdav { account.serverURL = "https://nas.example/dav" }
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func partial() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(".icloudy-test-" + UUID().uuidString + ".part") }
    private func driveFile(_ data: Data? = nil) -> CloudFile {
        let data = data ?? content
        return CloudFile(id: "f1", name: "video.bin", mime: "application/octet-stream", size: Int64(data.count), modified: nil, webURL: nil,
                         isFolder: false, checksum: ContentHash(algorithm: .md5, value: UploadHasher.hex(Insecure.MD5.hash(data: data))))
    }
    private func davFile() -> CloudFile {
        CloudFile(id: "/dav/video.bin", name: "video.bin", mime: "application/octet-stream", size: Int64(content.count), modified: nil, webURL: nil, isFolder: false)
    }
    /// A server that honours Range and If-Range the way RFC 9110 says, and cuts the first answer short.
    private func serve(_ body: @escaping () -> Data, etag: @escaping () -> String? = { nil }, cutFirstAt cut: Int? = nil) {
        CuttingProtocol.handler = { [recorder] request in
            let first = recorder.add(request) == 1
            let data = body()
            var headers: [String: String] = [:]
            if let tag = etag() { headers["ETag"] = tag }
            if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                let condition = request.value(forHTTPHeaderField: "If-Range")
                if condition == nil || condition == etag() {
                    guard start < data.count else { return .init(status: 416, headers: headers) }
                    headers["Content-Range"] = "bytes \(start)-\(data.count - 1)/\(data.count)"
                    return .init(status: 206, headers: headers, body: data.suffix(from: start))
                }
            }
            return .init(status: 200, headers: headers, body: data, cutAfter: first ? cut : nil)
        }
    }
    private func resuming<T: Sendable>(_ work: @MainActor () async throws -> T) async throws -> T {
        try await DownloadResume.$mode.withValue(.validated) { try await work() }
    }

    func testACutDownloadContinuesFromWhatArrived() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        serve({ self.content }, cutFirstAt: 1500)
        let api = client(.google)
        do { _ = try await resuming { try await api.download(file: self.driveFile(), to: target) }; XCTFail("The connection was cut") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        XCTAssertEqual(try Data(contentsOf: target), content.prefix(1500), "What arrived stays for the next attempt")

        var reported: [Int64] = []
        let result = try await resuming { try await api.download(file: self.driveFile(), to: target) { bytes, _ in reported.append(bytes) } }
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(try Data(contentsOf: target), content)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=1500-")
        XCTAssertNil(DownloadResume.validator(of: target), "The finished file keeps no trace of the resume")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(reported.allSatisfy { $0 > 1500 }, "Progress counts the bytes that were already there")
    }

    func testOutsideTheQueueAFailureLeavesNothingAndNothingIsContinued() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        serve({ self.content }, cutFirstAt: 1500)
        let api = client(.google)
        do { _ = try await api.download(file: driveFile(), to: target); XCTFail("The connection was cut") } catch is URLError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        _ = try await api.download(file: driveFile(), to: target)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testWithoutAChecksumTheServerVouchesWithIfRange() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        serve({ self.content }, etag: { "\"v1\"" }, cutFirstAt: 1000)
        let api = client(.webdav)
        do { _ = try await resuming { try await api.download(file: self.davFile(), to: target) }; XCTFail("The connection was cut") } catch is URLError {}
        XCTAssertEqual(DownloadResume.validator(of: target), "\"v1\"")
        let result = try await resuming { try await api.download(file: self.davFile(), to: target) }
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=1000-")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testAFileThatChangedArrivesWholeInsteadOfSpliced() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        var body = content, tag = "\"v1\""
        serve({ body }, etag: { tag }, cutFirstAt: 1000)
        let api = client(.webdav)
        do { _ = try await resuming { try await api.download(file: self.davFile(), to: target) }; XCTFail("The connection was cut") } catch is URLError {}
        body = Data(content.reversed()); tag = "\"v2\""
        _ = try await resuming { try await api.download(file: self.davFile(), to: target) }
        XCTAssertEqual(try Data(contentsOf: target), body, "The server ignored the range: nothing of the old version is left")
    }

    func testWithoutChecksumOrValidatorNothingIsContinued() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        serve({ self.content }, cutFirstAt: 1000)
        let api = client(.webdav)
        do { _ = try await resuming { try await api.download(file: self.davFile(), to: target) }; XCTFail("The connection was cut") } catch is URLError {}
        _ = try await resuming { try await api.download(file: self.davFile(), to: target) }
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"), "Nobody could tell whether the rest belongs to the same file")
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testASpliceThatFailsItsChecksumIsFetchedWholeOnce() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        // Bytes left by an attempt against another version of the file: the rest will not match the listed MD5.
        try Data(repeating: 7, count: 1200).write(to: target)
        serve({ self.content })
        let result = try await resuming { try await self.client(.google).download(file: self.driveFile(), to: target) }
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(try Data(contentsOf: target), content)
        XCTAssertEqual(requests.compactMap { $0.value(forHTTPHeaderField: "Range") }, ["bytes=1200-"])
        XCTAssertEqual(requests.count, 2, "One continued attempt, one whole; the metadata is not asked for")
    }

    func testALeftoverAsLongAsTheFileStartsOver() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        try Data(repeating: 7, count: content.count + 10).write(to: target)
        serve({ self.content })
        let result = try await resuming { try await self.client(.google).download(file: self.driveFile(), to: target) }
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testAnExportIsNeverContinued() async throws {
        let target = partial(); defer { try? FileManager.default.removeItem(at: target) }
        try Data(repeating: 7, count: 100).write(to: target)
        serve({ self.content })
        let document = CloudFile(id: "f1", name: "Informe", mime: "application/vnd.google-apps.document", size: nil, modified: nil, webURL: nil, isFolder: false)
        let result = try await resuming { try await self.client(.google).download(file: document, to: target, exportMime: "application/pdf") }
        XCTAssertEqual(result, .exported)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    // MARK: - The queue

    private func queue(_ api: CloudAPI) -> (TransferQueue, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-" + UUID().uuidString)
        let output = root.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("transfers.json"))
        queue.client = { _ in api }
        queue.retryDelay = 0.01
        return (queue, output)
    }
    private func wait(_ queue: TransferQueue) async throws {
        for _ in 0..<500 {
            if !queue.isWorking, queue.items.allSatisfy(\.finished) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
    }

    func testTheQueueRetriesACutDownloadFromWhereItStopped() async throws {
        serve({ self.content }, cutFirstAt: 2500)
        let (queue, output) = queue(client(.google)); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let file = driveFile()
        try queue.add([Transfer(name: file.name, destination: output.path, accountID: "test", direction: .download, localURL: output, file: file)])
        try await wait(queue)
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(done.verifiedFiles, 1)
        XCTAssertEqual(requests.compactMap { $0.value(forHTTPHeaderField: "Range") }, ["bytes=2500-"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("video.bin")), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["video.bin"], "No partial file is left beside it")
        XCTAssertTrue(done.partials.isEmpty)
    }

    func testCancellingAFailedDownloadRemovesItsPartialFile() async throws {
        // Every answer is cut (past the 512 bytes URLSession holds back to sniff the type), so the three attempts run out and the job fails with bytes on disk.
        CuttingProtocol.handler = { [content, recorder] request in
            _ = recorder.add(request)
            if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                return .init(status: 206, headers: ["Content-Range": "bytes \(start)-\(content.count - 1)/\(content.count)"], body: content.suffix(from: start), cutAfter: 600)
            }
            return .init(body: content, cutAfter: 600)
        }
        let (queue, output) = queue(client(.google)); defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let file = driveFile()
        try queue.add([Transfer(name: file.name, destination: output.path, accountID: "test", direction: .download, localURL: output, file: file)])
        try await wait(queue)
        let failed = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(failed.state, .failed)
        let left = try FileManager.default.contentsOfDirectory(atPath: output.path)
        guard left.count == 1, left[0].hasSuffix(".part") else { return XCTFail("Expected one partial file, found \(left): \(failed.detail)") }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(left[0])).count, 2400, "Each attempt added to the one before")
        queue.clearFailed()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testOldQueuesDecodeWithoutPartials() throws {
        let legacy = #"{"accountID":"a","direction":"download","localURL":"file:///tmp/"}"#
        XCTAssertTrue(try JSONDecoder().decode(Transfer.self, from: Data(legacy.utf8)).partials.isEmpty)
    }
}
