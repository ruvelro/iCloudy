import XCTest
@testable import iCloudy

/// The glob matcher decides what a mirror never touches, so every corner of its syntax is pinned down here.
final class SyncExclusionsTests: XCTestCase {
    private func glob(_ pattern: String, _ path: String, folder: Bool = false, insensitive: Bool = false) -> Bool {
        GlobPattern(pattern, caseInsensitive: insensitive).matches(path, isFolder: folder)
    }

    func testStarAndQuestionMarkStayInsideOneComponent() {
        XCTAssertTrue(glob("*.tmp", "a.tmp"))
        XCTAssertTrue(glob("*.tmp", ".tmp"), "An empty run is still a run")
        XCTAssertTrue(glob("*.tmp", ".oculto.tmp"), "As in gitignore, a leading dot is matched")
        XCTAssertFalse(glob("*.tmp", "a.tmpx"))
        XCTAssertTrue(glob("?.txt", "a.txt"))
        XCTAssertFalse(glob("?.txt", "ab.txt"))
        XCTAssertFalse(glob("?.txt", ".txt"), "? needs exactly one character")
        XCTAssertFalse(glob("a/*", "a/b/c"), "* does not cross folders")
        XCTAssertTrue(glob("a/*", "a/b"))
        XCTAssertFalse(glob("a?b", "a/b"), "? never matches a slash")
        XCTAssertTrue(glob("*", "cualquier cosa"))
        XCTAssertTrue(glob("a*b*c", "aXXbYYc"))
        XCTAssertFalse(glob("a*b*c", "aXXbYY"))
        XCTAssertTrue(glob("a**b", "aXb"), "Glued to other characters, ** is an ordinary *")
        XCTAssertFalse(glob("a**b", "x/aX/Yb"))
    }

    func testDoubleStarCrossesFolders() {
        XCTAssertTrue(glob("**/build", "build"), "**/ may stand for no folder at all")
        XCTAssertTrue(glob("**/build", "a/b/build"))
        XCTAssertFalse(glob("**/build", "a/rebuild"), "**/ starts at a component boundary")
        XCTAssertTrue(glob("docs/**", "docs/a"))
        XCTAssertTrue(glob("docs/**", "docs/a/b/c.txt"))
        XCTAssertFalse(glob("docs/**", "docs"), "docs/** is what is inside, not the folder itself")
        XCTAssertTrue(glob("a/**/b", "a/b"))
        XCTAssertTrue(glob("a/**/b", "a/x/y/b"))
        XCTAssertFalse(glob("a/**/b", "a/x/yb"))
        XCTAssertTrue(glob("**", "a/b/c"))
        XCTAssertTrue(glob("**/*.log", "x/y/z.log"))
    }

    func testCharacterClasses() {
        XCTAssertTrue(glob("[abc].txt", "b.txt"))
        XCTAssertFalse(glob("[abc].txt", "d.txt"))
        XCTAssertTrue(glob("file[0-9].txt", "file7.txt"))
        XCTAssertFalse(glob("file[0-9].txt", "fileX.txt"))
        XCTAssertTrue(glob("[!0-9]*", "a1"))
        XCTAssertFalse(glob("[!0-9]*", "1a"))
        XCTAssertTrue(glob("[^0-9]*", "a1"), "^ negates like !")
        XCTAssertTrue(glob("[]x].txt", "].txt"), "A ] right after [ is a member")
        XCTAssertTrue(glob("[a-]", "-"), "A - before ] is a member")
        XCTAssertTrue(glob("[", "["), "An unclosed [ is a literal")
        XCTAssertTrue(glob("a[", "a["))
        XCTAssertFalse(glob("a[/]b", "a/b"), "A class never matches a slash")
        XCTAssertTrue(glob("[ñ]", "ñ"))
    }

    func testEscapesMakeSpecialCharactersLiteral() {
        XCTAssertTrue(glob("\\*.txt", "*.txt"))
        XCTAssertFalse(glob("\\*.txt", "a.txt"))
        XCTAssertTrue(glob("\\?", "?"))
        XCTAssertTrue(glob("\\[a]", "[a]"))
        XCTAssertTrue(glob("fin\\", "fin\\"), "A trailing backslash stands for itself")
    }

    func testAnchoredAgainstBasenamePatterns() {
        XCTAssertTrue(glob("node_modules", "a/b/node_modules"), "Without a slash the name is matched at any depth")
        XCTAssertTrue(glob("/node_modules", "node_modules"))
        XCTAssertFalse(glob("/node_modules", "a/node_modules"), "A leading slash anchors it to the root")
        XCTAssertTrue(glob("a/b.txt", "a/b.txt"))
        XCTAssertFalse(glob("a/b.txt", "x/a/b.txt"), "A slash inside also anchors it")
        XCTAssertTrue(glob("build/", "build", folder: true))
        XCTAssertFalse(glob("build/", "build", folder: false), "A trailing slash is for folders only")
        XCTAssertTrue(glob("build/", "x/build", folder: true), "…and does not anchor the pattern")
        XCTAssertFalse(GlobPattern("build/").anchored)
        XCTAssertTrue(GlobPattern("/build").anchored)
        XCTAssertTrue(glob("a\\/b", "a/b"), "An escaped slash is still a slash in the path")
    }

