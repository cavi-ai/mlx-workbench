import Foundation

// MARK: - ComparisonMediaRunner
//
// One prompt through one variant in a media comparison mode. The coordinator
// owns ordering (variant by variant, prompt by prompt) and storage; the runner
// only calls the agent. Injectable so the coordinator is testable without a model.

struct MediaRunRequest: Sendable, Equatable {
    let mode: ComparisonMode
    let modelPath: String
    let entry: PromptEntry
    /// The input file for modes that take one.
    let inputURL: URL?
    /// The new file the model writes, for modes whose output is a file (audio, image, video).
    let outputURL: URL?
    let maxTokens: Int
    /// The spoken language of the input when it is known: set for the built-in speech clips,
    /// nil for user-picked files so the model detects it.
    let language: String?
}

struct MediaRunOutput: Sendable, Equatable {
    var text: String?
    var seconds: Double?
    var loadSeconds: Double?
    var audioSeconds: Double?
    var realTimeFactor: Double?
    var generationTokens: Int?
    var generationTokensPerSecond: Double?
    var peakMemoryGB: Double?
    var steps: Int?
    var frames: Int?
    var secondsPerFrame: Double?
    var pixelStd: Double?

    init(
        text: String? = nil,
        seconds: Double? = nil,
        loadSeconds: Double? = nil,
        audioSeconds: Double? = nil,
        realTimeFactor: Double? = nil,
        generationTokens: Int? = nil,
        generationTokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil,
        steps: Int? = nil,
        frames: Int? = nil,
        secondsPerFrame: Double? = nil,
        pixelStd: Double? = nil
    ) {
        self.text = text
        self.seconds = seconds
        self.loadSeconds = loadSeconds
        self.audioSeconds = audioSeconds
        self.realTimeFactor = realTimeFactor
        self.generationTokens = generationTokens
        self.generationTokensPerSecond = generationTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
        self.steps = steps
        self.frames = frames
        self.secondsPerFrame = secondsPerFrame
        self.pixelStd = pixelStd
    }
}

protocol ComparisonMediaRunner: Sendable {
    func run(_ request: MediaRunRequest) async throws -> MediaRunOutput
}

enum ComparisonMediaError: LocalizedError, Equatable {
    case notAMediaMode
    case missingInput
    case missingOutputPath
    case outputNotWritten
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAMediaMode: return "Chat comparisons run through the serve probe, not the media runner."
        case .missingInput: return "This prompt needs an input file."
        case .missingOutputPath: return "No output file was prepared for this prompt."
        case .outputNotWritten: return "The model reported success but wrote no file."
        case .unavailable: return "Media comparisons are not available in this build."
        }
    }
}

/// Calls the agent: `convert describe|transcribe|speak|generate|video`. Each call hops onto the
/// API actor, so nothing runs on the main actor.
struct LiveComparisonMediaRunner: ComparisonMediaRunner {
    let api: WorkbenchAPI

    func run(_ request: MediaRunRequest) async throws -> MediaRunOutput {
        let entry = request.entry
        switch request.mode {
        case .chat:
            throw ComparisonMediaError.notAMediaMode
        case .vision, .videoUnderstanding:
            guard let input = request.inputURL else { throw ComparisonMediaError.missingInput }
            let isVideo = request.mode == .videoUnderstanding
            let result = try await api.describe(
                path: request.modelPath, prompt: entry.text,
                image: isVideo ? nil : input.path, video: isVideo ? input.path : nil,
                maxTokens: request.maxTokens
            )
            return MediaRunOutput(
                text: result.text, seconds: result.seconds, loadSeconds: result.loadSeconds,
                generationTokens: result.generationTokens, generationTokensPerSecond: result.generationTps,
                peakMemoryGB: result.peakMemoryGB
            )
        case .speechToText:
            guard let input = request.inputURL else { throw ComparisonMediaError.missingInput }
            let result = try await api.transcribe(path: request.modelPath, audio: input.path, language: request.language)
            return MediaRunOutput(text: result.text, seconds: result.seconds, audioSeconds: result.audioSeconds)
        case .textToSpeech:
            guard let out = request.outputURL else { throw ComparisonMediaError.missingOutputPath }
            let result = try await api.speak(path: request.modelPath, text: entry.text, out: out.path)
            return MediaRunOutput(
                seconds: result.seconds, loadSeconds: result.loadSeconds, audioSeconds: result.audioSeconds,
                realTimeFactor: result.realTimeFactor, peakMemoryGB: result.peakMemoryGB
            )
        case .musicGeneration:
            guard let out = request.outputURL else { throw ComparisonMediaError.missingOutputPath }
            let result = try await api.music(path: request.modelPath, caption: entry.text, out: out.path,
                                             parameters: entry.media ?? ComparisonMediaFixtures.musicGenerationParameters)
            return MediaRunOutput(seconds: result.seconds, loadSeconds: result.loadSeconds, audioSeconds: result.audioSeconds,
                                  realTimeFactor: result.realTimeFactor, peakMemoryGB: result.peakMemoryGB)
        case .imageGeneration:
            guard let out = request.outputURL else { throw ComparisonMediaError.missingOutputPath }
            let parameters = entry.media ?? MediaParameters()
            let image = ImageRequest(
                prompt: entry.text, size: parameters.size ?? 512,
                steps: parameters.steps ?? 20, seed: parameters.seed ?? 42
            )
            let result = try await api.generate(path: request.modelPath, out: out.path, request: image)
            return MediaRunOutput(
                seconds: result.seconds, loadSeconds: result.loadSeconds, steps: result.steps, pixelStd: result.pixelStd
            )
        case .videoGeneration:
            guard let out = request.outputURL else { throw ComparisonMediaError.missingOutputPath }
            let result = try await api.video(
                path: request.modelPath, prompt: entry.text, out: out.path,
                parameters: entry.media ?? ComparisonMediaFixtures.videoGenerationParameters
            )
            return MediaRunOutput(
                seconds: result.seconds, loadSeconds: result.loadSeconds, peakMemoryGB: result.peakMemoryGB,
                steps: result.steps, frames: result.frames, secondsPerFrame: result.secondsPerFrame,
                pixelStd: result.pixelStd
            )
        }
    }
}

