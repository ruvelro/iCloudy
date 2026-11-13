import Foundation
import Combine

/// When a mirror or a saved job runs by itself: every so often, or once a day at a time of the Mac's clock. The
/// queue's own window, network and pause rules still apply on top: a run that falls due while the queue is held waits
/// for the hold to lift.
enum SyncSchedule: Codable, Equatable, Hashable, Sendable {
    /// Seconds between runs.
    case every(TimeInterval)
    /// Minutes after midnight.
    case daily(Int)

    /// When the next run is due, given the last one. Something never run is due now. A daily run missed while the
    /// Mac slept is due as soon as it wakes, once, not once per missed day.
    func nextRun(after last: Date?, now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .every(let interval):
            guard let last else { return now }
            return last.addingTimeInterval(max(interval, 60))
        case .daily(let minute):
            let parts = DateComponents(hour: (minute / 60) % 24, minute: minute % 60, second: 0)
            // The most recent moment the run was meant to happen, at or before now.
            let due = calendar.nextDate(after: now.addingTimeInterval(1), matching: parts, matchingPolicy: .nextTime, direction: .backward) ?? now
            if let last, last >= due {
                return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
            }
            return due
        }
    }

    var title: String {
        switch self {
        case .every(let interval):
            let minutes = Int(interval / 60)
            if minutes % 60 == 0 { return L("Cada \(minutes / 60) h") }
            return L("Cada \(minutes) min")
        case .daily(let minute): return L("Cada día a las \(TransferWindow.text(minute))")
        }
    }
}

extension FolderMirror {
    /// What a schedule counts from: the last run it started or the last sync, whichever is later.
    var scheduleBase: Date? {
        switch (lastScheduledRun, lastSync) {
        case (let a?, let b?): return max(a, b)
        case (let a, let b): return a ?? b
        }
    }
}

extension MirrorManager {
    /// Runs whatever is due now: scheduled syncs and verification passes. Called by the schedule's timer and when
    /// the queue's hold lifts; tests call it with the time they want.
    func tick(now: Date = Date()) {
        // Outside the window, offline or on a costly network nothing starts; the run stays due and goes when the
        // hold lifts, through the subscription below.
        if queue?.currentHold != nil { return }
        for mirror in mirrors where !mirror.paused {
            if let schedule = mirror.options.schedule, schedule.nextRun(after: mirror.scheduleBase, now: now) <= now {
                if let index = mirrors.firstIndex(where: { $0.id == mirror.id }) { mirrors[index].lastScheduledRun = now; persist(mirror.id) }
                scheduleSync(mirror.id, immediate: true)
            }
            if let every = mirror.options.verifyEvery, mirror.lastSync != nil, !verifying.contains(mirror.id),
               (mirror.lastVerified ?? .distantPast).addingTimeInterval(every) <= now {
                verifying.insert(mirror.id)
                let id = mirror.id
                Task { [weak self] in
                    _ = try? await self?.verify(id, now: now)
                    self?.verifying.remove(id)
                }
            }
        }
    }

    /// The earliest moment anything scheduled falls due, for the timer.
    func nextScheduled(now: Date = Date()) -> Date? {
        var dates: [Date] = []
        for mirror in mirrors where !mirror.paused {
            if let schedule = mirror.options.schedule { dates.append(schedule.nextRun(after: mirror.scheduleBase, now: now)) }
            if let every = mirror.options.verifyEvery, mirror.lastSync != nil { dates.append((mirror.lastVerified ?? .distantPast).addingTimeInterval(every)) }
        }
        return dates.min()
    }

    /// Keeps a timer for the next scheduled moment, capped so a change of clock or time zone is noticed, and runs
    /// what is due when the queue's hold lifts.
    func startSchedules() {
        holdSubscription = queue?.stateChanges.sink { [weak self] _ in
            guard let self, self.queue?.currentHold == nil, let next = self.nextScheduled(), next <= Date() else { return }
            self.tick()
        }
        armSchedule()
    }
    func armSchedule() {
        scheduleTimer?.cancel()
        guard let next = nextScheduled() else { scheduleTimer = nil; return }
        let delay = min(max(1, next.timeIntervalSinceNow), 15 * 60)
        scheduleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.tick()
            self.armSchedule()
        }
    }
}
