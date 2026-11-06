// icloudy — the command-line companion of iCloudy. It talks to the running app (and launches it if needed): the app
// is sandboxed and cannot be reached on a socket of its own, so this program listens on 127.0.0.1, asks the app to
// connect back through an icloudy:// link, and reads the answer. See Sources/iCloudyCommandWire.
//
// Its messages are in English: a terminal tool's output is read by scripts as much as by people.
import Foundation
import Darwin
import iCloudyCommandWire

let usage = """
usage: icloudy <command> [arguments]

  pair                          authorise this companion (iCloudy asks you to confirm)
  accounts                      list the connected accounts
  ls <account>:/<path>          list a folder
  get <account>:/<path> [file]  download a file (to ./name, or to file; - for standard output)
  put <file> <account>:/<path>  queue an upload of file into the folder
  search <term> [account]       search every account (or one)
  open <account>:/<path>        show the place in iCloudy
  jobs                          list the folder mirrors
  jobs run <name>               sync a mirror now

An account is named by its id, its alias, its name or its e-mail, as iCloudy shows them.
The token from `pair` is kept in ~/.config/icloudy/token (or taken from $ICLOUDY_TOKEN).
"""

struct Failure: Error, CustomStringConvertible { let description: String }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("icloudy: " + message + "\n").utf8))
    exit(code)
}

// MARK: - Token

let tokenFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/icloudy/token")
func readToken() -> String? {
    if let env = ProcessInfo.processInfo.environment["ICLOUDY_TOKEN"], !env.isEmpty { return env }
    return (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}
func saveToken(_ token: String) throws {
    let folder = tokenFile.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
}

// MARK: - Socket

/// A listening socket on 127.0.0.1 and an ephemeral port, for the app's one connection back.
final class Listener {
    let descriptor: Int32
    let port: UInt16
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "cannot create a socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw Failure(description: "cannot listen on 127.0.0.1") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }
    /// The connection the app makes, or nil after `timeout` seconds.
    func accept(timeout: Int32) -> Connection? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, timeout * 1000) > 0 else { return nil }
        let client = Darwin.accept(descriptor, nil, nil)
        return client >= 0 ? Connection(descriptor: client) : nil
    }
    deinit { close(descriptor) }
}

final class Connection {
    let descriptor: Int32
    init(descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { close(descriptor) }
    func read(exactly count: Int) throws -> Data {
        var data = Data(count: count), done = 0
        while done < count {
            let got = data.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress! + done, count - done, 0) }
            guard got > 0 else { throw Failure(description: "iCloudy closed the connection") }
            done += got
        }
        return data
    }
    func write(_ data: Data) throws {
        var done = 0
        while done < data.count {
            let sent = data.withUnsafeBytes { send(descriptor, $0.baseAddress! + done, data.count - done, 0) }
            guard sent > 0 else { throw Failure(description: "iCloudy closed the connection") }
            done += sent
        }
    }
    func frame() throws -> CLIFrame {
        let (type, length) = try CLIFrame.header(try read(exactly: 5))
        return try CLIFrame.decode(type: type, payload: length > 0 ? try read(exactly: length) : Data())
    }
}

// MARK: - Request

func nonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    arc4random_buf(&bytes, bytes.count)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Opens the link without bringing iCloudy forward. Run from inside an iCloudy.app, it addresses that copy of the app.
func deliver(_ url: URL) throws {
    var arguments = ["-g"]
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    if let range = executable.range(of: ".app/Contents/") { arguments += ["-a", String(executable[..<range.lowerBound]) + ".app"] }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = arguments + [url.absoluteString]
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else { throw Failure(description: "could not open iCloudy (is it installed?)") }
}

/// Sends `command` and returns the connection with the first message already read and checked.
func request(_ command: String, _ arguments: [String], token: String?) throws -> (Connection, CLIMessage) {
    let listener = try Listener()
    let id = nonce()
    try deliver(CLIRequest(command: command, arguments: arguments, port: listener.port, nonce: id, token: token).url)
    // Long enough for a cold start and for macOS to ask about the Keychain.
    guard let connection = listener.accept(timeout: 90) else { throw Failure(description: "iCloudy did not answer") }
    guard case .message(let message) = try connection.frame(), message.nonce == id else { throw Failure(description: "unexpected answer") }
    guard message.ok else { throw Failure(description: message.error ?? "refused") }
    return (connection, message)
}

