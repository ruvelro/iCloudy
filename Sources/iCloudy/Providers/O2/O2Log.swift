import Foundation

/// A short, bounded record of what O2's server actually answers.
///
/// Three explanations for why its sessions die have now failed in a row, and guessing a fourth time without data
/// would be more of the same. O2 documents nothing, so the only way forward is to watch the traffic.
///
/// What is written is deliberately thin: which call was made, what the server answered, and whether the session
/// material changed. No cookie values, no keys, no file names, no addresses of anyone's files. The file is capped so
/// it cannot grow without bound, and it lives beside the app's own data, never inside anyone's cloud.
enum O2Log {
    static var url: URL { LocalStore.directory.appendingPathComponent("o2-diagnostico.txt") }
    /// Roughly a session's worth of calls. Older lines are dropped, newest kept.
    static let keep = 400
    /// True while the test suite runs. The suite is not sandboxed, so without this the file would pile up in the
    /// real Application Support folder of whoever ran it. A diagnostic has no business leaving residue there.
    private static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    /// Whether there is anything to hand over, so the interface only offers it when it would do something.
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func record(_ line: String) {
        guard !underTest else { return }
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Trimming drops the final newline, so without this every line after the first is glued to the one
            // before it and the file becomes one enormous line. It was, until a real record showed it.
            if !previous.isEmpty, !previous.hasSuffix("\n") { previous += "\n" }
            try (capped(previous + entry) + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A diagnostic that breaks the thing it is diagnosing would be worse than no diagnostic.
        }
    }
    /// Keeps only the most recent lines, so the file cannot grow without bound.
    static func capped(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > keep { lines = Array(lines.suffix(keep)) }
        return lines.joined(separator: "\n")
    }
    /// Describes a response without repeating anything private.
    static func describe(path: String, action: String, status: Int, error: String?, keyChanged: Bool,
                         cookieNames: [String]) -> String {
        var parts = ["\(path) \(action)", "HTTP \(status)"]
        if let error { parts.append("error \(error)") }
        if keyChanged { parts.append("clave renovada") }
        parts.append("cookies: " + (cookieNames.isEmpty ? "ninguna" : cookieNames.joined(separator: ",")))
        return parts.joined(separator: " · ")
    }
}
