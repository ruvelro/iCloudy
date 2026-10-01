import Foundation

/// What the transfer queue reports. Names of files and folders never go in: a job is its identifier, its direction,
/// its accounts and its numbers.
extension Diagnostics {
    /// The context a job runs in. Every request made while it runs inherits it.
    static func context(for transfer: Transfer, accounts: (String) -> Account?) -> DiagnosticsContext {
        let stage: String
        switch transfer.direction {
        case .upload: stage = DiagnosticStage.upload
        case .download: stage = DiagnosticStage.download
        case .transfer: stage = DiagnosticStage.transfer
        }
        return DiagnosticsContext(account: transfer.accountID, provider: accounts(transfer.accountID)?.cloud.rawValue,
                                  transfer: transfer.id, stage: stage, target: transfer.targetAccountID,
                                  targetProvider: transfer.targetAccountID.flatMap(accounts)?.cloud.rawValue)
    }

    static func transferRetrying(_ transfer: Transfer, context: DiagnosticsContext, attempt: Int, wait: Double, error: Error) {
        record(DiagnosticRecord(.retry, stage: DiagnosticStage.retry, provider: context.provider, account: transfer.accountID,
                                transfer: transfer.id, duration: wait, attempt: attempt, error: error))
    }
    static func transferWaitsForNetwork(_ transfer: Transfer, context: DiagnosticsContext) {
        record(DiagnosticRecord(.summary, stage: DiagnosticStage.networkChange, provider: context.provider,
                                account: transfer.accountID, transfer: transfer.id, message: "en espera de red"))
    }
    static func transferFinished(_ transfer: Transfer, context: DiagnosticsContext, since started: Date) {
        let counts = "verificados \(transfer.verifiedFiles) · sin verificar \(transfer.unverifiedFiles)"
            + (transfer.exportedFiles > 0 ? " · exportados \(transfer.exportedFiles)" : "")
        let upload = transfer.direction != .download
        record(DiagnosticRecord(.summary, stage: context.stage ?? transfer.direction.rawValue, provider: context.provider,
                                account: transfer.accountID, transfer: transfer.id,
                                duration: Date().timeIntervalSince(started),
                                bytesSent: upload ? transfer.total : nil, bytesReceived: upload ? nil : transfer.total,
                                attempt: transfer.attempts, message: "completada · " + counts))
    }
    static func transferFailed(_ transfer: Transfer, context: DiagnosticsContext, error: Error, since started: Date) {
        let stage = error is DownloadIntegrityError ? DiagnosticStage.verify : (context.stage ?? transfer.direction.rawValue)
        record(DiagnosticRecord(.error, stage: stage, provider: context.provider, account: transfer.accountID,
                                transfer: transfer.id, duration: Date().timeIntervalSince(started),
                                attempt: transfer.attempts, error: error))
    }
}
