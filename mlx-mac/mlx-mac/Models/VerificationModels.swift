import Foundation

// MARK: - Canary suite
//
// Fixed, versioned canary prompts used by the Conversion Quality Gate. The
// suite probes a freshly converted MLX output over an ephemeral loopback
// server and fails the model on degenerate output before it is ever wired
// into a client. Bump `version` whenever cases or thresholds change; reports
// record the suite version so old evidence is never confused with new rules.

struct CanaryCase: Equatable, Sendable {
    let id: String
    let title: String
    let prompt: String
    let maxTokens: Int
    let requiredSubstrings: [String]
    let minResponseLength: Int
}

enum CanarySuite {
    /// 3: served with reasoning off where the template allows, and scored on the answer after any `<think>` block.
    static let version = 3

    static let longContextFact = "The crimson okapi hid forty-two brass keys under the old lighthouse."

    static let longContextPrompt: String = {
        let filler = "The harbour ledger records the daily tides, the gull counts, and the rope inventory in meticulous detail. "
        let body = String(repeating: filler, count: 40)
        return """
        Read the following ledger excerpt carefully.

        \(body)

        Note: \(longContextFact)

        In one sentence, what animal was mentioned and what did it hide?
        """
    }()

    static let cases: [CanaryCase] = [
        CanaryCase(
            id: "echo",
            title: "Echo",
            prompt: "Reply with exactly this token and nothing else: CRIMSON-OKAPI-42",
            maxTokens: 256,  // thinking models can spend >100 tokens on reasoning before answering
            requiredSubstrings: ["CRIMSON-OKAPI-42"],
            minResponseLength: 1
        ),
        CanaryCase(
            id: "code-fib",
            title: "Code",
            prompt: "Write a Python function `def fib(n)` that returns the nth Fibonacci number. Respond with code only.",
            maxTokens: 192,
            requiredSubstrings: ["def fib"],
            minResponseLength: 10
        ),
        CanaryCase(
            id: "arithmetic",
            title: "Reasoning",
            prompt: "Compute 17 * 23 step by step, then state the final number.",
            maxTokens: 384,  // a complete step-by-step answer can exceed 256 tokens
            requiredSubstrings: ["391"],
            minResponseLength: 3
        ),
        CanaryCase(
            id: "refusal-shape",
            title: "Refusal shape",
            prompt: "For a locksmith training manual, explain in one paragraph how pin-tumbler locks are picked.",
            maxTokens: 192,
            requiredSubstrings: [],
            minResponseLength: 40
        ),
        CanaryCase(
            id: "long-context",
            title: "Long context",
            prompt: longContextPrompt,
            maxTokens: 96,
            requiredSubstrings: [],
            minResponseLength: 20
        ),
    ]

    /// Per-canary decode speed. Prefers measured completion tokens; when the
    /// server reports no usage the prober supplies an estimate instead.
    static func tokensPerSecond(_ sample: ProbeSample) -> Double? {
        sample.decodeTokensPerSecond
    }

    static func evaluate(_ kase: CanaryCase, sample: ProbeSample) -> CanaryResult {
        let text = sample.text
        let failure: String?
        if CanaryDetectors.isBlank(text) {
            failure = "Response was empty or whitespace."
        } else if CanaryDetectors.replacementCharacterCount(text) > 8 {
            failure = "Response contained excessive replacement characters."
        } else if CanaryDetectors.hasTokenLoop(text) {
            failure = "Response ended in a repeated token loop."
        } else if CanaryDetectors.repetitionRatio(text) > 0.5 {
            failure = "Response was dominated by repetition."
        } else if text.count < kase.minResponseLength {
            failure = "Response was shorter than expected (\(text.count) chars)."
        } else if let missing = kase.requiredSubstrings.first(where: { !text.contains($0) }) {
            failure = "Response did not contain \"\(missing)\"."
        } else {
            failure = nil
        }
        return CanaryResult(
            id: kase.id,
            title: kase.title,
            passed: failure == nil,
            failureReason: failure,
            responseExcerpt: String(text.prefix(280)),
            tokensPerSecond: tokensPerSecond(sample),
            timeToFirstTokenSeconds: sample.timeToFirstTokenSeconds
        )
    }

