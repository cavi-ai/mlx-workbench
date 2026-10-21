import Foundation
import Darwin
import CoreFoundation

// MARK: - ServeProbe
//
// Shared harness for the Conversion Quality Gate (and later Measured
// Comparisons): serve one model on an ephemeral loopback port through the
// existing mlx-agent preview/confirm flow, probe it over the OpenAI-compatible
// HTTP API, and always stop the server afterwards. No new mlx-agent
// subcommands; serving stays inside the argv boundary.

struct DraftTokenEvidence: Codable, Equatable, Sendable {
    let offered: Int
    let accepted: Int
    var isValid: Bool { offered >= 0 && accepted >= 0 && accepted <= offered }
    var acceptanceFraction: Double? { isValid && offered > 0 ? Double(accepted) / Double(offered) : nil }

    init?(timings: [String: Any]) {
        guard timings["draft_n"] is NSNumber, timings["draft_n_accepted"] is NSNumber,
              let offered = timings.int("draft_n"), let accepted = timings.int("draft_n_accepted"),
              offered >= 0, accepted >= 0, accepted <= offered else { return nil }
        self.offered = offered; self.accepted = accepted
    }
}

struct PromptProcessingEvidence: Codable, Equatable, Sendable {
    let promptTokens: Int
    let cachedTokens: Int
    let processedTokens: Int
    let processingSeconds: Double

    var isValid: Bool {
        promptTokens > 0 && cachedTokens >= 0 && cachedTokens <= promptTokens
            && processedTokens == promptTokens - cachedTokens && processingSeconds.isFinite && processingSeconds >= 0
    }
    var tokensPerSecond: Double? {
        guard isValid, processedTokens > 0, processingSeconds > 0 else { return nil }
        let rate = Double(processedTokens) / processingSeconds
        return rate.isFinite ? rate : nil
    }

