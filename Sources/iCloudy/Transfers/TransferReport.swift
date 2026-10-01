import Foundation

/// What became of one file of a job. The same vocabulary covers uploads, downloads and cross-cloud copies, so a batch
/// that mixes them reads as one report.
enum FileOutcome: String, Codable, CaseIterable, Identifiable {
    /// Copied, and the provider's checksum matched.
    case verified
    /// Copied, but only the size could be compared: resumed upload, no checksum, or a provider without one.
    case unverified
    /// A Google document converted on the way out, or saved as a link: there was nothing to compare it with.
    case exported
    /// Left alone because the destination already had it and "Omitir" was chosen.
    case skipped
    /// Cannot travel at all (Google forms, sites and shortcuts) and was left out on purpose.
    case excluded
    case failed
    /// Not reached yet: the job stopped first, or it has not started.
    case pending
    /// The destination may or may not have it: a folder whose creation was never confirmed, or an upload whose
    /// completion could not be checked. Worth a look before repeating.
    case uncertain
    var id: String { rawValue }
    /// Bytes are already at the destination.
    var isCopied: Bool { [.verified, .unverified, .exported].contains(self) }
    /// Still work to do: what "Reintentar solo lo pendiente" picks up.
    var isOutstanding: Bool { [.failed, .pending, .uncertain].contains(self) }
    var title: String {
        switch self {
        case .verified: return L("Copiado y verificado")
        case .unverified: return L("Copiado sin verificar")
        case .exported: return L("Exportado")
        case .skipped: return L("Omitido")
        case .excluded: return L("Excluido")
        case .failed: return L("Fallido")
        case .pending: return L("Pendiente")
        case .uncertain: return L("Sin confirmar")
        }
    }
    var symbol: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .unverified: return "checkmark.circle"
        case .exported: return "doc.badge.arrow.up"
        case .skipped: return "arrow.uturn.right.circle"
        case .excluded: return "nosign"
        case .failed: return "xmark.octagon.fill"
        case .pending: return "clock"
        case .uncertain: return "questionmark.circle"
        }
    }
    init(_ integrity: DownloadIntegrity) {
        switch integrity {
        case .verified: self = .verified
        case .unavailable: self = .unverified
        case .exported: self = .exported
        case .failed: self = .failed
        }
    }
}

/// One line of a job's report. Short keys and absent optionals keep `transfers.json` small even for jobs with
/// thousands of files, since the whole queue is rewritten on every state change.
struct FileRecord: Codable, Equatable {
    /// Readable path from the job's own item, e.g. "Fotos/2024/playa.jpg". A trailing slash marks a folder.
    var path: String
    var outcome: FileOutcome
    var bytes: Int64?
    var reason: String?
    /// False for a record the summary counters leave out although its outcome is one they count. Only stored when false.
    var counted = true
    enum CodingKeys: String, CodingKey { case path = "p", outcome = "o", bytes = "b", reason = "r", counted = "c" }
    init(path: String, outcome: FileOutcome, bytes: Int64? = nil, reason: String? = nil) {
        self.path = path; self.outcome = outcome; self.bytes = bytes; self.reason = reason
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
        // An outcome written by a newer version is treated as unknown work rather than losing the report.
        outcome = (try? values.decodeIfPresent(FileOutcome.self, forKey: .outcome)) ?? .pending
        bytes = try values.decodeIfPresent(Int64.self, forKey: .bytes)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        counted = try values.decodeIfPresent(Bool.self, forKey: .counted) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(outcome, forKey: .outcome)
        try values.encodeIfPresent(bytes, forKey: .bytes)
        try values.encodeIfPresent(reason, forKey: .reason)
        if !counted { try values.encode(false, forKey: .counted) }
    }
}

