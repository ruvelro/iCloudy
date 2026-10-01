import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

extension ExplorerView {
    var fileList: some View {
        Table(model.visibleFiles, selection: $selected) {
            TableColumn("Nombre") { file in
                HStack(spacing: 8) {
                    // Folders carry no badge: iCloudy cannot claim that everything inside is present and current.
                    Group {
                        if file.isFolder { Color.clear } else { LocalCopyBadge(status: model.localStatus(file)) }
                    }.frame(width: 15)
                    FileIcon(file: file)
                    Text(file.name).lineLimit(1)
                    if model.isFavorite(file) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }.padding(.vertical, 5)
            }.width(min: 200, ideal: 320)
            TableColumn("Modificado") { file in
                Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
            }.width(125)
            TableColumn("Tamaño") { file in
                Text(file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—").foregroundStyle(.secondary)
            }.width(85)
        }
        // A Table insets its own cells; this brings their text onto the margin shared by the title and the footer.
        .padding(.horizontal, Layout.tableCorrection)
        .onDeleteCommand { model.requestDelete(model.selection(selected)) }
        .contextMenu(forSelectionType: CloudFile.ID.self) { ids in
            if ids.count > 1, model.inTrash {
                Button("Restaurar \(ids.count) elementos") { Task { await model.restore(model.selection(ids)) } }
                Divider()
                Button("Eliminar \(ids.count) elementos definitivamente…", role: .destructive) { model.requestPermanentDelete(model.selection(ids)) }
                    .disabled(model.limitation(.permanentDelete, for: model.selection(ids)) != nil)
                    .help(model.limitation(.permanentDelete, for: model.selection(ids)) ?? "")
            } else if ids.count > 1 {
                Button("Descargar \(ids.count) elementos…") { Task { await model.saveMany(model.selection(ids)) } }
                Button("Mover \(ids.count) elementos a…") { model.requestRelocation(model.selection(ids), copy: false) }
                Button("Copiar \(ids.count) elementos a…") { model.requestRelocation(model.selection(ids), copy: true) }
                    .disabled(!model.canCopy(model.selection(ids)))
                    .help(model.limitation(.copy, for: model.selection(ids)) ?? "")
                if model.accounts.count > 1 { Button("Enviar \(ids.count) elementos a otra nube…") { model.requestCrossCloud(model.selection(ids)) } }
                Divider()
                Button("Enviar \(ids.count) elementos a la papelera…", role: .destructive) { model.requestTrash(model.selection(ids)) }
                if model.account?.capabilities.permanentDelete == true {
                    Button("Eliminar \(ids.count) elementos definitivamente…", role: .destructive) { model.requestPermanentDelete(model.selection(ids)) }
                        .disabled(model.limitation(.permanentDelete, for: model.selection(ids)) != nil)
                        .help(model.limitation(.permanentDelete, for: model.selection(ids)) ?? "")
                }
            } else if let file = model.selection(ids).first { fileActions(file) }
        } primaryAction: { ids in
            guard let file = model.selection(ids).first else { return }
            if file.isFolder { model.navigate(file) }
            else if file.isGoogleDocument { model.openBrowser(file) }
            else { Task { await model.save(file) } }
        }
    }

    var fileBrowser: some View {
        Group {
            if model.viewMode == "grid" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 18) {
                        ForEach(model.visibleFiles) { file in
                            VStack(spacing: 10) {
                                FileIcon(file: file, size: 42)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !file.isFolder {
                                            LocalCopyBadge(status: model.localStatus(file), size: 14)
                                                .background(Circle().fill(.background).padding(-1))
                                                .offset(x: 8, y: 2)
                                        }
                                    }
                                Text(file.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                                if model.isFavorite(file) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                            }.frame(maxWidth: .infinity).frame(height: 112).padding(8)
                                .background(selected.contains(file.id) ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if file.isFolder { model.navigate(file) }
                                    else if file.isGoogleDocument { model.openBrowser(file) }
                                    else { Task { await model.save(file) } }
                                }
                                .onTapGesture {
                                    gridFocused = true
                                    let modifiers = NSEvent.modifierFlags
                                    if modifiers.contains(.command) {
                                        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                                        anchor = file.id
                                    } else if modifiers.contains(.shift), let from = anchor {
                                        selected = Self.range(from: from, to: file.id, in: model.visibleFiles)
                                    } else {
                                        selected = [file.id]; anchor = file.id
                                    }
                                }
                                .contextMenu { fileActions(file) }
                                .accessibilityLabel(file.name)
                                .accessibilityAddTraits(selected.contains(file.id) ? [.isSelected, .isButton] : .isButton)
                        }
                    }.padding(.horizontal, Layout.margin).padding(.vertical, 18)
                }.focusable().focusEffectDisabled().focused($gridFocused)
                    // The grid had no keyboard at all: no Delete, and no way to take a run of files without
                    // clicking each one with Command held down.
                    .onDeleteCommand { model.requestDelete(model.selection(selected)) }
            } else { fileList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.space) {
            guard selected.count == 1 else { return .ignored }
            previewSelection(); return .handled
        }
        .overlay {
            if model.visibleFiles.isEmpty && !model.loading {
                ContentUnavailableView(emptyTitle, systemImage: model.path.isEmpty ? model.collection.icon : "folder", description: Text(emptyDescription))
                    .allowsHitTesting(false)
            }
            // Only where an upload can actually land. The welcome frame used to appear over Recientes and Compartido
            // conmigo as well, and dropping there answered with a telling-off.
            if dropTarget, model.canWrite {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)).overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                }.overlay { Label("Subir a esta carpeta", systemImage: "arrow.up.doc.fill").font(.title2).padding().background(.regularMaterial, in: Capsule()) }.padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let local = urls.filter(\.isFileURL)
            guard !local.isEmpty, model.canWrite else { return false }
            model.planUploads(local); return true
        } isTargeted: { dropTarget = $0 }
    }
}
