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

/// A download that lost its connection used to start again from the first byte, however much had arrived. SFTP
/// already continued its own; this is the same for the providers that download over HTTP.
@MainActor
final class ResumableHTTPDownloadTests: XCTestCase {
    private let content = Data((0..<4000).map { UInt8($0 % 251) })
    private let listed = Date(timeIntervalSince1970: 1_790_000_000)
    /// The stand-in server answers on URLSession's threads; what it saw is read back on the main actor.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock(); private var seen: [URLRequest] = []
        func add(_ request: URLRequest) -> Int { lock.withLock { seen.append(request); return seen.count } }
        var all: [URLRequest] { lock.withLock { seen } }
    }
    private var recorder = Recorder()
    private var requests: [URLRequest] { recorder.all }
    private var folder: URL!

    override func setUp() async throws {
        recorder = Recorder()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func client(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CuttingProtocol.self]
        var account = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil)
        if cloud == .webdav { account.serverURL = "https://nas.example/dav" }
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    /// The queue's own name for a partial, which is what tells a provider it may be continued.
    private func partial() -> URL { folder.appendingPathComponent(ResumableDownload.partialName(job: UUID(), key: ".")) }
    private func driveFile(modified: Date? = Date(timeIntervalSince1970: 1_790_000_000)) -> CloudFile {
        CloudFile(id: "f1", name: "video.bin", mime: "application/octet-stream", size: Int64(content.count), modified: modified, webURL: nil,
                  isFolder: false, checksum: ContentHash(algorithm: .md5, value: UploadHasher.hex(Insecure.MD5.hash(data: content))))
    }
    private func davFile() -> CloudFile {
        CloudFile(id: "/dav/video.bin", name: "video.bin", mime: "application/octet-stream", size: Int64(content.count), modified: listed, webURL: nil, isFolder: false)
    }
    /// A server that honours Range and If-Range the way RFC 9110 says, and cuts the first answer short.
    private func serve(_ body: @escaping () -> Data, modified: @escaping () -> String? = { nil }, cutFirstAt cut: Int? = nil) {
        CuttingProtocol.handler = { [recorder] request in
            let first = recorder.add(request) == 1
            let data = body()
            if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                let condition = request.value(forHTTPHeaderField: "If-Range")
                if condition == nil || condition == modified() {
                    guard start < data.count else { return .init(status: 416) }
                    return .init(status: 206, headers: ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], body: data.suffix(from: start))
                }
            }
            return .init(status: 200, body: data, cutAfter: first ? cut : nil)
        }
    }

    func testACutDownloadContinuesFromWhatArrived() async throws {
        let target = partial()
        serve({ self.content }, cutFirstAt: 1500)
        let api = client(.google)
        do { _ = try await api.download(file: driveFile(), to: target); XCTFail("The connection was cut") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        XCTAssertEqual(try Data(contentsOf: target), content.prefix(1500), "What arrived stays for the next attempt")

        var reported: [Int64] = []
        let result = try await api.download(file: driveFile(), to: target) { bytes, _ in reported.append(bytes) }
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(try Data(contentsOf: target), content)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=1500-")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "If-Range"), "The checksum at the end is what vouches here")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(reported.allSatisfy { $0 > 1500 }, "Progress counts the bytes that were already there")
    }

    func testOutsideAPartialAFailureLeavesNothingAndNothingIsContinued() async throws {
        let target = folder.appendingPathComponent("plain.bin")
        serve({ self.content }, cutFirstAt: 1500)
        let api = client(.google)
        do { _ = try await api.download(file: driveFile(), to: target); XCTFail("The connection was cut") } catch is URLError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        _ = try await api.download(file: driveFile(), to: target)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testWithoutAChecksumTheListedDateGoesInIfRange() async throws {
        let target = partial()
        let date = CloudSession.httpDate(listed)
        XCTAssertEqual(date, "Mon, 21 Sep 2026 14:13:20 GMT")
        serve({ self.content }, modified: { date }, cutFirstAt: 1000)
        let api = client(.webdav)
        do { _ = try await api.download(file: davFile(), to: target); XCTFail("The connection was cut") } catch is URLError {}
        let result = try await api.download(file: davFile(), to: target)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=1000-")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Range"), date)
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testAServerHoldingAnotherVersionSendsTheWholeFileAndNothingIsSpliced() async throws {
        let target = partial()
        var body = content, stamp = CloudSession.httpDate(listed)
        serve({ body }, modified: { stamp }, cutFirstAt: 1000)
        let api = client(.webdav)
        do { _ = try await api.download(file: davFile(), to: target); XCTFail("The connection was cut") } catch is URLError {}
        // Replaced on the server by something of the same size, after the listing this job still carries.
        body = Data(content.reversed()); stamp = CloudSession.httpDate(listed.addingTimeInterval(60))
        _ = try await api.download(file: davFile(), to: target)
        XCTAssertEqual(try Data(contentsOf: target), body, "The server ignored the range: nothing of the old version is left")
    }

    func testAListingWithoutADateContinuesNothing() async throws {
        let target = partial()
        serve({ self.content }, cutFirstAt: 1000)
        let api = client(.google)
        do { _ = try await api.download(file: driveFile(modified: nil), to: target); XCTFail("The connection was cut") } catch is URLError {}
        _ = try await api.download(file: driveFile(modified: nil), to: target)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"), "Nobody could tell whether the rest belongs to the same version")
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testALeftoverOfAnotherVersionStartsOver() async throws {
        let target = partial()
        let other = CloudFile(id: "f1", name: "video.bin", mime: "application/octet-stream", size: 9000, modified: listed.addingTimeInterval(-500), webURL: nil, isFolder: false)
        _ = try ResumableDownload.prepare(target, for: other)
        try FileHandle(forWritingTo: target).write(contentsOf: Data(repeating: 7, count: 1200))
        serve({ self.content })
        let result = try await client(.google).download(file: driveFile(), to: target)
        XCTAssertEqual(result, .verified)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testAnExportIsNeverContinued() async throws {
        let target = partial()
        serve({ self.content })
        let document = CloudFile(id: "f1", name: "Informe", mime: "application/vnd.google-apps.document", size: nil, modified: listed, webURL: nil, isFolder: false)
        let result = try await client(.google).download(file: document, to: target, exportMime: "application/pdf")
        XCTAssertEqual(result, .exported)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: target), content)
    }

    func testTheProvidersThatDownloadOverHTTPDeclareIt() {
        for cloud in [Cloud.google, .microsoft, .dropbox, .box, .webdav, .sftp] { XCTAssertTrue(cloud.capabilities.resumesDownloads, cloud.rawValue) }
        for cloud in [Cloud.ftp, .mega, .o2, .volume] { XCTAssertFalse(cloud.capabilities.resumesDownloads, cloud.rawValue) }
        XCTAssertFalse(Account.demo.capabilities.resumesDownloads)
    }

    // MARK: - The queue

    private func wait(_ queue: TransferQueue) async throws {
        for _ in 0..<500 {
            if !queue.isWorking, queue.items.allSatisfy(\.finished) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for queue")
    }

    func testTheQueueRetriesACutDownloadFromWhereItStopped() async throws {
        serve({ self.content }, cutFirstAt: 2500)
        let api = client(.google)
        let output = folder.appendingPathComponent("out"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let queue = TransferQueue(storeURL: folder.appendingPathComponent("transfers.json"))
        queue.client = { _ in api }; queue.retryDelay = 0.01
        let file = driveFile()
        try queue.add([Transfer(name: file.name, destination: output.path, accountID: "test", direction: .download, localURL: output, file: file)])
        try await wait(queue)
        let done = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(done.state, .completed, done.detail)
        XCTAssertEqual(done.verifiedFiles, 1)
        XCTAssertEqual(requests.compactMap { $0.value(forHTTPHeaderField: "Range") }, ["bytes=2500-"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("video.bin")), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["video.bin"], "No partial file is left beside it")
    }
}