extension Transfer {
    /// Records the outcome of one file, keyed like `completedPaths`. The summary counters follow the record, so a
    /// file recorded again by a later run moves between counters instead of being counted twice. `counted: false`
    /// keeps a record out of the counters, for things the completion summary has never counted (a `.webloc`).
    mutating func record(_ key: String, _ outcome: FileOutcome, path: String? = nil, bytes: Int64? = nil, reason: String? = nil, counted: Bool = true) {
        let previous = report[key]
        if let previous, previous.counted { tally(previous.outcome, -1) }
        var entry = FileRecord(path: path ?? previous?.path ?? reportPath(for: key), outcome: outcome,
                               bytes: bytes ?? previous?.bytes, reason: reason)
        entry.counted = counted
        if counted { tally(outcome, 1) }
        report[key] = entry
    }
    /// Marks what a skipped folder contained, so its planned files do not sit in the report as pending forever.
    mutating func skipSubtree(_ key: String, reason: String) {
        for (child, entry) in report where child.hasPrefix(key + "/") && entry.outcome == .pending {
            record(child, .skipped, reason: reason)
        }
    }
    /// "Omitir" in the conflict dialog. A skipped folder takes its planned contents with it.
    mutating func recordSkip(_ key: String, leaf: String, folder: Bool, bytes: Int64?) {
        let reason = L("Ya existía en el destino y se eligió omitirlo.")
        record(key, .skipped, path: reportPath(for: key, leaf: leaf) + (folder ? "/" : ""), bytes: folder ? nil : bytes, reason: reason)
        if folder { skipSubtree(key, reason: reason) }
    }
    /// The item a job was on when it failed. A folder whose creation was never confirmed, or an upload the provider
    /// finished without letting it be checked, may already be at the destination: that is uncertain, not failed.
    mutating func recordFailure(at cursor: ReportCursor, _ error: Error) {
        let uncertain = uncertainFolders.contains(cursor.key) || uploads[cursor.key]?.complete == true
        let path = reportPath(for: cursor.key, leaf: names[cursor.key] ?? cursor.leaf) + (cursor.folder ? "/" : "")
        record(cursor.key, uncertain ? .uncertain : .failed, path: path, reason: error.localizedDescription)
    }
    /// Called when a job completes: a planned file never reached is no longer at the source.
    mutating func settleReport() {
        for (key, entry) in report where entry.outcome == .pending {
            record(key, .failed, reason: L("No se encontró al transferir: pudo borrarse o moverse después del plan."))
        }
    }
    /// The readable path of a key: the names chosen for its ancestors, then its own. Uploads key by local names, so
    /// the key itself already reads well; downloads and cross-cloud copies key by remote ids and use `names`.
    func reportPath(for key: String, leaf: String? = nil) -> String {
        if direction == .upload {
            let root = localURL.lastPathComponent
            guard key != "." else { return leaf ?? root }
            let parts = key.split(separator: "/").dropFirst().map(String.init)
            return ([root] + parts.dropLast() + [leaf ?? parts.last ?? ""]).joined(separator: "/")
        }
        var parts: [String] = [leaf ?? names[key] ?? (key == "." ? name : String(key.split(separator: "/").last ?? ""))]
        var current = Self.parentKey(key)
        while let ancestor = current {
            parts.insert(names[ancestor] ?? (ancestor == "." ? name : String(ancestor.split(separator: "/").last ?? "")), at: 0)
            current = Self.parentKey(ancestor)
        }
        return parts.joined(separator: "/")
    }
    nonisolated static func parentKey(_ key: String) -> String? {
        guard key != ".", let slash = key.lastIndex(of: "/") else { return nil }
        return String(key[..<slash])
    }
    private mutating func tally(_ outcome: FileOutcome, _ delta: Int) {
        switch outcome {
        case .verified: verifiedFiles += delta
        case .unverified: unverifiedFiles += delta
        case .exported: exportedFiles += delta
        default: break
        }
    }
}

/// Where a running job is, kept in memory only: on failure it names the line of the report that failed.
struct ReportCursor {
    let key: String
    let leaf: String
    let folder: Bool
}

