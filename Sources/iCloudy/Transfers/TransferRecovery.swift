import Foundation

/// What a check of the destination found, for the line under the report's buttons.
struct VerificationSummary: Equatable {
    var checked = 0
    var verified = 0
    var sizeOnly = 0
    var missing = 0
    /// Lines that could not be looked at: no known folder, no source, an export with nothing to compare.
    var skipped = 0
    var text: String {
        var parts = [L("Comprobados \(checked) archivos.")]
        if verified > 0 { parts.append(L("\(verified) coinciden con la suma del proveedor.")) }
        if sizeOnly > 0 { parts.append(L("\(sizeOnly) coinciden en tamaño; no hay suma con la que compararlos.")) }
        if missing > 0 { parts.append(L("\(missing) no están en el destino o no coinciden: quedan pendientes.")) }
        if skipped > 0 { parts.append(L("\(skipped) no se pudieron comprobar.")) }
        return parts.joined(separator: " ")
    }
}

/// Guided recovery of a batch that failed or stopped halfway: retry only what is left, and look at the destination
/// to confirm what the report says is already there.
@MainActor
enum TransferRecovery {
    /// The judgement for one file: the description the destination (or the source) gives against the bytes in hand.
    /// `digest` is the other side's digest in the listed checksum's algorithm, nil when there is none to compare.
    static func judge(listed: CloudFile, size: Int64?, digest: String?) -> (FileOutcome, String?) {
        if let expected = listed.size, let size, expected != size {
            return (.failed, L("El tamaño no coincide: \(size) bytes frente a los \(expected) que anuncia el proveedor."))
        }
        if let checksum = listed.checksum, let digest {
            return checksum.matches(digest)
                ? (.verified, nil)
                : (.failed, L("La suma de verificación no coincide con la que anuncia el proveedor."))
        }
        if listed.size == nil || size == nil { return (.unverified, L("Está en el destino, pero no hay tamaño ni suma con los que compararlo.")) }
        return (.unverified, L("Coincide en tamaño; el proveedor no da una suma con la que compararlo."))
    }
}

extension TransferQueue {
    /// Jobs of the batch with work left: those that did not finish, and completed ones in which a check found a
    /// copied file missing. Completed jobs with nothing outstanding stay as they are.
    func recoverable(_ batchID: UUID) -> [Transfer] {
        items.filter { job in
            job.batchID == batchID && ([.failed, .cancelled, .paused].contains(job.state)
                || job.state == .completed && job.report.values.contains { $0.outcome.isOutstanding })
        }
    }
    /// "Reintentar solo lo pendiente": puts back in the queue exactly the jobs with work left. Within each, the walk
    /// skips every path already completed or skipped, so only failed and pending files travel again.
    @discardableResult func retryPending(_ batchID: UUID) -> Int {
        let jobs = recoverable(batchID)
        for job in jobs { if job.state == .completed { requeue(job.id) } else { retry(job.id) } }
        return jobs.count
    }

    /// "Verificar lo copiado": asks the destination about every file the report says is there and compares size and,
    /// where both sides have one, checksum. A file that is missing or different goes back to pending, so a retry of
    /// the pending part copies it again.
    func verifyCopied(_ batchID: UUID, progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> VerificationSummary {
        var summary = VerificationSummary()
        let jobs = items.filter { $0.batchID == batchID && !$0.report.isEmpty && ![.queued, .running].contains($0.state) }
        let total = jobs.reduce(0) { $0 + $1.report.values.filter(Self.checkable).count }
        var done = 0
        for job in jobs {
            guard let lookup = client else { throw CloudError.message(L("Conecta la cuenta de esta transferencia.")) }
            let api = try lookup(job.accountID)
            let target = try job.targetAccountID.map(lookup)
            let checker = DestinationChecker(job: job, api: api, target: target)
            try await checker.open { checker in
                for (key, record) in job.report.sorted(by: { $0.key < $1.key }) where Self.checkable(record) {
                    try Task.checkCancellation()
                    guard let (outcome, reason) = try await checker.check(key, record) else { summary.skipped += 1; done += 1; progress(done, total); continue }
                    summary.checked += 1
                    switch outcome {
                    case .verified: summary.verified += 1
                    case .unverified: summary.sizeOnly += 1
                    default: summary.missing += 1
                    }
                    // A file that is not what the report says is work to do again, not a dead end. A copy checked
                    // against the provider's checksum when it was sent stays verified if its size still matches: a
                    // listing without checksums is weaker evidence, not evidence against it.
                    switch outcome {
                    case .failed: applyCheck(job.id, key: key, .pending, reason: reason)
                    case .unverified where record.outcome == .verified: applyCheck(job.id, key: key, .verified, reason: nil)
                    default: applyCheck(job.id, key: key, outcome, reason: reason)
                    }
                    done += 1; progress(done, total)
                }
            }
        }
        return summary
    }
    nonisolated private static func checkable(_ record: FileRecord) -> Bool {
        !record.path.hasSuffix("/") && [.verified, .unverified, .uncertain].contains(record.outcome)
    }
}

/// Finds, for one job, the copy each report line refers to and judges it. Listings are asked for once per folder.
@MainActor
private final class DestinationChecker {
    let job: Transfer
    let api: CloudAPI
    let target: CloudAPI?
    private var listings: [String: [CloudFile]] = [:]
    private var local: URL
    init(job: Transfer, api: CloudAPI, target: CloudAPI?) {
        self.job = job; self.api = api; self.target = target; local = job.localURL
    }

