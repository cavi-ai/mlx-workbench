import Foundation

// MARK: - Comparison models
//
// Measured Comparisons (premium spec 03): replay a prompt set against a set
// of ready MLX variants on an ephemeral server (ServeProbe) and record
// measured tok/s + TTFT per prompt. Results persist, feed the
// RecommendationEngine as real local evidence, and back keep/quarantine
// decisions with numbers instead of vibes.

// MARK: Prompt sets

/// Generation settings preserved with image, video and music prompt snapshots.
struct MediaParameters: Codable, Equatable, Sendable {
    /// Square edge for image generation.
    var size: Int?
    /// Video generation frame size; takes precedence over `size`.
    var width: Int?
    var height: Int?
    var steps: Int?
    var seed: Int?
    var frames: Int?
    var fps: Int?
    /// Maximum requested music duration; the output reports its measured duration.
    var durationSeconds: Double?
    var lyrics: String?

    init(size: Int? = nil, width: Int? = nil, height: Int? = nil, steps: Int? = nil, seed: Int? = nil, frames: Int? = nil, fps: Int? = nil, durationSeconds: Double? = nil, lyrics: String? = nil) {
        self.size = size
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.frames = frames
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.lyrics = lyrics
    }
}

struct PromptEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// Chat: the prompt. Vision and video understanding: the question.
    /// Speech to text: the reference sentence the audio says (scored by word
    /// error rate). Text to speech: the sentence to speak. Image and video
    /// generation: the prompt.
    var text: String
    var maxTokens: Int
    /// When set, the probe offers this tool and records what the model calls.
    var tool: PromptToolSpec?
    /// The kind of input file this prompt carries; nil for text-only prompts.
    var inputKind: ComparisonMediaKind?
    /// Absolute path of a user-picked input file.
    var inputPath: String?
    /// Id of a built-in input generated at run time into the run's folder.
    var builtinInput: String?
    /// Words an answer must all contain (case-insensitive) to count as correct.
    var expectedKeywords: [String]?
    var media: MediaParameters?

    init(
        id: String,
        text: String,
        maxTokens: Int = 256,
        tool: PromptToolSpec? = nil,
        inputKind: ComparisonMediaKind? = nil,
        inputPath: String? = nil,
        builtinInput: String? = nil,
        expectedKeywords: [String]? = nil,
        media: MediaParameters? = nil
    ) {
        self.id = id
        self.text = text
        self.maxTokens = maxTokens
        self.tool = tool
        self.inputKind = inputKind
        self.inputPath = inputPath
        self.builtinInput = builtinInput
        self.expectedKeywords = expectedKeywords
        self.media = media
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
    /// The comparison mode this set is for; nil decodes as chat.
    var mode: ComparisonMode? = nil

    var effectiveMode: ComparisonMode { mode ?? .chat }
}

/// An editable, temporary copy of recorded music inputs. Never writes a preset
/// or carries results, reviews or old model signatures into the next run.
struct MusicComparisonSetup: Identifiable {
    struct InvalidSetup: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Prompt: Identifiable {
        private let original: PromptEntry
        var id: String { original.id }
        var caption: String
        var lyrics: String
        var duration: String
        var steps: String
        var seed: String

        init(_ entry: PromptEntry) {
            original = entry
            caption = entry.text
            lyrics = entry.media?.lyrics ?? ""
            duration = entry.media?.durationSeconds.map { String($0) } ?? ""
            steps = entry.media?.steps.map { String($0) } ?? ""
            seed = entry.media?.seed.map { String($0) } ?? ""
        }

        func entry() throws -> PromptEntry {
            func validateText(_ text: String, name: String, limit: Int) throws {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.unicodeScalars.count <= limit,
                      !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else {
                    throw InvalidSetup(message: "\(name) must contain text, at most \(limit) characters, without control characters.")
                }
            }
            func integer(_ text: String, name: String, range: ClosedRange<Int>) throws -> Int? {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { return nil }
                guard let number = Int(value), range.contains(number) else {
                    throw InvalidSetup(message: "\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
                }
                return number
            }
            try validateText(caption, name: "Caption", limit: 2000)
            let lyricsValue: String? = lyrics.isEmpty ? nil : lyrics
            if lyrics.isEmpty, original.media?.lyrics == "" {
                throw InvalidSetup(message: "Recorded lyrics are empty. Enter lyrics or [instrumental] before using this setup.")
            }
            try validateText(lyricsValue ?? "[instrumental]", name: "Lyrics", limit: 10000)
            let durationText = duration.trimmingCharacters(in: .whitespacesAndNewlines)
            let durationValue: Double?
            if durationText.isEmpty { durationValue = nil }
            else {
                guard let number = Double(durationText), number.isFinite, number > 0, number <= 360 else {
                    throw InvalidSetup(message: "Duration must be greater than 0 and at most 360 seconds.")
                }
                durationValue = number
            }
            let stepsValue = try integer(steps, name: "Steps", range: 1...30)
            let seedValue = try integer(seed, name: "Seed", range: 0...4_294_967_295)
            var copy = original
            copy.text = caption
            // Preserve optional fields exactly when untouched, including a nil
            // media object and any fields this editor does not manage.
            if lyrics != (original.media?.lyrics ?? "") || duration != (original.media?.durationSeconds.map { String($0) } ?? "")
                || steps != (original.media?.steps.map { String($0) } ?? "") || seed != (original.media?.seed.map { String($0) } ?? "") {
                var media = original.media ?? MediaParameters()
                media.lyrics = lyricsValue
                media.durationSeconds = durationValue
                media.steps = stepsValue
                media.seed = seedValue
                copy.media = media
            }
            return copy
        }
    }

