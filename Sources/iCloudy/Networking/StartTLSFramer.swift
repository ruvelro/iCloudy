import Foundation
import Network

/// The one thing Network.framework cannot do by itself: start a connection in the clear and encrypt it later, which
/// is what explicit FTPS (`AUTH TLS`) asks for. A framer may insert a protocol beneath itself, but only while the
/// connection is still coming up, so this one runs the clear-text prologue as its own handshake: it reads the
/// server's greeting, sends `AUTH TLS`, and on the `234` slides TLS in underneath and declares the connection
/// ready. The session above then sees a ready, encrypted connection with no greeting to read: the framer already read it.
final class StartTLSFramer: NWProtocolFramerImplementation {
    static let label = "iCloudy.StartTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
    /// Set by tests that talk to a stand-in with a certificate of its own. Never set by the app: a NAS certificate
    /// is trusted by installing it in the Keychain, as `docs/FTP.md` explains.
    nonisolated(unsafe) static var trustAnyCertificateForTesting = false
    /// The server name the certificate is checked against. The framer cannot see the endpoint it was opened to,
    /// so the session registers it here before connecting, keyed by what the framer will see in the greeting.
    nonisolated(unsafe) private static var pendingHosts: [ObjectIdentifier: String] = [:]
    private static let lock = NSLock()
    static func serverName(for parameters: NWParameters, host: String) {
        lock.withLock { pendingHosts[ObjectIdentifier(parameters)] = host }
    }
    /// Name registered for any pending connection. One at a time is the practical case; when several explicit
    /// sessions open at once they all verify against the last registered name, and a mismatch fails closed.
    private static func takeServerName() -> String? {
        lock.withLock { let value = pendingHosts.values.first; return value }
    }

    private enum Phase { case greeting, awaitingAuth, passthrough }
    private var phase = Phase.greeting
    private var pending = Data()

    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var chunk: Data?
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1 << 16) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                chunk = Data(buffer)
                return buffer.count
            }
            guard parsed, let data = chunk else { return 0 }
            switch phase {
            case .passthrough:
                framer.deliverInput(data: data, message: NWProtocolFramer.Message(instance: framer), isComplete: false)
            case .greeting:
                pending.append(data)
                guard let code = Self.finalReply(in: pending) else { continue }
                guard code == 220 else { framer.markFailed(error: NWError.posix(.ECONNREFUSED)); return 0 }
                pending = Data()
                phase = .awaitingAuth
                framer.writeOutput(data: Data("AUTH TLS\r\n".utf8))
            case .awaitingAuth:
                pending.append(data)
                guard let code = Self.finalReply(in: pending) else { continue }
                guard code == 234 else { framer.markFailed(error: NWError.posix(.EPROTONOSUPPORT)); return 0 }
                let options = NWProtocolTLS.Options()
                // SNI carries host names only (RFC 6066); an address literal is verified against the certificate's
                // IP entries without being announced.
                if let host = Self.takeServerName(), !Self.isAddressLiteral(host) {
                    sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
                }
                if Self.trustAnyCertificateForTesting {
                    sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
                }
                do { try framer.prependApplicationProtocol(options: options) }
                catch { framer.markFailed(error: NWError.posix(.EPROTO)); return 0 }
                // The greeting stays here. Once TLS is in place everything delivered upwards goes through it, and
                // a clear-text line handed up at that point reads as a broken TLS record.
                phase = .passthrough
                pending = Data()
                framer.markReady()
            }
        }
    }
    static func isAddressLiteral(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.contains(":") { return true }
        let parts = name.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
    /// The code of a complete reply, when `buffer` holds one: the last line of the form "NNN text". Nil while the
    /// reply is still arriving, including the continuation lines of a multi-line answer ("NNN-text").
    static func finalReply(in buffer: Data) -> Int? {
        // Checked on the bytes: Swift folds "\r\n" into one character, and `hasSuffix("\n")` then never matches.
        guard buffer.last == 0x0A else { return nil }
        let text = String(decoding: buffer, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, let code = Int(trimmed.prefix(3)) else { continue }
            if trimmed.count == 3 || trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)] == " " { return code }
            return nil
        }
        return nil
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        guard messageLength > 0 else { return }
        do { try framer.writeOutputNoCopy(length: messageLength) } catch { framer.markFailed(error: nil) }
    }
}
