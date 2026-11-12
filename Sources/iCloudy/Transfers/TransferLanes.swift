import Foundation

/// How many files of one job may be travelling at this moment. A counting semaphore for the main actor: whoever
/// finds no lane free waits in line, and a cancelled wait leaves the line instead of holding a place in it.
@MainActor
final class TransferLanes {
    private var free: Int
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(_ count: Int) { free = max(1, count) }

    func acquire() async throws {
        try Task.checkCancellation()
        if free > 0 { free -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
        } onCancel: {
            // Queued behind the append above, which runs to its end on the main actor before this can.
            Task { @MainActor in self.abandon(id) }
        }
    }

    /// Hands the lane to whoever has waited longest, or returns it to the pool.
    func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().continuation.resume() }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
