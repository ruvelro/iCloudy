import Foundation
import CryptoKit

/// An SSH-2 client connection carrying one channel: the transport of RFC 4253, the password and keyboard-interactive
/// methods of RFC 4252 and the session channel of RFC 4254, with the `sftp` subsystem on it. Nothing more: no shell,
/// no forwarding, no agent. Everything runs off the main actor, and one operation at a time, because the protocol is
/// one ordered stream in each direction.
actor SSHTransport {
    static let clientVersion = "SSH-2.0-iCloudy_0.5"
    let host: String
    let port: UInt16
    private let user: String
    private let password: String
    private var socket: RawSocket?
    private var encrypt = SSHPacketCipher()
    private var decrypt = SSHPacketCipher()
    private var sessionID: Data?
    private var serverVersion = ""
    /// The key the server proved it holds, kept so a rekey cannot swap it for another.
    private(set) var hostKey: Data?
    /// What the caller expects the server's key to be, from an earlier connection. Nil the first time.
    private let expectedHostKey: Data?
    private(set) var timeout: TimeInterval

    // The one channel.
    private var remoteChannel: UInt32 = 0
    private var remoteWindow: Int = 0
    private var remoteMaxPacket: Int = 32768
    private var localWindowConsumed = 0
    private var inbox = Data()
    private var channelOpen = false
    private var channelEOF = false
    static let localWindow = 1 << 22
    static let localMaxPacket = 32768

    init(host: String, port: UInt16, user: String, password: String, expectedHostKey: Data?, timeout: TimeInterval = 45) {
        self.host = host; self.port = port; self.user = user; self.password = password
        self.expectedHostKey = expectedHostKey; self.timeout = timeout
    }

    struct Disconnected: LocalizedError {
        let reason: String
        var errorDescription: String? { L("El servidor SSH cerró la sesión: \(reason)") }
    }
    /// The key differs from the one seen before. Either the server was reinstalled, or something between this Mac
    /// and it is answering in its place; the person has to decide which, and only after seeing both fingerprints.
    struct HostKeyChanged: LocalizedError {
        let stored: String
        let offered: String
        var errorDescription: String? {
            L("La clave del servidor SSH ha cambiado. iCloudy conocía \(stored) y ahora el servidor presenta \(offered). Si has reinstalado el servidor, desconecta la cuenta y vuelve a conectarla; si no, alguien podría estar interceptando la conexión.")
        }
    }

    // MARK: - Connecting

    /// Opens the TCP connection, agrees on keys, checks the host key, signs in and opens the SFTP channel.
    func connect() async throws {
        guard socket == nil else { return }
        let socket = try RawSocket(host: host, port: port, timeout: timeout)
        try await socket.connect()
        self.socket = socket
        do {
            try await exchangeVersions()
            try await keyExchange(serverKexInit: nil)
            try await authenticate()
            try await openSFTPChannel()
        } catch {
            close()
            throw error
        }
    }
    func close() {
        if let socket, channelOpen || sessionID != nil {
            var writer = SSHWriter()
            writer.byte(SSHMessage.disconnect); writer.uint32(11); writer.string("closed by iCloudy"); writer.string("")
            // A courtesy the server may never read; nothing waits on it.
            let sealed = try? encrypt.seal(writer.data)
            if let sealed { Task { try? await socket.send(sealed) } }
        }
        socket?.close(); socket = nil
        channelOpen = false; inbox = Data(); sessionID = nil
    }

    private func exchangeVersions() async throws {
        guard let socket else { throw RawSocket.ConnectionClosed() }
        try await socket.send(Data((Self.clientVersion + "\r\n").utf8))
        // RFC 4253 §4.2 lets the server print banner lines before its version string.
        for _ in 0..<32 {
            let line = try await socket.receiveLine()
            if line.hasPrefix("SSH-") { serverVersion = line; break }
        }
        guard serverVersion.hasPrefix("SSH-2.0") || serverVersion.hasPrefix("SSH-1.99") else {
            // A String, not the Substring `prefix` gives: older compilers cannot interpolate one into a localized value.
            let shown = String(serverVersion.prefix(40))
            throw CloudError.message(L("Eso no es un servidor SSH 2 (respondió «\(shown)»)."))
        }
    }

    // MARK: - Packets

    private func send(_ payload: Data) async throws {
        guard let socket else { throw RawSocket.ConnectionClosed() }
        try await socket.send(try encrypt.seal(payload))
    }
    /// True while a packet is being read. The actor is reentrant at every `await`, and two readers on one stream
    /// would each get half of the other's packets: the bytes would still decrypt into nothing but noise. The
    /// client above serialises its operations; this turns a slip there into an error instead of silent corruption.
    private var reading = false
    private func readPacket() async throws -> Data {
        guard let socket else { throw RawSocket.ConnectionClosed() }
        guard !reading else { throw CloudError.message(L("Dos operaciones intentaron leer del canal SSH a la vez.")) }
        reading = true
        defer { reading = false }
        let head = try await socket.receive(exactly: decrypt.headLength)
        let (length, kept) = try decrypt.packetLength(head: head)
        let rest = try await socket.receive(exactly: 4 + length - kept.count)
        let trailer = try await socket.receive(exactly: decrypt.trailerLength)
        return try decrypt.open(head: kept, rest: rest, trailer: trailer)
    }
    /// Reads one packet and deals with everything that can arrive at any time: keep-alives, window adjustments,
    /// channel data, a rekey, a goodbye. Returns only the messages the caller has to interpret itself.
    private func pump() async throws -> (type: UInt8, reader: SSHReader)? {
        let payload = try await readPacket()
        var reader = SSHReader(payload)
        let type = try reader.byte()
        switch type {
        case SSHMessage.ignore, SSHMessage.debug, SSHMessage.extInfo, SSHMessage.userauthBanner, SSHMessage.unimplemented:
            return nil
        case SSHMessage.disconnect:
            _ = try reader.uint32()
            throw Disconnected(reason: try reader.text())
        case SSHMessage.globalRequest:
            _ = try reader.text()
            if try reader.bool() { var reply = SSHWriter(); reply.byte(SSHMessage.requestFailure); try await send(reply.data) }
            return nil
        case SSHMessage.channelWindowAdjust:
            _ = try reader.uint32()
            remoteWindow += Int(try reader.uint32())
            return nil
        case SSHMessage.channelData:
            _ = try reader.uint32()
            let data = try reader.string()
            inbox.append(data)
            try await consumeWindow(data.count)
            return nil
        case SSHMessage.channelExtendedData:
            _ = try reader.uint32(); _ = try reader.uint32()
            try await consumeWindow(try reader.string().count)
            return nil
        case SSHMessage.channelEOF:
            channelEOF = true
            return nil
        case SSHMessage.channelClose:
            channelEOF = true; channelOpen = false
            var reply = SSHWriter(); reply.byte(SSHMessage.channelClose); reply.uint32(remoteChannel)
            try? await send(reply.data)
            return nil
        case SSHMessage.kexInit where !inKeyExchange:
            // The server wants new keys, which OpenSSH asks for after an hour or a few gigabytes. Refusing would end
            // any transfer longer than that. During an exchange the message is the one being waited for.
            try await keyExchange(serverKexInit: payload)
            return nil
        default:
            return (type, reader)
        }
    }
    /// Reads until one of the wanted messages arrives. Anything else that is not housekeeping is a protocol error.
    private func expect(_ wanted: Set<UInt8>) async throws -> (type: UInt8, reader: SSHReader) {
        while true {
            try Task.checkCancellation()
            guard let message = try await pump() else { continue }
            guard wanted.contains(message.type) else {
                throw CloudError.message(L("El servidor SSH envió un mensaje inesperado (\(message.type)) durante la conexión."))
            }
            return message
        }
    }
    private func consumeWindow(_ count: Int) async throws {
        localWindowConsumed += count
        guard channelOpen, localWindowConsumed >= Self.localWindow / 2 else { return }
        var writer = SSHWriter()
        writer.byte(SSHMessage.channelWindowAdjust); writer.uint32(remoteChannel); writer.uint32(UInt32(localWindowConsumed))
        localWindowConsumed = 0
        try await send(writer.data)
    }

    // MARK: - Key exchange

    private func kexInitPayload() -> Data {
        var writer = SSHWriter()
        writer.byte(SSHMessage.kexInit)
        writer.raw(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        writer.nameList(SSHAlgorithms.kex); writer.nameList(SSHAlgorithms.hostKeys)
        writer.nameList(SSHAlgorithms.ciphers); writer.nameList(SSHAlgorithms.ciphers)
        writer.nameList(SSHAlgorithms.macs); writer.nameList(SSHAlgorithms.macs)
        writer.nameList(SSHAlgorithms.compression); writer.nameList(SSHAlgorithms.compression)
        writer.nameList([]); writer.nameList([])
        writer.bool(false); writer.uint32(0)
        return writer.data
    }
    private struct Negotiated { let kex, hostKey, cipherOut, cipherIn, macOut, macIn: String }
    private func negotiate(_ serverKexInit: Data) throws -> Negotiated {
        var reader = SSHReader(serverKexInit)
        _ = try reader.byte(); _ = try reader.bytes(16)
        let kex = try reader.nameList(), hostKeys = try reader.nameList()
        let ciphersIn = try reader.nameList(), ciphersOut = try reader.nameList()
        let macsIn = try reader.nameList(), macsOut = try reader.nameList()
        let compressionIn = try reader.nameList(), compressionOut = try reader.nameList()
        guard let kexName = SSHAlgorithms.negotiate(SSHAlgorithms.kex, kex) else {
            throw CloudError.message(L("El servidor SSH no ofrece ningún intercambio de claves que iCloudy conozca (ofrece \(kex.joined(separator: ", ")))."))
        }
        guard let hostKeyName = SSHAlgorithms.negotiate(SSHAlgorithms.hostKeys, hostKeys) else {
            throw CloudError.message(L("El servidor SSH solo ofrece claves de servidor que iCloudy no admite (\(hostKeys.joined(separator: ", ")))."))
        }
        guard let out = SSHAlgorithms.negotiate(SSHAlgorithms.ciphers, ciphersIn), let inbound = SSHAlgorithms.negotiate(SSHAlgorithms.ciphers, ciphersOut) else {
            throw CloudError.message(L("El servidor SSH no ofrece ningún cifrado que iCloudy conozca (ofrece \(ciphersIn.joined(separator: ", ")))."))
        }
        guard let macOut = SSHAlgorithms.negotiate(SSHAlgorithms.macs, macsIn), let macIn = SSHAlgorithms.negotiate(SSHAlgorithms.macs, macsOut) else {
            throw CloudError.message(L("El servidor SSH no ofrece ningún código de integridad que iCloudy conozca (ofrece \(macsIn.joined(separator: ", ")))."))
        }
        guard compressionIn.contains("none"), compressionOut.contains("none") else {
            throw CloudError.message(L("El servidor SSH exige compresión, que iCloudy no usa."))
        }
        return Negotiated(kex: kexName, hostKey: hostKeyName, cipherOut: out, cipherIn: inbound, macOut: macOut, macIn: macIn)
    }
    /// The whole exchange, first time and rekeys alike. `serverKexInit` is set when the server spoke first.
    private var inKeyExchange = false
    private func keyExchange(serverKexInit: Data?) async throws {
        inKeyExchange = true
        defer { inKeyExchange = false }
        let ours = kexInitPayload()
        try await send(ours)
        let theirs: Data
        if let serverKexInit { theirs = serverKexInit }
        else {
            let message = try await expect([SSHMessage.kexInit])
            theirs = message.reader.data
        }
        let chosen = try negotiate(theirs)
        let ephemeral = try SSHKeyExchange.start(chosen.kex)
        var initMessage = SSHWriter()
        initMessage.byte(SSHMessage.kexECDHInit); initMessage.string(ephemeral.publicBytes)
        try await send(initMessage.data)
        var reply = try await expect([SSHMessage.kexECDHReply]).reader
        let serverKey = try reply.string(), serverPublic = try reply.string(), signature = try reply.string()
        let secret = try ephemeral.sharedSecret(with: serverPublic)
        let hash = SSHKeyExchange.exchangeHash(clientVersion: Self.clientVersion, serverVersion: serverVersion,
                                               clientKexInit: ours, serverKexInit: theirs, hostKey: serverKey,
                                               clientPublic: ephemeral.publicBytes, serverPublic: serverPublic, sharedSecret: secret)
        guard try SSHHostKey.verify(blob: serverKey, signature: signature, message: hash) else {
            throw CloudError.message(L("La firma del servidor SSH no es válida: la clave que presenta no es la que usó para firmar."))
        }
        // The key is checked before anything is sent under the new keys, and never accepted twice under two names.
        try checkHostKey(serverKey)
        var newKeys = SSHWriter(); newKeys.byte(SSHMessage.newKeys)
        try await send(newKeys.data)
        _ = try await expect([SSHMessage.newKeys])
        let session = sessionID ?? hash
        sessionID = session
        func derive(_ letter: Character, _ length: Int) -> Data {
            SSHKeyDerivation.derive(sharedSecret: secret, exchangeHash: hash, letter: letter, sessionID: session, length: length)
        }
        let outbound = try SSHPacketCipher.build(cipher: chosen.cipherOut, mac: chosen.macOut,
                                                 key: derive("C", SSHPacketCipher.keyLength(chosen.cipherOut)),
                                                 iv: derive("A", SSHPacketCipher.ivLength(chosen.cipherOut)), macKey: derive("E", 32))
        let inbound = try SSHPacketCipher.build(cipher: chosen.cipherIn, mac: chosen.macIn,
                                                key: derive("D", SSHPacketCipher.keyLength(chosen.cipherIn)),
                                                iv: derive("B", SSHPacketCipher.ivLength(chosen.cipherIn)), macKey: derive("F", 32))
        // Sequence numbers run on across a rekey; only the keys change.
        outbound.sequence = encrypt.sequence; inbound.sequence = decrypt.sequence
        encrypt = outbound; decrypt = inbound
    }
    private func checkHostKey(_ offered: Data) throws {
        if let hostKey {
            guard hostKey == offered else { throw HostKeyChanged(stored: SSHHostKey.fingerprint(hostKey), offered: SSHHostKey.fingerprint(offered)) }
            return
        }
        if let expectedHostKey, expectedHostKey != offered {
            throw HostKeyChanged(stored: SSHHostKey.fingerprint(expectedHostKey), offered: SSHHostKey.fingerprint(offered))
        }
        hostKey = offered
    }

    // MARK: - Signing in

    private func authenticate() async throws {
        var request = SSHWriter()
        request.byte(SSHMessage.serviceRequest); request.string("ssh-userauth")
        try await send(request.data)
        _ = try await expect([SSHMessage.serviceAccept])

        var auth = SSHWriter()
        auth.byte(SSHMessage.userauthRequest); auth.string(user); auth.string("ssh-connection")
        auth.string("password"); auth.bool(false); auth.string(password)
        try await send(auth.data)
        var outcome = try await expect([SSHMessage.userauthSuccess, SSHMessage.userauthFailure])
        if outcome.type == SSHMessage.userauthSuccess { return }
        let offered = try outcome.reader.nameList()
        guard offered.contains("keyboard-interactive") else {
            if offered.contains("password") { throw CloudError.message(L("El servidor SSH rechazó el usuario o la contraseña.")) }
            throw CloudError.message(L("El servidor SSH no acepta contraseñas para este usuario (admite: \(offered.joined(separator: ", "))). iCloudy todavía no inicia sesión con claves."))
        }
        // Servers that only take the password through PAM offer this instead of "password": each prompt is
        // answered with the same password, and a server that wants a second factor gets it too and refuses.
        var interactive = SSHWriter()
        interactive.byte(SSHMessage.userauthRequest); interactive.string(user); interactive.string("ssh-connection")
        interactive.string("keyboard-interactive"); interactive.string(""); interactive.string("")
        try await send(interactive.data)
        while true {
            outcome = try await expect([SSHMessage.userauthSuccess, SSHMessage.userauthFailure, SSHMessage.userauthInfoRequest])
            switch outcome.type {
            case SSHMessage.userauthSuccess: return
            case SSHMessage.userauthInfoRequest:
                _ = try outcome.reader.text(); _ = try outcome.reader.text(); _ = try outcome.reader.text()
                let prompts = Int(try outcome.reader.uint32())
                var response = SSHWriter()
                response.byte(SSHMessage.userauthInfoResponse); response.uint32(UInt32(prompts))
                for _ in 0..<prompts { response.string(password) }
                try await send(response.data)
            default:
                throw CloudError.message(L("El servidor SSH rechazó el usuario o la contraseña."))
            }
        }
    }

    // MARK: - The channel

    private func openSFTPChannel() async throws {
        var open = SSHWriter()
        open.byte(SSHMessage.channelOpen); open.string("session"); open.uint32(0)
        open.uint32(UInt32(Self.localWindow)); open.uint32(UInt32(Self.localMaxPacket))
        try await send(open.data)
        var reply = try await expect([SSHMessage.channelOpenConfirmation, SSHMessage.channelOpenFailure])
        guard reply.type == SSHMessage.channelOpenConfirmation else {
            _ = try reply.reader.uint32(); _ = try reply.reader.uint32()
            throw CloudError.message(L("El servidor SSH no abrió la sesión: \(try reply.reader.text())"))
        }
        _ = try reply.reader.uint32()
        remoteChannel = try reply.reader.uint32()
        remoteWindow = Int(try reply.reader.uint32())
        remoteMaxPacket = max(1024, Int(try reply.reader.uint32()))
        channelOpen = true
        var request = SSHWriter()
        request.byte(SSHMessage.channelRequest); request.uint32(remoteChannel); request.string("subsystem"); request.bool(true); request.string("sftp")
        try await send(request.data)
        let outcome = try await expect([SSHMessage.channelSuccess, SSHMessage.channelFailure])
        guard outcome.type == SSHMessage.channelSuccess else {
            throw CloudError.message(L("El servidor SSH no ofrece SFTP para este usuario. Comprueba que el subsistema sftp está habilitado."))
        }
    }
    /// Sends channel data, waiting for the server to widen its window when it is full.
    func write(_ data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            try Task.checkCancellation()
            guard channelOpen else { throw RawSocket.ConnectionClosed() }
            if remoteWindow <= 0 {
                _ = try await pump()
                continue
            }
            let count = min(data.endIndex - offset, remoteWindow, remoteMaxPacket - 64)
            var writer = SSHWriter()
            writer.byte(SSHMessage.channelData); writer.uint32(remoteChannel); writer.string(Data(data[offset..<offset + count]))
            try await send(writer.data)
            remoteWindow -= count
            offset += count
        }
    }
    /// Returns at least `count` bytes of channel data, reading packets until they are there.
    func read(atLeast count: Int) async throws -> Data {
        while inbox.count < count {
            try Task.checkCancellation()
            if channelEOF { throw RawSocket.ConnectionClosed() }
            if let stray = try await pump() {
                throw CloudError.message(L("El servidor SSH envió un mensaje inesperado (\(stray.type)) durante la transferencia."))
            }
        }
        let slice = Data(inbox.prefix(count))
        inbox.removeFirst(count)
        return slice
    }
    var isConnected: Bool { socket != nil && channelOpen }
}