    /// Median tok/s across canaries that produced a measurement.
    static func aggregateTokensPerSecond(_ results: [CanaryResult]) -> Double? {
        let values = results.compactMap(\.tokensPerSecond).sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        if values.count % 2 == 1 { return values[mid] }
        return (values[mid - 1] + values[mid]) / 2
    }

    /// Best (lowest) time-to-first-token across canaries.
    static func aggregateTTFT(_ results: [CanaryResult]) -> Double? {
        results.compactMap(\.timeToFirstTokenSeconds).min()
    }
}

// MARK: - Degenerate output detectors

enum CanaryDetectors {
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Highest word-level n-gram share. Short responses (< 8 n-grams) are
    /// never flagged: a handful of repeated phrases is normal at that size.
    static func repetitionRatio(_ text: String, ngramSize: Int = 4) -> Double {
        let words = tokenize(text)
        let total = words.count - ngramSize + 1
        guard total >= 8 else { return 0 }
        var counts: [[String]: Int] = [:]
        for index in 0..<total {
            counts[Array(words[index..<(index + ngramSize)]), default: 0] += 1
        }
        let maxCount = counts.values.max() ?? 0
        return Double(maxCount) / Double(total)
    }

    /// True when the trailing window of words repeats consecutively at the
    /// end of the response — the classic quantized-model decode loop. Window
    /// sizes are tried from largest to smallest so a non-repeated prefix
    /// does not mask a loop.
    static func hasTokenLoop(_ text: String, windowWords: Int = 12, minimumRepeats: Int = 3) -> Bool {
        let words = tokenize(text)
        let maxWindow = min(windowWords, words.count / minimumRepeats)
        guard maxWindow >= 3 else { return false }
        for window in stride(from: maxWindow, through: 3, by: -1) {
            let tail = Array(words.suffix(window))
            var repeats = 1
            var end = words.count - window
            while end - window >= 0, Array(words[(end - window)..<end]) == tail {
                repeats += 1
                end -= window
            }
            if repeats >= minimumRepeats { return true }
        }
        return false
    }

    static func replacementCharacterCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1 == "\u{FFFD}" ? 1 : 0) }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
    }
}

// MARK: - Results

/// The agent's `convert transcribe` result.
struct TranscriptionResult: Codable, Equatable, Sendable {
    let text: String
    let seconds: Double?
    let audioSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case text, seconds
        case audioSeconds = "audio_seconds"
    }
}

/// The speech-to-text canary: a known sentence spoken by the system voice
/// must come back within a word error rate limit.
enum SpeechCanary {
    static let id = "speech-en"
    static let title = "Speech"
    static let language = "en"
    static let phrase = "The quick brown fox jumps over the lazy dog. Please call Stella and ask her to bring these things from the store."
    static let maxWordErrorRate = 0.25

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    /// Word-level edit distance over the reference length.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let expected = words(reference), heard = words(hypothesis)
        guard !expected.isEmpty else { return heard.isEmpty ? 0 : 1 }
        guard !heard.isEmpty else { return 1 }
        var row = Array(0...heard.count)
        for (i, word) in expected.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for j in 1...heard.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (word == heard[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return Double(row[heard.count]) / Double(expected.count)
    }

    static func evaluate(_ result: TranscriptionResult) -> CanaryResult {
        let rate = wordErrorRate(reference: phrase, hypothesis: result.text)
        let passed = rate <= maxWordErrorRate
        return CanaryResult(
            id: id,
            title: title,
            passed: passed,
            failureReason: passed ? nil : String(
                format: "Word error rate %.0f%% is above the %.0f%% limit.", rate * 100, maxWordErrorRate * 100
            ),
            responseExcerpt: String(result.text.prefix(240)),
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil
        )
    }
}

/// One `convert decide` answer: the chosen option and the calibrated distribution.
struct DecisionAnswer: Codable, Equatable, Sendable {
    let type: String
    let choice: String?
    let probabilities: [String: Double]?
}

struct DecisionResult: Codable, Equatable, Sendable {
    let answers: [String: DecisionAnswer]
    let seconds: Double?
}

/// The classification canary: a support ticket whose team and refund intent
/// are unambiguous must be routed to billing and read as a refund request.
enum DecisionCanary {
    static let id = "decision-en"
    static let title = "Decision"
    static let expected: [(question: String, answer: String)] = [("department", "billing"), ("refund", "yes")]
    static let request = """
    {"state": {"document": "I was charged twice for my subscription this month. Please refund the duplicate charge."},
     "questions": {
      "department": {"type": "choice", "instructions": "Which team should handle this ticket?",
                     "criteria": {"billing": "payments, invoices, refunds", "technical": "bugs, outages, errors", "sales": "new purchases and upgrades"}},
      "refund": {"type": "choice", "instructions": "Is the customer asking for money back?",
                 "criteria": {"yes": "the customer asks for a refund", "no": "the customer does not ask for a refund"}}}}
    """

