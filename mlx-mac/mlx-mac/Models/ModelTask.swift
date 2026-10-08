import Foundation

// MARK: - ModelTaskType
//
// What a model does, as labelled by mlx-agent (`convert scan` items and
// `intake resolve`). Separate from `UseCase`, which is the serving-role
// vocabulary for endpoints, the fleet router, and recommendations.

enum ModelTaskType: String, Codable, CaseIterable, Identifiable {
    case textLLM = "text_llm"
    case visionLanguage = "vision_language"
    case speechToText = "speech_to_text"
    case textToSpeech = "text_to_speech"
    case musicGeneration = "music_generation"
    case embedding = "embedding"
    case classification = "classification"
    case imageGeneration = "image_generation"
    case videoGeneration = "video_generation"
    case speculativeDraft = "speculative_draft"
    case other = "other"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModelTaskType(rawValue: raw) ?? .other
    }

    var title: String {
        switch self {
        case .textLLM: return "Text LLM"
        case .visionLanguage: return "Vision-language"
        case .speechToText: return "Speech-to-text"
        case .textToSpeech: return "Text-to-speech"
        case .musicGeneration: return "Music generation"
        case .embedding: return "Embedding"
        case .classification: return "Classification"
        case .imageGeneration: return "Image generation"
        case .videoGeneration: return "Video generation"
        case .speculativeDraft: return "Speculative drafter"
        case .other: return "Other"
        }
    }

    /// The one SF Symbol for this model type, rendered hierarchically in the
    /// Library rows and the inspector header.
    var symbolName: String {
        switch self {
        case .textLLM: return "text.bubble"
        case .visionLanguage: return "eye"
        case .speechToText: return "waveform"
        case .textToSpeech: return "speaker.wave.2"
        case .musicGeneration: return "music.note"
        case .embedding: return "point.3.connected.trianglepath.dotted"
        case .classification: return "tag"
        case .imageGeneration: return "photo"
        case .videoGeneration: return "film"
        case .speculativeDraft: return "bolt"
        case .other: return "cube"
        }
    }

    /// The Conversion Quality Gate has a canary: chat completions for chat
    /// models, a spoken sentence to transcribe for speech-to-text models, a
    /// support ticket to route for classification models, a render for image models.
    /// A speculative drafter has none: it runs only beside its target model.
    var hasCanary: Bool { isServable || [.speechToText, .classification, .imageGeneration].contains(self) }

    /// Run and Compare serve through mlx-lm's chat server.
    var isServable: Bool { self == .textLLM || self == .visionLanguage }
}

// MARK: - ModelTask

struct ModelTask: Codable, Equatable, Hashable {
    let type: ModelTaskType
    let useCases: [String]
    let source: String
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case type, source, confidence
        case useCases = "use_cases"
    }

    init(type: ModelTaskType, useCases: [String], source: String, confidence: String) {
        self.type = type
        self.useCases = useCases
        self.source = source
        self.confidence = confidence
    }

    init?(dictionary: [String: Any]?) {
        guard let dictionary, let raw = dictionary["type"] as? String else { return nil }
        self.init(
            type: ModelTaskType(rawValue: raw) ?? .other,
            useCases: (dictionary["use_cases"] as? [String]) ?? [],
            source: (dictionary["source"] as? String) ?? "default",
            confidence: (dictionary["confidence"] as? String) ?? "likely"
        )
    }

    var primaryUseCase: String? { useCases.first }
}

// MARK: - ModelDraft
//
// `convert scan`'s `draft` object for a speculative-decoding drafter GGUF:
// the target it drafts for (it borrows that model's embeddings and head) and
// the mlx-agent port that converts it, if any.

struct ModelDraft: Codable, Equatable, Hashable {
    let port: String?
    let target: String?
    let blockSize: Int?

    enum CodingKeys: String, CodingKey {
        case port, target
        case blockSize = "block_size"
    }

    init(port: String?, target: String?, blockSize: Int?) {
        self.port = port
        self.target = target
        self.blockSize = blockSize
    }

    init?(dictionary: [String: Any]?) {
        guard let dictionary else { return nil }
        self.init(
            port: dictionary["port"] as? String,
            target: dictionary["target"] as? String,
            blockSize: dictionary["block_size"] as? Int
        )
    }
}

// MARK: - ModelTaskPresentation

enum ModelTaskPresentation {
    static let unclassifiedUseCase = "unclassified"

    static func useCaseTitle(_ raw: String) -> String {
        switch raw {
        case "coding": return "Coding"
        case "general_chat": return "General chat"
        case "reasoning": return "Reasoning"
        case "vision": return "Image understanding"
        case "ocr_documents": return "OCR & documents"
        case "video": return "Video"
        case "realtime_transcription": return "Realtime transcription"
        case "transcription": return "Transcription"
        case "diarization": return "Diarization"
        case "speech_translation": return "Speech translation"
        case "narration": return "Narration"
        case "voice_cloning": return "Voice cloning"
        case "retrieval": return "Retrieval"
        case "reranking": return "Reranking"
        case "image_generation": return "Image generation"
        case "moderation": return "Moderation"
        case "routing": return "Routing"
        case "classification": return "Classification"
        case "speculative_decoding": return "Speculative decoding"
        case unclassifiedUseCase: return "Unclassified"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func isServable(_ model: LibraryModel) -> Bool {
        model.item.task?.type.isServable ?? true
    }

    /// Serving-role capabilities the RecommendationEngine ranks on.
    static func capabilities(for task: ModelTask) -> [UseCase] {
        guard task.type.isServable else { return [] }
        return task.useCases.compactMap { UseCase(rawValue: $0) }
    }
}