    let id: UUID
    let sourceName: String
    let modelPaths: [String]
    var prompts: [Prompt]

    init(run: ComparisonRun) throws {
        guard run.state == .completed, run.effectiveMode == .musicGeneration,
              let entries = run.promptEntries, !entries.isEmpty else {
            throw InvalidSetup(message: "This run has no recorded music setup to reuse.")
        }
        guard !run.variants.isEmpty, run.variants.count <= 4,
              !run.variants.contains(where: { $0.isEmpty }), Set(run.variants).count == run.variants.count,
              !entries.contains(where: { $0.id.isEmpty }), Set(entries.map(\.id)).count == entries.count else {
            throw InvalidSetup(message: "This recorded setup contains invalid model or prompt selections.")
        }
        id = run.id
        sourceName = run.promptSetName
        modelPaths = run.variants
        prompts = entries.map(Prompt.init)
    }

    var validationError: String? {
        do { _ = try validatedPrompts(); return nil }
        catch { return error.localizedDescription }
    }

    private func validatedPrompts() throws -> [PromptEntry] {
        guard !prompts.isEmpty else { throw InvalidSetup(message: "At least one prompt is required.") }
        return try prompts.map { try $0.entry() }
    }

    func promptSet(named name: String? = nil) throws -> PromptSet {
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(sourceName) · reused"
        guard !title.isEmpty, !title.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw InvalidSetup(message: "Enter a prompt set name without control characters.")
        }
        return PromptSet(id: UUID().uuidString, name: title, useCase: nil,
                         prompts: try validatedPrompts(), origin: .userCreated, mode: .musicGeneration)
    }
}

/// A value-only draft of a saved set. The original remains the authority for
/// its identity and metadata, and lets persistence detect a stale editor.
struct MusicPromptSetEdit: Identifiable {
    let original: PromptSet
    var id: String { original.id }
    var prompts: [MusicComparisonSetup.Prompt]

    init(set: PromptSet) throws {
        guard set.origin == .userCreated, set.effectiveMode == .musicGeneration,
              !set.prompts.isEmpty, !set.prompts.contains(where: { $0.id.isEmpty }),
              Set(set.prompts.map(\.id)).count == set.prompts.count else {
            throw MusicComparisonSetup.InvalidSetup(message: "Select a saved, user-created music prompt set with valid prompt identities.")
        }
        original = set
        prompts = set.prompts.map(MusicComparisonSetup.Prompt.init)
    }

    var validationError: String? {
        do { _ = try updatedPromptSet(); return nil }
        catch { return error.localizedDescription }
    }

    func updatedPromptSet() throws -> PromptSet {
        guard prompts.map(\.id) == original.prompts.map(\.id) else {
            throw MusicComparisonSetup.InvalidSetup(message: "The edited set must keep its original prompt identities.")
        }
        var updated = original
        updated.prompts = try prompts.map { try $0.entry() }
        return updated
    }
}

/// Small built-in starter sets per use case. Versioned content: changing a
/// prompt's text changes its id's meaning, so edits bump the entry id suffix.
enum BuiltinPromptSets {
    static let all: [PromptSet] = [coding, generalChat, reasoning, toolCalling]

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