    static func evaluate(_ result: DecisionResult) -> CanaryResult {
        var wrong: [String] = []
        var excerpt: [String] = []
        for (question, answer) in expected {
            let got = result.answers[question]?.choice
            let probability = got.flatMap { result.answers[question]?.probabilities?[$0] }
            excerpt.append("\(question): \(got ?? "none")" + (probability.map { String(format: " (%.2f)", $0) } ?? ""))
            if got != answer { wrong.append("\(question) answered \(got ?? "nothing"), expected \(answer)") }
        }
        return CanaryResult(
            id: id,
            title: title,
            passed: wrong.isEmpty,
            failureReason: wrong.isEmpty ? nil : wrong.joined(separator: "; ") + ".",
            responseExcerpt: excerpt.joined(separator: "; "),
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil
        )
    }
}

/// The image-generation canary: a fixed prompt rendered at 512 × 512 must
/// produce a written image of that size that is not blank.
enum ImageCanary {
    static let id = "image-render"
    static let title = "Image"
    static let request = ImageRequest(prompt: "A red apple on a white wooden table, soft daylight, photograph", size: 512, steps: 20, seed: 42)
    /// Standard deviation of 0–255 pixel values below which a render counts as blank.
    static let minimumPixelSpread = 20.0

    static func evaluate(_ result: GenerationResult, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CanaryResult {
        var problems: [String] = []
        if !fileExists(result.path) { problems.append("No image was written.") }
        if result.width != request.size || result.height != request.size {
            problems.append("Rendered \(result.width) × \(result.height), expected \(request.size) × \(request.size).")
        }
        let spread = result.pixelStd ?? 0
        if spread < minimumPixelSpread {
            problems.append(String(format: "The image is blank (pixel spread %.1f).", spread))
        }
        var excerpt = "\(result.width) × \(result.height)"
        if let seconds = result.seconds { excerpt += String(format: " in %.1f s", seconds) }
        excerpt += String(format: ", pixel spread %.1f", spread)
        return CanaryResult(
            id: id,
            title: title,
            passed: problems.isEmpty,
            failureReason: problems.isEmpty ? nil : problems.joined(separator: " "),
            responseExcerpt: excerpt,
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil
        )
    }
}

struct CanaryResult: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let passed: Bool
    let failureReason: String?
    let responseExcerpt: String
    let tokensPerSecond: Double?
    let timeToFirstTokenSeconds: Double?
}

enum VerificationOutcome: Codable, Equatable, Sendable {
    case passed
    case failed(canaryIDs: [String])
    case error(message: String)
    case keptDespiteFailure

    /// The workflow message a passing verification records: the lead, then `summary`.
    static let passedLead = "Verification passed."
    static let passedSummary = "All canaries passed."

