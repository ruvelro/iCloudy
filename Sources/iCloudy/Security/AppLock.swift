import AppKit
import SwiftUI
import LocalAuthentication

extension Prefs {
    static let appLock = "appLockEnabled"
    /// Minutes away from iCloudy before it locks again. Zero locks only at launch and when the screen locks.
    static let appLockIdleMinutes = "appLockIdleMinutes"
    /// Whether a vault's remembered passphrase is only used after the same check.
    static let appLockVaults = "appLockVaults"
}

/// Asks macOS to confirm that whoever is at the Mac is its owner: Touch ID, an Apple Watch, or the login password
/// where neither is there. iCloudy never sees how it was confirmed, only whether it was.
enum DeviceOwner {
    /// Why the check cannot be made at all on this Mac (no password set, for instance), or nil when it can.
    static func unavailableReason() -> String? {
        var error: NSError?
        guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        return error?.localizedDescription ?? L("Este Mac no tiene Touch ID ni contraseña con los que comprobar quién lo usa.")
    }
    static func confirm(_ reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = L("Cancelar")
        do { _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) { throw CancellationError() }
    }
}

/// When the window locks. Pure, so the rules can be read and tested without waiting for anything.
struct AppLockPolicy: Equatable {
    var enabled = false
    var idleMinutes = 5
    var protectsVaults = true

    static func stored(in defaults: UserDefaults = .standard) -> AppLockPolicy {
        AppLockPolicy(enabled: defaults.bool(forKey: Prefs.appLock),
                      idleMinutes: defaults.object(forKey: Prefs.appLockIdleMinutes) as? Int ?? 5,
                      protectsVaults: defaults.object(forKey: Prefs.appLockVaults) as? Bool ?? true)
    }
    /// Whether coming back to the app after being away since `resigned` should find it locked.
    func locksAfterAbsence(since resigned: Date?, now: Date = Date()) -> Bool {
        guard enabled, idleMinutes > 0, let resigned else { return false }
        return now.timeIntervalSince(resigned) >= Double(idleMinutes) * 60
    }
}

/// The lock itself is a privacy screen over iCloudy's windows, not encryption: it keeps someone who sits at an
/// unlocked Mac from browsing the accounts, and it is what stands between them and a vault whose passphrase was
/// remembered. Transfers, mirrors and scheduled copies carry on underneath.
extension AppModel {
    var lockPolicy: AppLockPolicy { AppLockPolicy.stored(in: lockDefaults) }

    /// Called once at launch, before the window shows anything.
    func startLock() {
        isLocked = lockPolicy.enabled
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } },
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } },
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } },
        ]
    }

    /// Locks now, if the lock is on. Whatever shows account contents outside the main window is closed with it.
    func lock() {
        guard lockPolicy.enabled, !isLocked else { return }
        isLocked = true
        lockProblem = nil
        preview.close()
        CompareCenter.shared.hide()
        showGlobalSearch = false
    }

    func unlock() async {
        guard isLocked, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        do {
            try await confirmOwner(L("desbloquear iCloudy"))
            isLocked = false; lockProblem = nil; resignedAt = nil
        } catch is CancellationError {
        } catch { lockProblem = error.localizedDescription }
    }

    /// Turning the lock on or off is itself behind the check: on, so nobody is locked out of a Mac that cannot
    /// make it; off, so the person the lock is meant to stop cannot simply switch it off.
    func setLockEnabled(_ enabled: Bool) async -> String? {
        do { try await confirmOwner(enabled ? L("activar el bloqueo de iCloudy") : L("desactivar el bloqueo de iCloudy")) }
        catch is CancellationError { return "" }
        catch { return error.localizedDescription }
        lockDefaults.set(enabled, forKey: Prefs.appLock)
        if !enabled { isLocked = false }
        return nil
    }

    /// Before a vault is opened with the passphrase kept in the Keychain. True when no check is asked for.
    func ownerConfirmed(for reason: String) async -> Bool {
        let policy = lockPolicy
        guard policy.enabled, policy.protectsVaults else { return true }
        do { try await confirmOwner(reason); return true }
        catch is CancellationError { return false }
        catch { self.error = error.localizedDescription; return false }
    }

    func appResignedActive() { if !isLocked { resignedAt = Date() } }
    func appBecameActive() {
        if lockPolicy.locksAfterAbsence(since: resignedAt) { lock() }
        resignedAt = nil
    }
}

/// What the window shows while iCloudy is locked: nothing of what it holds.
struct LockedView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("iCloudy está bloqueado").font(.title2.weight(.semibold))
            Text("Las transferencias, los reflejos y las copias programadas siguen su curso.").font(.callout).foregroundStyle(.secondary)
            Button { Task { await model.unlock() } } label: { Label("Desbloquear", systemImage: "touchid").padding(.horizontal, 8) }
                .controlSize(.large).keyboardShortcut(.defaultAction).disabled(model.unlocking)
            if let problem = model.lockProblem { Text(problem).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 380) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Asked for as soon as the window is there, so opening the app is one touch and not a click and a touch.
        .task { await model.unlock() }
    }
}

/// The lock, in the settings.
struct AppLockSettings: View {
    @Bindable var model: AppModel
    @State private var enabled = AppLockPolicy.stored().enabled
    @AppStorage(Prefs.appLockIdleMinutes) private var idleMinutes = 5
    @AppStorage(Prefs.appLockVaults) private var protectsVaults = true
    @State private var problem: String?
    var body: some View {
        Section {
            Toggle("Pedir Touch ID o la contraseña del Mac para abrir iCloudy", isOn: Binding(get: { enabled }, set: { wanted in
                Task {
                    let refusal = await model.setLockEnabled(wanted)
                    enabled = model.lockPolicy.enabled
                    problem = (refusal ?? "").isEmpty ? nil : refusal
                }
            }))
            if enabled {
                Picker("Volver a bloquear tras", selection: $idleMinutes) {
                    Text("1 minuto fuera de iCloudy").tag(1)
                    Text("5 minutos").tag(5)
                    Text("15 minutos").tag(15)
                    Text("30 minutos").tag(30)
                    Text("Solo al abrir y al bloquear la pantalla").tag(0)
                }
                Toggle("Pedirlo también antes de usar la contraseña guardada de una bóveda", isOn: $protectsVaults)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Es una pantalla de privacidad, no un cifrado: evita que quien se siente ante el Mac desbloqueado recorra tus nubes. Las credenciales siguen en el Llavero y las transferencias no se detienen. Para cifrar de verdad están las bóvedas.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
