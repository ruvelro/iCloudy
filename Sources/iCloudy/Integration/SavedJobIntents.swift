import AppIntents
import Foundation

/// A saved transfer job, as Shortcuts lists and picks it.
struct SavedJobEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Trabajo guardado de iCloudy"
    static let defaultQuery = SavedJobQuery()
    let id: UUID
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    init(_ job: SavedJob) {
        id = job.id
        title = job.name
    }
}

struct SavedJobQuery: EntityQuery {
    @MainActor func entities(for identifiers: [SavedJobEntity.ID]) async throws -> [SavedJobEntity] {
        try await ColdStart.model().jobs.jobs.filter { identifiers.contains($0.id) }.map(SavedJobEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [SavedJobEntity] {
        try await ColdStart.model().jobs.jobs.map(SavedJobEntity.init)
    }
}

/// Runs a saved job once. It has no App Shortcut phrase of its own: the app is at the ten-shortcut limit, and the
/// intent is in the Shortcuts app's list all the same.
struct RunSavedJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Ejecutar un trabajo guardado de iCloudy"
    static let description = IntentDescription("Pone en la cola una pasada de un trabajo guardado, con su informe y su entrada en el historial.")
    static let openAppWhenRun = false

    @Parameter(title: "Trabajo") var job: SavedJobEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await ColdStart.model()
        guard let found = model.jobs.job(job.id) else { throw CloudError.message(L("Ese trabajo ya no existe.")) }
        try await model.runJob(id: found.id)
        return .result(dialog: IntentDialog(stringLiteral: L("«\(found.name)» está en la cola.")))
    }
}