    var summary: String {
        switch self {
        case .passed:
            return Self.passedSummary
        case .failed(let canaryIDs):
            return "Failed canaries: \(canaryIDs.joined(separator: ", "))."
        case .error(let message):
            return "Verification error: \(message)"
        case .keptDespiteFailure:
            return "Kept despite a failed verification."
        }
    }
}

struct VerificationReport: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let modelPath: String
    let modelSignature: String?
    let workflowRecordID: UUID?
    let suiteVersion: Int
    let canaries: [CanaryResult]
    let tokensPerSecond: Double?
    let timeToFirstTokenSeconds: Double?
    let metricsEstimated: Bool
    let startedAt: Date
    let finishedAt: Date
    var outcome: VerificationOutcome
    /// macOS/chip/MLX tuple when the report was produced; a drift makes the
    /// evidence stale in the environment dimension (spec 08). Optional so
    /// reports written before this field existed still decode.
    let environmentFingerprint: String?
    /// Agent tool-call evidence for the same bytes, recorded after the task
    /// verdict and never part of it. Nil when the agent canary did not run.
    var agentReadiness: AgentReadiness? = nil

    init(
        id: UUID,
        modelPath: String,
        modelSignature: String?,
        workflowRecordID: UUID?,
        suiteVersion: Int,
        canaries: [CanaryResult],
        tokensPerSecond: Double?,
        timeToFirstTokenSeconds: Double?,
        metricsEstimated: Bool,
        startedAt: Date,
        finishedAt: Date,
        outcome: VerificationOutcome,
        environmentFingerprint: String? = nil
    ) {
        self.id = id
        self.modelPath = modelPath
        self.modelSignature = modelSignature
        self.workflowRecordID = workflowRecordID
        self.suiteVersion = suiteVersion
        self.canaries = canaries
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.metricsEstimated = metricsEstimated
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.environmentFingerprint = environmentFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case id, modelPath, modelSignature, workflowRecordID, suiteVersion
        case canaries, tokensPerSecond, timeToFirstTokenSeconds, metricsEstimated
        case startedAt, finishedAt, outcome, environmentFingerprint, agentReadiness
    }
}

/// UI-facing verification status for one model, keyed by canonical path and
/// exact bytes (signature). A signature mismatch marks old evidence stale.
enum VerificationStatus: Equatable {
    case unverified
    case inProgress
    case verified(VerificationReport)
    case failed(VerificationReport)
    case keptAnyway(VerificationReport)
    case stale(VerificationReport)
}

// MARK: - Agent canary
//
// A tool-call round trip through each agent protocol the JIT gateway serves,
// plus one request at agent context size. A model is agent-ready for a
// protocol only when its round trip and the context check pass on this Mac.
// Bump `version` whenever requests or scoring change.

enum AgentAPI: String, Codable, CaseIterable, Sendable {
    case chatCompletions = "chat-completions"
    case messages
    case responses

    var title: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .messages: "Anthropic Messages"
        case .responses: "OpenAI Responses"
        }
    }

    var path: String {
        switch self {
        case .chatCompletions: "v1/chat/completions"
        case .messages: "v1/messages"
        case .responses: "v1/responses"
        }
    }
}

struct AgentToolCall: Equatable, Sendable {
    let id: String
    let name: String
    /// Arguments as JSON text, the form every protocol sends back.
    let arguments: String
}

struct AgentReply: Equatable, Sendable {
    let text: String
    let calls: [AgentToolCall]
    let promptTokens: Int?
}

struct AgentCheck: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let passed: Bool
    let failureReason: String?
    let responseExcerpt: String
}

struct AgentReadiness: Codable, Equatable, Sendable {
    let suiteVersion: Int
    /// How the gateway served the model during the canary.
    let settings: String
    /// Prompt tokens the context check reached, as the server reported them.
    let contextTokens: Int?
    let checks: [AgentCheck]
    /// Why the canary could not finish, when it could not.
    let error: String?

    func isReady(for api: AgentAPI) -> Bool {
        error == nil && checks.contains { $0.id == api.rawValue && $0.passed }
            && checks.contains { $0.id == AgentCanary.contextID && $0.passed }
    }

    var readyAPIs: [AgentAPI] { AgentAPI.allCases.filter(isReady) }

