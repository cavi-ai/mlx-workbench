import Foundation
import Darwin

// MARK: - ServeProbe
//
// Shared harness for the Conversion Quality Gate (and later Measured
// Comparisons): serve one model on an ephemeral loopback port through the
// existing mlx-agent preview/confirm flow, probe it over the OpenAI-compatible
// HTTP API, and always stop the server afterwards. No new mlx-agent
// subcommands; serving stays inside the argv boundary.

struct ProbeSample: Equatable, Sendable {
    let text: String
    let completionTokens: Int?
    /// Prompt tokens as reported by the server's usage block, when present.
    let promptTokens: Int?
    let timeToFirstTokenSeconds: Double?
    let durationSeconds: Double
    /// True when `completionTokens` was estimated from text length because
    /// the server did not report usage.
    let metricsEstimated: Bool
    /// Number of tool calls the model emitted, when the prompt carried tool
    /// definitions. Nil when no tools were offered.
    let toolCalls: Int?
    /// Names of the tools the model called, in order.
    let toolNames: [String]?

    init(
        text: String,
        completionTokens: Int?,
        promptTokens: Int? = nil,
        timeToFirstTokenSeconds: Double?,
        durationSeconds: Double,
        metricsEstimated: Bool,
        toolCalls: Int? = nil,
        toolNames: [String]? = nil
    ) {
        self.text = text
        self.completionTokens = completionTokens
        self.promptTokens = promptTokens
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.durationSeconds = durationSeconds
        self.metricsEstimated = metricsEstimated
        self.toolCalls = toolCalls
        self.toolNames = toolNames
    }

    /// Prompt-processing speed estimated as prompt tokens over TTFT. TTFT
    /// includes queueing and first decode, so this is a lower bound — the UI
    /// labels it as an estimate.
    var prefillTokensPerSecond: Double? {
        guard let promptTokens, promptTokens > 0,
              let ttft = timeToFirstTokenSeconds, ttft > 0 else { return nil }
        return Double(promptTokens) / ttft
    }
}

/// A tool definition offered during a probe. The parameters schema stays
/// JSON text so prompt-set persistence remains schema-stable.
struct PromptToolSpec: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let parametersJSON: String

    /// The OpenAI `tools` payload fragment for this spec. Nil when the
    /// parameters JSON is unreadable — the caller then drops the tool.
    var openAITool: [String: Any]? {
        guard let data = parametersJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": schema,
            ],
        ]
    }
}

struct ProbeRunResult: Equatable, Sendable {
    let port: Int
    /// Prompt id → sample. Guaranteed to contain every requested prompt id.
    let samples: [String: ProbeSample]
}

/// One prompt to send through a probed endpoint. The canary suite and
/// comparison prompt sets both reduce to this.
struct ProbePrompt: Equatable, Sendable {
    let id: String
    let prompt: String
    let maxTokens: Int
    /// When set, the probe offers this tool and records what the model calls.
    var tool: PromptToolSpec? = nil
}

protocol EndpointProbing: Sendable {
    func isReady(baseURL: URL) async -> Bool
    func listModels(baseURL: URL) async -> [String]
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample
    /// Tool-aware variant. The default drops the tool so older fakes and
    /// conformers keep working unchanged.
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int, tool: PromptToolSpec?) async throws -> ProbeSample
}

extension EndpointProbing {
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int, tool: PromptToolSpec?) async throws -> ProbeSample {
        try await chat(baseURL: baseURL, model: model, prompt: prompt, maxTokens: maxTokens)
    }
}

enum ServeProbeError: LocalizedError {
    case noEphemeralPort
    case servePreviewMissingHash
    case serverNeverReady(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noEphemeralPort:
            return "Could not reserve an ephemeral loopback port for the verification server."
        case .servePreviewMissingHash:
            return "The serve preview did not include a preview hash."
        case .serverNeverReady(let timeout):
            return "The verification server did not become ready within \(Int(timeout)) seconds."
        }
    }
}

/// Injectable serve lifecycle so tests never touch mlx-agent or the network.
struct ServeLifecycle: Sendable {
    var preview: @Sendable (_ modelPath: String, _ port: Int) async throws -> String
    var start: @Sendable (_ modelPath: String, _ port: Int, _ previewHash: String) async throws -> Void
    var stop: @Sendable (_ port: Int) async throws -> Void
}

extension ServeLifecycle {
    /// Production lifecycle: mlx-agent serve preview/start/stop, runtime mlx.
    static func live(api: WorkbenchAPI, runtime: String = "mlx") -> ServeLifecycle {
        ServeLifecycle(
            preview: { modelPath, port in
                let response = try await api.servePreview(repo: modelPath, runtime: runtime, port: port)
                return response.string("preview_hash") ?? ""
            },
            start: { modelPath, port, previewHash in
                _ = try await api.serveStart(repo: modelPath, runtime: runtime, port: port, previewHash: previewHash)
            },
            stop: { port in
                _ = try await api.serveStop(port: port)
            }
        )
    }
}

struct ServeProbe: Sendable {
    let lifecycle: ServeLifecycle
    let prober: any EndpointProbing
    var readyTimeout: TimeInterval = 120
    var readyPollIntervalNanoseconds: UInt64 = 1_000_000_000
    var pickPort: @Sendable () -> Int? = EphemeralPort.pick

    /// Serves `modelPath` on an ephemeral loopback port, runs the canary
    /// suite sequentially, and stops the server even when a probe throws.
    func run(modelPath: String) async throws -> ProbeRunResult {
        try await run(modelPath: modelPath, prompts: CanarySuite.cases.map {
            ProbePrompt(id: $0.id, prompt: $0.prompt, maxTokens: $0.maxTokens)
        })
    }

