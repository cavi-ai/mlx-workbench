import Foundation

// MARK: - Comparison models
//
// Measured Comparisons (premium spec 03): replay a prompt set against a set
// of ready MLX variants on an ephemeral server (ServeProbe) and record
// measured tok/s + TTFT per prompt. Results persist, feed the
// RecommendationEngine as real local evidence, and back keep/quarantine
// decisions with numbers instead of vibes.

// MARK: Prompt sets

struct PromptEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var maxTokens: Int

    init(id: String, text: String, maxTokens: Int = 256) {
        self.id = id
        self.text = text
        self.maxTokens = maxTokens
    }
}

enum PromptSetOrigin: String, Codable, Sendable {
    case builtin
    case userCreated
}

struct PromptSet: Codable, Equatable, Identifiable, Sendable {
    /// Stable slug for builtin sets, UUID string for user-created sets.
    let id: String
    var name: String
    var useCase: UseCase?
    var prompts: [PromptEntry]
    var origin: PromptSetOrigin
}

/// Small built-in starter sets per use case. Versioned content: changing a
/// prompt's text changes its id's meaning, so edits bump the entry id suffix.
enum BuiltinPromptSets {
    static let all: [PromptSet] = [coding, generalChat, reasoning]

    static let coding = PromptSet(
        id: "builtin-coding",
        name: "Coding basics",
        useCase: .coding,
        prompts: [
            PromptEntry(
                id: "coding-func",
                text: "Write a Python function `def fib(n)` that returns the nth Fibonacci number. Respond with code only."
            ),
            PromptEntry(
                id: "coding-explain",
                text: "Explain in two sentences what a Python context manager does and when to use one."
            ),
            PromptEntry(
                id: "coding-fix",
                text: "This Swift code fails to compile: `let x: Int = \"5\"`. Give the corrected line and a one-sentence reason."
            ),
        ],
        origin: .builtin
    )

    static let generalChat = PromptSet(
        id: "builtin-general-chat",
        name: "General chat",
        useCase: .generalChat,
        prompts: [
            PromptEntry(
                id: "chat-summary",
                text: "Summarize in one sentence why local-first inference matters for privacy."
            ),
            PromptEntry(
                id: "chat-plan",
                text: "Suggest a three-step plan to organize a messy downloads folder."
            ),
            PromptEntry(
                id: "chat-tone",
                text: "Rewrite this sentence to sound friendlier: \"Your request was denied.\""
            ),
        ],
        origin: .builtin
    )

    static let reasoning = PromptSet(
        id: "builtin-reasoning",
        name: "Reasoning",
        useCase: .reasoning,
        prompts: [
            PromptEntry(
                id: "reason-arithmetic",
                text: "Compute 17 * 23 step by step, then state the final number."
            ),
            PromptEntry(
                id: "reason-logic",
                text: "All glorks are flims. Some flims are blue. Can we conclude some glorks are blue? Answer yes or no, then one sentence why."
            ),
            PromptEntry(
                id: "reason-units",
                text: "A tank fills at 3 liters per minute and drains at 1 liter per minute. Starting empty at 40 liters capacity, when does it overflow? Show the steps."
            ),
        ],
        origin: .builtin
    )
}

// MARK: Runs and results

struct ComparisonSample: Codable, Equatable, Sendable {
    let promptID: String
    let outputExcerpt: String
    let tokensPerSecond: Double?
    let timeToFirstTokenSeconds: Double?
    let error: String?
}

struct VariantResult: Codable, Equatable, Identifiable, Sendable {
    let modelPath: String
    let modelSignature: String?
    let samples: [ComparisonSample]
    let aggregateTokensPerSecond: Double?
    let aggregateTTFTSeconds: Double?
    let error: String?
    /// Environment fingerprint at measurement time; mismatch with the
    /// current environment marks the benchmark stale in the engine.
    let environmentFingerprint: String?

    var id: String { modelPath }

    init(
        modelPath: String,
        modelSignature: String?,
        samples: [ComparisonSample],
        aggregateTokensPerSecond: Double?,
        aggregateTTFTSeconds: Double?,
        error: String?,
        environmentFingerprint: String? = nil
    ) {
        self.modelPath = modelPath
        self.modelSignature = modelSignature
        self.samples = samples
        self.aggregateTokensPerSecond = aggregateTokensPerSecond
        self.aggregateTTFTSeconds = aggregateTTFTSeconds
        self.error = error
        self.environmentFingerprint = environmentFingerprint
    }
}

enum ComparisonRunState: String, Codable, Sendable {
    case running
    case completed
}

