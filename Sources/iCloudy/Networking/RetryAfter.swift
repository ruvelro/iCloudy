import Foundation

/// The one reading of `Retry-After` the providers share. It used to be parsed in five places, each with
/// `Double(header)`, so the HTTP-date form RFC 9110 also allows was read as no header at all.
enum RetryAfter {
    /// Longest wait honoured before repeating a request in place. Box and Graph announce 60 to 120 seconds when they
    /// throttle; a 30-second cap meant asking again while still throttled and failing a second time.
    static let cap: Double = 120

    /// Seconds to wait from a `Retry-After` value: either delay-seconds or an HTTP-date. A date in the past means
    /// "now", which the callers turn into their one-second minimum.
    static func seconds(_ value: String?, now: Date = Date()) -> Double? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) { return seconds.isFinite && seconds >= 0 ? seconds : nil }
        guard let date = httpDate(text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
    static func seconds(_ response: URLResponse?, now: Date = Date()) -> Double? {
        seconds((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), now: now)
    }

    /// What to wait before the next attempt: what the server announced, or a doubling back-off, never under a second
    /// and never over `cap`.
    static func delay(announced: Double?, attempt: Int, cap: Double = cap) -> Double {
        min(max(1, announced ?? pow(2, Double(attempt))), cap)
    }

    /// IMF-fixdate first, then the two obsolete forms recipients must still accept (RFC 850 and asctime).
    static func httpDate(_ text: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            // A formatter per call: this runs only on refusals, and DateFormatter is not Sendable.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
