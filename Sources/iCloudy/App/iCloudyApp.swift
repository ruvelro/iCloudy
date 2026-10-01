// iCloudy — todas tus nubes en una sola ventana del Mac.
// Copyright (C) 2026 ruvelro
//
// This program is free software: you can redistribute it and/or modify it under the terms of the GNU General
// Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
// Public License for more details. You should have received a copy of it along with this program; if not, see
// <https://www.gnu.org/licenses/>.

import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// What the `iCloudyMain` binary calls. The app itself is a library, so the Finder extension can link the same
/// providers; a library cannot carry `@main`, so the entry point is spelled out here instead.
public enum AppLauncher {
    /// `main.swift` runs on the main thread, which is where SwiftUI expects to be entered.
    @MainActor public static func run() { iCloudyApp.main() }
}

struct iCloudyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    var body: some Scene {
        // A WindowGroup always restores a window at launch and when the Dock icon is clicked; a `Window` scene that
        // the user (or a crash) closed stays closed, leaving the app running with nothing on screen. "Nueva ventana"
        // is removed below, so this still behaves as a single-window app over one shared model.
        WindowGroup(id: "explorer") {
            ExplorerView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.model = model }
                // Opening a Spotlight result brings the app forward on the indexed item.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    model.openSpotlightItem(identifier: id)
                }
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // There is still one window; ⌘T opens a tab in it instead of a second one.
            CommandGroup(replacing: .newItem) {
                Button("Nueva pestaña") { model.newTab() }.keyboardShortcut("t", modifiers: .command)
                Divider()
                // F5 and F6, as in the two-pane file managers they come from.
                Button("Copiar al otro panel") { model.sendSelectionToOtherPane(move: false) }
                    .keyboardShortcut(KeyEquivalent.function(5), modifiers: []).disabled(!model.isSplit)
                Button("Mover al otro panel") { model.sendSelectionToOtherPane(move: true) }
                    .keyboardShortcut(KeyEquivalent.function(6), modifiers: []).disabled(!model.isSplit)
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W closes a tab while there are others and the window with the last one. Any other window with
                // the focus (Configuración, the preview) closes as it always did.
                Button("Cerrar pestaña") {
                    guard let window = NSApp.keyWindow else { return }
                    if window === ExplorerWindowReader.window { model.closeTabOrWindow(window) } else { window.performClose(nil) }
                }.keyboardShortcut("w", modifiers: .command)
                Button("Cerrar ventana") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Mostrar la pestaña anterior") { model.cycleTabs(forward: false) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(model.tabCount < 2)
                Button("Mostrar la pestaña siguiente") { model.cycleTabs(forward: true) }
                    .keyboardShortcut(.tab, modifiers: .control).disabled(model.tabCount < 2)
                Menu("Ir a la pestaña") {
                    ForEach(1...8, id: \.self) { number in
                        Button("Pestaña \(number)") { model.showTab(number: number) }
                            .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    }
                    Button("Última pestaña") { model.showTab(number: 9) }.keyboardShortcut("9", modifiers: .command)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Añadir cuenta…") { model.showConnect = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Subir archivos…") { Task { await model.pickUpload() } }.disabled(!model.canWrite)
                Button("Subir el portapapeles") { model.uploadFromPasteboard() }.disabled(!model.canWrite)
                Button("Buscar en todas las nubes") { model.preview.close(); model.showGlobalSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Comparar carpetas…") { model.openComparator() }.disabled(model.accounts.isEmpty)
                Button("Buscar duplicados…") { model.openDuplicateFinder() }.disabled(model.accounts.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button(model.isSplit ? "Cerrar el segundo panel" : "Dividir en dos paneles") { model.toggleSplit() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Toggle("Mostrar iCloudy en la barra de menús", isOn: $menuBarEnabled)
            }
        }
        MenuBarExtra("iCloudy", systemImage: "cloud.fill", isInserted: $menuBarEnabled) {
            MenuBarContent(model: model, queue: model.queue)
        }
        Settings { SettingsView(model: model) }
    }
}
