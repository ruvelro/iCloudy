import Foundation
import AppKit
import iCloudyCommandWire

/// The app's side of the `icloudy` command-line companion (`Sources/iCloudyCLI`). A request arrives as an
/// `icloudy://cli` link; the app connects back to the port it names, on this Mac only, and answers in frames.
///
/// Any program can open a link, so a request is answered only when it carries the token this app handed out to a
/// companion the person approved (`icloudy pair` shows the question in the app). Without it, nothing is read, listed
/// or sent: the companion is told to pair, and that is all. A token can be withdrawn by pairing again.
@MainActor
final class CLIBridge {
    static let shared = CLIBridge()
    static let tokenKey = "cliToken"
    /// Asks the person whether to let a companion in. Tests answer for them.
    var approve: @MainActor (String) async -> Bool = { question in
        NSApp?.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("¿Permitir la línea de órdenes?")
        alert.informativeText = question
        alert.addButton(withTitle: L("Permitir"))
        alert.addButton(withTitle: L("No permitir"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Where the bytes a companion uploads are kept until the queue sends them; cleared with the clipboard's.
    var inbox = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Pasteboard", isDirectory: true)

    private var token: String? {
        get { Prefs.defaults.string(forKey: Self.tokenKey) }
        set { Prefs.defaults.set(newValue, forKey: Self.tokenKey) }
    }

    /// Compares without stopping at the first difference, so the time taken says nothing about the token.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func handle(_ request: CLIRequest, model: AppModel) async {
        let socket: RawSocket
        do {
            socket = try RawSocket(host: "127.0.0.1", port: request.port, timeout: 120)
            try await socket.connect()
        } catch { return } // nobody is waiting on that port: there is no one to answer
        defer { socket.close() }
        let nonce = request.nonce
        func reply(_ message: CLIMessage) async throws { try await socket.send(CLIFrame.message(message).encoded()) }
        do {
            if request.command == "pair" {
                try await reply(try await pair(nonce: nonce))
                return
            }
            guard let expected = token, let given = request.token, Self.same(expected, given) else {
                try await reply(CLIMessage(nonce: nonce, ok: false, error: L("Esta línea de órdenes no está autorizada. Ejecuta «icloudy pair» y acepta en iCloudy.")))
                return
            }
            try await run(request, model: model, socket: socket, reply: reply)
        } catch {
            try? await reply(CLIMessage(nonce: nonce, ok: false, error: error.localizedDescription))
        }
    }

    private func pair(nonce: String) async throws -> CLIMessage {
        let question = L("Un programa de este Mac pide usar iCloudy desde la línea de órdenes: listar, buscar, descargar y subir archivos de tus cuentas. Permítelo solo si acabas de ejecutar «icloudy pair».")
        guard await approve(question) else { return CLIMessage(nonce: nonce, ok: false, error: L("No se ha permitido el acceso.")) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudError.message(L("No se pudo generar el token.")) }
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        // A new pairing retires the token of every companion paired before.
        token = fresh
        return CLIMessage(nonce: nonce, ok: true, lines: [L("Línea de órdenes autorizada.")], token: fresh)
    }

    private func place(_ argument: String?, model: AppModel) throws -> (Account, String) {
        guard let argument, let place = CLIPlace(argument) else { throw CloudError.message(L("Indica un lugar como cuenta:/ruta.")) }
        return (try model.account(named: place.account), place.path)
    }

    private func run(_ request: CLIRequest, model: AppModel, socket: RawSocket, reply: (CLIMessage) async throws -> Void) async throws {
        let nonce = request.nonce, arguments = request.arguments
        switch request.command {
        case "accounts":
            try await reply(CLIMessage(nonce: nonce, ok: true, lines: model.accounts.map { "\($0.id)\t\(model.accountTitle($0))\t\($0.cloud.title)" }))
        case "ls":
            let (account, path) = try place(arguments.first, model: model)
            let items = try await model.automationList(account, path: path)
            try await reply(CLIMessage(nonce: nonce, ok: true, lines: items.map { item in
                let size = item.isFolder ? "-" : (item.size.map(String.init) ?? "?")
                let date = item.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
                return "\(size)\t\(date)\t\(item.name)\(item.isFolder ? "/" : "")"
            }))
        case "search":
            guard let term = arguments.first else { throw CloudError.message(L("Indica qué buscar.")) }
            let only = try arguments.dropFirst().first.map { try model.account(named: $0) }
            let hits = await model.automationSearch(term, in: only, limit: 500)
            try await reply(CLIMessage(nonce: nonce, ok: true, lines: hits.map { hit in
                let title = model.accounts.first { $0.id == hit.accountID }.map(model.accountTitle) ?? hit.accountID
                return "\(title)\t\(hit.file.name)\(hit.file.isFolder ? "/" : "")"
            }))
        case "open":
            let (account, path) = try place(arguments.first, model: model)
            try await model.openLink(account: account, path: path.split(separator: "/").map(String.init), revealing: true)
            try await reply(CLIMessage(nonce: nonce, ok: true))
        case "jobs":
            try await jobs(arguments, model: model, nonce: nonce, reply: reply)
        case "get":
            let (account, path) = try place(arguments.first, model: model)
            guard let file = try await model.resolve(path: path, in: account).file, !file.isFolder else {
                throw CloudError.message(L("Indica un archivo, no una carpeta."))
            }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-cli-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            // Checked against the provider's size and checksum before a byte goes out, as any download.
            try await model.client(account).download(file: file, to: scratch)
            let size = Int64((try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try await reply(CLIMessage(nonce: nonce, ok: true, name: file.name, size: size))
            let handle = try FileHandle(forReadingFrom: scratch)
            defer { try? handle.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try await blockingIO { try handle.read(upToCount: 1024 * 1024) ?? Data() }
                if chunk.isEmpty { break }
                try await socket.send(CLIFrame.data(chunk).encoded())
            }
            try await socket.send(CLIFrame.end.encoded())
        case "put":
            guard arguments.count == 3, let size = Int64(arguments[2]), size >= 0 else { throw CloudError.message(L("Indica el archivo y el destino.")) }
            let name = FileNames.safe((arguments[1] as NSString).lastPathComponent)
            let (account, path) = try place(arguments.first, model: model)
            let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let local = folder.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: local.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CloudError.message(L("No se pudo preparar la subida."))
            }
            try await reply(CLIMessage(nonce: nonce, ok: true, awaitingUpload: true))
            let handle = try FileHandle(forWritingTo: local)
            var received: Int64 = 0
            do {
                defer { try? handle.close() }
                receiving: while true {
                    let (type, length) = try CLIFrame.header(try await socket.receive(exactly: 5))
                    switch try CLIFrame.decode(type: type, payload: length > 0 ? try await socket.receive(exactly: length) : Data()) {
                    case .data(let chunk):
                        received += Int64(chunk.count)
                        guard received <= size else { throw CloudError.message(L("Llegaron más bytes de los anunciados.")) }
                        try handle.write(contentsOf: chunk)
                    case .end: break receiving
                    case .message: throw CloudError.message(L("La línea de órdenes envió algo inesperado."))
                    }
                }
                guard received == size else { throw CloudError.message(L("La subida llegó incompleta desde la línea de órdenes.")) }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            try await model.automationUpload([local], to: account, path: path)
            try await reply(CLIMessage(nonce: nonce, ok: true, lines: [L("«\(name)» en cola hacia \(model.accountTitle(account)). Sigue la subida en el panel de transferencias.")]))
        default:
            throw CloudError.message(L("iCloudy no sabe hacer «\(request.command)» desde la línea de órdenes."))
        }
    }

    /// The saved transfer jobs and the folder mirrors: `jobs` lists both, saved jobs first, and `jobs run <nombre>`
    /// starts one by its name or its id. A saved job of that name wins over a mirror of the same name.
    private func jobs(_ arguments: [String], model: AppModel, nonce: String, reply: (CLIMessage) async throws -> Void) async throws {
        let mirrors = model.mirrors.mirrors
        let saved = model.jobs.jobs
        guard arguments.first == "run" else {
            let paused = L("en pausa"), running = L("en marcha")
            let jobLines = saved.map { job in
                [job.id.uuidString, job.name, job.destination.title].joined(separator: "\t") + (job.running ? "\t" + running : "")
            }
            try await reply(CLIMessage(nonce: nonce, ok: true, lines: jobLines + mirrors.map { mirror in
                [mirror.id.uuidString, mirror.title, mirror.remoteName].joined(separator: "\t") + (mirror.paused ? "\t" + paused : "")
            }))
            return
        }
        guard let name = arguments.dropFirst().first else { throw CloudError.message(L("Indica qué reflejo ejecutar.")) }
        if let job = saved.first(where: { $0.id.uuidString.lowercased() == name.lowercased() }) ?? model.jobs.job(named: name) {
            try await model.runJob(id: job.id)
            try await reply(CLIMessage(nonce: nonce, ok: true, lines: [L("«\(job.name)» está en la cola.")]))
            return
        }
        let matches = mirrors.filter { $0.id.uuidString.lowercased() == name.lowercased() || $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
        guard let mirror = matches.first else { throw CloudError.message(L("No hay ningún reflejo llamado «\(name)».")) }
        guard matches.count == 1 else { throw CloudError.message(L("Hay varios reflejos llamados «\(name)». Usa su identificador.")) }
        guard !mirror.paused else { throw CloudError.message(L("Ese reflejo está en pausa. Reanúdalo en iCloudy para sincronizarlo.")) }
        model.mirrors.syncNow(mirror.id)
        try await reply(CLIMessage(nonce: nonce, ok: true, lines: [L("Sincronizando «\(mirror.title)».")]))
    }
}