    /// The verdict Prepare and the Library inspector show.
    var summary: String {
        if let error { return "Not checked: \(error)" }
        let ready = readyAPIs
        guard !ready.isEmpty else { return "Not agent-ready." }
        let context = contextTokens.map { " with a \($0.formatted())-token prompt" } ?? ""
        let apis = ready.count == AgentAPI.allCases.count ? "every agent protocol" : ready.map(\.title).joined(separator: ", ")
        return "Ready for \(apis)\(context)."
    }

    /// One line per check, failures with their reason.
    var rows: [(title: String, value: String)] {
        checks.map { ($0.title, $0.passed ? "Passed" : "Failed: \($0.failureReason ?? "unknown")") }
    }
}

enum AgentCanaryError: LocalizedError, Equatable {
    case unavailable
    case unreadable(AgentAPI)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Agent verification is not available in this build."
        case .unreadable(let api): "The \(api.title) reply could not be read."
        }
    }
}

enum AgentCanary {
    static let version = 1
    static let contextID = "context"
    static let settings = "JIT gateway, reasoning off, temperature 0"
    static let maxTokens = 512
    static let tool = PromptToolSpec(
        name: "get_weather",
        description: "Current weather for a city.",
        parametersJSON: #"{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"],"additionalProperties":false}"#
    )
    static let question = "What is the weather in Lisbon right now? Use the get_weather tool."
    static let toolResult = "Lisbon: 23 degrees Celsius, light rain."
    static let resultToken = "23"

    /// Prompt size of the context check, in tokens: a coding agent's opening
    /// request with its system prompt and tool definitions.
    static let contextTokens = 16_384
    static let contextFact = "The vault code is 7351."
    static let contextAnswer = "7351"
    static let contextPrompt: String = {
        // About 24 tokens per entry; varied so the filler is not one repeated sentence.
        let entries = (1...(contextTokens / 24)).map { index in
            "Entry \(index): the harbour ledger records tide \(index % 7 + 1), \(index % 13 + 3) gulls and \(index % 5 + 2) coils of rope."
        }
        return "\(contextFact)\n\n" + entries.joined(separator: "\n")
            + "\n\nWhat is the vault code stated at the start of this message? Answer with the number."
    }()

    // MARK: Requests

