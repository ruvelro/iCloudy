import Foundation

extension Prefs {
    static let transferConcurrency = "transferConcurrency"
    static let transferPerAccount = "transferPerAccount"
    static let uploadLimitEnabled = "uploadLimitEnabled"
    static let uploadLimitValue = "uploadLimitValue"
    static let uploadLimitUnit = "uploadLimitUnit"
    static let downloadLimitEnabled = "downloadLimitEnabled"
    static let downloadLimitValue = "downloadLimitValue"
    static let downloadLimitUnit = "downloadLimitUnit"
    static let transferWindowEnabled = "transferWindowEnabled"
    static let transferWindowStart = "transferWindowStart"
    static let transferWindowEnd = "transferWindowEnd"
    static let pauseOnCostlyNetwork = "pauseOnCostlyNetwork"
}

/// Units offered for the bandwidth limit. Decimal, like the speeds `ByteCountFormatter` shows on every card, so a
/// limit of 2 MB/s reads as 2 MB/s in the panel too.
enum BandwidthUnit: String, CaseIterable, Identifiable {
    case kilobytes = "KB", megabytes = "MB"
    var id: String { rawValue }
    var title: String { rawValue + "/s" }
    var bytes: Int64 { self == .kilobytes ? 1000 : 1_000_000 }
}

/// "Only transfer between HH:MM and HH:MM", in minutes after midnight of the Mac's own clock. A window whose end comes
/// before its start crosses midnight, which is the usual shape: 22:00 to 07:00.
struct TransferWindow: Codable, Equatable {
    var start: Int
    var end: Int

