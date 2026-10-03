import Foundation

// MARK: - Comparison modes
//
// Compare runs chat prompts through the serve probe. The other modes run one
// agent task per variant and prompt (`convert describe|transcribe|speak|
// generate|video`) and keep the output next to the metrics, so the operator
// can read, look at, and listen to what each variant produced.

enum ComparisonMediaKind: String, Codable, Sendable {
    case image
    case video
    case audio
}

/// What a mode's output looks like in the results grid.
enum ComparisonOutputKind: String, Sendable {
    case text
    case image
    case audio
    case video

    /// File extension of the saved artifact.
    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .image: return "png"
        case .audio: return "wav"
        case .video: return "mp4"
        }
    }
}

/// The metric a mode ranks and charts.
enum ComparisonMetric: String, Sendable {
    case tokensPerSecond
    case generationTokensPerSecond
    case realTimeFactor
    case secondsPerStep
    case secondsPerFrame

    var title: String {
        switch self {
        case .tokensPerSecond: return "Decode speed (tok/s)"
        case .generationTokensPerSecond: return "Generation speed (tok/s)"
        case .realTimeFactor: return "Real-time factor (s per audio s)"
        case .secondsPerStep: return "Seconds per step"
        case .secondsPerFrame: return "Seconds per frame"
        }
    }

    var higherIsBetter: Bool {
        switch self {
        case .tokensPerSecond, .generationTokensPerSecond: return true
        case .realTimeFactor, .secondsPerStep, .secondsPerFrame: return false
        }
    }

    func value(of sample: ComparisonSample) -> Double? {
        switch self {
        case .tokensPerSecond: return sample.tokensPerSecond
        case .generationTokensPerSecond: return sample.generationTokensPerSecond
        case .realTimeFactor: return sample.realTimeFactor
        case .secondsPerStep: return sample.secondsPerStep
        case .secondsPerFrame: return sample.secondsPerFrame
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .tokensPerSecond, .generationTokensPerSecond: return String(format: "%.1f tok/s", value)
        case .realTimeFactor: return String(format: "RTF %.2f", value)
        case .secondsPerStep: return String(format: "%.2f s/step", value)
        case .secondsPerFrame: return String(format: "%.2f s/frame", value)
        }
    }
}

enum ComparisonMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case vision
    case videoUnderstanding
    case speechToText
    case textToSpeech
    case imageGeneration
    case videoGeneration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .vision: return "Vision"
        case .videoUnderstanding: return "Video understanding"
        case .speechToText: return "Speech to text"
        case .textToSpeech: return "Text to speech"
        case .imageGeneration: return "Image generation"
        case .videoGeneration: return "Video generation"
        }
    }

    /// Task types whose models can run in this mode. Chat also takes models
    /// with no task label (the Library treats those as servable).
    var acceptedTaskTypes: [ModelTaskType] {
        switch self {
        case .chat: return [.textLLM, .visionLanguage]
        case .vision, .videoUnderstanding: return [.visionLanguage]
        case .speechToText: return [.speechToText]
        case .textToSpeech: return [.textToSpeech]
        case .imageGeneration: return [.imageGeneration]
        case .videoGeneration: return [.videoGeneration]
        }
    }

    func accepts(_ type: ModelTaskType?) -> Bool {
        guard let type else { return self == .chat }
        return acceptedTaskTypes.contains(type)
    }

    /// The input file a prompt carries in this mode; nil for text-only prompts.
    var inputKind: ComparisonMediaKind? {
        switch self {
        case .vision: return .image
        case .videoUnderstanding: return .video
        case .speechToText: return .audio
        case .chat, .textToSpeech, .imageGeneration, .videoGeneration: return nil
        }
    }

    var outputKind: ComparisonOutputKind {
        switch self {
        case .chat, .vision, .videoUnderstanding, .speechToText: return .text
        case .textToSpeech: return .audio
        case .imageGeneration: return .image
        case .videoGeneration: return .video
        }
    }

    var primaryMetric: ComparisonMetric {
        switch self {
        case .chat: return .tokensPerSecond
        case .vision, .videoUnderstanding: return .generationTokensPerSecond
        case .speechToText, .textToSpeech: return .realTimeFactor
        case .imageGeneration: return .secondsPerStep
        case .videoGeneration: return .secondsPerFrame
        }
    }
}

// MARK: - Agent results

/// `convert speak`: one sentence spoken into a new WAV.
struct SpeakResult: Codable, Equatable, Sendable {
    let path: String
    let sampleRate: Int?
    let audioSeconds: Double?
    let seconds: Double?
    let loadSeconds: Double?
    let realTimeFactor: Double?
    let peakMemoryGB: Double?

    enum CodingKeys: String, CodingKey {
        case path, seconds
        case sampleRate = "sample_rate"
        case audioSeconds = "audio_seconds"
        case loadSeconds = "load_seconds"
        case realTimeFactor = "real_time_factor"
        case peakMemoryGB = "peak_memory_gb"
    }
}

/// `convert describe`: one question about an image or a video.
struct DescribeResult: Codable, Equatable, Sendable {
    let text: String
    let promptTokens: Int?
    let generationTokens: Int?
    let promptTps: Double?
    let generationTps: Double?
    let peakMemoryGB: Double?
    let seconds: Double?
    let loadSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case text, seconds
        case promptTokens = "prompt_tokens"
        case generationTokens = "generation_tokens"
        case promptTps = "prompt_tps"
        case generationTps = "generation_tps"
        case peakMemoryGB = "peak_memory_gb"
        case loadSeconds = "load_seconds"
    }
}

/// `convert video`: one prompt rendered into a new MP4.
struct VideoResult: Codable, Equatable, Sendable {
    let path: String
    let width: Int?
    let height: Int?
    let frames: Int?
    let fps: Int?
    let durationSeconds: Double?
    let steps: Int?
    let seed: Int?
    let seconds: Double?
    let loadSeconds: Double?
    let secondsPerFrame: Double?
    let peakMemoryGB: Double?
    let pixelStd: Double?

    enum CodingKeys: String, CodingKey {
        case path, width, height, frames, fps, steps, seed, seconds
        case durationSeconds = "duration_seconds"
        case loadSeconds = "load_seconds"
        case secondsPerFrame = "seconds_per_frame"
        case peakMemoryGB = "peak_memory_gb"
        case pixelStd = "pixel_std"
    }
}
