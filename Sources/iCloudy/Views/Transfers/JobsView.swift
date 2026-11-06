import SwiftUI
import AppKit

/// The saved jobs: run one again, see how its last run went and its report, edit or delete it.
struct JobsView: View {
    let model: AppModel
    @Bindable var store: JobStore
    @State private var editing: SavedJob?
    @State private var creating = false
    @State private var pairing = false
    @State private var deleting: SavedJob?
    @State private var reporting: [Transfer]?
    @State private var failure: String?

    init(model: AppModel) {
        self.model = model
        store = model.jobs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trabajos guardados").font(.title2)
                Spacer()
                Button { pairing = true } label: { Label("Sincronizar dos nubes…", systemImage: "cloud") }
                    .help("Mantener iguales dos carpetas de nubes, en los dos sentidos (experimental)")
                    .disabled(model.accounts.isEmpty)
                Button { creating = true } label: { Label("Nuevo trabajo…", systemImage: "plus") }
            }
            Text("Una transferencia con nombre que se vuelve a lanzar cuando quieras, a una hora o desde Atajos. Cada pasada va a la cola como cualquier otra, con su informe y su entrada en el historial.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(store.jobs) { job in row(job) }
                .overlay {
                    if store.jobs.isEmpty {
                        Text("No hay trabajos guardados. Crea uno con «Nuevo trabajo…».").foregroundStyle(.secondary)
                    }
                }
            if let message = failure ?? store.persistenceError {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 400)
        .sheet(isPresented: $creating) { JobEditor(model: model, job: nil) }
        .sheet(isPresented: $pairing) { CloudPairEditor(model: model) }
        .sheet(item: $editing) { job in JobEditor(model: model, job: job) }
        .sheet(isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } })) {
            if let reporting { TransferReportView(model: model, queue: model.queue, batchID: reporting[0].batchID) }
        }
        .confirmationDialog("¿Borrar «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Borrar el trabajo", role: .destructive) { if let deleting { store.remove(deleting.id) }; deleting = nil }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: { Text("Solo se borra el trabajo guardado; lo que ya copió se queda donde está.") }
    }

    private func row(_ job: SavedJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.running ? "arrow.triangle.2.circlepath" : "tray.and.arrow.up").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).fontWeight(.medium)
                Text(verbatim: job.sources.map(\.title).joined(separator: ", ") + " → " + job.destination.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                Text(verbatim: summary(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Ejecutar") { run(job, allowingMassDeletion: false) }.disabled(job.running)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Ejecutar") { run(job, allowingMassDeletion: false) }.disabled(job.running)
            if job.options.deleteExtraneous {
                Button("Ejecutar aplicando los borrados") { run(job, allowingMassDeletion: true) }.disabled(job.running)
                    .help("Solo hace falta cuando una pasada se detuvo por borrar la mayor parte del destino")
            }
            let last = model.lastRun(of: job)
            Button("Ver informe de la última pasada") { reporting = last }.disabled(last.isEmpty)
            Divider()
            Button("Editar…") { editing = job }
            Button("Borrar…", role: .destructive) { deleting = job }
        }
    }

    private func summary(_ job: SavedJob) -> String {
        var parts: [String] = []
        if let last = job.lastRun { parts.append(L("Última: \(last.formatted(date: .abbreviated, time: .shortened))")) }
        if let result = job.lastResult { parts.append(result) }
        if let schedule = job.options.schedule { parts.append(schedule.title) }
        return parts.isEmpty ? L("Sin ejecutar todavía") : parts.joined(separator: " · ")
    }
    private func run(_ job: SavedJob, allowingMassDeletion: Bool) {
        failure = nil
        Task {
            do { try await model.runJob(id: job.id, allowingMassDeletion: allowingMassDeletion) }
            catch { failure = error.localizedDescription }
        }
    }
}

/// Creates or edits a saved job.
struct JobEditor: View {
    let model: AppModel
    let original: SavedJob?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var sources: [JobEndpoint]
    @State private var destination: JobEndpoint?
    @State private var options: JobOptions
    @State private var patterns: String
    @State private var choosingSource = false
    @State private var choosingDestination = false
    @State private var error: String?

