import XCTest
@testable import iCloudy

/// The English table is a file nobody compiles, so nothing used to complain when it drifted from the code. It had
/// six duplicated keys and eighty-odd that named strings which no longer existed, while a hundred and forty-three
/// real ones were missing and simply showed in Spanish.
final class LocalizationTests: XCTestCase {
    private func table() throws -> [String: String] {
        let url = URL(fileURLWithPath: "Resources/en.lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }
    private func sources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: "Sources/iCloudy")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" })
        return try files.map { (path: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testTheEnglishTableParsesAndNamesEachStringOnlyOnce() throws {
        let parsed = try table()
        XCTAssertGreaterThan(parsed.count, 600)

        // A duplicated key is not an error for the parser: the last one silently wins, and the earlier translation
        // is dead weight that reads as if it were in use.
        let raw = try String(contentsOf: URL(fileURLWithPath: "Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        var seen: Set<String> = [], duplicates: [String] = []
        for line in raw.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\""), let end = Self.closingQuote(of: text) else { continue }
            let key = String(text[text.index(after: text.startIndex)..<end])
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        XCTAssertEqual(seen.count, parsed.count, "Cada entrada del archivo es una clave del diccionario")
        XCTAssertTrue(duplicates.isEmpty, "Claves repetidas: \(duplicates)")
    }

    func testEveryMessageOfTheModelLayerHasAnEnglishTranslation() throws {
        // Only the ones without interpolation: for those the key is exactly the literal, so the check is mechanical
        // and has no guessing in it. The rest are covered by the table having been generated from the compiler's
        // own key list.
        let parsed = try table()
        var untranslated: [String] = []
        for file in try sources() {
            for match in Self.literals(in: file.text) where !match.contains("\\(") {
                let key = match.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                guard !key.trimmingCharacters(in: .whitespaces).isEmpty, parsed[key] == nil else { continue }
                untranslated.append("\(file.path): \(key)")
            }
        }
        XCTAssertTrue(untranslated.isEmpty, "Mensajes sin traducir:\n" + untranslated.joined(separator: "\n"))
    }

    func testNoViewShowsAStringTheTableCannotReach() throws {
        // `Text(someString)` takes the verbatim initialiser, not the localized one, so a message built in the model
        // and handed to a view that way is shown in Spanish however complete the table is. These are the spellings
        // that made that mistake before; the check keeps them from coming back.
        for file in try sources() {
            for forbidden in ["Text(L(", "Label(L(", "Button(L("] {
                XCTAssertFalse(file.text.contains(forbidden),
                               "\(file.path) pasa una cadena ya traducida a una vista, que la mostrará tal cual")
            }
        }
    }

    /// Index of the quote that closes a key at the start of a line, skipping escaped ones.
    private static func closingQuote(of line: String) -> String.Index? {
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            if line[index] == "\\" {
                index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if line[index] == "\"" { return index }
            index = line.index(after: index)
        }
        return nil
    }
    /// Every `L("…")` of a source file, with the escapes left as they are written.
    private static func literals(in text: String) -> [String] {
        var result: [String] = []
        var search = text.startIndex
        while let start = text.range(of: "L(\"", range: search..<text.endIndex) {
            // `googleURL("https://…")` ends in the same three characters. Only a real call to `L` counts, so what
            // comes before has to be something other than the tail of a longer name.
            let before = start.lowerBound > text.startIndex ? text[text.index(before: start.lowerBound)] : " "
            guard !before.isLetter, !before.isNumber, before != "_" else {
                search = start.upperBound
                continue
            }
            var index = start.upperBound
            var literal = ""
            while index < text.endIndex {
                if text[index] == "\\" {
                    let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                    literal += text[index..<next]
                    index = next
                    continue
                }
                if text[index] == "\"" { break }
                literal.append(text[index])
                index = text.index(after: index)
            }
            // Only a literal that closes with `")` is the whole argument; anything else is a fragment of an expression.
            if index < text.endIndex, text.index(after: index) < text.endIndex, text[text.index(after: index)] == ")" {
                result.append(literal)
            }
            search = index < text.endIndex ? text.index(after: index) : text.endIndex
        }
        return result
    }
}
