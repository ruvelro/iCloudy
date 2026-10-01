import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings → Diagnóstico: how much the log keeps, what it has kept lately, and a way to hand it over that shows what
/// will leave the Mac before it does.
struct DiagnosticsSettings: View {
    @ObservedObject var model: AppModel
    @State private var level = Diagnostics.shared.level
    @State private var events: [DiagnosticEvent] = []
    @State private var accountFilter = ""
    @State private var severityFilter = ""
    @State private var stageFilter = ""
    @State private var confirmingDetailed = false
    @State private var confirmingClear = false
    @State private var exporting: ExportItem?
    @State private var preparing = false
    @State private var message: String?

    /// The hashed identifier the log uses for each connected account, back to a name only this window shows.
    private var accountNames: [String: String] {
        let redactor = Diagnostics.shared.redactor
        return Dictionary(model.accounts.map { account in
            (redactor.account(account.id), account.cloud.title + " · " + (model.appearances[account.id]?.title(for: account) ?? account.name))
        }, uniquingKeysWith: { first, _ in first })
    }
    private var visible: [DiagnosticEvent] {
        events.reversed().filter { event in
            (accountFilter.isEmpty || event.account == accountFilter)
                && (severityFilter.isEmpty || event.severity.rawValue == severityFilter)
                && (stageFilter.isEmpty || event.stage == stageFilter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Nivel", selection: Binding(get: { level }, set: choose)) {
                    ForEach(DiagnosticsLevel.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer()
            }
            Text(levelDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Cuenta", selection: $accountFilter) {
                    Text("Todas").tag("")
                    ForEach(accountNames.sorted { $0.value < $1.value }, id: \.key) { Text($0.value).tag($0.key) }
                }
                Picker("Tipo", selection: $severityFilter) {
                    Text("Todos").tag("")
                    ForEach(DiagnosticSeverity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Etapa", selection: $stageFilter) {
                    Text("Todas").tag("")
                    ForEach(Array(Set(events.map(\.stage))).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }.controlSize(.small)
            List(visible) { event in EventRow(event: event, account: event.account.flatMap { accountNames[$0] }) }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .overlay { if visible.isEmpty { Text("No hay eventos que mostrar").foregroundStyle(.secondary) } }
            HStack {
                Text("\(visible.count) de \(events.count) eventos").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Borrar diagnóstico…") { confirmingClear = true }
                Button("Exportar diagnóstico…") { prepareExport() }.disabled(preparing)
            }
        }
        .padding(Layout.margin)
        .task {
            // The log may be busy writing; reading it here never waits on the main actor.
            while !Task.isCancelled {
                events = await Task.detached { Diagnostics.shared.events() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("¿Activar el nivel detallado?", isPresented: $confirmingDetailed) {
            Button("Activar nivel detallado") { apply(.detailed) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El nivel detallado anota también cada petición correcta, con los nombres y las rutas de tus archivos y los argumentos de las órdenes FTP y SFTP. Nunca contraseñas, tokens, cookies ni enlaces de subida. Úsalo solo mientras reproduces un problema y vuelve después al nivel normal.")
        }
        .confirmationDialog("¿Borrar el diagnóstico?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Borrar diagnóstico", role: .destructive) {
                Task.detached { DiagnosticsExport.clear() }
                events = []
                message = nil
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Se borran los eventos guardados en este Mac, también el registro anterior de O2. No afecta a tus cuentas ni a tus archivos.") }
        .sheet(item: $exporting) { item in
            ExportPreview(package: item.package, save: { save(item.package) }, cancel: { exporting = nil })
        }
    }

    private var levelDetail: LocalizedStringKey {
        switch level {
        case .off: return "No se anota nada. Si algo falla, no habrá con qué explicarlo."
        case .normal: return "Se anotan errores, reintentos, límites de peticiones y resúmenes de cada transferencia. Las rutas se reducen a su forma y no aparece ningún nombre de archivo."
        case .detailed: return "Se anota también cada petición correcta, con nombres y rutas de archivos. Ni contraseñas, ni tokens, ni cookies, ni enlaces de subida."
        }
    }

    private func choose(_ new: DiagnosticsLevel) {
        // Names of files are only written after the person has said yes to it, every time.
        if new == .detailed, level != .detailed { confirmingDetailed = true } else { apply(new) }
    }
    private func apply(_ new: DiagnosticsLevel) {
        level = new
        Diagnostics.setLevel(new)
    }

    private func prepareExport() {
        preparing = true
        message = nil
        let snapshot = DiagnosticsExport.snapshot(model: model)
        Task {
            exporting = ExportItem(package: await Task.detached { DiagnosticsExport.prepare(snapshot) }.value)
            preparing = false
        }
    }
    /// The log lives inside the app's container, where nothing else on the Mac may read it, not even the owner's own
    /// terminal. Only the app can hand it over, and a save panel is how a sandboxed app is allowed to do that.
    private func save(_ package: DiagnosticsExport.Package) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "iCloudy-diagnostico-\(stamp).zip"
        panel.allowedContentTypes = [.zip]
        panel.message = L("Se guarda un archivo .zip con events.jsonl y summary.txt. No contiene contraseñas, tokens ni cookies.")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = nil
        Task {
            do {
                try await Task.detached { try DiagnosticsExport.archive(package, to: destination) }.value
                message = L("Diagnóstico exportado.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let package: DiagnosticsExport.Package
}

private struct EventRow: View {
    let event: DiagnosticEvent
    let account: String?

    private var symbol: (String, Color) {
        switch event.severity {
        case .error: return ("xmark.octagon.fill", .red)
        case .retry: return ("arrow.clockwise.circle.fill", .orange)
        case .summary: return ("checkmark.circle.fill", .green)
        case .notice: return ("text.bubble.fill", .blue)
        case .trace: return ("circle.fill", .secondary)
        }
    }
    private var request: String {
        var parts: [String] = []
        if let method = event.method { parts.append(method) }
        if let host = event.host { parts.append(host + (event.path ?? "")) }
        if let status = event.status { parts.append("→ \(status)") }
        if let duration = event.durationMs { parts.append("\(duration) ms") }
        let bytes = (event.bytesSent ?? 0) + (event.bytesReceived ?? 0)
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if let attempt = event.attempt, attempt > 0 { parts.append("#\(attempt)") }
        if let code = event.errorCode { parts.append((event.errorDomain.map { $0 + " " } ?? "") + code) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol.0).foregroundStyle(symbol.1).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.time, format: .dateTime.hour().minute().second()).monospacedDigit()
                    Text(verbatim: event.stage).fontWeight(.medium)
                    if let provider = event.provider { Text(verbatim: Cloud(rawValue: provider)?.title ?? provider) }
                    if let transfer = event.transfer { Text(verbatim: "#" + transfer).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Text(verbatim: account ?? event.account ?? "").foregroundStyle(.secondary).lineLimit(1)
                }.font(.caption)
                if !request.isEmpty { Text(verbatim: request).font(.caption.monospaced()).lineLimit(2) }
                if let message = event.message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }.textSelection(.enabled)
    }
}

/// What the export will contain, shown before anything is saved.
private struct ExportPreview: View {
    let package: DiagnosticsExport.Package
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Esto es lo que se exportará").font(.headline)
            Text("Archivos: \(package.fileNames.joined(separator: ", ")) · \(package.eventCount) eventos")
                .font(.caption).foregroundStyle(.secondary)
            if package.includesNames {
                Label("El nivel detallado está activo: el paquete incluye nombres y rutas de archivos.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(verbatim: "summary.txt").font(.caption.weight(.semibold))
            ScrollView {
                Text(verbatim: package.summary).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: 150).padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("events.jsonl (últimos eventos)").font(.caption.weight(.semibold))
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: package.preview(lines: 30)).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: 150).padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button("Guardar…") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(Layout.margin).frame(width: 600)
    }
}