func printLines(_ message: CLIMessage) { for line in message.lines ?? [] { print(line) } }

// MARK: - Commands

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command != "help", command != "-h", command != "--help" else {
    print(usage); exit(arguments.isEmpty ? 2 : 0)
}
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "pair":
        let (_, message) = try request("pair", [], token: nil)
        guard let token = message.token else { throw Failure(description: "no token received") }
        try saveToken(token)
        printLines(message)
    case "accounts", "jobs":
        guard let token = readToken() else { throw Failure(description: "not paired: run `icloudy pair` first") }
        printLines(try request(command, rest, token: token).1)
    case "ls", "open":
        guard rest.count == 1, CLIPlace(rest[0]) != nil else { fail("usage: icloudy \(command) <account>:/<path>", code: 2) }
        guard let token = readToken() else { throw Failure(description: "not paired: run `icloudy pair` first") }
        printLines(try request(command, rest, token: token).1)
    case "search":
        guard (1...2).contains(rest.count) else { fail("usage: icloudy search <term> [account]", code: 2) }
        guard let token = readToken() else { throw Failure(description: "not paired: run `icloudy pair` first") }
        printLines(try request(command, rest, token: token).1)
    case "get":
        guard (1...2).contains(rest.count), CLIPlace(rest[0]) != nil else { fail("usage: icloudy get <account>:/<path> [file]", code: 2) }
        guard let token = readToken() else { throw Failure(description: "not paired: run `icloudy pair` first") }
        let (connection, message) = try request("get", [rest[0]], token: token)
        let name = (message.name ?? "download").replacingOccurrences(of: "/", with: "_")
        let toStandardOutput = rest.count == 2 && rest[1] == "-"
        let target = rest.count == 2 && !toStandardOutput ? URL(fileURLWithPath: rest[1]) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name)
        let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloudy-part")
        let output: FileHandle
        if toStandardOutput { output = .standardOutput } else {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure(description: "\(target.path) already exists") }
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            output = try FileHandle(forWritingTo: partial)
        }
        var written: Int64 = 0
        do {
            loop: while true {
                switch try connection.frame() {
                case .data(let chunk): try output.write(contentsOf: chunk); written += Int64(chunk.count)
                case .end: break loop
                case .message(let late): throw Failure(description: late.error ?? "unexpected answer")
                }
            }
            guard message.size == nil || message.size == written else { throw Failure(description: "the download arrived incomplete") }
            if !toStandardOutput { try output.close(); try FileManager.default.moveItem(at: partial, to: target) }
        } catch {
            if !toStandardOutput { try? FileManager.default.removeItem(at: partial) }
            throw error
        }
        if !toStandardOutput { print(target.path) }
    case "put":
        guard rest.count == 2, CLIPlace(rest[1]) != nil else { fail("usage: icloudy put <file> <account>:/<path>", code: 2) }
        guard let token = readToken() else { throw Failure(description: "not paired: run `icloudy pair` first") }
        let source = URL(fileURLWithPath: rest[0])
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw Failure(description: "\(rest[0]) is not a regular file") }
        let input = try FileHandle(forReadingFrom: source)
        let (connection, message) = try request("put", [rest[1], source.lastPathComponent, String(size)], token: token)
        guard message.awaitingUpload == true else { throw Failure(description: "unexpected answer") }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try connection.write(CLIFrame.data(chunk).encoded()) }
        try connection.write(CLIFrame.end.encoded())
        guard case .message(let done) = try connection.frame() else { throw Failure(description: "unexpected answer") }
        guard done.ok else { throw Failure(description: done.error ?? "refused") }
        printLines(done)
    default:
        fail("unknown command \(command)\n\n" + usage, code: 2)
    }
} catch {
    fail("\(error)")
}
