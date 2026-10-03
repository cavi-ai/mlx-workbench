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
    static let version = 1

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
            maxTokens: 160,
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
        guard let tokens = sample.completionTokens, tokens > 0 else { return nil }
        let decodeSeconds = sample.durationSeconds - (sample.timeToFirstTokenSeconds ?? 0)
        guard decodeSeconds > 0 else { return nil }
        return Double(tokens) / decodeSeconds
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

    var summary: String {
        switch self {
        case .passed:
            return "All canaries passed."
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
        case startedAt, finishedAt, outcome, environmentFingerprint
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
