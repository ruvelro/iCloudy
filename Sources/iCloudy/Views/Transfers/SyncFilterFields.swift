import SwiftUI

/// The size and age filters of a mirror or a saved job. Each one is off until its box is ticked, and a value typed
/// with the box off is kept for when it is ticked again.
struct SyncFilterFields: View {
    @Binding var rules: SyncExclusions

    enum SizeUnit: Int64, CaseIterable, Identifiable {
        case kilobytes = 1000, megabytes = 1_000_000, gigabytes = 1_000_000_000
        var id: Int64 { rawValue }
        var title: String {
            switch self {
            case .kilobytes: return "KB"
            case .megabytes: return "MB"
            case .gigabytes: return "GB"
            }
        }
    }
    enum AgeUnit: Double, CaseIterable, Identifiable {
        case minutes = 60, hours = 3600, days = 86_400
        var id: Double { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .minutes: return "minutos"
            case .hours: return "horas"
            case .days: return "días"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            size("Solo archivos de al menos", value: $rules.minSize)
            size("Solo archivos de como mucho", value: $rules.maxSize)
            age("Solo los modificados en los últimos", value: $rules.maxAge, fallback: .days)
            age("Saltar los modificados hace menos de", value: $rules.minAge, fallback: .minutes)
            Text("Los filtros miran solo archivos, nunca carpetas. Lo que dejan fuera no se sube, no se baja y no se borra en ningún lado; un archivo que cumple en un lado y no en el otro se deja como está en los dos.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func size(_ title: LocalizedStringKey, value: Binding<Int64?>) -> some View {
        let unit = Self.unit(for: value.wrappedValue)
        return HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? SizeUnit.megabytes.rawValue : nil }))
            Spacer()
            TextField("Tamaño", value: Binding(get: { Int((value.wrappedValue ?? 0) / unit.rawValue) },
                                               set: { value.wrappedValue = Int64(max($0, 0)) * unit.rawValue }), format: .number)
                .frame(width: 70).multilineTextAlignment(.trailing).labelsHidden().disabled(value.wrappedValue == nil)
            Picker("Unidad", selection: Binding(get: { unit }, set: { new in
                value.wrappedValue = value.wrappedValue.map { $0 / unit.rawValue * new.rawValue }
            })) {
                ForEach(SizeUnit.allCases) { Text(verbatim: $0.title).tag($0) }
            }.labelsHidden().frame(width: 70).disabled(value.wrappedValue == nil)
        }
    }

    private func age(_ title: LocalizedStringKey, value: Binding<TimeInterval?>, fallback: AgeUnit) -> some View {
        let unit = Self.unit(for: value.wrappedValue, fallback: fallback)
        return HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? fallback.rawValue * (fallback == .days ? 30 : 5) : nil }))
            Spacer()
            TextField("Tiempo", value: Binding(get: { Int((value.wrappedValue ?? 0) / unit.rawValue) },
                                               set: { value.wrappedValue = Double(max($0, 0)) * unit.rawValue }), format: .number)
                .frame(width: 70).multilineTextAlignment(.trailing).labelsHidden().disabled(value.wrappedValue == nil)
            Picker("Unidad", selection: Binding(get: { unit }, set: { new in
                value.wrappedValue = value.wrappedValue.map { ($0 / unit.rawValue).rounded() * new.rawValue }
            })) {
                ForEach(AgeUnit.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 90).disabled(value.wrappedValue == nil)
        }
    }

    /// The largest unit the stored value is a whole number of, so 2 GB reads as 2 GB and not 2000 MB.
    static func unit(for bytes: Int64?) -> SizeUnit {
        guard let bytes, bytes > 0 else { return .megabytes }
        return SizeUnit.allCases.reversed().first { bytes % $0.rawValue == 0 } ?? .kilobytes
    }
    static func unit(for seconds: TimeInterval?, fallback: AgeUnit) -> AgeUnit {
        guard let seconds, seconds > 0 else { return fallback }
        return AgeUnit.allCases.reversed().first { seconds.truncatingRemainder(dividingBy: $0.rawValue) == 0 } ?? .minutes
    }
}
