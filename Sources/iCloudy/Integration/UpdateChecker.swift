import Foundation
import Observation

/// A version number as SemVer writes it: `0.9.0`, `v1.0.0`, `1.0.0-beta.2`. Build metadata (`+…`) is ignored, and a
/// missing minor or patch counts as zero, so `1.0` and `1.0.0` are the same version.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int
    /// The identifiers after the hyphen, or empty for a release.
    let prerelease: [String]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count) else { return nil }
        var core: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(number) else { return nil }
            core.append(value)
        }
        while core.count < 3 { core.append(0) }
        (major, minor, patch) = (core[0], core[1], core[2])
        if halves.count == 2 {
            let identifiers = halves[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.contains(where: \.isEmpty) else { return nil }
            prerelease = identifiers
        } else {
            prerelease = []
        }
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A release is newer than any of its pre-releases: 1.0.0-rc.1 < 1.0.0.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case (let l?, let r?): return l < r
            case (.some, nil): return true  // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// What the release workflow publishes as `appcast.json` beside each release (scripts/release.py appcast).
struct UpdateFeed: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        /// "dmg" or "zip".
        let kind: String
        let name: String
        let url: URL
        let size: Int64
        let sha256: String
    }
    let schemaVersion: Int
    let version: String
    let build: String?
    let published: Date?
    let minimumSystemVersion: String?
    /// False for a build without a Developer ID signature and notarization, which macOS will not open as is.
    let signed: Bool
    let releaseURL: URL
    let notes: String
    let assets: [Asset]

    /// The newest format this build understands. A newer feed is still offered, as a link to the release page.
    static let supportedSchema = 1

    /// What the download button fetches: the disk image when there is one. A feed in a newer format may mean
    /// something else by its assets, so it only gets the link to the release page.
    var download: Asset? {
        guard schemaVersion <= Self.supportedSchema else { return nil }
        return assets.first { $0.kind == "dmg" } ?? assets.first { $0.kind == "zip" } ?? assets.first
    }

    /// True when this Mac's system is older than the release asks for.
    var needsNewerSystem: Bool {
        guard let minimum = minimumSystemVersion.flatMap(AppVersion.init) else { return false }
        return !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: minimum.major, minorVersion: minimum.minor, patchVersion: minimum.patch))
    }

    /// The release notes as the update window shows them: CHANGELOG headings become bold lines, because the window
    /// renders inline Markdown only, and GitHub's alert markers (`> [!WARNING]`) are dropped with their quote marks.
    var displayNotes: String {
        notes.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            if line.hasPrefix("> [!") { return nil }
            let line = line.hasPrefix("> ") ? line.dropFirst(2) : line
            let trimmed = line.drop { $0 == "#" }
            guard trimmed.count < line.count, trimmed.first == " " else { return String(line) }
            return "**" + trimmed.dropFirst() + "**"
        }.joined(separator: "\n")
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case noRelease
    case http(Int)
    case invalidFeed
    case insecureLink

    var errorDescription: String? {
        switch self {
        case .noRelease: return L("Todavía no hay ninguna versión publicada en GitHub.")
        case .http(let status): return L("GitHub respondió con el código \(status) al pedir la última versión.")
        case .invalidFeed: return L("La ficha de la última versión no se ha podido leer.")
        case .insecureLink: return L("La ficha de la última versión trae un enlace sin cifrar, así que no se ofrece.")
        }
    }
}

