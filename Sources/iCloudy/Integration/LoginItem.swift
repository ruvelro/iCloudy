import AppKit
import ServiceManagement

/// Opening iCloudy when the person logs in, through the system's own list of login items. macOS may hold the request
/// until it is approved in System Settings; that state is reported as it is instead of pretending it worked.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Whether iCloudy shows in the Dock. Without it, the menu bar is the only way back to the window, so the Dock icon
/// comes back by itself whenever the menu bar item is off.
enum DockIcon {
    @MainActor static func apply() {
        let visible = Prefs.bool(Prefs.dockIcon, default: true) || !Prefs.bool(Prefs.menuBar, default: true)
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Changing the policy sends the app to the background; the window the person was using stays in front.
        NSApp.activate(ignoringOtherApps: true)
    }
}