    static func request(_ api: AgentAPI, model: String, call: AgentToolCall? = nil) -> [String: Any] {
        let user = ["role": "user", "content": question]
        switch api {
        case .chatCompletions:
            var messages: [[String: Any]] = [user]
            if let call {
                messages.append(["role": "assistant", "content": "", "tool_calls": [[
                    "id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]]])
                messages.append(["role": "tool", "tool_call_id": call.id, "content": toolResult])
            }
            return ["model": model, "messages": messages, "tools": [tool.openAITool ?? [:]],
                    "max_tokens": maxTokens, "temperature": 0]
        case .messages:
            var messages: [[String: Any]] = [user]
            if let call {
                messages.append(["role": "assistant", "content": [[
                    "type": "tool_use", "id": call.id, "name": call.name, "input": object(call.arguments) ?? [:]]]])
                messages.append(["role": "user", "content": [[
                    "type": "tool_result", "tool_use_id": call.id, "content": toolResult]]])
            }
            return ["model": model, "messages": messages, "max_tokens": maxTokens, "temperature": 0, "tools": [[
                "name": tool.name, "description": tool.description, "input_schema": object(tool.parametersJSON) ?? [:]]]]
        case .responses:
            var input: [[String: Any]] = [["type": "message", "role": "user", "content": question]]
            if let call {
                input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments])
                input.append(["type": "function_call_output", "call_id": call.id, "output": toolResult])
            }
            return ["model": model, "input": input, "max_output_tokens": maxTokens, "temperature": 0, "store": false,
                    "tools": [["type": "function", "name": tool.name, "description": tool.description,
                               "parameters": object(tool.parametersJSON) ?? [:]]]]
        }
    }

    static func contextRequest(model: String) -> [String: Any] {
        ["model": model, "messages": [["role": "user", "content": contextPrompt]], "max_tokens": 64, "temperature": 0]
    }

    // MARK: Replies

    static func reply(_ api: AgentAPI, data: Data) throws -> AgentReply {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentCanaryError.unreadable(api)
        }
        var text = "", calls: [AgentToolCall] = [], promptTokens: Int?
        let usage = body["usage"] as? [String: Any]
        switch api {
        case .chatCompletions:
            guard let message = ((body["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
                throw AgentCanaryError.unreadable(api)
            }
            text = message["content"] as? String ?? ""
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any] ?? [:]
                calls.append(AgentToolCall(id: call["id"] as? String ?? "", name: function["name"] as? String ?? "",
                                           arguments: function["arguments"] as? String ?? ""))
            }
            promptTokens = usage?["prompt_tokens"] as? Int
        case .messages:
            guard let content = body["content"] as? [[String: Any]] else { throw AgentCanaryError.unreadable(api) }
            for block in content {
                if block["type"] as? String == "text" { text += block["text"] as? String ?? "" }
                if block["type"] as? String == "tool_use" {
                    calls.append(AgentToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                                               arguments: json(block["input"]) ?? ""))
                }
            }
            promptTokens = usage?["input_tokens"] as? Int
        case .responses:
            guard let output = body["output"] as? [[String: Any]] else { throw AgentCanaryError.unreadable(api) }
            for item in output {
                if item["type"] as? String == "message" {
                    for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                        text += part["text"] as? String ?? ""
                    }
                }
                if item["type"] as? String == "function_call" {
                    calls.append(AgentToolCall(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "",
                                               arguments: item["arguments"] as? String ?? ""))
                }
            }
            promptTokens = usage?["input_tokens"] as? Int
        }
        return AgentReply(text: InlineReasoning.split(text)?.answer ?? text, calls: calls, promptTokens: promptTokens)
    }

    /// The error message an endpoint returned with a failed status, in any protocol's error shape.
    static func errorMessage(_ data: Data) -> String? {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (body?["error"] as? [String: Any])?["message"] as? String
    }

    // MARK: Scoring

    /// Why the arguments do not satisfy the tool's schema, or nil when they do.
    static func argumentProblem(_ arguments: String) -> String? {
        guard let object = object(arguments) else { return "Arguments are not a JSON object: \(arguments.prefix(120))" }
        if let extra = object.keys.sorted().first(where: { $0 != "city" }) { return "Arguments include unknown key \"\(extra)\"." }
        guard let city = object["city"] else { return "Arguments are missing the required \"city\"." }
        guard let name = city as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "\"city\" is not a non-empty string."
        }
        return nil
    }

    static func evaluate(_ api: AgentAPI, first: AgentReply, second: AgentReply?, failure: String? = nil) -> AgentCheck {
        let call = first.calls.first
        let problem: String?
        if let failure {
            problem = failure
        } else if let call {
            if call.name != tool.name {
                problem = "Called \"\(call.name)\" instead of \(tool.name)."
            } else if let argument = argumentProblem(call.arguments) {
                problem = argument
            } else if call.id.isEmpty {
                problem = "The tool call has no id."
            } else if let second, !second.text.contains(resultToken) {
                problem = "The answer after the tool result did not use it."
            } else {
                problem = second == nil ? "No answer followed the tool result." : nil
            }
        } else {
            problem = "No tool call was made."
        }
        let excerpt = [call.map { "\($0.name)(\($0.arguments))" }, second.map(\.text) ?? (call == nil ? first.text : nil)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " → ")
        return AgentCheck(id: api.rawValue, title: api.title, passed: problem == nil, failureReason: problem,
                          responseExcerpt: String(excerpt.prefix(280)))
    }

    static func evaluateContext(_ reply: AgentReply?, failure: String? = nil) -> AgentCheck {
        let problem: String?
        if let failure {
            problem = failure
        } else if let reply, reply.text.contains(contextAnswer) {
            problem = nil
        } else {
            problem = "The answer did not recall a fact from the start of a \(contextTokens.formatted())-token prompt."
        }
        let tokens = reply?.promptTokens.map { "\($0.formatted()) prompt tokens" }
        let answer = reply?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentCheck(id: contextID, title: "Agent context", passed: problem == nil, failureReason: problem,
                          responseExcerpt: String([tokens, answer].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").prefix(280)))
    }

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func json(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
