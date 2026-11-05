import Foundation
import CryptoKit
@testable import iCloudy

/// A deliberately small SSH-2 server on 127.0.0.1, for testing what the client does at the protocol's edges: strict key
/// exchange, the host key question, keyboard-interactive prompts, a rekey with data in flight, and an in-memory SFTP
/// file system. It speaks one connection, on a thread of its own with blocking sockets, and is built from the same
/// wire and cipher code the client uses, so a test exercises the client's side of each exchange and not this file.
/// It can also misbehave on purpose, which no real server would do on request.
final class FakeSSHServer: @unchecked Sendable {
    struct Script {
        var strict = true
        /// One cipher and one MAC, so the client's choice is forced. CTR with an EtM MAC makes the sequence numbers
        /// part of every packet's MAC: a client that got them wrong after NEWKEYS fails on its next packet.
        var cipher = "aes128-ctr"
        var mac = "hmac-sha2-256-etm@openssh.com"
        /// An IGNORE before the server's first KEXINIT, or between KEXINIT and the key exchange reply.
        var junkBeforeKexInit = false
        var junkDuringKex = false
        /// The methods a failure offers, and the password that succeeds.
        var methods = ["password"]
        var password = "secreta"
        /// keyboard-interactive rounds: each a list of (prompt, echo).
        var interactiveRounds: [[(String, Bool)]] = []
        /// After the channel opens, the server starts a rekey and, against the rules, sends this much channel data
        /// before its reply: the client must not answer it with a window adjustment until the exchange is over.
        var rekeyWithData = 0
        var sftp = false
        var posixRename = true
        /// The SFTP WRITE that fails, counting from one, or nil.
        var failingWrite: Int?
    }

    let script: Script
    private(set) var port: UInt16 = 0
    let hostKey = Curve25519.Signing.PrivateKey()
    var hostKeyBlob: Data {
        var writer = SSHWriter(); writer.string("ssh-ed25519"); writer.string(hostKey.publicKey.rawRepresentation)
        return writer.data
    }

    private let lock = NSLock()
    private var recorded: [String] = []
    private var stored: [String: Data] = [:]
    /// What the server saw and did, in order: `kex:<type>` for a packet received during a key exchange, `recv:<type>`
    /// for any other, plus named milestones and SFTP operations.
    var events: [String] { lock.withLock { recorded } }
    var files: [String: Data] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private(set) var clientKexAlgorithms: [String] = []
    private(set) var interactiveAnswers: [[String]] = []
    private func note(_ event: String) { lock.withLock { recorded.append(event) } }

    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private let serverVersion = "SSH-2.0-FakeSSH_1.0"
    private var clientVersion = ""
    private var tx = SSHPacketCipher(), rx = SSHPacketCipher()
    private var sessionID: Data?
    private var clientChannel: UInt32 = 0
    private var inKex = false
    private let finished = DispatchSemaphore(value: 0)

