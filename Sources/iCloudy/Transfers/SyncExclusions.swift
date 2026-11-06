import Foundation

/// One shell-style pattern, with the gitignore conventions people already know:
/// - `*` is any run of characters inside one path component, `?` one character, `[a-z]`, `[!0-9]` or `[^…]` a class,
///   and `\` makes the next character literal.
/// - `**` as a whole component crosses folders: `**/x` is `x` at any depth, `a/**` everything inside `a`, and `a/**/b`
///   includes `a/b`. Glued to other characters (`a**`) it is an ordinary `*`.
/// - A pattern with a `/` before its end is anchored to the mirror's root (a leading `/` only says so explicitly);
///   without one it is compared with the name alone, at any depth. A trailing `/` restricts it to folders.
/// `*` and `?` match a leading dot as well: `*.tmp` catches `.x.tmp`, as in gitignore and unlike the shell.
/// A leading `!` negates the pattern: whatever it matches is included again (`\!` is a literal `!`). The matcher
/// gives the last matching pattern the final word, as gitignore does.
struct GlobPattern: Equatable, Sendable {
    private enum Token: Equatable, Sendable {
        case literal(Character)
        case one
        case star
        /// Any run of characters, `/` included.
        case globstar
        /// `**/`: nothing, or one or more whole components with their trailing `/`.
        case folders
        case set([ClosedRange<Character>], negated: Bool)
    }
    let source: String
    let anchored: Bool
    let foldersOnly: Bool
    let caseInsensitive: Bool
    /// `!pattern`: a match re-includes the item instead of excluding it.
    let negated: Bool
    private let tokens: [Token]

    init(_ pattern: String, caseInsensitive: Bool = false) {
        source = pattern
        self.caseInsensitive = caseInsensitive
        negated = pattern.hasPrefix("!")
        var text = Self.normalize(negated ? String(pattern.dropFirst()) : pattern, caseInsensitive: caseInsensitive)
        var foldersOnly = false
        while text.count > 1, text.hasSuffix("/") { text.removeLast(); foldersOnly = true }
        var anchored = false
        if text.hasPrefix("/") { text.removeFirst(); anchored = true }
        let characters = Array(text)
        if !anchored { anchored = characters.contains("/") }
        self.anchored = anchored
        self.foldersOnly = foldersOnly
        tokens = Self.tokenize(characters)
    }

    /// `path` is relative to the mirror's root and uses `/`. `isFolder` matters only for patterns ending in `/`.
    func matches(_ path: String, isFolder: Bool) -> Bool {
        if foldersOnly, !isFolder { return false }
        let normalized = Self.normalize(path, caseInsensitive: caseInsensitive)
        let subject = anchored ? normalized : String(normalized.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(normalized))
        return Self.match(tokens, Array(subject))
    }

    /// Names on disk come decomposed and patterns are typed composed; comparing either way round has to agree.
    private static func normalize(_ text: String, caseInsensitive: Bool) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        return caseInsensitive ? composed.lowercased() : composed
    }
    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                // A trailing backslash has nothing to escape and stands for itself.
                tokens.append(.literal(index + 1 < characters.count ? characters[index + 1] : "\\"))
                index += 2
            case "?":
                tokens.append(.one); index += 1
            case "*":
                var end = index
                while end < characters.count, characters[end] == "*" { end += 1 }
                let startsComponent = index == 0 || characters[index - 1] == "/"
                let endsComponent = end == characters.count || characters[end] == "/"
                if end - index >= 2, startsComponent, endsComponent {
                    if end < characters.count { tokens.append(.folders); index = end + 1 } else { tokens.append(.globstar); index = end }
                } else {
                    tokens.append(.star); index = end
                }
            case "[":
                if let (set, next) = parseSet(characters, from: index) { tokens.append(set); index = next }
                else { tokens.append(.literal("[")); index += 1 }
            default:
                tokens.append(.literal(character)); index += 1
            }
        }
        return tokens
    }
    /// A class runs to the first `]` that is not its first member. With no closing bracket, `[` is a literal.
    private static func parseSet(_ characters: [Character], from start: Int) -> (Token, Int)? {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" { negated = true; index += 1 }
        var ranges: [ClosedRange<Character>] = []
        var first = true
        while index < characters.count {
            var character = characters[index]
            if character == "]", !first { return (.set(ranges, negated: negated), index + 1) }
            first = false
            if character == "\\", index + 1 < characters.count { index += 1; character = characters[index] }
            if index + 2 < characters.count, characters[index + 1] == "-", characters[index + 2] != "]" {
                var upper = characters[index + 2]
                var skip = 3
                if upper == "\\", index + 3 < characters.count { upper = characters[index + 3]; skip = 4 }
                if character <= upper { ranges.append(character...upper) }
                index += skip
            } else {
                ranges.append(character...character)
                index += 1
            }
        }
        return nil
    }
    /// Dynamic programming from the end: `next[t]` says whether the tokens after the current one match `text[t...]`.
    /// Quadratic at worst, which for a path and a pattern a person typed is nothing.
    private static func match(_ tokens: [Token], _ text: [Character]) -> Bool {
        let count = text.count
        var next = [Bool](repeating: false, count: count + 1)
        next[count] = true
        for token in tokens.reversed() {
            var current = [Bool](repeating: false, count: count + 1)
            for t in stride(from: count, through: 0, by: -1) {
                switch token {
                case .literal(let c): current[t] = t < count && text[t] == c && next[t + 1]
                case .one: current[t] = t < count && text[t] != "/" && next[t + 1]
                case .set(let ranges, let negated):
                    current[t] = t < count && text[t] != "/" && ranges.contains { $0.contains(text[t]) } != negated && next[t + 1]
                case .star: current[t] = next[t] || (t < count && text[t] != "/" && current[t + 1])
                case .globstar: current[t] = next[t] || (t < count && current[t + 1])
                case .folders:
                    // Zero folders, or any stretch that ends right after a `/`.
                    current[t] = next[t] || (t < count && (t + 1...count).contains { text[$0 - 1] == "/" && next[$0] })
                }
            }
            next = current
        }
        return next[0]
    }
}

