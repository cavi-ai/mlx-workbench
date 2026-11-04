import Foundation

// MARK: - Comparison modes
//
// Compare runs chat prompts through the serve probe. The other modes run one
// agent task per variant and prompt (`convert describe|transcribe|speak|
// generate|video|mesh|decide`) and keep the output next to the metrics, so the
// operator can read, look at, and listen to what each variant produced.

enum ComparisonMediaKind: String, Codable, Sendable {
    case image
    case video
    case audio
}

/// A Library selection prepares a comparison; it never starts a task.
struct ComparisonModelRequest: Identifiable, Equatable {
    let id = UUID()
    let modelPath: String
    let mode: ComparisonMode

    init?(model: LibraryModel) {
        guard model.readiness == .ready, let mode = ComparisonMode.preferred(for: model.item) else { return nil }
        modelPath = model.item.path
        self.mode = mode
    }

    func resolve(in models: [LibraryModel]) -> LibraryModel? {
        models.first { $0.item.path == modelPath && $0.readiness == .ready && mode.supports($0.item) }
    }
}

/// What a mode's output looks like in the results grid.
enum ComparisonOutputKind: String, Sendable {
    case text
    case image
    case audio
    case video
    case mesh

    /// File extension of the saved artifact.
    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .image: return "png"
        case .audio: return "wav"
        case .video: return "mp4"
        case .mesh: return "glb"
        }
    }
}

/// The metric a mode ranks and charts.
enum ComparisonMetric: String, Sendable {
    case decisionAccuracy
    case generationSeconds
    case tokensPerSecond
    case generationTokensPerSecond
    case realTimeFactor
    case secondsPerStep
    case secondsPerFrame

    var title: String {
        switch self {
        case .decisionAccuracy: return "Answers correct"
        case .generationSeconds: return "Generation time (s)"
        case .tokensPerSecond: return "Decode speed (tok/s)"
        case .generationTokensPerSecond: return "Generation speed (tok/s)"
        case .realTimeFactor: return "Real-time factor (s per audio s)"
        case .secondsPerStep: return "Seconds per step"
        case .secondsPerFrame: return "Seconds per frame"
        }
    }

    var higherIsBetter: Bool {
        switch self {
        case .tokensPerSecond, .generationTokensPerSecond, .decisionAccuracy: return true
        case .realTimeFactor, .secondsPerStep, .secondsPerFrame, .generationSeconds: return false
        }
    }

    func value(of sample: ComparisonSample) -> Double? {
        switch self {
        case .decisionAccuracy: return sample.decision?.accuracy
        case .generationSeconds: return sample.seconds
        case .tokensPerSecond: return sample.tokensPerSecond
        case .generationTokensPerSecond: return sample.generationTokensPerSecond
        case .realTimeFactor: return sample.realTimeFactor
        case .secondsPerStep: return sample.secondsPerStep
        case .secondsPerFrame: return sample.secondsPerFrame
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .decisionAccuracy: return String(format: "%.0f%% correct", value * 100)
        case .generationSeconds: return String(format: "%.2f s", value)
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
    case musicGeneration
    case imageGeneration
    case videoGeneration
    case meshGeneration
    case classification

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .vision: return "Vision"
        case .videoUnderstanding: return "Video understanding"
        case .speechToText: return "Speech to text"
        case .textToSpeech: return "Text to speech"
        case .musicGeneration: return "Music generation"
        case .imageGeneration: return "Image generation"
        case .videoGeneration: return "Video generation"
        case .meshGeneration: return "3D generation"
        case .classification: return "Classification"
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
        case .musicGeneration: return [.musicGeneration]
        case .imageGeneration: return [.imageGeneration]
        case .videoGeneration: return [.videoGeneration]
        case .meshGeneration: return [.meshGeneration]
        case .classification: return [.classification]
        }
    }

    func accepts(_ type: ModelTaskType?) -> Bool {
        guard let type else { return self == .chat }
        return acceptedTaskTypes.contains(type)
    }

    /// Runtime restrictions take precedence over the architecture's task label.
    func supports(_ item: ModelItem) -> Bool {
        accepts(item.task?.type) && (item.servingRuntime != "strata" || self == .chat)
    }

    static func preferred(for item: ModelItem) -> ComparisonMode? {
        allCases.first { $0.supports(item) }
    }

    /// The input file a prompt carries in this mode; nil for text-only prompts.
    var inputKind: ComparisonMediaKind? {
        switch self {
        case .vision, .meshGeneration: return .image
        case .videoUnderstanding: return .video
        case .speechToText: return .audio
        case .chat, .textToSpeech, .musicGeneration, .imageGeneration, .videoGeneration, .classification: return nil
        }
    }

    var outputKind: ComparisonOutputKind {
        switch self {
        case .chat, .vision, .videoUnderstanding, .speechToText, .classification: return .text
        case .textToSpeech, .musicGeneration: return .audio
        case .imageGeneration: return .image
        case .videoGeneration: return .video
        case .meshGeneration: return .mesh
        }
    }

    /// The value this mode ranks a result by; only positive, finite values count,
    /// except accuracy, where no correct answers is a measured zero.
    func metricValue(of result: VariantResult) -> Double? {
        let value = self == .chat ? result.aggregateTokensPerSecond : result.aggregateMetric
        if self == .classification { return value.flatMap { (0...1).contains($0) ? $0 : nil } }
        return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var primaryMetric: ComparisonMetric {
        switch self {
        case .chat: return .tokensPerSecond
        case .vision, .videoUnderstanding: return .generationTokensPerSecond
        case .speechToText, .textToSpeech, .musicGeneration: return .realTimeFactor
        case .imageGeneration: return .secondsPerStep
        case .videoGeneration: return .secondsPerFrame
        case .meshGeneration: return .generationSeconds
        case .classification: return .decisionAccuracy
        }
    }
}

/// `convert mesh`: image-conditioned shape generation into a binary glTF file.
struct MeshResult: Codable, Sendable {
    let path: String
    let seconds: Double?
    let loadSeconds: Double?
    let peakMemoryGB: Double?
    let vertices: Int?
    let faces: Int?

    enum CodingKeys: String, CodingKey {
        case path, seconds, vertices, faces
        case loadSeconds = "load_seconds"
        case peakMemoryGB = "peak_memory_gb"
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
    let fps: Double?
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
