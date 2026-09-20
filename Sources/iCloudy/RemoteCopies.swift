import Foundation
import Combine

struct RemoteCopy: Codable, Identifiable {
    enum State: String, Codable { case starting, monitoring, completed, failed, uncertain }
    var id = UUID()
    let accountID: String
    let name: String
    let destination: String
    var monitor: URL?
    var state: State = .starting
    var detail = ""
}

/// Durable receipts for server-side copies. Restarting only polls a receipt; it never repeats the POST.
@MainActor
final class RemoteCopies: ObservableObject {
    @Published private(set) var items: [RemoteCopy] = []
    let storeURL: URL
    var client: ((String) throws -> CloudAPI)?
    var didComplete: ((String) -> Void)?
    var pollDelay: Duration = .seconds(5)
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var loadError: Error?
    init(storeURL: URL = LocalStore.directory.appendingPathComponent("remote-copies.json")) {
        self.storeURL = storeURL
        do {
            items = try LocalStore.read([RemoteCopy].self, from: storeURL) ?? []
            for i in items.indices where items[i].state == .starting {
                items[i].state = .uncertain
                items[i].detail = L("La copia se interrumpió sin confirmación. Comprueba el destino antes de repetirla.")
            }
        } catch { loadError = error }
    }
    private func persist() throws { if let loadError { throw loadError }; try LocalStore.save(items, to: storeURL) }
    func start(file: CloudFile, destination: String, api: CloudAPI) async throws {
        let operation = RemoteCopy(accountID: api.account.id, name: file.name, destination: destination)
        items.append(operation)
        do { try persist() } catch { items.removeAll { $0.id == operation.id }; throw error }
        do {
            try await api.copy(file: file, to: destination, accepted: { monitor in
                guard let i = self.items.firstIndex(where: { $0.id == operation.id }) else { throw CancellationError() }
                self.items[i].monitor = monitor; self.items[i].state = .monitoring
                try self.persist()
            })
            if let i = items.firstIndex(where: { $0.id == operation.id }), items[i].monitor == nil {
                items[i].state = .completed; try persist(); didComplete?(operation.accountID)
            }
            resume()
        } catch {
            if let i = items.firstIndex(where: { $0.id == operation.id }) {
                items[i].state = .uncertain; items[i].detail = error.localizedDescription
                try? persist()
            }
            throw error
        }
    }
    func resume() {
        for item in items where item.state == .monitoring && tasks[item.id] == nil {
            tasks[item.id] = Task { [weak self] in
                guard let self else { return }
                defer { self.tasks[item.id] = nil }
                while !Task.isCancelled {
                    guard let i = self.items.firstIndex(where: { $0.id == item.id }), self.items[i].state == .monitoring,
                          let monitor = self.items[i].monitor else { return }
                    do {
                        guard let client = self.client else { return }
                        let status = try await client(item.accountID).remoteCopyStatus(monitor)
                        guard let current = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                        self.items[current].state = status
                        self.items[current].detail = ""
                        try self.persist()
                        if status == .completed { self.didComplete?(item.accountID); return }
                        if status == .failed { self.items[current].detail = L("OneDrive no pudo completar la copia."); try self.persist(); return }
                    } catch {
                        guard let position = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                        self.items[position].detail = error.localizedDescription
                        try? self.persist()
                    }
                    do { try await Task.sleep(for: self.pollDelay) } catch { return }
                }
            }
        }
    }
    func removeAccount(_ id: String) {
        for item in items where item.accountID == id { tasks.removeValue(forKey: item.id)?.cancel() }
        items.removeAll { $0.accountID == id }; try? persist()
    }
}

extension CloudAPI {
    nonisolated static func validCopyMonitor(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "graph.microsoft.com" || host == "api.onedrive.com" || host.hasSuffix(".sharepoint.com")
    }
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State {
        guard Self.validCopyMonitor(url) else { throw CloudError.message(L("OneDrive devolvió una dirección de seguimiento no válida.")) }
        // Monitor URLs on storage servers are capability URLs. Never forward the Graph bearer token to them.
        let request = url.host == "graph.microsoft.com" ? try await request(url) : URLRequest(url: url)
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        try HTTP.validate(response, data: data)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch (body?["status"] as? String)?.lowercased() {
        case "completed": return .completed
        case "failed", "deletefailed": return .failed
        case "inprogress", "notstarted", "updating", "waiting": return .monitoring
        default: throw CloudError.message(L("OneDrive todavía no ha confirmado el resultado de la copia."))
        }
    }
}