    init(model: AppModel, job: SavedJob?) {
        self.model = model
        original = job
        _name = State(initialValue: job?.name ?? "")
        _sources = State(initialValue: job?.sources ?? [])
        _destination = State(initialValue: job?.destination)
        _options = State(initialValue: job?.options ?? JobOptions())
        _patterns = State(initialValue: job?.options.exclusions.patterns.joined(separator: "\n") ?? "")
    }

    private var policy: Binding<ConflictPolicy> {
        Binding(get: { options.conflictPolicy ?? .ask }, set: { options.conflictPolicy = $0 == .ask ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(original == nil ? "Nuevo trabajo" : "Editar trabajo").font(.title3)
            Form {
                TextField("Nombre", text: $name)
                Section("Origen") {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        HStack {
                            Text(verbatim: source.title).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { sources.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                .accessibilityLabel("Quitar")
                        }
                    }
                    HStack {
                        Button("Añadir del Mac…") { Task { await addLocalSources() } }
                        Button("Añadir de una nube…") { choosingSource = true }
                    }
                }
                Section("Destino") {
                    Text(verbatim: destination?.title ?? L("Sin elegir")).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Una carpeta del Mac…") { Task { await chooseLocalDestination() } }
                        Button("Una carpeta de una nube…") { choosingDestination = true }
                    }
                }
                Section("Opciones") {
                    Picker("Si ya existe en el destino", selection: policy) {
                        ForEach(ConflictPolicy.allCases) { Text(verbatim: $0.jobTitle).tag($0) }
                    }
                    Toggle("No copiar lo que el destino ya tiene con la misma suma", isOn: $options.skipIdentical)
                    Toggle("Verificar lo copiado al terminar", isOn: $options.verifyAfter)
                    Toggle("Llevar también los borrados: lo que no esté en el origen va a la papelera del destino", isOn: $options.deleteExtraneous)
                    if options.deleteExtraneous {
                        Text("Solo dentro de las carpetas que copia el trabajo, y nunca lo que las exclusiones dejan fuera. Si fuera a borrar la mayor parte del destino, se detiene y pregunta.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    SyncScheduleField(title: "Ejecutar solo", schedule: $options.schedule)
                }
                Section("Exclusiones y filtros") {
                    Toggle("Excluir los archivos del sistema y de bloqueo habituales", isOn: $options.exclusions.useDefaults)
                    TextEditor(text: $patterns).font(.body.monospaced()).frame(minHeight: 60)
                    Text("Un patrón por línea, como en los reflejos; «!» vuelve a incluir.").font(.caption).foregroundStyle(.secondary)
                    SyncFilterFields(rules: $options.exclusions)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || sources.isEmpty || destination == nil)
            }
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .sheet(isPresented: $choosingSource) {
            RemoteItemChooser(model: model, title: "Elige qué copiar", allowsFiles: true) { sources.append($0) }
        }
        .sheet(isPresented: $choosingDestination) {
            RemoteItemChooser(model: model, title: "Elige la carpeta de destino") { destination = $0 }
        }
    }

    private func save() {
        guard let destination else { return }
        options.exclusions.patterns = patterns.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var job = original ?? SavedJob(name: name, sources: sources, destination: destination)
        job.name = name.trimmingCharacters(in: .whitespaces); job.sources = sources; job.destination = destination; job.options = options
        do {
            if original == nil { try model.jobs.add(job) } else { try model.jobs.update(job) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func addLocalSources() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = L("Añadir")
        guard await panel.begin() == .OK else { return }
        for url in panel.urls { sources.append(.local(url, bookmark: try? TransferQueue.bookmark(url))) }
    }
    private func chooseLocalDestination() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("Elegir")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        destination = .local(url, bookmark: try? TransferQueue.bookmark(url))
    }
}

extension ConflictPolicy {
    /// The name of each policy for a job, from its source to its destination.
    var jobTitle: String {
        switch self {
        case .keepBoth: return L("Conservar los dos, con otro nombre")
        case .newestWins: return L("Gana el más reciente")
        case .thisSideWins: return L("Sustituir lo del destino")
        case .otherSideWins: return L("Dejar lo del destino")
        case .ask: return L("Preguntar")
        }
    }
}
