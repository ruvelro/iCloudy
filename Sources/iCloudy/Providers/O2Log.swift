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
    private static let keep = 400

    static func record(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = (previous + entry).split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > keep { lines = Array(lines.suffix(keep)) }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A diagnostic that breaks the thing it is diagnosing would be worse than no diagnostic.
        }
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