    /// Resolves the job's bookmark and keeps its security scope open while `body` runs.
    func open(_ body: (DestinationChecker) async throws -> Void) async throws {
        if let bookmark = job.bookmark {
            var stale = false
            local = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? job.localURL
        }
        let scoped = local.startAccessingSecurityScopedResource()
        defer { if scoped { local.stopAccessingSecurityScopedResource() } }
        try await body(self)
    }

    /// nil when the line cannot be checked at all.
    func check(_ key: String, _ record: FileRecord) async throws -> (FileOutcome, String?)? {
        switch job.direction {
        case .upload:
            let file = key == "." ? local : key.split(separator: "/").dropFirst().reduce(local) { $0.appendingPathComponent(String($1)) }
            guard let remote = try await destination(key, name: names(key) ?? file.lastPathComponent) else { return Self.missing }
            return try await judge(remote, against: file)
        case .download:
            guard let listed = try await source(key) else { return (.failed, L("Ya no está en la nube de origen.")) }
            let file = localPath(key)
            guard FileManager.default.fileExists(atPath: file.path) else { return (.failed, L("Ya no está en la carpeta del Mac donde se guardó.")) }
            return try await judge(listed, against: file)
        case .transfer:
            guard record.outcome != .exported, let target else { return nil }
            guard let copy = try await destination(key, name: names(key), in: target) else { return Self.missing }
            guard let original = try await source(key) else { return (.unverified, L("Está en el destino, pero el original ya no está en la nube de origen.")) }
            // Google documents leave as Office files: there is nothing in the original to compare the copy with.
            guard !original.isGoogleDocument else { return nil }
            // Both sides must speak the same algorithm; otherwise only the size says anything.
            let digest = original.checksum?.algorithm == copy.checksum?.algorithm ? original.checksum?.value : nil
            return TransferRecovery.judge(listed: copy, size: original.size, digest: digest)
        }
    }
    private static let missing: (FileOutcome, String?) = (.failed, L("No está en el destino."))

    private func names(_ key: String) -> String? { job.names[key] }
    /// The remote folder a key's item went into: the job's parent for the top item, the folder created or merged into
    /// for anything below it.
    private func destinationParent(_ key: String) -> String? {
        guard let parent = Transfer.parentKey(key) else { return job.parent }
        return job.folders[parent] ?? job.replacements[parent]
    }
    private func destination(_ key: String, name: String?, in client: CloudAPI? = nil) async throws -> CloudFile? {
        guard let name, let parent = destinationParent(key) else { return nil }
        let children = try await listing(parent, client: client ?? api, scope: "d")
        return children.first { $0.name == name && !$0.isFolder } ?? children.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame && !$0.isFolder }
    }
    /// The source item of a download or cross-cloud key, found by id in its parent's listing.
    private func source(_ key: String) async throws -> CloudFile? {
        guard let root = job.file else { return nil }
        guard key != "." else { return try await api.currentMetadata(of: root) ?? root }
        let ids = key.split(separator: "/").dropFirst().map(String.init)
        let parent = ids.count == 1 ? root.id : ids[ids.count - 2]
        return try await listing(parent, client: api, scope: "s").first { $0.id == ids.last }
    }
    private func listing(_ parent: String, client: CloudAPI, scope: String) async throws -> [CloudFile] {
        if let known = listings[scope + parent] { return known }
        let children = try await client.list(parent: parent)
        listings[scope + parent] = children
        return children
    }
    /// The local path of a downloaded key, following the names chosen for it and its ancestors.
    private func localPath(_ key: String) -> URL {
        var keys: [String] = []
        var current: String? = key
        while let k = current { keys.insert(k, at: 0); current = Transfer.parentKey(k) }
        return keys.reduce(local) { url, k in url.appendingPathComponent(job.names[k] ?? FileNames.safe(job.name)) }
    }
    /// Hashes the local copy off the main thread, once and only in the algorithm the provider listed.
    private func judge(_ listed: CloudFile, against file: URL) async throws -> (FileOutcome, String?) {
        guard let size = try? await blockingIO({ Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) }) else {
            // The local side moved or was deleted: the destination can only say it is there.
            return TransferRecovery.judge(listed: listed, size: nil, digest: nil)
        }
        var digest: String?
        if let algorithm = listed.checksum?.algorithm, listed.size == nil || listed.size == size {
            digest = try await blockingIO { try ContentHasher.digest(of: file, algorithm: algorithm).digest }
        }
        return TransferRecovery.judge(listed: listed, size: size, digest: digest)
    }
}