struct ComparisonRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let promptSetID: String
    let promptSetName: String
    let useCase: UseCase?
    let variants: [String]
    var results: [VariantResult]
    let startedAt: Date
    var finishedAt: Date?
    var state: ComparisonRunState

    /// Fastest measured variant, for the "promote winner" affordance.
    var winner: VariantResult? {
        results
            .filter { $0.error == nil && $0.aggregateTokensPerSecond != nil }
            .sorted {
                ($0.aggregateTokensPerSecond ?? 0, -($0.aggregateTTFTSeconds ?? .infinity)) >
                ($1.aggregateTokensPerSecond ?? 0, -($1.aggregateTTFTSeconds ?? .infinity))
            }
            .first
    }
}

// MARK: - Output diffs (phase 2)

/// Pairs per-prompt outputs from two variants for the side-by-side diff view.
enum ComparisonDiff {
    struct Pair: Equatable, Identifiable {
        let promptID: String
        let left: String
        let right: String
        var id: String { promptID }
    }

    static func pairs(_ left: VariantResult, _ right: VariantResult) -> [Pair] {
        let rightByID = Dictionary(uniqueKeysWithValues: right.samples.map { ($0.promptID, $0) })
        return left.samples.compactMap { sample in
            guard let other = rightByID[sample.promptID] else { return nil }
            return Pair(promptID: sample.promptID, left: sample.outputExcerpt, right: other.outputExcerpt)
        }
    }
}

// MARK: - Per-model performance profile

/// Aggregated measured evidence for one model across all completed
/// comparison runs. Feeds the Model Details "Performance" surface so a
/// model's speed story is visible without opening individual runs.
struct ModelPerformanceProfile: Equatable {
    let runCount: Int
    let lastMeasuredAt: Date?
    let averageTokensPerSecond: Double?
    let bestTokensPerSecond: Double?
    let worstTokensPerSecond: Double?
    let bestTTFTSeconds: Double?

    /// Matches on exact path; when the caller knows the model's current
    /// signature, results recorded against a different signature are skipped
    /// so stale measurements never blend into the current profile.
    static func derive(
        modelPath: String,
        signature: String?,
        runs: [ComparisonRun]
    ) -> ModelPerformanceProfile? {
        let matches: [(measuredAt: Date, result: VariantResult)] = runs
            .filter { $0.state == .completed }
            .compactMap { run in
                guard let result = run.results.first(where: {
                    $0.modelPath == modelPath
                        && $0.error == nil
                        && (signature == nil || $0.modelSignature == nil || $0.modelSignature == signature)
                }) else { return nil }
                return (run.finishedAt ?? run.startedAt, result)
            }
        guard !matches.isEmpty else { return nil }
        let tpsValues = matches.compactMap { $0.result.aggregateTokensPerSecond }
        let ttftValues = matches.compactMap { $0.result.aggregateTTFTSeconds }
        return ModelPerformanceProfile(
            runCount: matches.count,
            lastMeasuredAt: matches.map(\.measuredAt).max(),
            averageTokensPerSecond: tpsValues.isEmpty ? nil : tpsValues.reduce(0, +) / Double(tpsValues.count),
            bestTokensPerSecond: tpsValues.max(),
            worstTokensPerSecond: tpsValues.min(),
            bestTTFTSeconds: ttftValues.min()
        )
    }
}

enum ComparisonAggregation {    static func medianTokensPerSecond(_ samples: [ComparisonSample]) -> Double? {
        let values = samples.compactMap(\.tokensPerSecond).sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        if values.count % 2 == 1 { return values[mid] }
        return (values[mid - 1] + values[mid]) / 2
    }

    static func bestTTFT(_ samples: [ComparisonSample]) -> Double? {
        samples.compactMap(\.timeToFirstTokenSeconds).min()
    }

    static func sample(from probe: ProbeSample, promptID: String) -> ComparisonSample {
        ComparisonSample(
            promptID: promptID,
            outputExcerpt: String(probe.text.prefix(280)),
            tokensPerSecond: decodeTokensPerSecond(probe),
            timeToFirstTokenSeconds: probe.timeToFirstTokenSeconds,
            error: nil
        )
    }

    /// Decode speed over the post-first-token window, mirroring the canary
    /// suite's metric so recommendation evidence is comparable across
    /// verification and comparison runs.
    private static func decodeTokensPerSecond(_ sample: ProbeSample) -> Double? {
        guard let tokens = sample.completionTokens, tokens > 0 else { return nil }
        let decodeSeconds = sample.durationSeconds - (sample.timeToFirstTokenSeconds ?? 0)
        guard decodeSeconds > 0 else { return nil }
        return Double(tokens) / decodeSeconds
    }
}
