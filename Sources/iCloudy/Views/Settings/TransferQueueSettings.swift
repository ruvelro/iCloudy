import SwiftUI

/// How the queue runs: how many jobs at once, how fast, and when. Sections of the Transfers tab of the settings.
struct TransferQueueSettings: View {
    let model: AppModel
    @AppStorage(Prefs.transferConcurrency) private var concurrency = 3
    @AppStorage(Prefs.transferPerAccount) private var perAccount = 2
    @AppStorage(Prefs.uploadLimitEnabled) private var uploadLimited = false
    @AppStorage(Prefs.uploadLimitValue) private var uploadValue = 1
    @AppStorage(Prefs.uploadLimitUnit) private var uploadUnit = BandwidthUnit.megabytes.rawValue
    @AppStorage(Prefs.downloadLimitEnabled) private var downloadLimited = false
    @AppStorage(Prefs.downloadLimitValue) private var downloadValue = 5
    @AppStorage(Prefs.downloadLimitUnit) private var downloadUnit = BandwidthUnit.megabytes.rawValue
    @AppStorage(Prefs.transferWindowEnabled) private var windowEnabled = false
    @AppStorage(Prefs.transferWindowStart) private var windowStart = 22 * 60
    @AppStorage(Prefs.transferWindowEnd) private var windowEnd = 7 * 60
    @AppStorage(Prefs.pauseOnCostlyNetwork) private var pauseOnCostly = false

    var body: some View {
        Group {
            Section("Simultáneas") {
                LabeledContent("Transferencias a la vez") {
                    Stepper(value: $concurrency, in: TransferPolicy.concurrencyRange) { Text(verbatim: "\(concurrency)").monospacedDigit() }
                }
                LabeledContent("Como mucho por cuenta") {
                    Stepper(value: $perAccount, in: TransferPolicy.perAccountRange) { Text(verbatim: "\(perAccount)").monospacedDigit() }
                }
                Text("FTP, SFTP, Mega y O2 Cloud hacen una cada vez por cuenta, digas lo que digas aquí: su sesión no admite dos operaciones a la vez. Una copia entre nubes cuenta para las dos cuentas.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Velocidad") {
                limit("Limitar la subida", enabled: $uploadLimited, value: $uploadValue, unit: $uploadUnit)
                limit("Limitar la descarga", enabled: $downloadLimited, value: $downloadValue, unit: $downloadUnit)
                Text("Es un límite para toda la cola, repartido a partes iguales entre lo que esté en marcha. No frena la vista previa ni la copia entre volúmenes montados. El mínimo es de 32 KB/s.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Cuándo") {
                Toggle("Transferir solo en un horario", isOn: $windowEnabled)
                if windowEnabled {
                    HStack {
                        DatePicker("Desde", selection: time($windowStart), displayedComponents: .hourAndMinute)
                        DatePicker("hasta", selection: time($windowEnd), displayedComponents: .hourAndMinute)
                    }
                }
                Toggle("Pausar en redes de datos móviles o con «Modo de datos reducidos»", isOn: $pauseOnCostly)
                Text("Fuera del horario, o en una red así, lo que esté en marcha se pausa con el motivo a la vista y se reanuda solo cuando se pueda. Si el final es anterior al inicio, el horario cruza la medianoche.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        // Each control writes its own default; the queue rereads them all whenever the result changes.
        .onChange(of: TransferPolicy.stored()) { model.applyTransferPolicy() }
    }

    private func limit(_ title: LocalizedStringKey, enabled: Binding<Bool>, value: Binding<Int>, unit: Binding<String>) -> some View {
        HStack {
            Toggle(title, isOn: enabled)
            Spacer()
            TextField("Velocidad", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, 1), 100_000) }), format: .number)
                .frame(width: 70).multilineTextAlignment(.trailing).labelsHidden()
                .disabled(!enabled.wrappedValue)
            Picker("Unidad", selection: unit) {
                ForEach(BandwidthUnit.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
            }.labelsHidden().frame(width: 80).disabled(!enabled.wrappedValue)
        }
    }
    /// The pickers edit a time of day; the setting keeps minutes after midnight, which is what the window compares.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                })
    }
}
