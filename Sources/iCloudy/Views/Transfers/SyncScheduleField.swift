import SwiftUI

/// Picks a `SyncSchedule`: none, every so often, or daily at a time.
struct SyncScheduleField: View {
    let title: LocalizedStringKey
    @Binding var schedule: SyncSchedule?

    private enum Kind: Hashable { case none, every, daily }
    static let intervals: [TimeInterval] = [15 * 60, 30 * 60, 3600, 3 * 3600, 6 * 3600, 12 * 3600, 86_400]

    private var kind: Binding<Kind> {
        Binding(get: {
            switch schedule {
            case .none: return .none
            case .every: return .every
            case .daily: return .daily
            }
        }, set: { kind in
            switch kind {
            case .none: schedule = nil
            case .every: schedule = .every(3600)
            case .daily: schedule = .daily(3 * 60)
            }
        })
    }

    var body: some View {
        Picker(title, selection: kind) {
            Text("Nunca").tag(Kind.none)
            Text("Cada cierto tiempo").tag(Kind.every)
            Text("Cada día a una hora").tag(Kind.daily)
        }
        switch schedule {
        case .every(let interval):
            Picker("Intervalo", selection: Binding(get: { interval }, set: { schedule = .every($0) })) {
                ForEach(Self.intervals.contains(interval) ? Self.intervals : Self.intervals + [interval], id: \.self) { value in
                    Text(verbatim: SyncSchedule.every(value).title).tag(value)
                }
            }
        case .daily(let minute):
            DatePicker("Hora", selection: Binding(
                get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date() },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    schedule = .daily((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
                }), displayedComponents: .hourAndMinute)
        case .none:
            EmptyView()
        }
    }
}