/// What a mirror or a two-way sync leaves alone. Stored per mirror; the built-in list below is on unless the mirror
/// turns it off, so every mirror starts with the same sensible defaults.
struct SyncExclusions: Codable, Equatable, Sendable {
    /// Use `SyncExclusions.defaults`.
    var useDefaults = true
    /// Names starting with a dot, at any depth. The Finder's hidden flag is ignored on purpose: the cloud side has no
    /// such flag, and both sides have to agree on what is excluded.
    var skipHidden = false
    /// Folders whose extension says they are a package (`packageExtensions`). Recognised by name on both sides for the
    /// same reason, instead of by what the apps installed on this Mac happen to register.
    var skipPackages = false
    /// The person's own patterns, one per entry. Blank entries and lines starting with `#` are ignored.
    var patterns: [String] = []
    /// Files outside these sizes, in bytes, are left alone. Folders are never filtered by size.
    var minSize: Int64?
    var maxSize: Int64?
    /// Files last modified longer ago than `maxAge` seconds, or more recently than `minAge`, are left alone: the
    /// first keeps a mirror to what is recent, the second skips what an app may still be writing.
    var maxAge: TimeInterval?
    var minAge: TimeInterval?

    /// System clutter and the lock and scratch files editors leave next to a document while it is open.
    static let defaults = [".DS_Store", "._*", ".Spotlight-V100", ".Trashes", ".fseventsd", "Icon\r", "~$*", "*.tmp", "*.swp",
                           ".~lock.*#", "Thumbs.db", "desktop.ini"]
    /// Always excluded, whatever the settings: the temporary files a two-way sync writes while it downloads.
    static let internalPatterns = [".icloudy-*"]
    /// Clutter that describes a folder and nothing else. A folder whose removal is carried to the other side takes
    /// these along instead of surviving only because of them.
    static let folderMetadata = [".DS_Store", "._*", "Icon\r", "Thumbs.db", "desktop.ini", ".icloudy-*"]
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "qlgenerator", "mdimporter", "saver", "prefpane", "xpc",
        "photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "theater", "logicx", "band", "pages", "numbers", "key", "rtfd", "xcodeproj", "xcworkspace",
        "playground", "xcarchive", "dsym", "sparsebundle", "pkg", "mpkg", "scptd", "workflow", "nib", "lpdf", "abbu",
    ]

    init(useDefaults: Bool = true, skipHidden: Bool = false, skipPackages: Bool = false, patterns: [String] = [],
         minSize: Int64? = nil, maxSize: Int64? = nil, maxAge: TimeInterval? = nil, minAge: TimeInterval? = nil) {
        self.useDefaults = useDefaults; self.skipHidden = skipHidden; self.skipPackages = skipPackages; self.patterns = patterns
        self.minSize = minSize; self.maxSize = maxSize; self.maxAge = maxAge; self.minAge = minAge
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        useDefaults = try values.decodeIfPresent(Bool.self, forKey: .useDefaults) ?? true
        skipHidden = try values.decodeIfPresent(Bool.self, forKey: .skipHidden) ?? false
        skipPackages = try values.decodeIfPresent(Bool.self, forKey: .skipPackages) ?? false
        patterns = try values.decodeIfPresent([String].self, forKey: .patterns) ?? []
        // Records written before the size and age filters existed filter nothing.
        minSize = try values.decodeIfPresent(Int64.self, forKey: .minSize)
        maxSize = try values.decodeIfPresent(Int64.self, forKey: .maxSize)
        maxAge = try values.decodeIfPresent(TimeInterval.self, forKey: .maxAge)
        minAge = try values.decodeIfPresent(TimeInterval.self, forKey: .minAge)
    }
    /// True when any size or age filter is set.
    var filtersFiles: Bool { minSize != nil || maxSize != nil || maxAge != nil || minAge != nil }
    /// The patterns that apply, in the order they are tried. The internal ones come first and cannot be negated.
    var activePatterns: [String] {
        let own = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Self.internalPatterns + (useDefaults ? Self.defaults : []) + own
    }
    func matcher(caseInsensitive: Bool) -> SyncExclusionMatcher {
        let rules = activePatterns.dropFirst(Self.internalPatterns.count).map { GlobPattern($0, caseInsensitive: caseInsensitive) }
        var matcher = SyncExclusionMatcher(patterns: Array(rules), skipHidden: skipHidden, skipPackages: skipPackages, caseInsensitive: caseInsensitive)
        matcher.sizes = (minSize, maxSize)
        matcher.ages = (maxAge, minAge)
        return matcher
    }
    /// Whether names on the volume holding `url` differ only by case. APFS and HFS+ are case-insensitive unless
    /// formatted otherwise; when the volume cannot be asked, that common case is assumed.
    nonisolated static func isCaseInsensitive(_ url: URL) -> Bool {
        guard let sensitive = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames else { return true }
        return !sensitive
    }
}

