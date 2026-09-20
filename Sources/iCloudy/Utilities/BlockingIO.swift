import Foundation

func blockingIO<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { try work() }
    // A detached task inherits neither the actor nor the cancellation of whoever started it. Escaping the actor is
    // the whole point; losing the cancellation was not. Work that does check it — the proof of work Mega asks for,
    // the walk of a volume — kept going long after the person had given up, with no way to stop it.
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