    /// Serves `modelPath` on an ephemeral loopback port, runs `prompts`
    /// sequentially, and stops the server even when a probe throws.
    func run(modelPath: String, prompts: [ProbePrompt]) async throws -> ProbeRunResult {
        guard let port = pickPort() else { throw ServeProbeError.noEphemeralPort }
        let hash = try await lifecycle.preview(modelPath, port)
        guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
        try await lifecycle.start(modelPath, port, hash)

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        do {
            guard await waitUntilReady(baseURL: baseURL) else {
                throw ServeProbeError.serverNeverReady(timeout: readyTimeout)
            }
            let modelID = await resolveModelID(baseURL: baseURL, modelPath: modelPath)
            var samples: [String: ProbeSample] = [:]
            for prompt in prompts {
                try Task.checkCancellation()
                samples[prompt.id] = try await prober.chat(
                    baseURL: baseURL,
                    model: modelID,
                    prompt: prompt.prompt,
                    maxTokens: prompt.maxTokens,
                    tool: prompt.tool
                )
            }
            try? await lifecycle.stop(port)
            return ProbeRunResult(port: port, samples: samples)
        } catch {
            // A crashed probe must never leave an orphan server behind.
            try? await lifecycle.stop(port)
            throw error
        }
    }

    /// The model id the server will accept: the served identity when the
    /// server lists it, else the first listed model, else the identity.
    /// (A bogus model id makes mlx_lm.server try to resolve it against the
    /// Hub — slow failure, or a hang when the network is unhappy.)
    private func resolveModelID(baseURL: URL, modelPath: String) async -> String {
        let identity = HFRepoID.serveIdentity(for: modelPath)
        let listed = await prober.listModels(baseURL: baseURL)
        if listed.contains(identity) { return identity }
        return listed.first ?? identity
    }

    private func waitUntilReady(baseURL: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await prober.isReady(baseURL: baseURL) { return true }
            try? await Task.sleep(nanoseconds: readyPollIntervalNanoseconds)
        }
        return false
    }
}

// MARK: - EphemeralPort

enum EphemeralPort {
    /// Reserve a free loopback port by binding port 0 and reading back the
    /// assignment. There is an inherent race before the server binds it; a
    /// lost race fails loudly at serve start, never silently.
    static func pick() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(fd, rebound, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

// MARK: - OpenAIEndpointProber

enum ProbeHTTPError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The verification server returned HTTP \(code)."
        case .invalidResponse:
            return "The verification server returned an unreadable response."
        }
    }
}

/// Live prober against an mlx_lm.server OpenAI-compatible endpoint.
/// Streaming is used so time-to-first-token is measured honestly; when the
/// server omits usage, token counts are estimated and flagged as such.
struct OpenAIEndpointProber: EndpointProbing {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    init(session: URLSession = .shared, requestTimeout: TimeInterval = 180) {
        self.session = session
        self.requestTimeout = requestTimeout
    }

    func isReady(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 5
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    func listModels(baseURL: URL) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 5
        guard let result = try? await session.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["id"] as? String }
    }

    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        try await chat(baseURL: baseURL, model: model, prompt: prompt, maxTokens: maxTokens, tool: nil)
    }

    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int, tool: PromptToolSpec?) async throws -> ProbeSample {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let tool, let openAITool = tool.openAITool {
            body["tools"] = [openAITool]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startedAt = Date()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProbeHTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProbeHTTPError.httpStatus(http.statusCode) }

        var text = ""
        var completionTokens: Int?
        var promptTokens: Int?
        var firstTokenAt: Date?
        // Streamed tool calls arrive as deltas keyed by index; collect the
        // highest index for the count and names as they stream in.
        var toolCallNamesByIndex: [Int: String] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let usage = chunk["usage"] as? [String: Any] {
                if let count = usage["completion_tokens"] as? Int {
                    completionTokens = count
                }
                if let count = usage["prompt_tokens"] as? Int {
                    promptTokens = count
                }
            }
            if let choices = chunk["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any] {
                // Thinking models (Qwen3 et al.) put output in `reasoning`
                // with empty `content`; both count as the response.
                let piece = (delta["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (delta["reasoning"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let piece {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    text += piece
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let index = call["index"] as? Int ?? 0
                        if let function = call["function"] as? [String: Any],
                           let name = function["name"] as? String, !name.isEmpty {
                            toolCallNamesByIndex[index] = name
                        }
                    }
                }
            }
        }

        let finishedAt = Date()
        let estimated: Bool
        let tokens: Int?
        if let completionTokens {
            tokens = completionTokens
            estimated = false
        } else {
            // Rough chars-per-token estimate; flagged on the sample so reports
            // never present estimates as measurements.
            tokens = text.isEmpty ? nil : max(1, text.count / 4)
            estimated = true
        }
        let toolCalls: Int? = tool == nil ? nil : toolCallNamesByIndex.count
        let toolNames: [String]? = tool == nil
            ? nil
            : toolCallNamesByIndex.sorted { $0.key < $1.key }.map(\.value)
        return ProbeSample(
            text: text,
            completionTokens: tokens,
            promptTokens: promptTokens,
            timeToFirstTokenSeconds: firstTokenAt.map { $0.timeIntervalSince(startedAt) },
            durationSeconds: finishedAt.timeIntervalSince(startedAt),
            metricsEstimated: estimated,
            toolCalls: toolCalls,
            toolNames: toolNames
        )
    }
}
