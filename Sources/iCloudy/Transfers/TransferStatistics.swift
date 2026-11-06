import Foundation

/// The queue's combined speed over the last couple of minutes, one sample a second while anything runs, for the
/// chart in the transfer panel. Kept in memory only.
@MainActor
@Observable
final class SpeedHistory {
    struct Sample: Identifiable, Equatable {
        let date: Date
        let bytesPerSecond: Double
        var id: Date { date }
    }
    private(set) var samples: [Sample] = []
    /// Two minutes at one sample a second.
    static let limit = 120

    func record(_ bytesPerSecond: Double, at date: Date = Date()) {
        samples.append(Sample(date: date, bytesPerSecond: max(0, bytesPerSecond)))
        if samples.count > Self.limit { samples.removeFirst(samples.count - Self.limit) }
    }
    var peak: Double { samples.map(\.bytesPerSecond).max() ?? 0 }
    func clear() { samples = [] }
}

extension TransferQueue {
    /// Samples the combined speed every `speedSampleInterval` while any job runs, ending with a zero so the chart
    /// comes back down when the queue stops.
    func startSampling() {
        guard samplingTask == nil else { return }
        let interval = speedSampleInterval
        samplingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.speed.record(TransferActivity(self.items).bytesPerSecond)
                if self.runningIDs.isEmpty { break }
                try? await Task.sleep(for: interval)
            }
            self?.samplingTask = nil
        }
    }
}

extension TransferHistory {
    struct Day: Identifiable, Equatable {
        let day: Date
        let bytes: Int64
        var id: Date { day }
    }
    /// Bytes moved per calendar day over the last `days`, oldest first, days without transfers at zero.
    func bytesPerDay(days: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        Self.bytesPerDay(entries, days: days, now: now, calendar: calendar)
    }
    nonisolated static func bytesPerDay(_ entries: [HistoryEntry], days: Int, now: Date, calendar: Calendar) -> [Day] {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<max(1, days)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var totals: [Date: Int64] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.finishedAt)
            guard let first = starts.first, day >= first else { continue }
            totals[day, default: 0] += entry.bytes
        }
        return starts.map { Day(day: $0, bytes: totals[$0] ?? 0) }
    }
}