/// The compiled form of `SyncExclusions`, answering for paths relative to the mirror's root. Pure: it never touches
/// the disk, so the local and the remote tree are judged by exactly the same rules.
struct SyncExclusionMatcher: Sendable {
    /// The defaults and the person's rules, in order: the last one that matches an item decides.
    let patterns: [GlobPattern]
    let skipHidden: Bool
    let skipPackages: Bool
    let caseInsensitive: Bool
    /// `SyncExclusions.internalPatterns`: always excluded, whatever a negated rule says.
    private let internals: [GlobPattern]
    private let metadata: [GlobPattern]
    /// Smallest and largest file, in bytes, that is looked at.
    var sizes: (min: Int64?, max: Int64?) = (nil, nil)
    /// Oldest and newest a file may be, in seconds since it was last modified.
    var ages: (max: TimeInterval?, min: TimeInterval?) = (nil, nil)

    init(patterns: [GlobPattern], skipHidden: Bool, skipPackages: Bool, caseInsensitive: Bool,
         internalPatterns: [String] = SyncExclusions.internalPatterns) {
        self.patterns = patterns; self.skipHidden = skipHidden; self.skipPackages = skipPackages; self.caseInsensitive = caseInsensitive
        internals = internalPatterns.map { GlobPattern($0, caseInsensitive: caseInsensitive) }
        metadata = SyncExclusions.folderMetadata.map { GlobPattern($0, caseInsensitive: caseInsensitive) }
    }
    /// Excludes nothing; what the planners used before exclusions existed.
    static let none = SyncExclusionMatcher(patterns: [], skipHidden: false, skipPackages: false, caseInsensitive: false, internalPatterns: [])
    /// Whether any path rule is set at all, so the common case of none skips the walk up the path.
    private var excludesPaths: Bool { !patterns.isEmpty || !internals.isEmpty || skipHidden || skipPackages }

    /// True when a size or age filter is set.
    var filtersFiles: Bool { sizes.min != nil || sizes.max != nil || ages.max != nil || ages.min != nil }

    /// Whether a file is left out by its size or its age alone. What is not known never filters a file out: a listing
    /// without dates keeps every file rather than dropping all of them.
    func filtersOut(size: Int64?, modified: Date?, now: Date) -> Bool {
        if let size {
            if let min = sizes.min, size < min { return true }
            if let max = sizes.max, size > max { return true }
        }
        if let modified {
            let age = now.timeIntervalSince(modified)
            if let max = ages.max, age > max { return true }
            if let min = ages.min, age < min { return true }
        }
        return false
    }
    /// A file judged by its path and by its size and age.
    func excludesFile(_ path: String, size: Int64?, modified: Date?, now: Date) -> Bool {
        excludes(path, isFolder: false) || filtersOut(size: size, modified: modified, now: now)
    }

    /// True when `path` or any folder above it is excluded. Everything inside an excluded folder is excluded too, so,
    /// as in gitignore, a negated rule cannot bring back an item whose folder is excluded.
    func excludes(_ path: String, isFolder: Bool) -> Bool {
        guard excludesPaths else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var prefix = ""
        for (index, component) in components.enumerated() {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if excludesItself(prefix, name: component, isFolder: index < components.count - 1 || isFolder) { return true }
        }
        return false
    }
    /// The item alone, without looking at the folders above it. The switches for hidden items and packages count as
    /// rules that come before the patterns, so `!.config/` brings one hidden folder back.
    func excludesItself(_ path: String, name: Substring, isFolder: Bool) -> Bool {
        if internals.contains(where: { $0.matches(path, isFolder: isFolder) }) { return true }
        var excluded = false
        if skipHidden, name.hasPrefix(".") { excluded = true }
        if skipPackages, isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex,
           SyncExclusions.packageExtensions.contains(name[name.index(after: dot)...].lowercased()) { excluded = true }
        // The last rule that matches decides, so the search runs from the end and stops at the first hit.
        if let last = patterns.last(where: { $0.matches(path, isFolder: isFolder) }) { return !last.negated }
        return excluded
    }
    /// System clutter that only describes the folder holding it (see `SyncExclusions.folderMetadata`).
    func isFolderMetadata(_ path: String) -> Bool {
        metadata.contains { $0.matches(path, isFolder: false) }
    }
}
