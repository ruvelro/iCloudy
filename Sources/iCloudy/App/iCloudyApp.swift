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
    public static func run() { iCloudyApp.main() }
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
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Añadir cuenta…") { model.showConnect = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Subir archivos…") { Task { await model.pickUpload() } }.disabled(!model.canWrite)
                Button("Subir el portapapeles") { model.uploadFromPasteboard() }.disabled(!model.canWrite)
                Button("Buscar en todas las nubes") { model.preview.close(); model.showGlobalSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Comparar carpetas…") { model.openComparator() }.disabled(model.accounts.isEmpty)
                Button("Buscar duplicados…") { model.openDuplicateFinder() }.disabled(model.accounts.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Mostrar iCloudy en la barra de menús", isOn: $menuBarEnabled)
            }
        }
        MenuBarExtra("iCloudy", systemImage: "cloud.fill", isInserted: $menuBarEnabled) {
            MenuBarContent(model: model, queue: model.queue)
        }
        Settings { SettingsView(model: model) }
    }
}