    init(_ script: Script = Script()) throws {
        self.script = script
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 1) == 0 else { throw CloudError.message("No se pudo abrir el servidor SSH de prueba") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in serve(); finished.signal() }.start()
    }
    /// Closes everything and waits for the server thread, so a test leaves no thread behind.
    func stop() {
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        shutdown(listener, SHUT_RDWR); close(listener)
        _ = finished.wait(timeout: .now() + 5)
    }
    /// Waits until `event` has been recorded, or a few seconds have passed.
    func waitFor(_ event: String) -> Bool {
        for _ in 0..<500 { if events.contains(event) { return true }; usleep(10_000) }
        return false
    }

    // MARK: - Bytes

    private struct Closed: Error {}
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(connection, raw.baseAddress! + sent, raw.count - sent, 0)
                guard count > 0 else { throw Closed() }
                sent += count
            }
        }
    }
    private func read(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(connection, $0.baseAddress! + got, count - got, 0) }
            guard n > 0 else { throw Closed() }
            got += n
        }
        return Data(buffer)
    }
    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        while bytes.last != 0x0A { bytes += try read(1) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    private func sendPacket(_ payload: Data) throws { try writeAll(try tx.seal(payload)) }
    private func readPacket() throws -> (type: UInt8, reader: SSHReader, payload: Data) {
        let head = try read(rx.headLength)
        let (length, kept) = try rx.packetLength(head: head)
        let rest = try read(4 + length - kept.count)
        let trailer = try read(rx.trailerLength)
        let payload = try rx.open(head: kept, rest: rest, trailer: trailer)
        var reader = SSHReader(payload)
        let type = try reader.byte()
        note((inKex ? "kex:" : "recv:") + String(type))
        return (type, reader, payload)
    }
    private func message(_ type: UInt8, _ fill: (inout SSHWriter) -> Void = { _ in }) throws {
        var writer = SSHWriter(); writer.byte(type); fill(&writer)
        try sendPacket(writer.data)
    }

    // MARK: - The conversation

    /// One connection after another, until the listener is closed: signing in connects once, and the account's
    /// own session connects again.
    private func serve() {
        while true {
            var length = socklen_t(0)
            connection = accept(listener, nil, &length)
            guard connection >= 0 else { return }
            tx = SSHPacketCipher(); rx = SSHPacketCipher(); sessionID = nil; inKex = false
            converse()
            close(connection)
        }
    }
    private func converse() {
        do {
            try writeAll(Data((serverVersion + "\r\n").utf8))
            clientVersion = try readLine()
            if script.junkBeforeKexInit { try message(SSHMessage.ignore) { $0.string("relleno") } }
            let ours = kexInit(initial: true)
            inKex = true
            try sendPacket(ours)
            var theirs = try readPacket()
            while theirs.type != SSHMessage.kexInit { theirs = try readPacket() }
            var names = theirs.reader
            _ = try names.bytes(16)
            clientKexAlgorithms = try names.nameList()
            try keyExchange(clientKexInit: theirs.payload, serverKexInit: ours)
            note("kex-done")
            try authenticateAndOpen()
            note("channel-open")
            if script.rekeyWithData > 0 { try rekeyWithData() }
            if script.sftp { try serveSFTP() }
            else { while true { _ = try readPacket() } }
        } catch {
            note("closed")
        }
    }

    private func kexInit(initial: Bool) -> Data {
        var writer = SSHWriter()
        writer.byte(SSHMessage.kexInit)
        writer.raw(Data(repeating: 7, count: 16))
        writer.nameList(["curve25519-sha256"] + (initial && script.strict ? [SSHTransport.strictKexServer] : []))
        writer.nameList(["ssh-ed25519"])
        writer.nameList([script.cipher]); writer.nameList([script.cipher])
        writer.nameList([script.mac]); writer.nameList([script.mac])
        writer.nameList(["none"]); writer.nameList(["none"])
        writer.nameList([]); writer.nameList([])
        writer.bool(false); writer.uint32(0)
        return writer.data
    }

    private func keyExchange(clientKexInit: Data, serverKexInit: Data) throws {
        inKex = true
        var initMessage = try readPacket()
        while initMessage.type != SSHMessage.kexECDHInit { initMessage = try readPacket() }
        let clientPublic = try initMessage.reader.string()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublic))
            .withUnsafeBytes { Data($0) }
        let serverPublic = ephemeral.publicKey.rawRepresentation
        let hash = SSHKeyExchange.exchangeHash(clientVersion: clientVersion, serverVersion: serverVersion,
                                               clientKexInit: clientKexInit, serverKexInit: serverKexInit, hostKey: hostKeyBlob,
                                               clientPublic: clientPublic, serverPublic: serverPublic, sharedSecret: secret)
        let session = sessionID ?? hash
        sessionID = session
        var signature = SSHWriter(); signature.string("ssh-ed25519"); signature.string(try hostKey.signature(for: hash))
        if script.junkDuringKex { try message(SSHMessage.ignore) { $0.string("relleno") } }
        try message(SSHMessage.kexECDHReply) { $0.string(hostKeyBlob); $0.string(serverPublic); $0.string(signature.data) }
        try message(SSHMessage.newKeys)
        var newKeys = try readPacket()
        while newKeys.type != SSHMessage.newKeys { newKeys = try readPacket() }
        func derive(_ letter: Character, _ length: Int) -> Data {
            SSHKeyDerivation.derive(sharedSecret: secret, exchangeHash: hash, letter: letter, sessionID: session, length: length)
        }
        let cipher = script.cipher, mac = script.mac
        let outbound = try SSHPacketCipher.build(cipher: cipher, mac: mac, key: derive("D", SSHPacketCipher.keyLength(cipher)),
                                                 iv: derive("B", SSHPacketCipher.ivLength(cipher)), macKey: derive("F", 32))
        let inbound = try SSHPacketCipher.build(cipher: cipher, mac: mac, key: derive("C", SSHPacketCipher.keyLength(cipher)),
                                                iv: derive("A", SSHPacketCipher.ivLength(cipher)), macKey: derive("E", 32))
        let strict = script.strict && clientKexAlgorithms.contains(SSHTransport.strictKexClient)
        outbound.sequence = strict ? 0 : tx.sequence
        inbound.sequence = strict ? 0 : rx.sequence
        tx = outbound; rx = inbound
        inKex = false
    }

    private func authenticateAndOpen() throws {
        var round = 0
        while true {
            var packet = try readPacket()
            switch packet.type {
            case SSHMessage.serviceRequest:
                try message(SSHMessage.serviceAccept) { $0.string("ssh-userauth") }
            case SSHMessage.userauthRequest:
                _ = try packet.reader.text(); _ = try packet.reader.text()
                let method = try packet.reader.text()
                note("auth:" + method)
                if method == "password", script.methods.contains("password") {
                    _ = try packet.reader.bool()
                    if try packet.reader.text() == script.password { try message(SSHMessage.userauthSuccess); continue }
                }
                if method == "keyboard-interactive", script.methods.contains("keyboard-interactive"), !script.interactiveRounds.isEmpty {
                    round = 0
                    try sendInfoRequest(script.interactiveRounds[0])
                    continue
                }
                try message(SSHMessage.userauthFailure) { $0.nameList(script.methods); $0.bool(false) }
            case SSHMessage.userauthInfoResponse:
                let count = Int(try packet.reader.uint32())
                interactiveAnswers.append(try (0..<count).map { _ in try packet.reader.text() })
                round += 1
                if round < script.interactiveRounds.count { try sendInfoRequest(script.interactiveRounds[round]); continue }
                if interactiveAnswers.last?.allSatisfy({ $0 == script.password }) == true { try message(SSHMessage.userauthSuccess) }
                else { try message(SSHMessage.userauthFailure) { $0.nameList(script.methods); $0.bool(false) } }
            case SSHMessage.channelOpen:
                _ = try packet.reader.text()
                clientChannel = try packet.reader.uint32()
                try message(SSHMessage.channelOpenConfirmation) { $0.uint32(clientChannel); $0.uint32(0); $0.uint32(1 << 30); $0.uint32(32768) }
            case SSHMessage.channelRequest:
                try message(SSHMessage.channelSuccess) { $0.uint32(clientChannel) }
                return
            default:
                continue
            }
        }
    }
    private func sendInfoRequest(_ prompts: [(String, Bool)]) throws {
        try message(SSHMessage.userauthInfoRequest) {
            $0.string(""); $0.string(""); $0.string(""); $0.uint32(UInt32(prompts.count))
            for (text, echo) in prompts { $0.string(text); $0.bool(echo) }
        }
    }

    /// A server-initiated rekey with channel data sent, against the rules, between KEXINIT and the reply.
    private func rekeyWithData() throws {
        note("rekey-start")
        let ours = kexInit(initial: false)
        inKex = true
        try sendPacket(ours)
        var sent = 0
        while sent < script.rekeyWithData {
            let chunk = Data(repeating: UInt8(sent / 32_000 % 251), count: min(32_000, script.rekeyWithData - sent))
            try message(SSHMessage.channelData) { $0.uint32(clientChannel); $0.string(chunk) }
            sent += chunk.count
        }
        var theirs = try readPacket()
        while theirs.type != SSHMessage.kexInit { theirs = try readPacket() }
        try keyExchange(clientKexInit: theirs.payload, serverKexInit: ours)
        note("rekey-done")
    }

    // MARK: - SFTP

    private func serveSFTP() throws {
        var buffer = Data()
        var writes = 0
        var listed: Set<String> = []
        while true {
            var packet = try readPacket()
            guard packet.type == SSHMessage.channelData else {
                if packet.type == SSHMessage.channelClose || packet.type == SSHMessage.disconnect { return }
                continue
            }
            _ = try packet.reader.uint32()
            buffer += try packet.reader.string()
            while buffer.count >= 4 {
                var head = SSHReader(Data(buffer.prefix(4)))
                let length = Int(try head.uint32())
                guard buffer.count >= 4 + length else { break }
                var request = SSHReader(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
                let type = try request.byte()
                if type == SFTPClient.Packet.initialize {
                    reply(SFTPClient.Packet.version) { $0.uint32(3); if self.script.posixRename { $0.string("posix-rename@openssh.com"); $0.string("1") } }
                    continue
                }
                let id = try request.uint32()
                switch type {
                case SFTPClient.Packet.opendir:
                    let path = try request.text()
                    note("sftp:opendir " + path)
                    reply(SFTPClient.Packet.handle) { $0.uint32(id); $0.string("d:" + path) }
                case SFTPClient.Packet.readdir:
                    let handle = try request.text()
                    let folder = String(handle.dropFirst(2))
                    guard listed.insert(handle).inserted else { status(id, 1); continue }
                    let children = files.keys.filter { ($0 as NSString).deletingLastPathComponent == folder }.sorted()
                    reply(SFTPClient.Packet.name) {
                        $0.uint32(id); $0.uint32(UInt32(children.count))
                        for path in children {
                            $0.string((path as NSString).lastPathComponent); $0.string("")
                            $0.uint32(0x1 | 0x4); $0.uint64(UInt64(self.files[path]?.count ?? 0)); $0.uint32(0o100644)
                        }
                    }
                case SFTPClient.Packet.close:
                    listed.remove(try request.text())
                    status(id, 0)
                case SFTPClient.Packet.open:
                    let path = try request.text()
                    note("sftp:open " + path)
                    files[path] = Data()
                    reply(SFTPClient.Packet.handle) { $0.uint32(id); $0.string("f:" + path) }
                case SFTPClient.Packet.write:
                    let path = String(try request.text().dropFirst(2))
                    let offset = Int(try request.uint64())
                    let chunk = try request.string()
                    writes += 1
                    if writes == script.failingWrite { status(id, 4); continue }
                    var contents = files[path] ?? Data()
                    if contents.count < offset + chunk.count { contents += Data(count: offset + chunk.count - contents.count) }
                    contents.replaceSubrange(offset..<offset + chunk.count, with: chunk)
                    files[path] = contents
                    status(id, 0)
                case SFTPClient.Packet.stat, SFTPClient.Packet.lstat:
                    let path = try request.text()
                    if let contents = files[path] { reply(SFTPClient.Packet.attrs) { $0.uint32(id); $0.uint32(0x1); $0.uint64(UInt64(contents.count)) } }
                    else { status(id, 2) }
                case SFTPClient.Packet.remove:
                    let path = try request.text()
                    note("sftp:remove " + path)
                    status(id, files.removeValue(forKey: path) == nil ? 2 : 0)
                case SFTPClient.Packet.rename:
                    let from = try request.text(), to = try request.text()
                    note("sftp:rename " + from + " " + to)
                    guard files[to] == nil, let contents = files.removeValue(forKey: from) else { status(id, 4); continue }
                    files[to] = contents
                    status(id, 0)
                case SFTPClient.Packet.extended:
                    let name = try request.text()
                    guard name == "posix-rename@openssh.com" else { status(id, 8); continue }
                    let from = try request.text(), to = try request.text()
                    note("sftp:posix-rename " + from + " " + to)
                    guard let contents = files.removeValue(forKey: from) else { status(id, 2); continue }
                    files[to] = contents
                    status(id, 0)
                default:
                    status(id, 8)
                }
            }
        }
    }
    private func reply(_ type: UInt8, _ fill: (inout SSHWriter) -> Void) {
        var body = SSHWriter(); body.byte(type); fill(&body)
        var framed = SSHWriter(); framed.uint32(UInt32(body.data.count)); framed.raw(body.data)
        try? message(SSHMessage.channelData) { $0.uint32(clientChannel); $0.string(framed.data) }
    }
    private func status(_ id: UInt32, _ code: UInt32) {
        reply(SFTPClient.Packet.status) { $0.uint32(id); $0.uint32(code); $0.string(code == 0 ? "" : "fallo \(code)"); $0.string("") }
    }
}