/// Tells the user when a newer iCloudy is published, and nothing else: it reads one small JSON file from the
/// GitHub release, compares versions and shows the notes, the download link and its SHA-256. It never downloads or
/// installs anything; the user does, from the browser. docs/DISTRIBUCION.md explains why this and not Sparkle.
@MainActor @Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateFeed)
        case failed(String)
    }

    /// GitHub redirects `latest/download/<file>` to that file in the newest release that is not a pre-release.
    static let defaultFeedURL = URL(string: "https://github.com/ruvelro/iCloudy/releases/latest/download/appcast.json")!
    static let interval: TimeInterval = 24 * 60 * 60
    /// The placeholder a bundle carries when it was not built by scripts/build-app.sh (`swift run`, for instance).
    static let placeholderVersion = "0.0.0"

    static let shared = UpdateChecker()

    private(set) var status: Status = .idle
    /// A release an automatic check found and the user has not seen yet; the update window opens for it.
    var pendingPrompt: UpdateFeed?
    /// Whether to check by itself once a day. Off until the user turns it on: a request to GitHub the user did not
    /// ask for would be the first one iCloudy makes to anyone other than their own clouds.
    var automatic: Bool { didSet { Prefs.defaults.set(automatic, forKey: Prefs.automaticUpdateChecks) } }
    private(set) var lastCheck: Date?
    /// The version the user chose to skip; automatic checks stay quiet about it, a manual one still shows it.
    private(set) var skippedVersion: String?

    let currentVersion: String
    let currentBuild: String?
    private let feedURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(currentVersion: String? = nil, currentBuild: String? = nil, feedURL: URL = UpdateChecker.defaultFeedURL,
         session: URLSession? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.currentVersion = currentVersion ?? info["CFBundleShortVersionString"] as? String ?? Self.placeholderVersion
        self.currentBuild = currentBuild ?? info["CFBundleVersion"] as? String
        self.feedURL = feedURL
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.now = now
        automatic = Prefs.bool(Prefs.automaticUpdateChecks, default: false)
        lastCheck = Prefs.defaults.object(forKey: Prefs.lastUpdateCheck) as? Date
        skippedVersion = Prefs.defaults.string(forKey: Prefs.skippedUpdateVersion)
    }

    /// A build without a real version cannot say whether anything is newer, so it never checks by itself.
    var isDevelopmentBuild: Bool { AppVersion(currentVersion) == AppVersion(Self.placeholderVersion) }

    /// True when the automatic check is on and the last one is a day old, or never happened, or is in the future
    /// (the clock was changed).
    var isDue: Bool {
        guard automatic, !isDevelopmentBuild else { return false }
        guard let lastCheck else { return true }
        let elapsed = now().timeIntervalSince(lastCheck)
        return elapsed >= Self.interval || elapsed < 0
    }

    func isNewer(_ feed: UpdateFeed) -> Bool {
        guard let offered = AppVersion(feed.version) else { return false }
        guard let installed = AppVersion(currentVersion) else { return true }
        return installed < offered
    }

    /// Asks GitHub for the newest release. A manual check reports every outcome; an automatic one only raises
    /// `pendingPrompt`, and only for a version the user has not skipped.
    @discardableResult
    func check(manual: Bool) async -> Status {
        if status == .checking { return status }
        let previous = status
        status = .checking
        do {
            let feed = try await fetchFeed()
            lastCheck = now()
            Prefs.defaults.set(lastCheck, forKey: Prefs.lastUpdateCheck)
            if isNewer(feed), manual || feed.version != skippedVersion {
                status = .available(feed)
                if !manual { pendingPrompt = feed }
            } else {
                status = .upToDate
            }
        } catch {
            // A failed automatic check stays silent and is tried again later; it does not count as the day's check.
            status = manual ? .failed(error.localizedDescription) : previous
        }
        return status
    }

    func checkIfDue() async {
        guard isDue else { return }
        await check(manual: false)
    }

    /// Runs for as long as the explorer window is open, looking once an hour whether a check is due.
    func runSchedule() async {
        while !Task.isCancelled {
            await checkIfDue()
            try? await Task.sleep(for: .seconds(60 * 60))
        }
    }

    func skip(_ feed: UpdateFeed) {
        skippedVersion = feed.version
        Prefs.defaults.set(feed.version, forKey: Prefs.skippedUpdateVersion)
        pendingPrompt = nil
        status = .upToDate
    }

    private func fetchFeed() async throws -> UpdateFeed {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("iCloudy/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 404 else { throw UpdateCheckError.noRelease }
        guard (200..<300).contains(status) else { throw UpdateCheckError.http(status) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> UpdateFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let feed = try? decoder.decode(UpdateFeed.self, from: data), AppVersion(feed.version) != nil else {
            throw UpdateCheckError.invalidFeed
        }
        // The links are opened in the browser as they come: anything but HTTPS could be swapped on the way.
        let links = [feed.releaseURL] + feed.assets.map(\.url)
        guard links.allSatisfy({ $0.scheme?.lowercased() == "https" }) else { throw UpdateCheckError.insecureLink }
        return feed
    }
}
