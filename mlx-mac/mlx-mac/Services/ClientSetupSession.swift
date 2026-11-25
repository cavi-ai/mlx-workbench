import Foundation
import Combine

extension ServingClient {
    /// Clients that can wire directly to the unified Front Door endpoint.
    var supportsFrontDoor: Bool {
        switch self {
        case .opencode, .openclaw, .claude, .codex, .hermes: return true
        }
    }

    /// Clients whose chat-completions endpoints are verified with a tool-call probe.
    var supportsToolCallCheck: Bool {
        switch self {
        case .opencode, .openclaw, .hermes: return true
        case .codex, .claude: return false
        }
    }
}

enum ClientToolCallCheck: Equatable, Sendable { case passed, notVerified, timedOut }

struct ClientConnectionResult: Equatable, Sendable {
    let protocolName: String
    let answer: String
    var toolCall: ClientToolCallCheck? = nil
}

enum ClientConnectionTest {
    static func run(client: ServingClient, server: ServerInfo, token: String?, http: HostHTTPClient = .init()) async throws -> ClientConnectionResult {
        guard let endpoint = WireEndpoint(server: server), !client.requiresGateway || server.jit == true else { throw HostHTTPError.invalidResponse }
        return try await run(client: client, endpoint: endpoint, token: token, http: http)
    }

    static func run(client: ServingClient, endpoint: WireEndpoint, token: String?, http: HostHTTPClient = .init()) async throws -> ClientConnectionResult {
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
        var result = ClientConnectionResult(protocolName: name, answer: String(text.prefix(4_000)))
        if client.supportsToolCallCheck {
            do {
                result.toolCall = try await checkToolCall(baseURL: baseURL, model: endpoint.modelName, token: token, http: http) ? .passed : .notVerified
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result.toolCall = (error as? HostHTTPError) == .timedOut ? .timedOut : .notVerified
            }
        }
        return result
    }