/// The report of a whole batch: every job added together, which is what a multi-selection or a folder is to the
/// person who started it. Jobs from before reports existed, or that never started, get one line of their own.
struct TransferReport {
    struct Line: Identifiable, Equatable {
        let id: String
        let jobID: UUID
        let key: String
        let record: FileRecord
    }
    let lines: [Line]
    let jobs: [Transfer]
    /// True when some job had no plan and stopped early: files it never reached are not listed.
    let incomplete: Bool

    init(jobs: [Transfer]) {
        self.jobs = jobs
        var lines: [Line] = []
        var incomplete = false
        for job in jobs {
            if job.report.isEmpty {
                lines.append(Line(id: job.id.uuidString + ":.", jobID: job.id, key: ".", record: Self.synthesized(job)))
                continue
            }
            if !job.planned && job.state != .completed { incomplete = true }
            for (key, record) in job.report {
                lines.append(Line(id: job.id.uuidString + ":" + key, jobID: job.id, key: key, record: record))
            }
        }
        self.lines = lines.sorted { $0.record.path.localizedStandardCompare($1.record.path) == .orderedAscending }
        self.incomplete = incomplete
    }
    /// A job without records: what can be said about it from its state and counters alone.
    private static func synthesized(_ job: Transfer) -> FileRecord {
        let outcome: FileOutcome
        switch job.state {
        case .completed: outcome = job.exportedFiles > 0 ? .exported : (job.verifiedFiles > 0 ? .verified : .unverified)
        case .failed: outcome = .failed
        default: outcome = .pending
        }
        let size = job.file?.isFolder == true ? nil : (job.total > 0 ? job.total : job.file?.size)
        return FileRecord(path: job.name, outcome: outcome, bytes: size, reason: job.failed ? job.detail : nil)
    }
    func count(_ outcome: FileOutcome) -> Int { lines.filter { $0.record.outcome == outcome }.count }
    var copied: Int { lines.filter { $0.record.outcome.isCopied }.count }
    var copiedBytes: Int64 { lines.filter { $0.record.outcome.isCopied }.reduce(0) { $0 + ($1.record.bytes ?? 0) } }
    var outstanding: Int { lines.filter { $0.record.outcome.isOutstanding }.count }
    /// Keys still to be done, per job: exactly what a retry of the pending part will transfer.
    var outstandingKeys: [UUID: Set<String>] {
        Dictionary(grouping: lines.filter { $0.record.outcome.isOutstanding }, by: \.jobID).mapValues { Set($0.map(\.key)) }
    }

    // MARK: - Export

    /// RFC 4180: fields with a comma, quote or line break are quoted and their quotes doubled. Names can contain all
    /// three, and FTP servers have been seen with line breaks in names.
    func csv() -> String {
        var rows = [[L("Ruta"), L("Estado"), L("Código"), L("Bytes"), L("Motivo")]]
        for line in lines {
            rows.append([line.record.path, line.record.outcome.title, line.record.outcome.rawValue,
                         line.record.bytes.map(String.init) ?? "", line.record.reason ?? ""])
        }
        return rows.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
    nonisolated static func csvField(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    struct Export: Codable, Equatable {
        struct Job: Codable, Equatable {
            let name: String
            let direction: String
            let destination: String
            let state: String
            let detail: String
        }
        struct File: Codable, Equatable {
            let path: String
            let status: String
            let label: String
            let bytes: Int64?
            let reason: String?
        }
        let generated: Date
        let jobs: [Job]
        let files: [File]
        let incomplete: Bool
    }
    /// Machine-readable: statuses as stable codes, with the translated label beside them.
    func json(generated: Date = Date()) throws -> Data {
        let export = Export(generated: generated,
                            jobs: jobs.map { Export.Job(name: $0.name, direction: $0.direction.rawValue, destination: $0.destination, state: $0.state.rawValue, detail: $0.detail) },
                            files: lines.map { Export.File(path: $0.record.path, status: $0.record.outcome.rawValue, label: $0.record.outcome.title, bytes: $0.record.bytes, reason: $0.record.reason) },
                            incomplete: incomplete)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }
}
