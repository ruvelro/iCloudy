import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Which slice of the transfers the panel is showing. One list held all of them at once — running, just finished,
/// and whatever had failed days ago — so the thing the panel was opened for was never the thing at the top of it.
enum TransferTab: String, CaseIterable, Identifiable {
    case active, done, error, history
    var id: Self { self }
    var title: String {
        switch self {
        case .active: return L("En curso")
        case .done: return L("Finalizadas")
        case .error: return L("Error")
        case .history: return L("Historial")
        }
    }
}

/// The error tab tells two different stories: a transfer that broke on its own, and one the user stopped by hand.
/// Both are over and neither will resume, which is why they share a tab; only the filter tells them apart.
enum TransferErrorFilter: String, CaseIterable, Identifiable {
    case all, failed, cancelled
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return L("Todas")
        case .failed: return L("Fallidas")
        case .cancelled: return L("Canceladas")
        }
    }
    func matches(_ state: TransferState) -> Bool {
        switch self {
        case .all: return [.failed, .cancelled].contains(state)
        case .failed: return state == .failed
        case .cancelled: return state == .cancelled
        }
    }
}

/// "Completadas hoy" used to be a section pinned under the queue, answering the same question as the history with
/// a shorter list. It is a filter over the history now, rather than a second list saying half of the same thing.
enum TransferHistoryFilter: String, CaseIterable, Identifiable {
    case all, today
    var id: Self { self }
    var title: String { self == .all ? L("Todas") : L("Hoy") }
}
