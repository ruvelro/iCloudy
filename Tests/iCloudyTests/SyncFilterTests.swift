import XCTest
@testable import iCloudy

/// Negated rules and the size and age filters: what a mirror, a sync or a saved job leaves alone.
@MainActor
final class SyncFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func matcher(_ patterns: [String], hidden: Bool = false, defaults: Bool = false) -> SyncExclusionMatcher {
        SyncExclusions(useDefaults: defaults, skipHidden: hidden, patterns: patterns).matcher(caseInsensitive: false)
    }

    func testTheLastMatchingRuleDecidesAndNegationReincludes() {
        let rules = matcher(["*.log", "!importante.log"])
        XCTAssertTrue(rules.excludes("a/registro.log", isFolder: false))
        XCTAssertFalse(rules.excludes("a/importante.log", isFolder: false), "! brings it back")
        let reversed = matcher(["!importante.log", "*.log"])
        XCTAssertTrue(reversed.excludes("importante.log", isFolder: false), "A later rule overrides an earlier negation")
        XCTAssertFalse(matcher(["\\!raro"]).excludes("otro", isFolder: false))
        XCTAssertTrue(matcher(["\\!raro"]).excludes("!raro", isFolder: false), "\\! is a literal exclamation mark")
    }

    func testNothingInsideAnExcludedFolderCanBeReincluded() {
        let rules = matcher(["build/", "!build/keep.txt"])
        XCTAssertTrue(rules.excludes("build/keep.txt", isFolder: false), "As in gitignore, the folder is never entered")
        let contents = matcher(["build/*", "!build/keep.txt"])
        XCTAssertFalse(contents.excludes("build/keep.txt", isFolder: false), "Excluding the contents instead lets one back in")
        XCTAssertTrue(contents.excludes("build/other.txt", isFolder: false))
    }

    func testNegationCanUndoTheSwitchesButNeverTheInternalFiles() {
        let rules = matcher(["!.config/", "!.icloudy-temp"], hidden: true)
        XCTAssertTrue(rules.excludes(".cache", isFolder: true))
        XCTAssertFalse(rules.excludes(".config/settings.json", isFolder: false), "One hidden folder brought back")
        XCTAssertTrue(rules.excludes(".icloudy-temp", isFolder: false), "The sync's own temporary files stay out")
        XCTAssertFalse(matcher(["!*.tmp"], defaults: true).excludes("a.tmp", isFolder: false), "A default can be negated")
        XCTAssertFalse(SyncExclusionMatcher.none.excludes(".icloudy-x", isFolder: false), ".none still excludes nothing")
    }

    func testSizeAndAgeFiltersOnlyLookAtWhatIsKnown() {
        var rules = SyncExclusions(useDefaults: false, minSize: 10, maxSize: 100, maxAge: 86_400 * 30, minAge: 300).matcher(caseInsensitive: true)
        XCTAssertTrue(rules.filtersFiles)
        XCTAssertTrue(rules.filtersOut(size: 5, modified: nil, now: now))
        XCTAssertTrue(rules.filtersOut(size: 500, modified: nil, now: now))
        XCTAssertFalse(rules.filtersOut(size: 50, modified: nil, now: now))
        XCTAssertFalse(rules.filtersOut(size: nil, modified: nil, now: now), "Nothing known, nothing filtered")
        XCTAssertTrue(rules.filtersOut(size: 50, modified: now.addingTimeInterval(-86_400 * 31), now: now), "Too old")
        XCTAssertTrue(rules.filtersOut(size: 50, modified: now.addingTimeInterval(-60), now: now), "Still being written")
        XCTAssertFalse(rules.filtersOut(size: 50, modified: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(rules.excludesFile("x.bin", size: 1, modified: nil, now: now))
        rules = SyncExclusions().matcher(caseInsensitive: true)
        XCTAssertFalse(rules.filtersFiles)
    }

    func testTheScanSetsFilteredFilesAsideButKeepsTheirFolders() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("sub/pequeño.bin"))
        try Data(repeating: 1, count: 50).write(to: root.appendingPathComponent("sub/bueno.bin"))
        let rules = SyncExclusions(useDefaults: false, minSize: 10).matcher(caseInsensitive: true)
        let scan = try MirrorPlanner.scan(root, exclusions: rules)
        XCTAssertEqual(Set(scan.stamps.keys), ["sub", "sub/bueno.bin"])
        XCTAssertEqual(Set(scan.excluded.keys), ["sub/pequeño.bin"])
    }

    func testTheTwoWayPlannerLeavesAFileFilteredOnEitherSideAloneOnBoth() throws {
        let stamp = FileStamp(size: 50, modified: now.addingTimeInterval(-3600))
        let big = CloudFile(id: "g", name: "g.bin", mime: "x", size: 5_000, modified: now.addingTimeInterval(-3600), webURL: nil, isFolder: false)
        let old = SyncEntry(local: stamp, remoteID: "g", remoteSize: 50, remoteModified: stamp.modified, isFolder: false)
        let rules = SyncExclusions(useDefaults: false, maxSize: 1000).matcher(caseInsensitive: true)
        // The cloud copy grew past the limit: it is neither downloaded nor is the local one sent up over it.
        let plan = try TwoWayPlanner.plan(local: ["g.bin": stamp], remote: ["g.bin": big], baseline: ["g.bin": old], exclusions: rules, now: now)
        XCTAssertTrue(plan.isEmpty, "\(plan)")
        // Deleted locally while too big in the cloud: the cloud copy stays.
        XCTAssertTrue(try TwoWayPlanner.plan(local: [:], remote: ["g.bin": big], baseline: ["g.bin": old], exclusions: rules, now: now).isEmpty)
        let shown = TwoWayPlanner.excludedItems(local: ["g.bin": stamp], remote: ["g.bin": big], exclusions: rules, now: now)
        XCTAssertEqual(shown.map(\.path), ["g.bin"], "The dry run lists it as left alone")
    }

    func testAFolderUploadLeavesOutWhatTheJobsOwnRulesExclude() async throws {
        let root = try temporaryRoot()
        let local = root.appendingPathComponent("Carpeta")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: local.appendingPathComponent("b.log"))
        try Data("c".utf8).write(to: local.appendingPathComponent("c.log"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .zero
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        var job = Transfer(name: "Carpeta", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: local)
        job.options = TransferOptions(exclusions: SyncExclusions(useDefaults: false, patterns: ["*.log", "!c.log"]))
        try queue.add([job])
        try await wait { queue.items.first?.state == .completed }
        let folder = try XCTUnwrap(demo.list("root").first { $0.name == "Carpeta" })
        XCTAssertEqual(try demo.list(folder.id).map(\.name).sorted(), ["a.txt", "c.log"])
    }

    func testOlderRecordsWithoutTheNewFieldsStillLoad() throws {
        let rules = try JSONDecoder().decode(SyncExclusions.self, from: Data(#"{"useDefaults":false,"patterns":["*.tmp"]}"#.utf8))
        XCTAssertNil(rules.minSize); XCTAssertNil(rules.maxAge); XCTAssertFalse(rules.filtersFiles)
        let job = try JSONDecoder().decode(Transfer.self, from: Data(#"{"accountID":"a","direction":"upload","localURL":"file:///tmp/x","state":"paused"}"#.utf8))
        XCTAssertNil(job.options)
        let future = try JSONDecoder().decode(Transfer.self, from: Data(#"{"accountID":"a","direction":"upload","localURL":"file:///tmp/x","options":{"conflictPolicy":"flipACoin","skipIdentical":true}}"#.utf8))
        XCTAssertNil(future.options?.conflictPolicy, "An unknown policy asks")
        XCTAssertEqual(future.options?.skipIdentical, true)
        var saved = SyncExclusions(maxSize: 7)
        saved = try JSONDecoder().decode(SyncExclusions.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(saved.maxSize, 7)
    }
}
