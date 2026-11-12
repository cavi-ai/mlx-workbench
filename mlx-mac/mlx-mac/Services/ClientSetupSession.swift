import Foundation
import Combine

struct ClientConnectionResult: Equatable, Sendable {
    let protocolName: String
    let answer: String
}

enum ClientConnectionTest {
    static func run(client: ServingClient, server: ServerInfo, token: String?, http: HostHTTPClient = .init()) async throws -> ClientConnectionResult {
        guard let endpoint = WireEndpoint(server: server), !client.requiresGateway || server.jit == true else { throw HostHTTPError.invalidResponse }
        let baseURL = String(endpoint.baseURL.dropLast(3))
        let prompt = "Reply with the word CONNECTED."
        var body: [String: Any] = ["model": endpoint.modelName, "stream": false]
        let path: String, name: String
        switch client {
        case .codex:
            path = "v1/responses"; name = "Responses"
            body["input"] = prompt; body["max_output_tokens"] = 128
        case .claude:
            path = "v1/messages"; name = "Messages"
            body["messages"] = [["role": "user", "content": prompt]]; body["max_tokens"] = 128
        default:
            path = "v1/chat/completions"; name = "Chat Completions"
            body["messages"] = [["role": "user", "content": prompt]]; body["max_tokens"] = 128
        }
        let data = try await CaviConnectionClient.request(baseURL: baseURL, path: path,
            body: JSONSerialization.data(withJSONObject: body), token: token,
            http: http,
            headers: client == .claude ? ["anthropic-version": "2023-06-01"] : [:])
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any], response["error"] == nil else { throw HostHTTPError.invalidResponse }
        let text: String
        switch client {
        case .codex:
            guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else { throw HostHTTPError.invalidResponse }
            text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .claude:
            guard response["type"] as? String == "message", let content = response["content"] as? [[String: Any]] else { throw HostHTTPError.invalidResponse }
            text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default:
            guard let choice = (response["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any], let content = message["content"] as? String else { throw HostHTTPError.invalidResponse }
            text = content
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostHTTPError.invalidResponse }
        return ClientConnectionResult(protocolName: name, answer: String(text.prefix(4_000)))
    }
}

/// One client, one reviewed process, one existing wiring transaction.
@MainActor
final class ClientSetupSession: ObservableObject {
    enum Stage: Equatable { case choose, review, saved }
    @Published private(set) var stage = Stage.choose
    @Published private(set) var client: ServingClient
    @Published private(set) var servers: [ServerInfo] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var result: ClientConnectionResult?
    @Published private(set) var appFound: Bool?
    @Published private(set) var receipt: ClientEditReceipt?
    @Published private(set) var transactionID: UUID?
    private let wiring: WiringCoordinator
    private let readServers: () async throws -> [ServerInfo]
    private let testConnection: (ServingClient, ServerInfo, String?) async throws -> ClientConnectionResult
    private let detect: (ServingClient) async -> Bool
    private var reviewed: ServerInfo?
    private var hash: String?
    private var activeTask: Task<Void, Never>?
    private var initialServer: ServerInfo?

    init(wiring: WiringCoordinator, client: ServingClient = .opencode, server: ServerInfo? = nil,
         servers: @escaping () async throws -> [ServerInfo],
         test: @escaping (ServingClient, ServerInfo, String?) async throws -> ClientConnectionResult = { try await ClientConnectionTest.run(client: $0, server: $1, token: $2) },
         detect: @escaping (ServingClient) async -> Bool = { client in
             await WorkbenchIO.perform {
                 var environment = ProcessInfo.processInfo.environment
                 let home = WorkbenchStatePaths.userHome().path
                 environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + home + "/.local/bin:" + home + "/.openclaw/npm/bin"
                 return WorkbenchPython.resolveOnPath(client.rawValue == "claude" ? "claude" : client.rawValue, environment: environment, fileManager: .default) != nil
             }
         }) {
        self.wiring = wiring; self.client = client; self.initialServer = server
        readServers = servers; testConnection = test; self.detect = detect
    }
    var selected: ServerInfo? { servers.first { $0.id == selectedID } }
    var supported: Bool { selected.map { !client.requiresGateway || $0.jit == true } ?? false }
    var plan: ClientEditPlan? { wiring.plans.first { $0.clientID == client.rawValue } }

