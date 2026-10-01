import Foundation

/// What the export says about this Mac and this app, gathered on the main actor in one go. Only counts and kinds: no
/// account names, no addresses, no file names.
struct DiagnosticsSnapshot: Sendable {
    struct AccountGroup: Sendable, Equatable {
        var provider: String
        var count: Int
        var capabilities: [String]
    }
    var appVersion: String
    var system: String
    var level: DiagnosticsLevel
    var accounts: [AccountGroup]
    var queue: [String: Int]
    var generated: Date
}

/// Builds the package a person can hand over: `events.jsonl`, `summary.txt` and, when an earlier version left one,
/// O2's old record. Everything goes through the redactor once more at the level in force when exporting, so what is
/// exported never says more than what that level allows, whatever was recorded before.
enum DiagnosticsExport {
    struct Package: Sendable {
        var summary: String
        var events: Data
        var eventCount: Int
        var legacyO2: String?
        var includesNames: Bool
        var fileNames: [String] {
            ["summary.txt", "events.jsonl"] + (legacyO2 == nil ? [] : [legacyO2Name])
        }
        /// The most recent lines of `events.jsonl`, for the preview.
        func preview(lines: Int) -> String {
            String(decoding: events, as: UTF8.self).split(separator: "\n").suffix(lines).joined(separator: "\n")
        }
    }
    static let legacyO2Name = "o2-diagnostico-anterior.txt"

    @MainActor
    static func snapshot(model: AppModel, level: DiagnosticsLevel = Diagnostics.shared.level) -> DiagnosticsSnapshot {
        snapshot(accounts: model.accounts, transfers: model.queue.items, level: level)
    }

    static func snapshot(accounts: [Account], transfers: [Transfer], level: DiagnosticsLevel,
                         bundle: Bundle = .main, now: Date = Date()) -> DiagnosticsSnapshot {
        let info = bundle.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String).map { short in
            short + ((info["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
        } ?? "desarrollo"
        // Accounts of one provider with the same capabilities are one line: a Nextcloud and a plain WebDAV differ.
        var groups: [String: DiagnosticsSnapshot.AccountGroup] = [:]
        for account in accounts {
            let provider = account.isDemo ? "demo" : account.cloud.rawValue
            let capabilities = Self.capabilityNames(account.capabilities)
            let key = provider + "|" + capabilities.joined(separator: ",")
            groups[key, default: .init(provider: provider, count: 0, capabilities: capabilities)].count += 1
        }
        var queue: [String: Int] = [:]
        for transfer in transfers { queue[transfer.state.rawValue, default: 0] += 1 }
        return DiagnosticsSnapshot(appVersion: version, system: ProcessInfo.processInfo.operatingSystemVersionString,
                                   level: level,
                                   accounts: groups.values.sorted { ($0.provider, $0.capabilities.count) < ($1.provider, $1.capabilities.count) },
                                   queue: queue, generated: now)
    }

    /// The capabilities that are on, by name. Read by reflection so that a capability added later shows up here
    /// without anyone having to remember this list.
    static func capabilityNames(_ capabilities: CloudCapabilities) -> [String] {
        Mirror(reflecting: capabilities).children.compactMap { child in
            (child.value as? Bool) == true ? child.label : nil
        }
    }

    /// Reads the log and prepares everything to be written. Reads files: call it off the main actor.
    static func prepare(_ snapshot: DiagnosticsSnapshot, log: DiagnosticsLog = Diagnostics.shared,
                        legacyO2: URL? = O2Log.legacyURL) -> Package {
        let redactor = DiagnosticsRedactor(salt: log.salt, revealNames: snapshot.level.revealsNames)
        let events = log.storedEvents().map { DiagnosticsLog.scrub($0, redactor: redactor) }
        let lines = events.reduce(into: Data()) { $0.append(DiagnosticsLog.line($1)) }
        let legacy = legacyO2.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { text in
            text.split(separator: "\n").map { redactor.text(String($0)) }.joined(separator: "\n") + "\n"
        }
        return Package(summary: summary(snapshot, events: events), events: lines, eventCount: events.count,
                       legacyO2: legacy, includesNames: snapshot.level.revealsNames)
    }

    static func summary(_ snapshot: DiagnosticsSnapshot, events: [DiagnosticEvent]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Diagnóstico de iCloudy",
            "Generado: \(formatter.string(from: snapshot.generated))",
            "Versión de la app: \(snapshot.appVersion)",
            "macOS: \(snapshot.system)",
            "Nivel de diagnóstico: \(snapshot.level.rawValue)",
            "Nombres de archivo y rutas: \(snapshot.level.revealsNames ? "incluidos (nivel detallado aceptado)" : "no incluidos")",
            "",
            "Cuentas por proveedor:",
        ]
        if snapshot.accounts.isEmpty { lines.append("- ninguna") }
        for group in snapshot.accounts {
            lines.append("- \(group.provider): \(group.count) · capacidades: \(group.capabilities.joined(separator: ", "))")
        }
        lines += ["", "Cola de transferencias:"]
        if snapshot.queue.isEmpty { lines.append("- vacía") }
        for (state, count) in snapshot.queue.sorted(by: { $0.key < $1.key }) { lines.append("- \(state): \(count)") }
        lines += ["", "Eventos: \(events.count)"]
        let bySeverity = Dictionary(grouping: events, by: \.severity.rawValue).mapValues(\.count)
        lines.append("- por tipo: " + bySeverity.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let byStage = Dictionary(grouping: events, by: \.stage).mapValues(\.count)
        lines.append("- por etapa: " + byStage.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let byProvider = Dictionary(grouping: events, by: { $0.provider ?? "-" }).mapValues(\.count)
        lines.append("- por proveedor: " + byProvider.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        if let first = events.first?.time, let last = events.last?.time {
            lines.append("- desde \(formatter.string(from: first)) hasta \(formatter.string(from: last))")
        }
        lines += ["", "Las cuentas aparecen como un resumen (cuenta-…) que solo este Mac sabe relacionar con cada una.",
                  "No hay contraseñas, tokens, cookies, firmas ni direcciones de sesiones de subida en este paquete."]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the package into `folder`, which is created with private permissions.
    static func write(_ package: Package, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files: [(String, Data)] = [("summary.txt", Data(package.summary.utf8)), ("events.jsonl", package.events)]
            + (package.legacyO2.map { [(legacyO2Name, Data($0.utf8))] } ?? [])
        for (name, data) in files {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Writes the package as a .zip at `destination`. The archive is made by the system, the same one the Finder's
    /// "Compress" makes, so nothing outside macOS is needed for it.
    static func archive(_ package: Package, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("iCloudy-" + UUID().uuidString, isDirectory: true)
        let folder = staging.appendingPathComponent(destination.deletingPathExtension().lastPathComponent, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(package, to: folder)
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordination) { zipped in
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// Deletes everything the log has kept, and O2's old record with it.
    static func clear(log: DiagnosticsLog = Diagnostics.shared, legacyO2: URL? = O2Log.legacyURL) {
        log.clear()
        if let legacyO2 { try? FileManager.default.removeItem(at: legacyO2) }
    }
}
