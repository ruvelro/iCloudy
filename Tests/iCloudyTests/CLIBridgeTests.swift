import XCTest
import Darwin
import iCloudyCommandWire
@testable import iCloudy

/// The command-line companion's protocol, and the app's side of it end to end over a real loopback socket, with the
/// test playing the companion.
@MainActor
final class CLIBridgeTests: XCTestCase {
    func testARequestRoundTripsThroughItsURLAndRefusesWhatIsMalformed() throws {
        let request = CLIRequest(command: "ls", arguments: ["Trabajo:/Fotos/año 2024", "x&y=z"], port: 50_123,
                                 nonce: "0123456789abcdef0123456789abcdef", token: "tok")
        guard case .cli(let parsed) = try URLCommand.parse(request.url) else { return XCTFail("Not a CLI request") }
        XCTAssertEqual(parsed, request)
        let base = ["v": "1", "cmd": "ls", "port": "50123", "nonce": "0123456789abcdef"]
        XCTAssertNoThrow(try CLIRequest(fields: base))
        var bad = base; bad["cmd"] = "rm"; XCTAssertThrowsError(try CLIRequest(fields: bad), "Only known commands")
        bad = base; bad["port"] = "80"; XCTAssertThrowsError(try CLIRequest(fields: bad), "No privileged ports")
        bad = base; bad["nonce"] = "short"; XCTAssertThrowsError(try CLIRequest(fields: bad))
        bad = base; bad["v"] = "2"; XCTAssertThrowsError(try CLIRequest(fields: bad))
        bad = base; bad["args"] = "!!"; XCTAssertThrowsError(try CLIRequest(fields: bad))
    }

    func testFramesAndPlaces() throws {
        let message = CLIMessage(nonce: "n", ok: true, lines: ["a"], size: 3)
        for frame in [CLIFrame.message(message), .data(Data("abc".utf8)), .end] {
            let bytes = frame.encoded()
            let (type, length) = try CLIFrame.header(bytes.prefix(5))
            XCTAssertEqual(try CLIFrame.decode(type: type, payload: bytes.dropFirst(5).prefix(length)), frame)
        }
        XCTAssertThrowsError(try CLIFrame.header(Data([0x44, 0xFF, 0xFF, 0xFF, 0xFF])), "No frame is that long")
        XCTAssertEqual(CLIPlace("webdav:nas#ana:/Fotos/a.jpg"), CLIPlace(account: "webdav:nas#ana", path: "/Fotos/a.jpg"), "Ids with colons")
        XCTAssertEqual(CLIPlace("Trabajo:Fotos"), CLIPlace(account: "Trabajo", path: "Fotos"))
        XCTAssertEqual(CLIPlace("Trabajo"), CLIPlace(account: "Trabajo", path: ""))
        XCTAssertNil(CLIPlace(":/x"))
        XCTAssertTrue(CLIBridge.same("abc", "abc")); XCTAssertFalse(CLIBridge.same("abc", "abd")); XCTAssertFalse(CLIBridge.same("abc", "ab"))
    }

    // MARK: - End to end