    func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            servers = try await readServers().filter { WireEndpoint(server: $0) != nil }
            try Task.checkCancellation()
            if let expected = initialServer {
                selectedID = servers.first { $0.sameProcess(as: expected) }?.id
                if selectedID == nil { error = "This endpoint changed or stopped. Choose a running endpoint." }
                initialServer = nil
            } else if selectedID == nil { selectedID = servers.first?.id }
            appFound = await detect(client)
        } catch { self.error = AppHost.render(error) }
    }
    func choose(client: ServingClient) {
        guard !busy else { return }
        self.client = client; reset(); appFound = nil
        activeTask = Task { [weak self] in
            guard let self else { return }
            let found = await detect(client)
            if self.client == client { appFound = found }
        }
    }
    func choose(serverID: String?) { guard !busy else { return }; selectedID = serverID; reset() }
    func back() { guard !busy else { return }; reset() }
    private func reset() { stage = .choose; error = nil; result = nil; reviewed = nil; hash = nil; receipt = nil; transactionID = nil }
    var canUndo: Bool {
        wiring.transactions.contains { $0.id == transactionID && !$0.receipts.isEmpty && $0.rolledBackAt == nil }
    }
    func undo() {
        guard !busy, let transactionID else { return }
        wiring.rollback(transactionID: transactionID)
        if let error = wiring.lastError { self.error = error }
        else { reset() }
    }

    func preview() async {
        guard !busy, supported, let selected else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            _ = try await current(selected)
            await wiring.preview(server: selected, clientIDs: [client.rawValue])
            guard wiring.previewMatches(server: selected), wiring.plans.count == 1, let hash = wiring.previewHash else {
                throw WorkflowEvidenceError.invalid(wiring.lastError ?? "Setup could not be prepared. Review this client’s configuration.")
            }
            self.hash = hash; reviewed = selected; stage = .review
        } catch { self.error = AppHost.render(error) }
    }
    func apply() async {
        guard !busy, let reviewed, let hash else { return }
        busy = true; error = nil; defer { busy = false }
        let transaction = await wiring.confirm(server: reviewed, previewHash: hash, currentServers: readServers)
        guard let transaction, transaction.failures.isEmpty, transaction.receipts.count == 1,
              let receipt = transaction.receipts.first, receipt.clientID == client.rawValue else {
            error = wiring.lastError ?? "The configuration was not applied. Review setup again."; return
        }
        self.receipt = receipt; transactionID = transaction.id; stage = .saved
        if let failure = wiring.persistenceError { error = failure }
    }
    func test() async {
        guard !busy, stage == .saved, let reviewed, let receipt, let endpoint = WireEndpoint(server: reviewed) else { return }
        busy = true; error = nil; result = nil; defer { busy = false }
        do {
            let latest = try await current(reviewed)
            guard await wiring.matchesAppliedConfig(receipt, endpoint: endpoint) else { throw changedConfig() }
            let key = reviewed.apiKeySHA256 == nil ? nil : try await wiring.inferenceKey(server: reviewed, currentServers: { latest })
            let response = try await testConnection(client, reviewed, key)
            try Task.checkCancellation()
            _ = try await current(reviewed)
            guard await wiring.matchesAppliedConfig(receipt, endpoint: endpoint) else { throw changedConfig() }
            result = response
        } catch { self.error = error is CancellationError ? "Connection test stopped." : AppHost.render(error) }
    }
    private func current(_ expected: ServerInfo) async throws -> [ServerInfo] {
        let latest = try await readServers()
        try Task.checkCancellation()
        let samePort = latest.filter { $0.port == expected.port && $0.state == "running" }
        guard samePort.count == 1, samePort[0].sameProcess(as: expected) else {
            throw WorkflowEvidenceError.invalid("The endpoint changed or stopped. Refresh and review setup again.")
        }
        return latest
    }
    private func changedConfig() -> WorkflowEvidenceError { .invalid("The client configuration changed. Review setup again before testing it.") }
}
