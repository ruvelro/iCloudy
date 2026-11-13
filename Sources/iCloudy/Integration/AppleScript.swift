import Foundation
import AppKit

// The commands of Resources/iCloudy.sdef. Scripting works under the sandbox because the app only receives Apple
// Events; the script that sends them is the one macOS asks the person about (Automation in Privacy & Security). The
// dictionary only reads and shows, like an icloudy:// link: nothing a script says deletes, moves or uploads.
//
// AppKit runs every command on the main thread; the Objective-C names are the ones the dictionary refers to.

@objc(ICListAccountsCommand)
final class ListAccountsScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let lines: [String] = MainActor.assumeIsolated {
            guard let model = AppModel.shared, !model.isLocked else { return [] }
            return model.accounts.map { model.accountTitle($0) + ": " + $0.id }
        }
        return lines
    }
}

@objc(ICShowCommand)
final class ShowScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = L("Indica un lugar como cuenta:/ruta.")
            return nil
        }
        MainActor.assumeIsolated {
            ColdStart.deliver { model in
                NSApp?.activate(ignoringOtherApps: true)
                Task {
                    do { try await model.goToFolder(text) } catch { model.error = error.localizedDescription }
                }
            }
        }
        return nil
    }
}

@objc(ICSearchCommand)
final class SearchScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let term = directParameter as? String, !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = L("Indica qué buscar.")
            return nil
        }
        let accountName = evaluatedArguments?["account"] as? String
        // The answer comes from the network: the script waits for it, the main thread does not.
        suspendExecution()
        nonisolated(unsafe) let command = self
        MainActor.assumeIsolated {
            _ = Task { @MainActor in
                do {
                    let model = try await ColdStart.model()
                    let only = try accountName.map { try model.account(named: $0) }
                    let hits = await model.automationSearch(term, in: only, limit: 200)
                    let lines = hits.map { hit -> String in
                        let title = model.accounts.first { $0.id == hit.accountID }.map(model.accountTitle) ?? hit.accountID
                        return title + ": " + hit.file.name + (hit.file.isFolder ? "/" : "")
                    }
                    command.resumeExecution(withResult: lines)
                } catch {
                    command.scriptErrorNumber = errAEEventFailed
                    command.scriptErrorString = error.localizedDescription
                    command.resumeExecution(withResult: nil)
                }
            }
        }
        return nil
    }
}
