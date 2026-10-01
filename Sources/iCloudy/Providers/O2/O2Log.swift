import Foundation

/// A short, bounded record of what O2's server actually answers.
///
/// Three explanations for why its sessions die have now failed in a row, and guessing a fourth time without data
/// would be more of the same. O2 documents nothing, so the only way forward is to watch the traffic.
///
/// What is written is deliberately thin: which call was made, what the server answered, and whether the session
/// material changed. No cookie values, no keys, no file names, no addresses of anyone's files. It used to be a file of
/// its own; it is now O2's part of the general diagnostic log (`Diagnostics`), which bounds it, keeps it beside the
/// app's own data and exports it. Its lines are kept at the normal level, as they always were, and still pass through
/// the same redactor as everything else on the way in.
enum O2Log {
    /// Where earlier versions kept the record. Nothing writes there any more; it is only exported and deleted.
    static var legacyURL: URL { LocalStore.directory.appendingPathComponent("o2-diagnostico.txt") }

    static func record(_ line: String) {
        Diagnostics.record(DiagnosticRecord(.notice, stage: DiagnosticStage.o2, provider: Cloud.o2.rawValue, message: line))
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