    init?(usage: [String: Any], timings: [String: Any]) {
        guard usage["prompt_tokens"] is NSNumber, timings["cache_n"] is NSNumber, timings["prompt_n"] is NSNumber,
              let total = usage.int("prompt_tokens"), let cached = timings.int("cache_n"), let processed = timings.int("prompt_n"),
              let milliseconds = timings["prompt_ms"] as? NSNumber, CFGetTypeID(milliseconds) != CFBooleanGetTypeID(),
              milliseconds.doubleValue.isFinite, milliseconds.doubleValue >= 0,
              total > 0, cached >= 0, cached <= total, processed == total - cached else { return nil }
        promptTokens = total; cachedTokens = cached; processedTokens = processed
        processingSeconds = milliseconds.doubleValue / 1000
    }
}

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
    /// Of the emitted calls, how many carried arguments that parse as JSON
    /// and contain the offered tool's required keys.
    let toolCallsValid: Int?
    let reasoningText: String?
    let finishReason: String?
    let timeToFirstAnswerSeconds: Double?
    let draftTokens: DraftTokenEvidence?
    let promptProcessing: PromptProcessingEvidence?
    /// Streamed content deltas and the seconds between the first and last one.
    var streamedDeltas: Int? = nil
    var deltaWindowSeconds: Double? = nil

    /// Average spacing below which deltas were delivered in one burst, so their
    /// arrival times say nothing about generation speed.
    static let burstDeltaSpacingSeconds = 0.0005

    /// Completion tokens over decode time (duration after the first token);
    /// nil without usable counts or when the stream arrived in a burst.
    var decodeTokensPerSecond: Double? {
        guard let tokens = completionTokens, tokens > 0 else { return nil }
        if let deltas = streamedDeltas, deltas >= 4, let window = deltaWindowSeconds,
           window / Double(deltas - 1) < Self.burstDeltaSpacingSeconds {
            return nil
        }
        let decodeSeconds = durationSeconds - (timeToFirstTokenSeconds ?? 0)
        guard decodeSeconds > 0 else { return nil }
        return Double(tokens) / decodeSeconds
    }

    init(
        text: String,
        completionTokens: Int?,
        promptTokens: Int? = nil,
        timeToFirstTokenSeconds: Double?,
        durationSeconds: Double,
        metricsEstimated: Bool,
        toolCalls: Int? = nil,
        toolNames: [String]? = nil,
        toolCallsValid: Int? = nil,
        reasoningText: String? = nil,
        finishReason: String? = nil,
        timeToFirstAnswerSeconds: Double? = nil,
        draftTokens: DraftTokenEvidence? = nil,
        promptProcessing: PromptProcessingEvidence? = nil
    ) {
        self.text = text
        self.completionTokens = completionTokens
        self.promptTokens = promptTokens
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.durationSeconds = durationSeconds
        self.metricsEstimated = metricsEstimated
        self.toolCalls = toolCalls
        self.toolNames = toolNames
        self.toolCallsValid = toolCallsValid
        self.reasoningText = reasoningText
        self.finishReason = finishReason
        self.timeToFirstAnswerSeconds = timeToFirstAnswerSeconds
        self.draftTokens = draftTokens
        self.promptProcessing = promptProcessing
    }

    /// Client-side estimate over TTFT, using reported new-token counts when
    /// available. Without cache evidence it uses the whole prompt length.
    var prefillTokensPerSecond: Double? {
        let count = promptProcessing.flatMap { $0.isValid && $0.promptTokens == promptTokens ? $0.processedTokens : nil } ?? promptTokens
        guard let count, count > 0,
              let ttft = timeToFirstTokenSeconds, ttft > 0 else { return nil }
        return Double(count) / ttft
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
        guard let schema = parametersSchema else { return nil }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": schema,
            ],
        ]
    }

    /// Keys the schema marks required; used to judge whether a model's
    /// tool-call arguments are usable, not just parseable.
    var requiredKeys: [String] {
        guard let required = parametersSchema?["required"] as? [String] else { return [] }
        return required
    }

    private var parametersSchema: [String: Any]? {
        guard let data = parametersJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Whether raw tool-call arguments are usable: parse as a JSON object
    /// and contain every required key.
    func argumentsAreValid(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return requiredKeys.allSatisfy { object.keys.contains($0) }
    }
}

struct StrataComparisonOptions: Codable, Equatable, Sendable {
    var speculation = false
    var expertMemoryGB: Double? = nil
    var contextTokens = 131072

    var validationError: String? {
        if let budget = expertMemoryGB, !budget.isFinite || !(0.5...64).contains(budget) {
            return "Expert memory must be from 0.5 to 64 GB."
        }
        return (512...131072).contains(contextTokens) ? nil : "Context must be from 512 to 131072 tokens."
    }
    var isDefault: Bool { !speculation && expertMemoryGB == nil && contextTokens == 131072 }
    var arguments: [String] {
        ["--strata-speculation", speculation ? "on" : "off", "--strata-context-tokens", String(contextTokens)]
            + (expertMemoryGB.map { ["--strata-expert-memory-gb", String($0)] } ?? [])
    }
}

/// Facts from the exact serving preview confirmed for a measured endpoint.
struct ProbeServingEvidence: Codable, Equatable, Sendable {
    let runtime: String
    let previewHash: String
    let weightFormat: String?
    let weightQuantization: String?
    let weightsPreserved: Bool?
    let modelFingerprint: String?
    let runtimeFingerprint: String?
    let speculation: Bool?
    let expertMemoryGB: Double?
    let contextTokens: Int?

    var hasCustomOptions: Bool {
        speculation == true || expertMemoryGB != nil || contextTokens.map { $0 != 131072 } == true
    }

