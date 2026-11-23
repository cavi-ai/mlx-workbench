import Foundation

/// Supported Quick Connect snippet formats for local serving endpoints and Front Door.
enum QuickConnectFormat: String, CaseIterable, Identifiable, Sendable {
    case curlChat = "curl-chat"
    case curlResponses = "curl-responses"
    case curlAnthropic = "curl-anthropic"
    case curlEmbeddings = "curl-embeddings"
    case pythonOpenAI = "python-openai"
    case pythonAnthropic = "python-anthropic"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curlChat: return "curl · Chat"
        case .curlResponses: return "curl · Responses"
        case .curlAnthropic: return "curl · Anthropic"
        case .curlEmbeddings: return "curl · Embeddings"
        case .pythonOpenAI: return "Python · OpenAI"
        case .pythonAnthropic: return "Python · Anthropic"
        }
    }

    var shortTitle: String {
        switch self {
        case .curlChat: return "curl"
        case .curlResponses: return "Responses"
        case .curlAnthropic: return "Anthropic curl"
        case .curlEmbeddings: return "Embeddings"
        case .pythonOpenAI: return "OpenAI SDK"
        case .pythonAnthropic: return "Anthropic SDK"
        }
    }

    var language: String {
        switch self {
        case .curlChat, .curlResponses, .curlAnthropic, .curlEmbeddings:
            return "bash"
        case .pythonOpenAI, .pythonAnthropic:
            return "python"
        }
    }
}

/// Pure, secret-free description of a running endpoint or Front Door route.
/// Only records whether an API key is required; never holds or reads raw Keychain tokens.
struct QuickConnectTarget: Equatable, Hashable, Sendable {
    let baseURL: String
    let modelID: String
    let requiresAPIKey: Bool
    let isFrontDoor: Bool
    let supportsChat: Bool
    let supportsResponses: Bool
    let supportsAnthropic: Bool
    let supportsEmbeddings: Bool
    let statusLabel: String

    init(
        baseURL: String,
        modelID: String,
        requiresAPIKey: Bool = false,
        isFrontDoor: Bool = false,
        supportsChat: Bool = true,
        supportsResponses: Bool = false,
        supportsAnthropic: Bool = false,
        supportsEmbeddings: Bool = false,
        statusLabel: String = "Running"
    ) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.requiresAPIKey = requiresAPIKey
        self.isFrontDoor = isFrontDoor
        self.supportsChat = supportsChat
        self.supportsResponses = supportsResponses
        self.supportsAnthropic = supportsAnthropic
        self.supportsEmbeddings = supportsEmbeddings
        self.statusLabel = statusLabel
    }

    static func hasEmbeddingsTaskKind(_ taskKinds: [String]?) -> Bool {
        guard let taskKinds else { return false }
        return taskKinds.contains { kind in
            let lowered = kind.lowercased()
            return lowered == "embeddings" || lowered == "embedding" || lowered == "embed"
        }
    }

    static func statusLabel(for server: ServerInfo) -> String {
        if (server.activeRequests ?? 0) > 0 { return "Busy" }
        switch server.modelState?.lowercased() {
        case "loaded": return "Loaded"
        case "unloaded": return "Ready on request"
        case "loading": return "Loading"
        case "unloading": return "Unloading"
        case "failed": return "Needs attention"
        default: return server.state?.lowercased() == "running" ? "Running" : "Stopped"
        }
    }

    /// Build a direct endpoint target from a running ServerInfo.
    static func direct(server: ServerInfo, baseURL: String? = nil) -> QuickConnectTarget? {
        guard let url = baseURL ?? server.port.map({ "http://127.0.0.1:\($0)/v1" }),
              !url.isEmpty,
              !server.modelIdentity.isEmpty else {
            return nil
        }
        let embeddings = hasEmbeddingsTaskKind(server.taskKinds)
        let chat = server.supportsChatCompletions
        let gateway = chat && server.jit == true
        return QuickConnectTarget(
            baseURL: url,
            modelID: server.modelIdentity,
            requiresAPIKey: server.apiKeySHA256 != nil,
            isFrontDoor: false,
            supportsChat: chat,
            supportsResponses: gateway,
            supportsAnthropic: gateway,
            supportsEmbeddings: embeddings,
            statusLabel: statusLabel(for: server)
        )
    }

    /// Build a direct endpoint target from a saved EndpointSlot and optional live ServerInfo.
    static func direct(slot: EndpointSlot, server: ServerInfo? = nil) -> QuickConnectTarget {
        let modelID = server?.modelIdentity ?? slot.modelPath
        let embeddings = hasEmbeddingsTaskKind(server?.taskKinds)
        let chat = server?.supportsChatCompletions ?? true
        let gateway = chat && ((server?.jit ?? slot.usesJIT) == true)
        let status = server.map(statusLabel(for:)) ?? (slot.enabled ? "Starting" : "Saved")
        return QuickConnectTarget(
            baseURL: "http://127.0.0.1:\(slot.port)/v1",
            modelID: modelID,
            requiresAPIKey: (server?.apiKeySHA256 ?? slot.apiKeySHA256) != nil,
            isFrontDoor: false,
            supportsChat: chat,
            supportsResponses: gateway,
            supportsAnthropic: gateway,
            supportsEmbeddings: embeddings,
            statusLabel: status
        )
    }

    /// Build a Front Door target from an active FrontDoorListener.
    static func frontDoor(_ listener: FrontDoorListener, modelID: String? = nil) -> QuickConnectTarget? {
        let route: FrontDoorRoute?
        if let modelID, !modelID.isEmpty {
            route = listener.routes.first(where: { $0.id == modelID }) ?? FrontDoorRoute(id: modelID)
        } else {
            route = listener.routes.first(where: { $0.isChat }) ?? listener.routes.first
        }
        guard let selected = route else { return nil }
        let embeddings = hasEmbeddingsTaskKind(selected.taskKinds)
        let chat = selected.isChat
        return QuickConnectTarget(
            baseURL: listener.apiBase,
            modelID: selected.id,
            requiresAPIKey: true,
            isFrontDoor: true,
            supportsChat: chat,
            supportsResponses: chat,
            supportsAnthropic: chat,
            supportsEmbeddings: embeddings,
            statusLabel: "Front door"
        )
    }

    /// Build a Front Door target from saved FrontDoorSettings and a routed model ID.
    static func frontDoor(
        settings: FrontDoorSettings,
        modelID: String,
        taskKinds: [String] = [],
        statusLabel: String = "Front door"
    ) -> QuickConnectTarget {
        let embeddings = hasEmbeddingsTaskKind(taskKinds)
        let chat = taskKinds.isEmpty
        return QuickConnectTarget(
            baseURL: "http://127.0.0.1:\(settings.port)/v1",
            modelID: modelID,
            requiresAPIKey: true,
            isFrontDoor: true,
            supportsChat: chat,
            supportsResponses: chat,
            supportsAnthropic: chat,
            supportsEmbeddings: embeddings,
            statusLabel: statusLabel
        )
    }
}