    private static func checkToolCall(baseURL: String, model: String, token: String?, http: HostHTTPClient) async throws -> Bool {
        let toolName = "workbench_tool_check"
        let schema: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        let tool: [String: Any] = ["type": "function", "function": ["name": toolName,
            "description": "Check tool calling", "parameters": schema]]
        let body: [String: Any] = [
            "model": model, "stream": false, "max_tokens": 128,
            "messages": [["role": "user", "content": "Call workbench_tool_check with no arguments."]],
            "tool_choice": "auto", "tools": [tool],
        ]
        let data = try await CaviConnectionClient.request(baseURL: baseURL, path: "v1/chat/completions",
            body: JSONSerialization.data(withJSONObject: body), token: token, http: http, timeout: 10)
        try Task.checkCancellation()
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any], response["error"] == nil,
              let choice = (response["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any], let calls = message["tool_calls"] as? [[String: Any]], calls.count == 1,
              let call = calls.first, call["type"] as? String == "function",
              let id = call["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let function = call["function"] as? [String: Any], function["name"] as? String == toolName,
              let arguments = function["arguments"] as? String, let argumentData = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any], object.isEmpty else { return false }
        return true
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
    /// The app-owned front door while it routes at least one chat model; offered for Front Door-compatible clients.
    @Published private(set) var frontDoor: WireEndpoint?
    static let frontDoorID = "front-door"
    private let wiring: WiringCoordinator
    private let readServers: () async throws -> [ServerInfo]
    private let readFrontDoor: @MainActor () async -> WireEndpoint?
    private let readFleet: @MainActor () -> EndpointFleetConfig?
    private let testConnection: (ServingClient, ServerInfo, String?) async throws -> ClientConnectionResult
    private let testFrontDoor: (ServingClient, WireEndpoint, String?) async throws -> ClientConnectionResult
    private let detect: (ServingClient) async -> Bool
    private var reviewed: ServerInfo?
    private var reviewedFrontDoor: WireEndpoint?
    private var hash: String?
    private var activeTask: Task<Void, Never>?
    private var initialServer: ServerInfo?
    private var prefersFrontDoor: Bool

    deinit {
        activeTask?.cancel()
    }

    init(wiring: WiringCoordinator, client: ServingClient = .opencode, server: ServerInfo? = nil, prefersFrontDoor: Bool = false,
         servers: @escaping () async throws -> [ServerInfo],
         frontDoor: @escaping @MainActor () async -> WireEndpoint? = { nil },
         fleet: @escaping @MainActor () -> EndpointFleetConfig? = { nil },
         test: @escaping (ServingClient, ServerInfo, String?) async throws -> ClientConnectionResult = { try await ClientConnectionTest.run(client: $0, server: $1, token: $2) },
         testFrontDoor: @escaping (ServingClient, WireEndpoint, String?) async throws -> ClientConnectionResult = { try await ClientConnectionTest.run(client: $0, endpoint: $1, token: $2) },
         detect: @escaping (ServingClient) async -> Bool = { client in
             await WorkbenchIO.perform {
                 var environment = ProcessInfo.processInfo.environment
                 let home = WorkbenchStatePaths.userHome().path
                 environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + home + "/.local/bin:" + home + "/.openclaw/npm/bin"
                 return WorkbenchPython.resolveOnPath(client.rawValue == "claude" ? "claude" : client.rawValue, environment: environment, fileManager: .default) != nil
             }
         }) {
        self.wiring = wiring; self.client = client; self.initialServer = server; self.prefersFrontDoor = prefersFrontDoor
        readServers = servers; readFrontDoor = frontDoor; readFleet = fleet; testConnection = test; self.testFrontDoor = testFrontDoor; self.detect = detect
    }
    var selected: ServerInfo? { servers.first { $0.id == selectedID } }
    /// The front door is the chosen target for any Front Door-compatible client.
    var selectedFrontDoor: WireEndpoint? { client.supportsFrontDoor && selectedID == Self.frontDoorID ? frontDoor : nil }
    var supported: Bool { selectedFrontDoor != nil || (selected.map { !client.requiresGateway || $0.jit == true } ?? false) }
    var plan: ClientEditPlan? { wiring.plans.first { $0.clientID == client.rawValue } }
    /// Where setup writes this client's config, at its real location.
    var configPath: String? { wiring.setupClients.first { $0.clientID == client.rawValue }?.configPath }
    var choseConfigFolder: Bool { wiring.configDirectory(for: client.rawValue) != nil }

    /// Use `path` as this client's config folder, or its standard location for nil.
    func chooseConfigFolder(_ path: String?) {
        guard !busy else { return }
        wiring.setConfigDirectory(path, for: client.rawValue)
        reset()
    }

    func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            servers = try await readServers().filter { WireEndpoint(server: $0) != nil }
            try Task.checkCancellation()
            frontDoor = await readFrontDoor()
            if prefersFrontDoor, client.supportsFrontDoor, frontDoor != nil {
                selectedID = Self.frontDoorID; initialServer = nil
            } else if selectedID == Self.frontDoorID, selectedFrontDoor == nil { selectedID = servers.first?.id }
            prefersFrontDoor = false
            if let expected = initialServer {
                selectedID = servers.first { $0.sameProcess(as: expected) }?.id
                if selectedID == nil { error = "This endpoint changed or stopped. Choose a running endpoint." }
                initialServer = nil
            } else if selectedID == nil {
                if client == .opencode, let fleet = readFleet(), fleet.roleDefaults?.coding != nil {
                    if let slot = fleet.defaultSlot(for: .coding) {
                        let matches = servers.filter {
                            $0.port == slot.port && $0.jit == true && $0.apiKeySHA256 == slot.apiKeySHA256 &&
                            $0.matchesUnadaptedModel(slot.modelPath) && (slot.splashPresetName == nil || $0.runtime == "splash")
                        }
                        if matches.count == 1 { selectedID = matches[0].id; error = nil }
                    }
                    if selectedID == nil { error = "The Coding default is unavailable. Choose a running endpoint or update Serving defaults." }
                } else {
                    selectedID = servers.first?.id ?? (client.supportsFrontDoor && frontDoor != nil ? Self.frontDoorID : nil)
                }
            }
            appFound = await detect(client)
        } catch { self.error = AppHost.render(error) }
    }
    func choose(client: ServingClient) {
        guard !busy else { return }
        activeTask?.cancel()
        self.client = client; reset(); appFound = nil
        if selectedID == Self.frontDoorID, !client.supportsFrontDoor { selectedID = servers.first?.id }
        activeTask = Task { [weak self] in
            guard let self else { return }
            let found = await detect(client)
            guard !Task.isCancelled else { return }
            if self.client == client { appFound = found }
        }
    }
    func choose(serverID: String?) { guard !busy else { return }; selectedID = serverID; reset() }
    func back() { guard !busy else { return }; reset() }
    private func reset() { stage = .choose; error = nil; result = nil; reviewed = nil; reviewedFrontDoor = nil; hash = nil; receipt = nil; transactionID = nil }
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
        guard !busy, supported else { return }
        if let door = selectedFrontDoor { return await preview(frontDoor: door) }
        guard let selected else { return }
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
    private func preview(frontDoor door: WireEndpoint) async {
        busy = true; error = nil; defer { busy = false }
        do {
            guard let current = await readFrontDoor(), current.baseURL == door.baseURL,
                  current.apiKeySHA256 == door.apiKeySHA256 else { throw changedFrontDoor() }
            frontDoor = current
            await wiring.preview(frontDoor: current, clientIDs: [client.rawValue])
            guard wiring.previewMatches(frontDoor: current), wiring.plans.count == 1, let hash = wiring.previewHash else {
                throw WorkflowEvidenceError.invalid(wiring.lastError ?? "Setup could not be prepared. Review this client’s configuration.")
            }
            self.hash = hash; reviewedFrontDoor = current; stage = .review
        } catch { self.error = AppHost.render(error) }
    }
    func apply() async {
        guard !busy, let hash else { return }
        if let door = reviewedFrontDoor {
            busy = true; error = nil; defer { busy = false }
            finish(await wiring.confirm(frontDoor: door, previewHash: hash, current: readFrontDoor))
            return
        }
        guard let reviewed else { return }
        busy = true; error = nil; defer { busy = false }
        finish(await wiring.confirm(server: reviewed, previewHash: hash, currentServers: readServers))
    }
    private func finish(_ transaction: WiringTransaction?) {
        guard let transaction, transaction.failures.isEmpty, transaction.receipts.count == 1,
              let receipt = transaction.receipts.first, receipt.clientID == client.rawValue else {
            error = wiring.lastError ?? "The configuration was not applied. Review setup again."; return
        }
        self.receipt = receipt; transactionID = transaction.id; stage = .saved
        if let failure = wiring.persistenceError { error = failure }
    }
    func test() async {
        if let door = reviewedFrontDoor { return await test(frontDoor: door) }
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
    private func test(frontDoor door: WireEndpoint) async {
        guard !busy, stage == .saved, let receipt else { return }
        busy = true; error = nil; result = nil; defer { busy = false }
        do {
            guard await wiring.matchesAppliedConfig(receipt, endpoint: door) else { throw changedConfig() }
            let key = try await wiring.inferenceKey(frontDoor: door, current: readFrontDoor)
            let response = try await testFrontDoor(client, door, key)
            try Task.checkCancellation()
            guard await readFrontDoor() == door else { throw changedFrontDoor() }
            guard await wiring.matchesAppliedConfig(receipt, endpoint: door) else { throw changedConfig() }
            result = response
        } catch { self.error = error is CancellationError ? "Connection test stopped." : AppHost.render(error) }
    }
    private func changedFrontDoor() -> WorkflowEvidenceError {
        .invalid("The Workbench API changed or stopped. Refresh and review setup again.")
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