    init?(plan: [String: Any]) {
        guard let runtime = plan["runtime"] as? String, !runtime.isEmpty,
              let hash = plan["preview_hash"] as? String, !hash.isEmpty else { return nil }
        self.runtime = runtime; previewHash = hash
        weightFormat = plan["weight_format"] as? String
        weightQuantization = plan["weight_quantization"] as? String
        weightsPreserved = plan["weights_preserved"] as? Bool
        modelFingerprint = (plan["strata_model_fingerprint"] ?? plan["model_config_fingerprint"]) as? String
        runtimeFingerprint = plan["strata_runtime_fingerprint"] as? String
        speculation = plan["strata_speculation"] as? Bool
        expertMemoryGB = plan["strata_expert_memory_gb"] as? Double
        contextTokens = plan["strata_context_tokens"] as? Int
    }

    var summary: String {
        let title: String = switch runtime {
        case "strata": "Strata · Metal"
        case "mlx_lm": "MLX-LM"
        case "mlx-vlm": "MLX-VLM"
        default: runtime
        }
        return [title, weightFormat?.uppercased(), weightQuantization].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ProbeServePreview: Sendable {
    let hash: String
    var evidence: ProbeServingEvidence? = nil
}

struct ProbeRunResult: Equatable, Sendable {
    let port: Int
    /// Completed prompt samples; cancellation and cleanup errors may carry a partial run.
    let samples: [String: ProbeSample]
    var servingEvidence: ProbeServingEvidence? = nil
    /// Endpoint start through readiness, before warm-up and prompt timing.
    var startupSeconds: Double? = nil
    var systemMemory: SystemMemoryEvidence? = nil
    var ownedServer: ComparisonServerReceipt? = nil
}

struct ServeProbeCancelled: LocalizedError {
    let partial: ProbeRunResult
    var errorDescription: String? { "The comparison was cancelled." }
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
    case stopFailed(String, port: Int? = nil, partial: ProbeRunResult? = nil)
    case serverNeverReady(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noEphemeralPort:
            return "Could not reserve an ephemeral loopback port for the verification server."
        case .stopFailed(let detail, _, _):
            return "Could not stop the comparison server: \(detail). Further variants were not started."
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
    var jitPreview: (@Sendable (_ modelPath: String, _ port: Int, _ policy: EndpointMemoryPolicy?) async throws -> String)? = nil
    var jitStart: (@Sendable (_ modelPath: String, _ port: Int, _ previewHash: String, _ policy: EndpointMemoryPolicy?) async throws -> Void)? = nil
    var unload: (@Sendable (_ port: Int, _ expectedPID: Int) async throws -> Void)? = nil
    var configureMemory: (@Sendable (_ port: Int, _ expectedPID: Int, _ policy: EndpointMemoryPolicy) async throws -> Void)? = nil
    var reviewedPreview: (@Sendable (_ modelPath: String, _ port: Int) async throws -> ProbeServePreview)? = nil
    var startWithReceipt: (@Sendable (_ modelPath: String, _ port: Int, _ previewHash: String) async throws -> ComparisonServerReceipt?)? = nil
}

extension ServeLifecycle {
    /// Production lifecycle: the agent selects the declared loader from local model metadata.
    /// `thinkingOff` serves with the chat template's reasoning switched off (canary verification).
    static func live(api: WorkbenchAPI, runtime: String = "auto", strataOptions: StrataComparisonOptions? = nil,
                     thinkingOff: Bool = false) -> ServeLifecycle {
        ServeLifecycle(
            preview: { modelPath, port in
                let response = try await api.servePreview(repo: modelPath, runtime: runtime, port: port, strataOptions: strataOptions,
                    thinkingOff: thinkingOff)
                return response.string("preview_hash") ?? ""
            },
            start: { modelPath, port, previewHash in
                _ = try await api.serveStart(repo: modelPath, runtime: runtime, port: port, previewHash: previewHash,
                    timeout: runtime == "auto" || runtime == "strata" ? 960 : nil, strataOptions: strataOptions,
                    thinkingOff: thinkingOff)
            },
            stop: { port in
                _ = try await api.serveStop(port: port)
            },
            jitPreview: { modelPath, port, policy in
                let response = try await api.servePreview(repo: modelPath, runtime: runtime, port: port, jit: true, memoryPolicy: policy, strataOptions: strataOptions)
                return response.string("preview_hash") ?? ""
            },
            jitStart: { modelPath, port, hash, policy in
                _ = try await api.serveStart(repo: modelPath, runtime: runtime, port: port, previewHash: hash, jit: true, memoryPolicy: policy, strataOptions: strataOptions)
            },
            unload: { port, pid in
                _ = try await api.serveUnload(port: port, expectedPID: pid)
            },
            configureMemory: { port, pid, policy in
                _ = try await api.serveMemoryPolicy(port: port, expectedPID: pid, policy: policy)
            },
            reviewedPreview: { modelPath, port in
                let plan = try await api.servePreview(repo: modelPath, runtime: runtime, port: port, strataOptions: strataOptions,
                    thinkingOff: thinkingOff)
                return ProbeServePreview(hash: plan.string("preview_hash") ?? "", evidence: ProbeServingEvidence(plan: plan))
            },
            startWithReceipt: { path, port, hash in
                let response = try await api.serveStart(repo: path, runtime: runtime, port: port, previewHash: hash,
                    timeout: runtime == "auto" || runtime == "strata" ? 960 : nil, strataOptions: strataOptions,
                    thinkingOff: thinkingOff)
                return try? ComparisonServerReceipt(response: response, modelPath: path, port: port, previewHash: hash)
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
    /// Opt-in for comparisons; verification and ordinary serving do not sample.
    var memoryProbe: (@Sendable () -> MemorySnapshot?)? = nil
    var expectedServingEvidence: ProbeServingEvidence? = nil

    /// Serves `modelPath` on an ephemeral loopback port, runs the canary
    /// suite sequentially, and stops the server even when a probe throws.
    func run(modelPath: String) async throws -> ProbeRunResult {
        try await run(modelPath: modelPath, prompts: CanarySuite.cases.map {
            ProbePrompt(id: $0.id, prompt: $0.prompt, maxTokens: $0.maxTokens)
        })
    }

    /// Serves `modelPath` on an ephemeral loopback port, runs `prompts`
    /// sequentially, and stops the server even when a probe throws.
    func run(modelPath: String, prompts: [ProbePrompt], warmup: [ProbePrompt] = [], warmEachPrompt: Bool = false,
             onServerStarted: (@Sendable (ComparisonServerReceipt) async throws -> Void)? = nil) async throws -> ProbeRunResult {
        try Task.checkCancellation()
        guard let port = pickPort() else { throw ServeProbeError.noEphemeralPort }
        let preview: ProbeServePreview
        if let reviewedPreview = lifecycle.reviewedPreview {
            preview = try await reviewedPreview(modelPath, port)
        } else {
            preview = ProbeServePreview(hash: try await lifecycle.preview(modelPath, port))
        }
        guard !preview.hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
        try Task.checkCancellation()
        if let expected = expectedServingEvidence {
            guard expected.modelFingerprint?.isEmpty == false, expected.runtimeFingerprint?.isEmpty == false,
                  let actual = preview.evidence, actual.runtime == expected.runtime,
                  actual.modelFingerprint == expected.modelFingerprint, actual.runtimeFingerprint == expected.runtimeFingerprint,
                  actual.speculation == expected.speculation, actual.expertMemoryGB == expected.expertMemoryGB,
                  actual.contextTokens == expected.contextTokens else {
                throw WorkflowEvidenceError.invalid("The suggested model, runtime or settings changed. Run the comparison again before verifying its suggestion.")
            }
        }
        let memory = memoryProbe.map { SystemMemoryRecorder(probe: $0) }
        await memory?.sample()
        let sampling = memory.map { recorder in
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard !Task.isCancelled else { return }
                    await recorder.sample()
                }
            }
        }
        let startup = Date()
        var ownedServer: ComparisonServerReceipt?
        let requiresReceipt = onServerStarted != nil && lifecycle.startWithReceipt != nil
        do {
            try Task.checkCancellation()
            if onServerStarted != nil, let start = lifecycle.startWithReceipt {
                ownedServer = try await start(modelPath, port, preview.hash)
            } else { try await lifecycle.start(modelPath, port, preview.hash) }
        }
        catch {
            sampling?.cancel(); await sampling?.value
            throw error
        }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        var samples: [String: ProbeSample] = [:]
        var startupSeconds: Double?
        var systemMemory: SystemMemoryEvidence?
        func snapshot() -> ProbeRunResult {
            ProbeRunResult(port: port, samples: samples, servingEvidence: preview.evidence,
                startupSeconds: startupSeconds, systemMemory: systemMemory, ownedServer: ownedServer)
        }
        do {
            if requiresReceipt && ownedServer == nil {
                throw WorkflowEvidenceError.invalid("The confirmed comparison server did not return valid ownership evidence.")
            }
            if let ownedServer { try await onServerStarted?(ownedServer) }
            try Task.checkCancellation()
            guard await waitUntilReady(baseURL: baseURL) else {
                throw ServeProbeError.serverNeverReady(timeout: readyTimeout)
            }
            startupSeconds = Date().timeIntervalSince(startup)
            let modelID = await resolveModelID(baseURL: baseURL, modelPath: modelPath)
            // Warm the same loaded model that will produce the measurements.
            // Warm-up responses never enter the returned samples.
            for prompt in warmup {
                try Task.checkCancellation()
                _ = try await prober.chat(baseURL: baseURL, model: modelID,
                    prompt: prompt.prompt, maxTokens: prompt.maxTokens, tool: prompt.tool)
            }
            for prompt in prompts {
                try Task.checkCancellation()
                if warmEachPrompt {
                    _ = try await prober.chat(baseURL: baseURL, model: modelID,
                        prompt: prompt.prompt, maxTokens: 1, tool: prompt.tool)
                    try Task.checkCancellation()
                }
                let sample = try await prober.chat(
                    baseURL: baseURL,
                    model: modelID,
                    prompt: prompt.prompt,
                    maxTokens: prompt.maxTokens,
                    tool: prompt.tool
                )
                try Task.checkCancellation()
                samples[prompt.id] = sample
            }
            sampling?.cancel(); await sampling?.value
            systemMemory = await memory?.finish()
            do { try await lifecycle.stop(port) }
            catch { throw ServeProbeError.stopFailed(error.localizedDescription, port: port, partial: snapshot()) }
            if Task.isCancelled { throw ServeProbeCancelled(partial: snapshot()) }
            return snapshot()
        } catch {
            sampling?.cancel(); await sampling?.value
            if case ServeProbeError.stopFailed = error { throw error }
            if error is ServeProbeCancelled { throw error }
            systemMemory = await memory?.finish()
            do { try await lifecycle.stop(port) }
            catch { throw ServeProbeError.stopFailed(error.localizedDescription, port: port, partial: snapshot()) }
            if Task.isCancelled || error is CancellationError { throw ServeProbeCancelled(partial: snapshot()) }
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

/// One lane owns one recorder and joins its sampling task before cleanup or return.
private actor SystemMemoryRecorder {
    let probe: @Sendable () -> MemorySnapshot?
    let startedAt = Date()
    var total: Int64?
    var baseline: Int64?
    var minimum: Int64?
    var ending: Int64?
    var samples = 0
    var missed = 0
    var attempts = 0

    init(probe: @escaping @Sendable () -> MemorySnapshot?) { self.probe = probe }

    func sample() {
        defer { attempts += 1 }
        guard let value = probe(), value.totalBytes > 0, (0...value.totalBytes).contains(value.availableBytes),
              total == nil || total == value.totalBytes else { missed += 1; ending = nil; return }
        if attempts == 0 { baseline = value.availableBytes }
        total = value.totalBytes
        minimum = min(minimum ?? value.availableBytes, value.availableBytes)
        ending = value.availableBytes
        samples += 1
    }

    func finish() -> SystemMemoryEvidence? {
        sample()
        guard let total, let baseline, let minimum, let ending else { return nil }
        let evidence = SystemMemoryEvidence(totalBytes: total, baselineAvailableBytes: baseline,
            minimumAvailableBytes: minimum, endingAvailableBytes: ending, sampleCount: samples, missedSamples: missed,
            startedAt: startedAt, endedAt: Date(), samplingIntervalSeconds: 0.5)
        return evidence.isValid ? evidence : nil
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

enum ProbeHTTPError: LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The verification server returned HTTP \(code)."
        case .invalidResponse:
            return "The verification server returned an unreadable response."
        case .responseTooLarge:
            return "The model server response exceeded the streaming size limit."
        }
    }
}

/// Bounds the byte stream before building lines, including a peer that never sends a newline.
private struct BoundedProbeLines: AsyncSequence {
    typealias Element = String
    let bytes: URLSession.AsyncBytes
    let maximumBytes: Int
    let maximumLineBytes: Int
    func makeAsyncIterator() -> Iterator {
        Iterator(bytes: bytes.makeAsyncIterator(), maximumBytes: maximumBytes, maximumLineBytes: maximumLineBytes)
    }
    struct Iterator: AsyncIteratorProtocol {
        var bytes: URLSession.AsyncBytes.Iterator
        let maximumBytes: Int
        let maximumLineBytes: Int
        var received = 0
        mutating func next() async throws -> String? {
            var line = Data()
            while let byte = try await bytes.next() {
                try Task.checkCancellation()
                received += 1
                guard received <= maximumBytes else { throw ProbeHTTPError.responseTooLarge }
                if byte == 10 {
                    if line.last == 13 { line.removeLast() }
                    guard let value = String(data: line, encoding: .utf8) else { throw ProbeHTTPError.invalidResponse }
                    return value
                }
                guard line.count < maximumLineBytes else { throw ProbeHTTPError.responseTooLarge }
                line.append(byte)
            }
            guard !line.isEmpty else { return nil }
            guard let value = String(data: line, encoding: .utf8) else { throw ProbeHTTPError.invalidResponse }
            return value
        }
    }
}

/// Live prober against an mlx_lm.server OpenAI-compatible endpoint.
/// Streaming is used so time-to-first-token is measured honestly; when the
/// server omits usage, token counts are estimated and flagged as such.
struct OpenAIEndpointProber: EndpointProbing {
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let bearerToken: String?
    private let maximumResponseBytes: Int
    private let maximumLineBytes: Int

    init(session: URLSession = .shared, requestTimeout: TimeInterval = 180, bearerToken: String? = nil,
         maximumResponseBytes: Int = 8_388_608, maximumLineBytes: Int = 1_048_576) {
        self.session = session
        self.requestTimeout = requestTimeout
        self.bearerToken = bearerToken
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    func isReady(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 5
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    func listModels(baseURL: URL) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
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
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
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
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ProbeHTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProbeHTTPError.httpStatus(http.statusCode) }

        var text = ""
        var reasoning = ""
        var answerTracker = InlineReasoning.StreamTracker()
        var finishReason: String?
        var firstAnswerAt: Date?
        var completionTokens: Int?
        var promptTokens: Int?
        var draftTokens: DraftTokenEvidence?
        var draftCountsConflict = false
        var promptProcessing: PromptProcessingEvidence?
        var promptProcessingConflict = false
        var firstTokenAt: Date?
        var lastTokenAt: Date?
        var streamedDeltas = 0
        // Streamed tool calls arrive as deltas keyed by index; collect the
        // names and accumulate argument fragments per call.
        var toolCallNamesByIndex: [Int: String] = [:]
        var toolCallArgumentsByIndex: [Int: String] = [:]
        for try await line in BoundedProbeLines(bytes: bytes, maximumBytes: maximumResponseBytes, maximumLineBytes: maximumLineBytes) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if chunk["error"] != nil { throw ProbeHTTPError.invalidResponse }
            if let usage = chunk["usage"] as? [String: Any] {
                if let count = usage["completion_tokens"] as? Int {
                    completionTokens = count
                }
                if let count = usage["prompt_tokens"] as? Int {
                    promptTokens = count
                }
                if let timings = chunk["timings"] as? [String: Any],
                   timings["draft_n"] != nil || timings["draft_n_accepted"] != nil {
                    if let reported = DraftTokenEvidence(timings: timings), !draftCountsConflict,
                       draftTokens == nil || draftTokens == reported { draftTokens = reported }
                    else { draftCountsConflict = true; draftTokens = nil }
                }
                if let timings = chunk["timings"] as? [String: Any],
                   timings["cache_n"] != nil || timings["prompt_n"] != nil || timings["prompt_ms"] != nil {
                    if let reported = PromptProcessingEvidence(usage: usage, timings: timings), !promptProcessingConflict,
                       promptProcessing == nil || promptProcessing == reported { promptProcessing = reported }
                    else { promptProcessingConflict = true; promptProcessing = nil }
                }
            }
            if let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first {
                if let reason = choice["finish_reason"] as? String { finishReason = reason }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                let thought = (delta["reasoning_content"] ?? delta["reasoning"]) as? String ?? ""
                let answer = delta["content"] as? String ?? ""
                if !thought.isEmpty || !answer.isEmpty {
                    let now = Date()
                    if firstTokenAt == nil { firstTokenAt = now }
                    lastTokenAt = now
                    streamedDeltas += 1
                    if !answer.isEmpty, firstAnswerAt == nil {
                        answerTracker.consume(answer)
                        if answerTracker.hasAnswer { firstAnswerAt = now }
                    }
                    reasoning += thought
                    text += answer
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let index = call["index"] as? Int ?? 0
                        if let function = call["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty {
                                toolCallNamesByIndex[index] = name
                            }
                            if let fragment = function["arguments"] as? String {
                                toolCallArgumentsByIndex[index, default: ""] += fragment
                            }
                        }
                    }
                }
            }
        }

        let finishedAt = Date()
        if reasoning.isEmpty, let inline = InlineReasoning.split(text) {
            reasoning = inline.reasoning
            text = inline.answer
        }
        if promptProcessing?.promptTokens != promptTokens { promptProcessing = nil }
        let estimated: Bool
        let tokens: Int?
        if let completionTokens {
            tokens = completionTokens
            estimated = false
        } else {
            // Rough chars-per-token estimate; flagged on the sample so reports
            // never present estimates as measurements.
            let characters = text.count + reasoning.count
            tokens = characters == 0 ? nil : max(1, characters / 4)
            estimated = true
        }
        let toolCallIndices = Set(toolCallNamesByIndex.keys).union(toolCallArgumentsByIndex.keys)
        let toolCalls: Int? = tool == nil ? nil : toolCallIndices.count
        let toolNames: [String]? = tool == nil
            ? nil
            : toolCallNamesByIndex.sorted { $0.key < $1.key }.map(\.value)
        let toolCallsValid: Int? = tool.map { spec in
            toolCallIndices.filter { index in
                spec.argumentsAreValid(toolCallArgumentsByIndex[index] ?? "")
            }.count
        }
        var sample = ProbeSample(
            text: text,
            completionTokens: tokens,
            promptTokens: promptTokens,
            timeToFirstTokenSeconds: firstTokenAt.map { $0.timeIntervalSince(startedAt) },
            durationSeconds: finishedAt.timeIntervalSince(startedAt),
            metricsEstimated: estimated,
            toolCalls: toolCalls,
            toolNames: toolNames,
            toolCallsValid: toolCallsValid,
            reasoningText: reasoning,
            finishReason: finishReason,
            timeToFirstAnswerSeconds: firstAnswerAt.map { $0.timeIntervalSince(startedAt) },
            draftTokens: draftTokens,
            promptProcessing: promptProcessing
        )
        sample.streamedDeltas = streamedDeltas
        if let firstTokenAt, let lastTokenAt { sample.deltaWindowSeconds = lastTokenAt.timeIntervalSince(firstTokenAt) }
        return sample
    }
}
