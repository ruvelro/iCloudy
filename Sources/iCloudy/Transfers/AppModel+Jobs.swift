import Foundation

/// The entry points for saved jobs, for the jobs window, the menu bar, App Intents and the command line.
extension AppModel {
    /// Queues one run of a saved job and returns its batch, whose report and history are those of any transfer.
    @discardableResult
    func runJob(id: UUID, allowingMassDeletion: Bool = false) async throws -> UUID {
        try await jobs.run(id, allowingMassDeletion: allowingMassDeletion)
    }
    /// The same, by name, ignoring case and accents.
    @discardableResult
    func runJob(named name: String) async throws -> UUID {
        guard let job = jobs.job(named: name) else { throw CloudError.notFound(L("No hay ningún trabajo guardado llamado «\(name)».")) }
        return try await runJob(id: job.id)
    }
    /// The transfers of a job's last run, for its report.
    func lastRun(of job: SavedJob) -> [Transfer] {
        guard let batch = job.lastBatchID else { return [] }
        return queue.items.filter { $0.batchID == batch }
    }
}
