import SwiftUI

/// Presents the plan sheet for the window. It observes the coordinator alone, so counting thousands of files does not
/// re-render the explorer behind it.
struct TransferPlanHost: View {
    @ObservedObject var planner: TransferPlanCoordinator
    var body: some View {
        Color.clear
            .sheet(item: Binding(get: { planner.session?.shown == true ? planner.session : nil }, set: { _ in })) { _ in
                TransferPlanView(planner: planner)
            }
    }
}

/// "Antes de empezar": how much is about to move, where it needs room, what is already there and what will not
/// travel as it is. Nothing is queued until "Empezar".
struct TransferPlanView: View {
    @ObservedObject var planner: TransferPlanCoordinator
    @State private var dontAskAgain = false
    /// A plan of a whole drive can list thousands of conversions; the first ones say enough.
    private let visibleLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session = planner.session {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Antes de empezar").font(.title2)
                    Text(session.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let plan = session.plan { ready(plan) }
                else if let error = session.error { failed(error) }
                else { counting(session.progress) }
            }
        }.padding(22).frame(width: 600).interactiveDismissDisabled()
    }

    private func counting(_ progress: PlanProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Contando lo que hay que transferir…")
            }
            Text("\(progress.files) archivos y \(progress.folders) carpetas hasta ahora · \(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))")
                .monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { planner.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func failed(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("No se pudo preparar el plan", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(error).fixedSize(horizontal: false, vertical: true)
            Text("Puedes empezar igualmente: los conflictos se preguntarán al llegar a ellos, pero el informe solo listará lo que se alcance a transferir.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancelar") { planner.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Empezar sin plan") { planner.startWithoutPlan() }
            }
        }
    }

    private func ready(_ plan: TransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Contenido").foregroundStyle(.secondary)
                    Text("\(plan.files) archivos en \(plan.folders) carpetas")
                }
                GridRow {
                    Text("Tamaño").foregroundStyle(.secondary)
                    Text(plan.unknownSizes > 0
                         ? L("\(Self.bytes(plan.bytes)), más \(plan.unknownSizes) documentos de tamaño desconocido")
                         : Self.bytes(plan.bytes))
                }
                if plan.kind == .transfer {
                    GridRow {
                        Text("Espacio temporal").foregroundStyle(.secondary)
                        Text("\(Self.bytes(plan.largestFile)): cada archivo se descarga a este Mac y se borra en cuanto se sube, de uno en uno")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if plan.kind == .download {
                    GridRow {
                        Text("Espacio necesario").foregroundStyle(.secondary)
                        Text("\(Self.bytes(plan.bytes)) en este Mac")
                    }
                }
                if plan.kind != .upload {
                    GridRow {
                        Text("Libre en el Mac").foregroundStyle(.secondary)
                        space(plan.localFree, short: plan.localShort)
                    }
                }
                if plan.kind != .download {
                    GridRow {
                        Text("Libre en el destino").foregroundStyle(.secondary)
                        space(plan.destinationFree, short: plan.destinationShort)
                    }
                }
            }
            if plan.localShort || plan.destinationShort {
                Label(plan.localShort ? L("No hay espacio suficiente en este Mac.") : L("No hay espacio suficiente en el destino."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if !plan.conflicts.isEmpty || !plan.issues.isEmpty {
                List {
                    if !plan.conflicts.isEmpty {
                        Section {
                            ForEach(plan.conflicts.prefix(visibleLimit), id: \.self) { path in
                                Label(path, systemImage: "doc.on.doc").lineLimit(1).truncationMode(.middle)
                            }
                            if plan.conflicts.count > visibleLimit { Text("Y \(plan.conflicts.count - visibleLimit) más").foregroundStyle(.secondary) }
                        } header: {
                            Text("Ya existen en el destino (\(plan.conflicts.count)): se preguntará qué hacer con cada uno")
                        }
                    }
                    if !plan.issues.isEmpty {
                        Section {
                            ForEach(plan.issues.prefix(visibleLimit)) { issue in
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: issue.blocking ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                                        .foregroundStyle(issue.blocking ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(issue.path).lineLimit(1).truncationMode(.middle)
                                        Text(issue.explanation).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if plan.issues.count > visibleLimit { Text("Y \(plan.issues.count - visibleLimit) más").foregroundStyle(.secondary) }
                        } header: {
                            Text(plan.blockingIssues > 0
                                 ? L("No se pueden transferir o se convertirán (\(plan.issues.count)); \(plan.blockingIssues) harán fallar su transferencia")
                                 : L("Se convertirán o se dejarán fuera (\(plan.issues.count))"))
                        }
                    }
                }.frame(minHeight: 160, maxHeight: 260)
            }
            Toggle("No volver a mostrar el plan antes de transferir", isOn: $dontAskAgain)
            Text("Se muestra con más de \(TransferPlan.fileThreshold) archivos o \(Self.bytes(TransferPlan.byteThreshold)), o cuando falta espacio. Se vuelve a activar en Ajustes › Transferencias.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancelar") { planner.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Empezar") { planner.confirm(dontAskAgain: dontAskAgain) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func space(_ free: Int64?, short: Bool) -> some View {
        if let free { Text(Self.bytes(free)).foregroundStyle(short ? .red : .primary) }
        else { Text("Desconocido").foregroundStyle(.secondary) }
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
