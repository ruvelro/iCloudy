import SwiftUI
import AppKit

/// «Espacio»: what takes up room in a folder, largest first, one level at a time.
struct UsageView: View {
    @ObservedObject var center: CompareCenter
    @Bindable var model: AppModel
    @State private var showingFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let location = center.usageLocation {
                    FolderLocationIcon(model: model, location: location)
                    Text(center.title(of: location)).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Elige una carpeta para ver qué ocupa espacio en ella.").foregroundStyle(.secondary)
                }
                Spacer()
                FolderLocationMenu(model: model, title: "Elegir carpeta…") { center.usageLocation = $0 }.disabled(center.measuring)
                if center.measuring {
                    Button("Detener") { center.cancelUsage() }
                } else {
                    Button("Analizar") { center.startUsage() }.keyboardShortcut(.defaultAction).disabled(center.usageLocation == nil)
                }
            }
            if center.measuring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(center.usageProgress.folders) carpetas · \(center.usageProgress.files) archivos · \(ByteCountFormatter.string(fromByteCount: center.usageProgress.bytes, countStyle: .file))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let problem = center.usageProblem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            if let tree = center.usageTree, let node = tree.descendant(center.usagePath) {
                summary(tree)
                Picker("Vista", selection: $showingFiles) {
                    Text("Por carpetas").tag(false)
                    Text("Archivos más grandes").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                if showingFiles { largest(tree) } else { level(tree, node) }
            } else if !center.measuring {
                ContentUnavailableView("Sin analizar", systemImage: "chart.bar.doc.horizontal",
                                       description: Text("iCloudy recorre la carpeta y suma lo que ocupa cada cosa. Solo lee los listados: no descarga nada."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer() }
        }
        .padding(20)
    }

    @ViewBuilder private func summary(_ tree: UsageNode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(ByteCountFormatter.string(fromByteCount: tree.size, countStyle: .file)) en \(tree.files) archivos").font(.title3.weight(.semibold))
            if tree.unsized > 0 {
                Text("\(tree.unsized) elementos no tienen tamaño (documentos de Google, sobre todo) y no suman.").font(.caption).foregroundStyle(.secondary)
            }
            if center.usageTruncated {
                Text("El recorrido se detuvo en \(UsageScanner.itemLimit) elementos: lo que hay más allá no está contado.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func level(_ tree: UsageNode, _ node: UsageNode) -> some View {
        // The way back up, one box per folder, like the explorer's own breadcrumbs.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(tree.name) { center.usagePath = [] }.buttonStyle(.link)
                ForEach(Array(center.usagePath.enumerated()), id: \.offset) { index, _ in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(tree.descendant(Array(center.usagePath.prefix(index + 1)))?.name ?? "") {
                        center.usagePath = Array(center.usagePath.prefix(index + 1))
                    }.buttonStyle(.link)
                }
            }
        }
        if node.children.isEmpty {
            Text("Esta carpeta está vacía.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(node.children) { child in
                UsageRow(node: child, share: node.size > 0 ? Double(child.size) / Double(node.size) : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if child.isFolder { center.usagePath.append(child.id) } }
                    .contextMenu {
                        if child.isFolder { Button("Entrar") { center.usagePath.append(child.id) } }
                        Button("Mostrar en su sitio") { center.revealUsage(child, parent: node) }
                    }
            }
        }
    }

    @ViewBuilder private func largest(_ tree: UsageNode) -> some View {
        let files = tree.largestFiles(limit: 200)
        List(Array(files.enumerated()), id: \.offset) { _, item in
            UsageRow(node: item.node, share: tree.size > 0 ? Double(item.node.size) / Double(tree.size) : 0, detail: item.trail.joined(separator: " / "))
                .contextMenu { Button("Mostrar en su sitio") { center.revealUsage(item.node, trail: item.trail, in: tree) } }
        }
    }
}

/// One line of the usage list: what it is, how much of its folder it takes, and how much that is.
private struct UsageRow: View {
    let node: UsageNode
    let share: Double
    var detail: String?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.isFolder ? "folder.fill" : "doc").foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(2, geometry.size.width * min(1, max(0, share))))
                    }
                }.frame(height: 5)
                if let detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                else if node.isFolder { Text("\(node.files) archivos").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(node.name), \(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)), \(Int((share * 100).rounded())) %"))
    }
}
