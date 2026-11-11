import CryptoKit
import Foundation

typealias UseStreamUpdate = @Sendable (String, String) async throws -> Void

struct UseChatClient: Sendable {
    var prepare: @Sendable (ServerInfo) async throws -> String?
    var assertCurrent: @Sendable (ServerInfo) async throws -> Void
    var stream: @Sendable (ServerInfo, [[String: JSONValue]], UseRequestDefaults, String?, @escaping UseStreamUpdate) async throws -> ProbeSample

    static func supports(_ server: ServerInfo) -> Bool {
        server.supportsChatCompletions && server.state == "running" && (server.pid ?? 0) > 0
            && (1...65535).contains(server.port ?? 0) && server.path?.hasPrefix("/") == true
            && server.receiptsDirectory?.hasPrefix("/") == true
            && !(server.processStartedAt?.isEmpty ?? true) && !(server.startedAt?.isEmpty ?? true)
            && server.receipt == URL(fileURLWithPath: server.receiptsDirectory ?? "")
                .appendingPathComponent(".mlx-agent-receipts/serve/\(server.port ?? 0).json").path
    }
    static func supportsImages(_ server: ServerInfo?) -> Bool { server?.runtime == "mlx-vlm" }
    static func matches(_ server: ServerInfo, modelPath: String) -> Bool {
        guard let path = server.path else { return false }
        return Quarantine.resolve(path) == Quarantine.resolve(modelPath)
    }
    static func live(api: WorkbenchAPI) -> Self {
        let check: @Sendable (ServerInfo) async throws -> Void = { expected in
            guard supports(expected), let directory = expected.receiptsDirectory else { throw UseSessionError.noEndpoint }
            let candidates = try await api.serveStatus(receiptsDirectory: directory).filter { $0.port == expected.port }
            guard candidates.count == 1, let current = candidates.first, supports(current),
                  expected.sameProcess(as: current), expected.path == current.path,
                  expected.receiptsDirectory == current.receiptsDirectory else { throw UseSessionError.changed }
            try Task.checkCancellation()
        }
        return Self(prepare: { server in
            try await check(server)
            let token: String?
            if let hash = server.apiKeySHA256 {
                let value = try await Task.detached(priority: .utility) { try EndpointCredentialStore.token(for: hash) }.value
                guard SHA256.hash(data: Data(value.utf8)).map({ String(format: "%02x", $0) }).joined() == hash else { throw UseSessionError.changed }
                token = value
            } else { token = nil }
            let host = ModelHost(name: "Chat", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port!)")
            let data = try await HostHTTPClient().request(host: host, path: "/v1/models", token: token, maximumBytes: 1_048_576, timeout: 10)
            struct Inventory: Decodable { let data: [Model] }
            struct Model: Decodable { let id: String }
            let inventory = try JSONDecoder().decode(Inventory.self, from: data)
            guard inventory.data.contains(where: { $0.id == server.modelIdentity || $0.id == server.path }) else { throw UseSessionError.changed }
            return token
        }, assertCurrent: check, stream: { server, messages, settings, token, update in
            let session = HostHTTPClient.session()
            defer { session.invalidateAndCancel() }
            return try await OpenAIEndpointProber(session: session, requestTimeout: 120, bearerToken: token,
                maximumResponseBytes: 8_388_608, maximumLineBytes: 1_048_576)
                .conversation(baseURL: URL(string: "http://127.0.0.1:\(server.port!)")!, model: server.path!,
                              messages: messages, settings: settings, onUpdate: update)
        })
    }
}

struct UseChatRequest {
    static func messages(session: UseSession, prompt: String, images: [UseImage], inputs: UseImageStore,
                         server: ServerInfo) async throws -> [[String: JSONValue]] {
        try session.settings.validate()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32768 else { throw UseSessionError.history }
        let prior = session.turns.filter { $0.state.suppliesContext }
        let imageBytes = (prior.flatMap(\.images) + images).reduce(0) { $0 + $1.bytes }
        guard imageBytes <= 8_388_608 else { throw UseSessionError.requestTooLarge }
        guard imageBytes == 0 || UseChatClient.supportsImages(server) else { throw UseSessionError.imageUnsupported }
        var messages: [[String: JSONValue]] = []
        if !session.settings.systemPrompt.isEmpty { messages.append(["role": .string("system"), "content": .string(session.settings.systemPrompt)]) }
        for turn in prior {
            messages.append(try await userMessage(turn.prompt, turn.images, inputs: inputs))
            messages.append(["role": .string("assistant"), "content": .string(turn.answer)])
        }
        messages.append(try await userMessage(prompt, images, inputs: inputs))
        return messages
    }
    private static func userMessage(_ text: String, _ images: [UseImage], inputs: UseImageStore) async throws -> [String: JSONValue] {
        if images.isEmpty { return ["role": .string("user"), "content": .string(text)] }
        var parts: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for image in images {
            parts.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string(try await inputs.dataURL(image))])]))
        }
        return ["role": .string("user"), "content": .array(parts)]
    }
}
