import Foundation
import Network

/// A TCP connection with bounded, cancellable reads and writes, for protocols that are not HTTP: SSH here, where
/// every byte is framed by the protocol itself and a read that never returns has to become an error.
final class RawSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var pending = Data()
    private var eof = false
    private let lock = NSLock()
    /// How long a connection may sit in `waiting` before it is given up on: long enough for a Wi-Fi coming back
    /// after a sleep, short enough that a server that is not there fails quickly.
    static let pathGrace: TimeInterval = 3

    init(host: String, port: UInt16, timeout: TimeInterval = 45, tls: Bool = false) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw CloudError.message(L("Puerto de servidor no válido.")) }
        let parameters: NWParameters = tls ? .tls : .tcp
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        self.timeout = timeout
    }

    func connect() async throws {
        defer { connection.stateUpdateHandler = nil }
        let connection = self.connection
        try await wait(timeout: timeout) { (finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(CancellationError()))
                case .waiting(let error):
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.pathGrace) {
                        if case .waiting = connection.state { finish(.failure(error)) }
                    }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
    func close() { connection.cancel() }

    private func wait<T: Sendable>(timeout: TimeInterval, start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let wait = SocketWait<T>()
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard wait.install(continuation) else { return }
                wait.arm(timeout: timeout) { connection.cancel() }
                start { result in
                    if case .failure = result { connection.cancel() }
                    wait.resolve(result)
                }
            }
        } onCancel: {
            wait.resolve(.failure(CancellationError()))
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        let connection = self.connection
        try await wait(timeout: timeout) { (finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            })
        }
    }

    /// Exactly `count` bytes, or an error: a protocol frame that arrives short is a broken connection, not data.
    func receive(exactly count: Int) async throws -> Data {
        while true {
            let (head, closed): (Data?, Bool) = lock.withLock {
                guard pending.count >= count else { return (nil, eof) }
                let head = Data(pending.prefix(count))
                pending.removeFirst(count)
                return (head, eof)
            }
            if let head { return head }
            if closed { throw ConnectionClosed() }
            try Task.checkCancellation()
            let connection = self.connection
            let packet: (Data?, Bool) = try await wait(timeout: timeout) { finish in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                    if let error { finish(.failure(error)) } else { finish(.success((data, complete))) }
                }
            }
            lock.withLock {
                if let data = packet.0 { pending.append(data) }
                if packet.1 { eof = true }
            }
        }
    }
    /// Reads up to and including the first LF, for the one line of SSH that is not a binary frame.
    func receiveLine(maximum: Int = 255) async throws -> String {
        var line = Data()
        while line.count < maximum {
            let byte = try await receive(exactly: 1)
            line.append(byte)
            if byte[0] == 0x0A { break }
        }
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    struct ConnectionClosed: LocalizedError {
        var errorDescription: String? { L("El servidor cerró la conexión.") }
    }
}
