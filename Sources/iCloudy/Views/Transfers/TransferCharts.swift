import SwiftUI
import Charts

/// The queue's combined speed over the last two minutes, under the panel's tabs while something moves.
struct SpeedChart: View {
    let speed: SpeedHistory

    var body: some View {
        Chart(speed.samples) { sample in
            AreaMark(x: .value("Hora", sample.date), y: .value("Velocidad", sample.bytesPerSecond))
                .foregroundStyle(Color.accentColor.opacity(0.25))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Hora", sample.date), y: .value("Velocidad", sample.bytesPerSecond))
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel { if let bytes = value.as(Double.self) { Text(verbatim: Self.rate(bytes)) } }
            }
        }
        .frame(height: 54)
        .accessibilityLabel("Velocidad de las transferencias en los últimos dos minutos")
        .accessibilityValue(Text(verbatim: Self.rate(speed.samples.last?.bytesPerSecond ?? 0)))
    }
    static func rate(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "/s" }
}

/// Bytes moved per day, from the history.
struct DailyBytesChart: View {
    let days: [TransferHistory.Day]
    var height: CGFloat = 70

    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Día", day.day, unit: .day), y: .value("Bytes", day.bytes))
                .foregroundStyle(Color.accentColor.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, days.count / 4))) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel { if let bytes = value.as(Int64.self) { Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) } }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Datos transferidos por día")
    }
}
