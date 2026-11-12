import SwiftUI
import AppKit

/// A scheduled copy being set up, or one whose settings are being changed.
struct BackupDraft: Identifiable {
    let id = UUID()
    /// The plan being edited; nil for a new one.
    var editing: UUID?
    var sourceAccountID: String
    var sourceFolderID: String
    var sourceName: String
    var target: FolderLocation?
    var schedule = BackupSchedule()
    var keepsVersions = true
    var removesDeleted = false
    var retentionDays = 30
    var keepsForever = false
}

/// Where the copy goes, how often, and what happens to what it replaces.
struct BackupPlanSheet: View {
    @Bindable var model: AppModel
    @State var draft: BackupDraft
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: draft.schedule.minutes / 60, minute: draft.schedule.minutes % 60, second: 0, of: Date()) ?? Date() },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    draft.schedule.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                })
    }
    private var targetAccount: Account? { model.accounts.first { $0.id == draft.target?.accountID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.editing == nil ? "Copiar periódicamente a otra nube" : "Ajustes de la copia").font(.title2)
            Text("La carpeta se copia entera la primera vez. Después solo viaja lo nuevo y lo que haya cambiado, de nube a nube y sin dejar nada en el Mac. iCloudy tiene que estar abierto para que una copia programada se ejecute.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("Origen") { Text(draft.sourceName).lineLimit(1).truncationMode(.middle) }
                LabeledContent("Destino") {
                    HStack {
                        Text(draft.target.map { CompareCenter.shared.title(of: $0) } ?? L("Sin elegir")).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(draft.target == nil ? .secondary : .primary)
                        if draft.editing == nil {
                            FolderLocationMenu(model: model, title: "Elegir…") { location in
                                if location.accountID == nil { problem = L("El destino tiene que ser una carpeta de una cuenta conectada. Para copiar al Mac usa «Disponible sin conexión» o un reflejo.") }
                                else { draft.target = location; problem = nil }
                            }
                        }
                    }
                }
                Picker("Cuándo", selection: $draft.schedule.kind) {
                    Text("Solo a mano").tag(BackupSchedule.Kind.manual)
                    Text("Cada varias horas").tag(BackupSchedule.Kind.hourly)
                    Text("Cada día").tag(BackupSchedule.Kind.daily)
                    Text("Cada semana").tag(BackupSchedule.Kind.weekly)
                }
                switch draft.schedule.kind {
                case .manual: EmptyView()
                case .hourly:
                    Stepper(value: $draft.schedule.every, in: 1...24) { Text("Cada \(draft.schedule.every) horas") }
                case .daily:
                    DatePicker("A las", selection: time, displayedComponents: .hourAndMinute)
                case .weekly:
                    Picker("Día", selection: $draft.schedule.weekday) {
                        ForEach(1...7, id: \.self) { day in Text(verbatim: Calendar.current.weekdaySymbols[day - 1].capitalized).tag(day) }
                    }
                    DatePicker("A las", selection: time, displayedComponents: .hourAndMinute)
                }
                Toggle("Guardar las versiones anteriores", isOn: $draft.keepsVersions)
                if draft.keepsVersions {
                    Toggle("Conservarlas para siempre", isOn: $draft.keepsForever)
                    if !draft.keepsForever {
                        Stepper(value: $draft.retentionDays, in: 1...3650) { Text("Durante \(draft.retentionDays) días") }
                    }
                }
                Toggle("Quitar del destino lo que se borre en el origen", isOn: $draft.removesDeleted)
            }
            Text(draft.keepsVersions
                 ? "Lo que una copia sustituya o retire se mueve antes a «\(BackupPlan.versionsFolder)», en una carpeta con la fecha, dentro del destino. Así la copia guarda también cómo estaba cada archivo."
                 : "Sin versiones, un archivo que cambie sustituye a su copia, y lo que se retire va a la papelera del destino si la tiene.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let targetAccount, draft.keepsVersions, !targetAccount.capabilities.move {
                Text("\(targetAccount.cloud.title) no sabe mover archivos, así que ahí no se pueden guardar versiones: cada cambio sustituirá a su copia.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.editing == nil ? "Crear y copiar ahora" : "Guardar") { save() }
                    .keyboardShortcut(.defaultAction).disabled(draft.target == nil)
            }
        }
        .padding(24).frame(width: 540)
        // The titles of the places come from the tools window's own helper, which needs to know the accounts.
        .onAppear { CompareCenter.shared.model = model }
    }

    private func save() {
        let retention = draft.keepsForever ? nil : draft.retentionDays
        if let editing = draft.editing {
            model.backups.setSchedule(draft.schedule, for: editing)
            model.backups.setOptions(keepsVersions: draft.keepsVersions, removesDeleted: draft.removesDeleted, retentionDays: retention, for: editing)
            dismiss(); return
        }
        guard let target = draft.target, case .cloud(let accountID, let folder) = target.place else { return }
        var plan = BackupPlan(sourceAccountID: draft.sourceAccountID, sourceFolderID: draft.sourceFolderID, sourceName: draft.sourceName,
                              targetAccountID: accountID, targetFolderID: folder?.id ?? Collection.files.rootID, targetName: CompareCenter.shared.title(of: target))
        plan.schedule = draft.schedule; plan.keepsVersions = draft.keepsVersions; plan.removesDeleted = draft.removesDeleted; plan.retentionDays = retention
        do {
            try model.backups.add(plan)
            model.backups.runNow(plan.id)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// Sidebar section with every scheduled copy and its state.
struct BackupList: View {
    let model: AppModel
    @ObservedObject var backups: BackupManager
    @State private var removing: BackupPlan?
    @State private var editing: BackupDraft?
    var body: some View {
        if !backups.plans.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Divider().padding(.vertical, 8)
                Text("COPIAS PROGRAMADAS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(backups.plans) { (plan: BackupPlan) in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(plan.title, systemImage: plan.paused ? "pause.circle" : "clock.arrow.2.circlepath").lineLimit(1)
                        Text("→ " + plan.targetName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(backups.status(of: plan)).font(.caption2).foregroundStyle(plan.lastError == nil || plan.paused ? Color.secondary : Color.red).lineLimit(3)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .help(plan.sourceName + " → " + plan.targetName + "\n" + plan.schedule.summary)
                    .contextMenu {
                        Button("Copiar ahora") { backups.runNow(plan.id) }.disabled(plan.paused)
                        if plan.removesDeleted {
                            Button("Ejecutar aplicando los borrados") { backups.runNow(plan.id, applyingRemovals: true) }
                                .help("Solo hace falta cuando la copia se detuvo por retirar la mayor parte del destino").disabled(plan.paused)
                        }
                        Button(plan.paused ? "Reanudar" : "Pausar") { backups.setPaused(!plan.paused, for: plan.id) }
                        Button("Ajustes de la copia…") {
                            var draft = BackupDraft(editing: plan.id, sourceAccountID: plan.sourceAccountID, sourceFolderID: plan.sourceFolderID, sourceName: plan.sourceName)
                            draft.target = FolderLocation(place: .cloud(accountID: plan.targetAccountID, folder: nil), trail: [plan.targetName])
                            draft.schedule = plan.schedule; draft.keepsVersions = plan.keepsVersions; draft.removesDeleted = plan.removesDeleted
                            draft.retentionDays = plan.retentionDays ?? 30; draft.keepsForever = plan.retentionDays == nil
                            editing = draft
                        }
                        Divider()
                        Button("Abrir el origen") { model.openFolder(accountID: plan.sourceAccountID, folderID: plan.sourceFolderID) }
                        Button("Abrir el destino") { model.openFolder(accountID: plan.targetAccountID, folderID: plan.targetFolderID) }
                        Divider()
                        Button("Eliminar la copia programada…", role: .destructive) { removing = plan }
                    }
                }
            }
            .confirmationDialog("¿Eliminar la copia programada de «\(removing?.title ?? "")»?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Eliminar la copia programada", role: .destructive) { if let removing { backups.remove(removing.id) }; removing = nil }
                Button("Cancelar", role: .cancel) { removing = nil }
            } message: {
                Text("Deja de copiarse. Lo que ya está en el destino, y sus versiones anteriores, se quedan donde están.")
            }
            .sheet(item: $editing) { draft in BackupPlanSheet(model: model, draft: draft) }
        }
    }
}
