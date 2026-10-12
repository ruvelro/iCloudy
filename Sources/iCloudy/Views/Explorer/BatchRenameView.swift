import SwiftUI

/// The sheet for renaming a selection: a rule, and every name as it will end up before anything is sent.
struct BatchRenameView: View {
    @Bindable var model: AppModel
    let request: BatchRenameRequest
    @Environment(\.dismiss) private var dismiss
    @State private var rule = BatchRename()
    @State private var working = false

    private var names: [String] { rule.names(for: request.files) }
    /// Checked against the batch alone; the folder is listed again when the rename is confirmed.
    private var problem: String? { BatchRename.problem(files: request.files, names: names, siblings: [], cloud: request.account.cloud) }
    private var changes: Int { zip(request.files, names).filter { $0.name != $1 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Renombrar \(request.files.count) elementos").font(.title2)
            Picker("Cómo", selection: $rule.mode) {
                ForEach(BatchRename.Mode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch rule.mode {
                case .replace:
                    TextField("Buscar", text: $rule.find)
                    TextField("Reemplazar por", text: $rule.replacement)
                    Toggle("Sin distinguir mayúsculas", isOn: $rule.ignoresCase)
                case .add:
                    TextField("Texto", text: $rule.text)
                    Picker("Dónde", selection: $rule.position) {
                        ForEach(BatchRename.Position.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.radioGroup)
                case .format:
                    TextField("Nombre", text: $rule.base)
                    Stepper(value: $rule.start, in: 0...99_999) { Text("Empezar en \(rule.start)") }
                }
            }.textFieldStyle(.roundedBorder)
            Text("La extensión de cada archivo se conserva.").font(.caption).foregroundStyle(.secondary)
            List(Array(zip(request.files, names).enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.0.name).lineLimit(1).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    Text(pair.1).lineLimit(1).fontWeight(pair.0.name == pair.1 ? .regular : .medium)
                }
            }.frame(height: 190)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(changes == 0 ? L("Sin cambios") : L("Renombrar \(changes)")) {
                    working = true
                    Task {
                        let done = await model.commitBatchRename(request, rule: rule)
                        working = false
                        if done { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || changes == 0 || problem != nil)
            }
        }.padding(24).frame(width: 470)
    }
}
