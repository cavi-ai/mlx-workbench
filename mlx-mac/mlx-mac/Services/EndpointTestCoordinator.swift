import Foundation

struct EndpointTestPresentation: Identifiable {
    let id = UUID()
    let server: ServerInfo
}

struct EndpointTestClient: Sendable {
    var servers: @Sendable () async throws -> [ServerInfo]
    var ask: @Sendable (ServerInfo, String, Int) async throws -> ProbeSample

    static func live(api: WorkbenchAPI) -> Self {
        Self(servers: { try await api.serveStatus() }, ask: { server, prompt, limit in
            guard EndpointTestCoordinator.supports(server), let port = server.port,
                  let url = URL(string: "http://127.0.0.1:\(port)") else { throw EndpointTestError.changed }
            let session = HostHTTPClient.session()
            defer { session.invalidateAndCancel() }
            return try await OpenAIEndpointProber(session: session, requestTimeout: 120,
                maximumResponseBytes: 1_048_576, maximumLineBytes: 65_536)
                .chat(baseURL: url, model: server.modelIdentity, prompt: prompt, maxTokens: limit)
        })
    }
}

private enum EndpointTestError: LocalizedError {
    case changed, occupied
    var errorDescription: String? {
        switch self {
        case .changed: "The endpoint changed or is unavailable. Close this window and choose Try a prompt from Run again."
        case .occupied: "Wait for model operations to finish and refresh serving status before sending a prompt."
        }
    }
}

/// One transient prompt against an explicitly selected running process. No server lifecycle or history writes.
@MainActor
final class EndpointTestCoordinator: ObservableObject {
    @Published private(set) var isSending = false
    @Published private(set) var activeServer: ServerInfo?
    @Published private(set) var sample: ProbeSample?
    @Published private(set) var error: String?
    @Published private(set) var presentationID: UUID?
    var canUseServer: (ServerInfo) -> Bool = { _ in true }
    private let client: EndpointTestClient
    private var task: Task<Void, Never>?
    private var discardResult = false

    init(client: EndpointTestClient) { self.client = client }
    deinit { task?.cancel() }

    nonisolated static func supports(_ server: ServerInfo) -> Bool {
        server.state?.lowercased() == "running" && (server.pid ?? 0) > 0
            && (1...65535).contains(server.port ?? 0)
            && !server.modelIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func promptError(_ prompt: String) -> String? {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "Enter a prompt." }
        return value.count > 4000 ? "Keep the prompt to 4,000 characters or fewer." : nil
    }

    nonisolated static func outcome(_ sample: ProbeSample) -> String {
        if sample.finishReason == "length" { return "Token limit reached" }
        if sample.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No answer text returned" }
        return sample.finishReason == "stop" ? "Answer returned" : "Completion not confirmed"
    }

    /// Synchronous ownership prevents dismissal between a Send click and task creation.
    @discardableResult
    func send(to server: ServerInfo, prompt: String, presentationID: UUID? = nil) -> Task<Void, Never>? {
        guard self.presentationID == presentationID, !isSending else { return nil }
        reset(presentationID: presentationID)
        if let reason = Self.promptError(prompt) { error = reason; return nil }
        guard Self.supports(server) else { error = EndpointTestError.changed.localizedDescription; return nil }
        guard canUseServer(server) else { error = EndpointTestError.occupied.localizedDescription; return nil }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        activeServer = server
        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(server: server, prompt: text)
        }
        return task
    }

    private func perform(server: ServerInfo, prompt: String) async {
        defer { isSending = false; activeServer = nil; task = nil }
        do {
            try Task.checkCancellation()
            try await checkIdentity(server)
            guard canUseServer(server) else { throw EndpointTestError.occupied }
            let result = try await client.ask(server, prompt, 256)
            try Task.checkCancellation()
            try await checkIdentity(server)
            if !discardResult { sample = result }
        } catch {
            guard !discardResult else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.error = "Stopped waiting. The server may still be finishing the request."
            } else { self.error = error.localizedDescription }
        }
    }

    private func checkIdentity(_ expected: ServerInfo) async throws {
        let servers = try await client.servers()
        try Task.checkCancellation()
        let candidates = servers.filter { $0.port == expected.port }
        guard candidates.count == 1, let current = candidates.first,
              Self.supports(current), expected.sameProcess(as: current) else {
            throw EndpointTestError.changed
        }
    }

    func cancel(presentationID: UUID? = nil) {
        guard self.presentationID == presentationID else { return }
        task?.cancel()
    }

    func open(_ server: ServerInfo) -> EndpointTestPresentation? {
        guard presentationID == nil, !isSending, Self.supports(server) else { return nil }
        reset()
        let presentation = EndpointTestPresentation(server: server)
        presentationID = presentation.id
        return presentation
    }

    func close(presentationID: UUID? = nil) {
        guard self.presentationID == presentationID else { return }
        self.presentationID = nil
        discardResult = true
        sample = nil
        error = nil
        cancel()
    }

    func reset(presentationID: UUID? = nil) {
        guard self.presentationID == presentationID, !isSending else { return }
        discardResult = false
        sample = nil
        error = nil
    }
}