/// One generated, copy-ready Quick Connect snippet.
struct QuickConnectSnippet: Equatable, Identifiable, Sendable {
    let format: QuickConnectFormat
    let title: String
    let language: String
    let code: String

    var id: String { format.rawValue }
}

/// Pure, Sendable Quick Connect snippet generator.
/// Never reads Keychain or embeds raw secrets; protected endpoints always reference MLX_AGENT_API_KEY.
enum QuickConnectSnippets: Sendable {
    static let apiKeyEnvVar = "MLX_AGENT_API_KEY"

    /// Deterministic POSIX single-quote shell escaping.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Safe double-quoted Python string literal escaping backslashes, quotes, and control characters.
    static func pythonStringLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped.append(String(format: "\\u%04x", scalar.value))
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped.append("\"")
        return escaped
    }

    /// Normalize a base URL so it ends with /v1 without a trailing slash.
    static func normalizedV1BaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/v1") { return trimmed }
        return trimmed + "/v1"
    }

    /// Normalize a base URL to its root origin (without trailing /v1 or /), as expected by Anthropic SDKs.
    static func normalizedRootBaseURL(_ raw: String) -> String {
        let v1 = normalizedV1BaseURL(raw)
        if v1.hasSuffix("/v1") {
            return String(v1.dropLast(3))
        }
        return v1
    }

    /// Ordered snippet formats supported by target.
    static func availableFormats(for target: QuickConnectTarget) -> [QuickConnectFormat] {
        var formats: [QuickConnectFormat] = []
        if target.supportsChat {
            formats.append(.curlChat)
            if target.supportsResponses {
                formats.append(.curlResponses)
            }
            if target.supportsAnthropic {
                formats.append(.curlAnthropic)
            }
        }
        if target.supportsEmbeddings {
            formats.append(.curlEmbeddings)
        }
        if target.supportsChat || target.supportsEmbeddings {
            formats.append(.pythonOpenAI)
        }
        if target.supportsChat && target.supportsAnthropic {
            formats.append(.pythonAnthropic)
        }
        return formats
    }

    /// Generate all supported snippets for target.
    static func snippets(for target: QuickConnectTarget) -> [QuickConnectSnippet] {
        availableFormats(for: target).map { snippet(for: target, format: $0) }
    }

    /// Generate a single snippet for target and format.
    static func snippet(for target: QuickConnectTarget, format: QuickConnectFormat) -> QuickConnectSnippet {
        let code: String
        switch format {
        case .curlChat:
            code = curlChat(for: target)
        case .curlResponses:
            code = curlResponses(for: target)
        case .curlAnthropic:
            code = curlAnthropic(for: target)
        case .curlEmbeddings:
            code = curlEmbeddings(for: target)
        case .pythonOpenAI:
            code = pythonOpenAI(for: target)
        case .pythonAnthropic:
            code = pythonAnthropic(for: target)
        }
        return QuickConnectSnippet(format: format, title: format.title, language: format.language, code: code)
    }

    static func curlChat(for target: QuickConnectTarget) -> String {
        let url = normalizedV1BaseURL(target.baseURL) + "/chat/completions"
        let payload: [String: Any] = [
            "model": target.modelID,
            "messages": [
                ["role": "user", "content": "Hello from MLX Workbench"]
            ]
        ]
        return curlCommand(
            url: url,
            headers: openAIHeaders(requiresAPIKey: target.requiresAPIKey),
            payload: payload
        )
    }

    static func curlResponses(for target: QuickConnectTarget) -> String {
        let url = normalizedV1BaseURL(target.baseURL) + "/responses"
        let payload: [String: Any] = [
            "model": target.modelID,
            "input": "Hello from MLX Workbench"
        ]
        return curlCommand(
            url: url,
            headers: openAIHeaders(requiresAPIKey: target.requiresAPIKey),
            payload: payload
        )
    }

    static func curlAnthropic(for target: QuickConnectTarget) -> String {
        let url = normalizedV1BaseURL(target.baseURL) + "/messages"
        let payload: [String: Any] = [
            "model": target.modelID,
            "max_tokens": 256,
            "messages": [
                ["role": "user", "content": "Hello from MLX Workbench"]
            ]
        ]
        var headers = [
            "-H 'Content-Type: application/json'",
            "-H 'anthropic-version: 2023-06-01'"
        ]
        if target.requiresAPIKey {
            headers.append("-H \"x-api-key: $" + "{" + "\(apiKeyEnvVar)" + "}\"")
        }
        return curlCommand(url: url, headers: headers, payload: payload)
    }

    static func curlEmbeddings(for target: QuickConnectTarget) -> String {
        let url = normalizedV1BaseURL(target.baseURL) + "/embeddings"
        let payload: [String: Any] = [
            "model": target.modelID,
            "input": "Hello from MLX Workbench"
        ]
        return curlCommand(
            url: url,
            headers: openAIHeaders(requiresAPIKey: target.requiresAPIKey),
            payload: payload
        )
    }

    static func pythonOpenAI(for target: QuickConnectTarget) -> String {
        let baseURL = pythonStringLiteral(normalizedV1BaseURL(target.baseURL))
        let model = pythonStringLiteral(target.modelID)
        let apiKeyExpr = target.requiresAPIKey
            ? "os.environ[\"\(apiKeyEnvVar)\"]"
            : "os.environ.get(\"\(apiKeyEnvVar)\", \"local\")"

        if target.supportsEmbeddings && !target.supportsChat {
            return """
            import os
            from openai import OpenAI

            client = OpenAI(
                base_url=\(baseURL),
                api_key=\(apiKeyExpr),
            )
            response = client.embeddings.create(
                model=\(model),
                input="Hello from MLX Workbench",
            )
            print(len(response.data[0].embedding))
            """
        }

        return """
        import os
        from openai import OpenAI

        client = OpenAI(
            base_url=\(baseURL),
            api_key=\(apiKeyExpr),
        )
        response = client.chat.completions.create(
            model=\(model),
            messages=[{"role": "user", "content": "Hello from MLX Workbench"}],
        )
        print(response.choices[0].message.content)
        """
    }

    static func pythonAnthropic(for target: QuickConnectTarget) -> String {
        let baseURL = pythonStringLiteral(normalizedRootBaseURL(target.baseURL))
        let model = pythonStringLiteral(target.modelID)
        let apiKeyExpr = target.requiresAPIKey
            ? "os.environ[\"\(apiKeyEnvVar)\"]"
            : "os.environ.get(\"\(apiKeyEnvVar)\", \"local\")"

        return """
        import os
        from anthropic import Anthropic

        client = Anthropic(
            base_url=\(baseURL),
            api_key=\(apiKeyExpr),
        )
        message = client.messages.create(
            model=\(model),
            max_tokens=256,
            messages=[{"role": "user", "content": "Hello from MLX Workbench"}],
        )
        print(message.content[0].text)
        """
    }

    // MARK: - Helpers

    private static func openAIHeaders(requiresAPIKey: Bool) -> [String] {
        var headers = ["-H 'Content-Type: application/json'"]
        if requiresAPIKey {
            headers.append("-H \"Authorization: Bearer $" + "{" + "\(apiKeyEnvVar)" + "}\"")
        }
        return headers
    }

    private static func curlCommand(url: String, headers: [String], payload: [String: Any]) -> String {
        let json = encodeJSON(payload)
        var lines = ["curl -sS \(shellQuote(url)) \\"]
        for header in headers {
            lines.append("  \(header) \\")
        }
        lines.append("  -d \(shellQuote(json))")
        return lines.joined(separator: "\n")
    }

    private static func encodeJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