    /// The companion's side: a listener on 127.0.0.1, the frames it reads and, for put, the bytes it sends.
    final class Companion: @unchecked Sendable {
        let listener: Int32
        let port: UInt16
        init() throws {
            listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let fd = listener
            guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0,
                  Darwin.listen(fd, 1) == 0 else { throw TestTimeout(description: "listen") }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            port = UInt16(bigEndian: address.sin_port)
        }
        deinit { close(listener) }
        private func read(_ fd: Int32, _ count: Int) throws -> Data {
            var data = Data(count: count), done = 0
            while done < count {
                let got = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + done, count - done, 0) }
                guard got > 0 else { throw TestTimeout(description: "closed") }
                done += got
            }
            return data
        }
        /// Accepts the app's connection and reads frames until the app closes it, sending `upload` when asked.
        func exchange(upload: Data? = nil) async throws -> [CLIFrame] {
            let fd = listener
            return try await Task.detached {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 15_000) > 0 else { throw TestTimeout(description: "no connection") }
                let client = Darwin.accept(fd, nil, nil)
                defer { close(client) }
                var frames: [CLIFrame] = []
                while true {
                    guard let head = try? self.read(client, 5) else { return frames }
                    let (type, length) = try CLIFrame.header(head)
                    let frame = try CLIFrame.decode(type: type, payload: length > 0 ? try self.read(client, length) : Data())
                    frames.append(frame)
                    if case .message(let message) = frame, message.awaitingUpload == true, let upload {
                        let payload = CLIFrame.data(upload).encoded() + CLIFrame.end.encoded()
                        _ = payload.withUnsafeBytes { send(client, $0.baseAddress!, payload.count, 0) }
                    }
                }
            }.value
        }
    }

    private func demoModel() throws -> AppModel {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        return model
    }
    private let nonce = "00112233445566778899aabbccddeeff"
    private func run(_ bridge: CLIBridge, _ model: AppModel, _ command: String, _ arguments: [String] = [], token: String?, upload: Data? = nil) async throws -> [CLIFrame] {
        let companion = try Companion()
        async let frames = companion.exchange(upload: upload)
        await bridge.handle(CLIRequest(command: command, arguments: arguments, port: companion.port, nonce: nonce, token: token), model: model)
        return try await frames
    }
    private func message(_ frames: [CLIFrame], _ index: Int = 0) -> CLIMessage? {
        guard frames.indices.contains(index), case .message(let message) = frames[index] else { return nil }
        return message
    }

    func testPairingIsAskedForAndOnlyThePairedCompanionIsAnswered() async throws {
        let model = try demoModel()
        let bridge = CLIBridge()
        var asked = 0
        bridge.approve = { _ in asked += 1; return false }
        let refused = try await run(bridge, model, "pair", token: nil)
        XCTAssertEqual(message(refused)?.ok, false)
        XCTAssertNil(Prefs.defaults.string(forKey: CLIBridge.tokenKey))

        bridge.approve = { _ in asked += 1; return true }
        let paired = try await run(bridge, model, "pair", token: nil)
        let token = try XCTUnwrap(message(paired)?.token)
        XCTAssertEqual(message(paired)?.nonce, nonce, "The answer proves which request it belongs to")
        XCTAssertEqual(asked, 2, "The person is asked every time")

        let stranger = try await run(bridge, model, "ls", ["demo:local:/Proyectos"], token: "otro")
        XCTAssertEqual(message(stranger)?.ok, false)
        XCTAssertTrue(message(stranger)?.error?.contains("icloudy pair") == true, "Without the token nothing is listed")

        let listed = try await run(bridge, model, "ls", ["Demo local:/Proyectos"], token: token)
        XCTAssertEqual(message(listed)?.ok, true)
        XCTAssertTrue(message(listed)?.lines?.contains { $0.hasSuffix("\tNotas.txt") } == true, "\(message(listed)?.lines ?? [])")
        let accounts = try await run(bridge, model, "accounts", token: token)
        XCTAssertTrue(message(accounts)?.lines?.first?.hasPrefix("demo:local\t") == true)
    }

    func testGetStreamsTheCheckedBytesAndPutQueuesAnUpload() async throws {
        let model = try demoModel()
        let bridge = CLIBridge()
        bridge.inbox = try temporaryRoot()
        bridge.approve = { _ in true }
        let pairing = try await run(bridge, model, "pair", token: nil)
        let token = try XCTUnwrap(message(pairing)?.token)

        let frames = try await run(bridge, model, "get", ["Demo local:/Proyectos/Notas.txt"], token: token)
        let header = try XCTUnwrap(message(frames))
        XCTAssertEqual(header.name, "Notas.txt")
        let bytes = frames.reduce(into: Data()) { if case .data(let chunk) = $1 { $0 += chunk } }
        XCTAssertEqual(Int64(bytes.count), header.size)
        XCTAssertEqual(frames.last, .end)
        let folder = try await model.automationList(.demo, path: "Proyectos")
        let notes = try XCTUnwrap(folder.first { $0.name == "Notas.txt" })
        XCTAssertEqual(Int64(bytes.count), notes.size)

        let payload = Data("subido desde la terminal".utf8)
        let put = try await run(bridge, model, "put", ["Demo local:/Proyectos", "terminal.txt", String(payload.count)], token: token, upload: payload)
        XCTAssertEqual(message(put)?.awaitingUpload, true)
        XCTAssertEqual(message(put, 1)?.ok, true, "\(message(put, 1)?.error ?? "")")
        let job = try XCTUnwrap(model.queue.items.last)
        XCTAssertEqual(job.name, "terminal.txt")
        XCTAssertEqual(try Data(contentsOf: job.localURL), payload)

        let tooMuch = try await run(bridge, model, "put", ["Demo local:/Proyectos", "b.txt", "2"], token: token, upload: payload)
        XCTAssertEqual(message(tooMuch, 1)?.ok, false, "More bytes than announced are refused")
    }

    func testJobsAreTheMirrors() async throws {
        let model = try demoModel()
        let bridge = CLIBridge()
        bridge.approve = { _ in true }
        let pairing = try await run(bridge, model, "pair", token: nil)
        let token = try XCTUnwrap(message(pairing)?.token)
        let list = try await run(bridge, model, "jobs", token: token)
        XCTAssertEqual(message(list)?.lines, [])
        let missing = try await run(bridge, model, "jobs", ["run", "Fotos"], token: token)
        XCTAssertEqual(message(missing)?.ok, false)
    }
}