    /// Equal ends would be a window of no length; it is read as "always", so the setting can never freeze the queue.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard start != end else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }
    /// The next moment the answer of `contains` changes: the end while inside, the start while outside.
    func nextChange(after date: Date, calendar: Calendar = .current) -> Date? {
        guard start != end else { return nil }
        let boundary = contains(date, calendar: calendar) ? end : start
        return calendar.nextDate(after: date, matching: DateComponents(hour: boundary / 60, minute: boundary % 60, second: 0),
                                 matchingPolicy: .nextTime)
    }
    static func text(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// Why the queue paused a job by itself. Kept on the job, so it starts again on its own when the reason goes away;
/// a job without one was paused by the person and waits for them.
enum TransferHold: String, Codable {
    case offline, schedule, costlyNetwork

    var symbol: String {
        switch self {
        case .offline: return "wifi.slash"
        case .schedule: return "clock"
        case .costlyNetwork: return "antenna.radiowaves.left.and.right"
        }
    }
    func detail(window: TransferWindow?) -> String {
        switch self {
        case .offline: return L("Sin conexión · se reanudará automáticamente al volver la red")
        case .schedule:
            guard let window else { return L("Fuera del horario de transferencias · se reanudará automáticamente") }
            return L("Fuera del horario de transferencias · se reanudará a las \(TransferWindow.text(window.start))")
        case .costlyNetwork: return L("Red de datos móviles o en modo de datos reducidos · se reanudará en otra red")
        }
    }
}

/// Everything the person can set about how the queue runs. The defaults are what a queue with no settings does.
struct TransferPolicy: Equatable {
    var maxConcurrent = 3
    var maxPerAccount = 2
    /// Bytes per second; nil is no limit.
    var uploadLimit: Int64?
    var downloadLimit: Int64?
    var window: TransferWindow?
    var pauseOnCostlyNetwork = false

    static let concurrencyRange = 1...8
    static let perAccountRange = 1...4
    /// Below this a suspended download waits so long between turns that the server may give up on it.
    static let minimumLimit: Int64 = 32_000

    static func stored(in defaults: UserDefaults = .standard) -> TransferPolicy {
        func int(_ key: String) -> Int? { defaults.object(forKey: key) as? Int }
        func bool(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? false }
        func limit(_ enabled: String, _ value: String, _ unit: String) -> Int64? {
            guard bool(enabled), let amount = int(value), amount > 0 else { return nil }
            return max(minimumLimit, Int64(amount) * (BandwidthUnit(rawValue: defaults.string(forKey: unit) ?? "") ?? .megabytes).bytes)
        }
        var policy = TransferPolicy()
        policy.maxConcurrent = int(Prefs.transferConcurrency).map { min(max($0, concurrencyRange.lowerBound), concurrencyRange.upperBound) } ?? 3
        policy.maxPerAccount = int(Prefs.transferPerAccount).map { min(max($0, perAccountRange.lowerBound), perAccountRange.upperBound) } ?? 2
        policy.uploadLimit = limit(Prefs.uploadLimitEnabled, Prefs.uploadLimitValue, Prefs.uploadLimitUnit)
        policy.downloadLimit = limit(Prefs.downloadLimitEnabled, Prefs.downloadLimitValue, Prefs.downloadLimitUnit)
        if bool(Prefs.transferWindowEnabled) {
            let day = 24 * 60
            policy.window = TransferWindow(start: (int(Prefs.transferWindowStart) ?? 22 * 60) % day,
                                           end: (int(Prefs.transferWindowEnd) ?? 7 * 60) % day)
        }
        policy.pauseOnCostlyNetwork = bool(Prefs.pauseOnCostlyNetwork)
        return policy
    }
}

/// Decides which waiting jobs may start. Pure, so the limits can be tested without moving a byte.
enum TransferScheduler {
    /// Providers whose session does one thing at a time. FTP has a single control connection, SFTP one channel, and
    /// Mega and O2 a session the server serialises (or drops requests from) when it is asked two things at once. A
    /// second job on them would only queue inside the session while showing as running here.
    static func sessionLimit(for cloud: Cloud) -> Int? {
        switch cloud {
        case .ftp, .sftp, .mega, .o2: return 1
        default: return nil
        }
    }
    static func perAccountLimit(for cloud: Cloud?, policy: TransferPolicy) -> Int {
        let chosen = max(1, policy.maxPerAccount)
        guard let cloud, let session = sessionLimit(for: cloud) else { return chosen }
        return min(chosen, session)
    }
    /// A cross-cloud transfer occupies both accounts.
    static func accounts(of transfer: Transfer) -> [String] {
        guard let target = transfer.targetAccountID, target != transfer.accountID else { return [transfer.accountID] }
        return [transfer.accountID, target]
    }
    /// Waiting jobs to start now, in queue order. One that its account cannot take yet is passed over rather than
    /// blocking the ones behind it for other accounts; it keeps its place and starts as soon as its account frees up.
    static func startable(_ items: [Transfer], running: Set<UUID>, policy: TransferPolicy, cloud: (String) -> Cloud?) -> [UUID] {
        var load: [String: Int] = [:]
        for item in items where running.contains(item.id) {
            for account in accounts(of: item) { load[account, default: 0] += 1 }
        }
        var count = running.count
        var picked: [UUID] = []
        for item in items where item.state == .queued && !running.contains(item.id) {
            guard count < max(1, policy.maxConcurrent) else { break }
            let involved = accounts(of: item)
            guard involved.allSatisfy({ load[$0, default: 0] < perAccountLimit(for: cloud($0), policy: policy) }) else { continue }
            for account in involved { load[account, default: 0] += 1 }
            picked.append(item.id)
            count += 1
        }
        return picked
    }
}

/// The queue as a whole, for the menu bar and the panel: several jobs move at once now, so the first running one is
/// no longer the whole story.
struct TransferActivity: Equatable {
    var running = 0
    var waiting = 0
    var paused = 0
    var failed = 0
    var bytes: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0

    init(_ items: [Transfer]) {
        for item in items {
            switch item.state {
            case .running:
                running += 1
                bytes += item.bytes
                total += max(item.total, item.bytes)
                bytesPerSecond += item.bytesPerSecond
            case .queued: waiting += 1
            case .paused: paused += 1
            case .failed: failed += 1
            case .cancelled, .completed: break
            }
        }
    }
    var progress: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
    /// "3,4 MB/s" across every running job, or nil when nothing has reported a speed yet.
    var speed: String? {
        guard running > 0, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

/// Names that running jobs have chosen in a folder, remote or local, before the item is actually there.
///
/// One job at a time could trust its own listing: whatever an earlier job created was already in it. Two jobs side by
/// side each list the destination before the other has written anything, so both would pick «foto (2).jpg», or both
/// upload «foto.jpg» where the second one should have asked. A job now treats what the others have claimed as taken.
/// Claims last until the queue is idle, because a job that finished may have created a name that another one's
/// listing, taken earlier, still does not show.
struct NameClaims {
    private var claims: [String: [(job: UUID, name: String)]] = [:]

    static func remote(account: String, parent: String) -> String { "remote\u{1}" + account + "\u{1}" + parent }
    static func local(_ folder: URL) -> String { "local\u{1}" + folder.standardizedFileURL.path }

    mutating func claim(_ name: String, in folder: String, by job: UUID) {
        guard !taken(name, in: folder, by: job) else { return }
        claims[folder, default: []].append((job, name))
    }
    /// Names claimed in `folder` by every job but `job` itself.
    func others(in folder: String, excluding job: UUID) -> [String] {
        (claims[folder] ?? []).filter { $0.job != job }.map(\.name)
    }
    private func taken(_ name: String, in folder: String, by job: UUID) -> Bool {
        (claims[folder] ?? []).contains { $0.job == job && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
    mutating func removeAll() { claims = [:] }
}