    /// Tool-calling probes: the model is offered a tool and measured on
    /// whether it calls it. Models without tool templates answer in text —
    /// recorded honestly as zero calls.
    static let toolCalling = PromptSet(
        id: "builtin-tool-calling",
        name: "Tool calling",
        useCase: nil,
        prompts: [
            PromptEntry(
                id: "tool-weather",
                text: "What is the current weather in Paris? Use the get_current_weather tool.",
                maxTokens: 128,
                tool: PromptToolSpec(
                    name: "get_current_weather",
                    description: "Get the current weather for a city.",
                    parametersJSON: #"{"type":"object","properties":{"city":{"type":"string","description":"The city name"}},"required":["city"]}"#
                )
            ),
            PromptEntry(
                id: "tool-stock",
                text: "Look up the latest share price of Apple with the get_stock_price tool.",
                maxTokens: 128,
                tool: PromptToolSpec(
                    name: "get_stock_price",
                    description: "Get the latest share price for a ticker symbol.",
                    parametersJSON: #"{"type":"object","properties":{"ticker":{"type":"string","description":"The ticker symbol, e.g. AAPL"}},"required":["ticker"]}"#
                )
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
    /// Prompt tokens reported by the server's usage block, when present.
    let promptTokens: Int?
    /// Prompt-processing speed (prompt tokens over TTFT — a lower bound,
    /// since TTFT includes queueing and first decode).
    let prefillTokensPerSecond: Double?
    /// Tool calls emitted when the prompt offered a tool; nil otherwise.
    let toolCalls: Int?
    let toolNames: [String]?
    /// Of the emitted calls, how many carried usable arguments (parse as a
    /// JSON object containing the offered tool's required keys).
    let toolCallsValid: Int?
    /// Media modes: the full text output (`outputExcerpt` keeps the first 280 characters).
    let fullOutput: String?
    /// Media modes: file name of the saved output inside the run's output folder.
    let artifact: String?
    let seconds: Double?
    let loadSeconds: Double?
    let audioSeconds: Double?
    /// Seconds spent per second of audio (speech modes); below 1 is faster than real time.
    let realTimeFactor: Double?
    let wordErrorRate: Double?
    /// Whether the output contained every expected keyword; nil when none were expected.
    let keywordsMatched: Bool?
    let generationTokens: Int?
    let generationTokensPerSecond: Double?
    let peakMemoryGB: Double?
    let secondsPerStep: Double?
    let secondsPerFrame: Double?
    let pixelStd: Double?

    init(
        promptID: String,
        outputExcerpt: String,
        tokensPerSecond: Double?,
        timeToFirstTokenSeconds: Double?,
        error: String?,
        promptTokens: Int? = nil,
        prefillTokensPerSecond: Double? = nil,
        toolCalls: Int? = nil,
        toolNames: [String]? = nil,
        toolCallsValid: Int? = nil,
        fullOutput: String? = nil,
        artifact: String? = nil,
        seconds: Double? = nil,
        loadSeconds: Double? = nil,
        audioSeconds: Double? = nil,
        realTimeFactor: Double? = nil,
        wordErrorRate: Double? = nil,
        keywordsMatched: Bool? = nil,
        generationTokens: Int? = nil,
        generationTokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil,
        secondsPerStep: Double? = nil,
        secondsPerFrame: Double? = nil,
        pixelStd: Double? = nil
    ) {
        self.promptID = promptID
        self.outputExcerpt = outputExcerpt
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.error = error
        self.promptTokens = promptTokens
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.toolCalls = toolCalls
        self.toolNames = toolNames
        self.toolCallsValid = toolCallsValid
        self.fullOutput = fullOutput
        self.artifact = artifact
        self.seconds = seconds
        self.loadSeconds = loadSeconds
        self.audioSeconds = audioSeconds
        self.realTimeFactor = realTimeFactor
        self.wordErrorRate = wordErrorRate
        self.keywordsMatched = keywordsMatched
        self.generationTokens = generationTokens
        self.generationTokensPerSecond = generationTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
        self.secondsPerStep = secondsPerStep
        self.secondsPerFrame = secondsPerFrame
        self.pixelStd = pixelStd
    }
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
    /// Median of the run mode's primary metric across samples (media modes).
    let aggregateMetric: Double?

    var id: String { modelPath }

    /// Median prompt-processing speed across samples, when any sample
    /// reported prompt tokens.
    var aggregatePrefillTokensPerSecond: Double? {
        ComparisonAggregation.medianPrefillTokensPerSecond(samples)
    }

    /// Total tool calls across samples that offered a tool; nil when no
    /// prompt in the set carried tools.
    var totalToolCalls: Int? {
        let counts = samples.compactMap(\.toolCalls)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// Total calls with usable arguments; nil when no prompt offered tools.
    var totalToolCallsValid: Int? {
        let counts = samples.compactMap(\.toolCallsValid)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    init(
        modelPath: String,
        modelSignature: String?,
        samples: [ComparisonSample],
        aggregateTokensPerSecond: Double?,
        aggregateTTFTSeconds: Double?,
        error: String?,
        environmentFingerprint: String? = nil,
        aggregateMetric: Double? = nil
    ) {
        self.modelPath = modelPath
        self.modelSignature = modelSignature
        self.samples = samples
        self.aggregateTokensPerSecond = aggregateTokensPerSecond
        self.aggregateTTFTSeconds = aggregateTTFTSeconds
        self.error = error
        self.environmentFingerprint = environmentFingerprint
        self.aggregateMetric = aggregateMetric
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
    /// The comparison mode; nil (a run saved before modes existed) is chat.
    var mode: ComparisonMode? = nil
    /// The prompts this run replayed, kept so the results grid still shows
    /// them after the prompt set is edited. All new runs snapshot their cohort.
    var promptEntries: [PromptEntry]? = nil
    /// Explicit human task-outcome review, independent of speed and canary checks.
    var qualityReviews: [String: ComparisonQualityReview]? = nil

    var effectiveMode: ComparisonMode { mode ?? .chat }

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

    /// The value the run's mode ranks a result by; only positive, finite values count.
    func metricValue(of result: VariantResult) -> Double? {
        result.error == nil ? effectiveMode.metricValue(of: result) : nil
    }

    /// Every measured result that equals the best value, so ties share the lead.
    var leaders: [VariantResult] {
        let measured = results.compactMap { result in metricValue(of: result).map { (result, $0) } }
        let values = measured.map(\.1)
        guard let best = effectiveMode.primaryMetric.higherIsBetter ? values.max() : values.min() else { return [] }
        return measured.filter { $0.1 == best }.map(\.0)
    }
}

struct ComparisonQualityReview: Codable, Equatable, Sendable {
    let score: Int
    let rubricID: String
    let reviewedAt: Date
    static let taskOutcomeRubric = "task-outcome-v1"
    static let musicListeningRubric = "music-listening-v1"
    static let musicRubric = "Your listening judgment across this run's prompts: 1 unusable · 2 severe issues · 3 usable with issues · 4 good with minor issues · 5 clean and matches the prompt. Speed does not establish musical quality."

    static func musicScoreTitle(_ score: Int) -> String {
        switch score {
        case 1: return "1 · Unusable"
        case 2: return "2 · Severe issues"
        case 3: return "3 · Usable with issues"
        case 4: return "4 · Good, minor issues"
        case 5: return "5 · Clean, matches prompt"
        default: return "Not reviewed"
        }
    }
    static let rubric = "1 unusable · 2 major corrections · 3 usable with corrections · 4 minor corrections · 5 meets task without corrections"
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
    let averagePrefillTokensPerSecond: Double?
    let bestPrefillTokensPerSecond: Double?

    /// Matches on exact path; when the caller knows the model's current
    /// signature, results recorded against a different signature are skipped
    /// so stale measurements never blend into the current profile.
    static func derive(
        modelPath: String,
        signature: String?,
        runs: [ComparisonRun]
    ) -> ModelPerformanceProfile? {
        let matches: [(measuredAt: Date, result: VariantResult)] = runs
            .filter { $0.state == .completed && $0.effectiveMode == .chat }
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
        let prefillValues = matches.compactMap { $0.result.aggregatePrefillTokensPerSecond }
        return ModelPerformanceProfile(
            runCount: matches.count,
            lastMeasuredAt: matches.map(\.measuredAt).max(),
            averageTokensPerSecond: tpsValues.isEmpty ? nil : tpsValues.reduce(0, +) / Double(tpsValues.count),
            bestTokensPerSecond: tpsValues.max(),
            worstTokensPerSecond: tpsValues.min(),
            bestTTFTSeconds: ttftValues.min(),
            averagePrefillTokensPerSecond: prefillValues.isEmpty ? nil : prefillValues.reduce(0, +) / Double(prefillValues.count),
            bestPrefillTokensPerSecond: prefillValues.max()
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

    static func medianPrefillTokensPerSecond(_ samples: [ComparisonSample]) -> Double? {
        let values = samples.compactMap(\.prefillTokensPerSecond).sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        if values.count % 2 == 1 { return values[mid] }
        return (values[mid - 1] + values[mid]) / 2
    }

    static func sample(from probe: ProbeSample, promptID: String) -> ComparisonSample {
        ComparisonSample(
            promptID: promptID,
            outputExcerpt: String(probe.text.prefix(280)),
            tokensPerSecond: decodeTokensPerSecond(probe),
            timeToFirstTokenSeconds: probe.timeToFirstTokenSeconds,
            error: nil,
            promptTokens: probe.promptTokens,
            prefillTokensPerSecond: probe.prefillTokensPerSecond,
            toolCalls: probe.toolCalls,
            toolNames: probe.toolNames,
            toolCallsValid: probe.toolCallsValid
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