// MARK: - Scoring

enum ComparisonMediaScoring {
    /// Contains-all, case-insensitive. A keyword written `a|b` is met by either word.
    /// Nil when no keywords were expected.
    static func keywordsMatched(output: String, expected: [String]?) -> Bool? {
        guard let expected, !expected.isEmpty else { return nil }
        let haystack = output.lowercased()
        return expected.allSatisfy { keyword in
            keyword.lowercased().split(separator: "|").contains { alternative in
                let needle = alternative.trimmingCharacters(in: .whitespaces)
                return !needle.isEmpty && haystack.contains(needle)
            }
        }
    }

    /// The sample for one successful prompt: the output, the saved file, and every metric the
    /// mode reports, with speed ratios derived where the agent reports only totals.
    static func sample(
        mode: ComparisonMode,
        entry: PromptEntry,
        output: MediaRunOutput,
        artifact: String?
    ) -> ComparisonSample {
        let text = output.text ?? ""
        let seconds = output.seconds
        let realTimeFactor: Double? = output.realTimeFactor ?? {
            guard mode == .speechToText || mode == .textToSpeech || mode == .musicGeneration,
                  let seconds, let audio = output.audioSeconds, audio > 0 else { return nil }
            return seconds / audio
        }()
        let steps = entry.media?.steps ?? output.steps
        let secondsPerStep: Double? = {
            guard mode == .imageGeneration, let seconds, let steps, steps > 0 else { return nil }
            return seconds / Double(steps)
        }()
        let secondsPerFrame: Double? = output.secondsPerFrame ?? {
            guard mode == .videoGeneration, let seconds, let frames = output.frames ?? entry.media?.frames, frames > 0 else { return nil }
            return seconds / Double(frames)
        }()
        let wordErrorRate: Double? = {
            guard mode == .speechToText, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SpeechCanary.wordErrorRate(reference: entry.text, hypothesis: text)
        }()
        let describes = mode == .vision || mode == .videoUnderstanding
        return ComparisonSample(
            promptID: entry.id,
            outputExcerpt: String(text.prefix(280)),
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil,
            error: nil,
            fullOutput: output.text,
            artifact: artifact,
            seconds: seconds,
            loadSeconds: output.loadSeconds,
            audioSeconds: output.audioSeconds,
            realTimeFactor: realTimeFactor,
            wordErrorRate: wordErrorRate,
            keywordsMatched: describes ? keywordsMatched(output: text, expected: entry.expectedKeywords) : nil,
            generationTokens: output.generationTokens,
            generationTokensPerSecond: output.generationTokensPerSecond,
            peakMemoryGB: output.peakMemoryGB,
            secondsPerStep: secondsPerStep,
            secondsPerFrame: secondsPerFrame,
            pixelStd: output.pixelStd
        )
    }

    static func failedSample(promptID: String, message: String) -> ComparisonSample {
        ComparisonSample(
            promptID: promptID, outputExcerpt: "", tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil, error: message
        )
    }

    /// Median of the mode's primary metric over the samples that measured it.
    static func aggregateMetric(_ samples: [ComparisonSample], mode: ComparisonMode) -> Double? {
        let values = samples.filter { $0.error == nil }.compactMap { mode.primaryMetric.value(of: $0) }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }
}