    func testCaseAndUnicodeNormalisation() {
        XCTAssertFalse(glob("*.JPG", "foto.jpg"))
        XCTAssertTrue(glob("*.JPG", "foto.jpg", insensitive: true))
        XCTAssertTrue(glob("[A-Z]*", "abc", insensitive: true))
        XCTAssertTrue(glob("Thumbs.db", "THUMBS.DB", insensitive: true))
        // The Finder hands names over decomposed; people type them composed.
        let decomposed = "cancio\u{0301}n.txt", composed = "canción.txt"
        XCTAssertTrue(glob(composed, decomposed))
        XCTAssertTrue(glob(decomposed, composed))
        XCTAssertTrue(glob("canci?n.txt", decomposed), "A decomposed letter is still one character")
    }

    func testTheDefaultsCatchTheUsualClutterAndNothingElse() {
        let matcher = SyncExclusions().matcher(caseInsensitive: true)
        for path in [".DS_Store", "a/.DS_Store", "._foto.jpg", ".Spotlight-V100", ".Trashes", ".fseventsd", "Icon\r", "~$informe.docx",
                     "x.tmp", ".nota.txt.swp", ".~lock.hoja.ods#", "Thumbs.db", "desktop.ini", "sub/.icloudy-1234"] {
            XCTAssertTrue(matcher.excludes(path, isFolder: false), path)
        }
        for path in ["informe.docx", "Icon", "Iconos/a.png", "nota.txt", "temp/a.txt", ".gitignore", "a/b/c.swift"] {
            XCTAssertFalse(matcher.excludes(path, isFolder: false), path)
        }
        XCTAssertTrue(matcher.excludes(".Trashes/501/x.txt", isFolder: false), "Everything inside an excluded folder is excluded")
        let without = SyncExclusions(useDefaults: false).matcher(caseInsensitive: true)
        XCTAssertFalse(without.excludes(".DS_Store", isFolder: false))
        XCTAssertTrue(without.excludes(".icloudy-abc", isFolder: false), "iCloudy's own temporaries are always out")
    }

    func testHiddenPackagesAndOwnPatterns() {
        var rules = SyncExclusions(useDefaults: false, skipHidden: true, skipPackages: true, patterns: ["# comentario", "", "  *.log  ", "/privado/", "**/cache/**"])
        var matcher = rules.matcher(caseInsensitive: false)
        XCTAssertTrue(matcher.excludes(".git", isFolder: true))
        XCTAssertTrue(matcher.excludes("a/.git/config", isFolder: false))
        XCTAssertTrue(matcher.excludes("Apps/Calculadora.app", isFolder: true))
        XCTAssertTrue(matcher.excludes("Apps/Calculadora.APP/Contents/Info.plist", isFolder: false))
        XCTAssertFalse(matcher.excludes("Calculadora.app", isFolder: false), "Only a folder can be a package")
        XCTAssertTrue(matcher.excludes("Fotos.photoslibrary", isFolder: true))
        XCTAssertTrue(matcher.excludes("x/y.log", isFolder: false))
        XCTAssertTrue(matcher.excludes("privado", isFolder: true))
        XCTAssertTrue(matcher.excludes("privado/a.txt", isFolder: false))
        XCTAssertFalse(matcher.excludes("otro/privado/a.txt", isFolder: false))
        XCTAssertTrue(matcher.excludes("a/cache/b/c", isFolder: false))
        XCTAssertFalse(matcher.excludes("comentario", isFolder: false), "# lines are comments")
        XCTAssertFalse(matcher.excludes("a/b.txt", isFolder: false))
        rules.skipHidden = false; rules.skipPackages = false
        matcher = rules.matcher(caseInsensitive: false)
        XCTAssertFalse(matcher.excludes(".git", isFolder: true))
        XCTAssertFalse(matcher.excludes("Calculadora.app", isFolder: true))
        XCTAssertFalse(SyncExclusionMatcher.none.excludes(".DS_Store", isFolder: false))
    }

    func testFolderMetadataIsTheDisposableSubset() {
        let matcher = SyncExclusions(patterns: ["*.secreto"]).matcher(caseInsensitive: true)
        XCTAssertTrue(matcher.isFolderMetadata("a/.DS_Store"))
        XCTAssertTrue(matcher.isFolderMetadata("a/Icon\r"))
        XCTAssertFalse(matcher.isFolderMetadata("a/clave.secreto"))
        XCTAssertFalse(matcher.isFolderMetadata("a/x.tmp"), "A scratch file may be somebody's work; it is not folder metadata")
    }

    func testRulesDecodeWithDefaultsAndRoundTrip() throws {
        let empty = try JSONDecoder().decode(SyncExclusions.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, SyncExclusions())
        let rules = SyncExclusions(useDefaults: false, skipHidden: true, skipPackages: true, patterns: ["*.bak"])
        XCTAssertEqual(try JSONDecoder().decode(SyncExclusions.self, from: JSONEncoder().encode(rules)), rules)
    }

    func testCaseSensitivityComesFromTheVolume() {
        // The temporary folder lives on the startup volume, which is case-insensitive unless formatted otherwise.
        let probe = FileManager.default.temporaryDirectory
        let sensitive = (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        XCTAssertEqual(SyncExclusions.isCaseInsensitive(probe), !sensitive)
    }
}
