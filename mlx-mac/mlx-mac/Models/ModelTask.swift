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
    case embedding = "embedding"
    case imageGeneration = "image_generation"
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
        case .embedding: return "Embedding"
        case .imageGeneration: return "Image generation"
        case .other: return "Other"
        }
    }

    /// The Conversion Quality Gate has a canary: chat completions for chat
    /// models, a spoken sentence to transcribe for speech-to-text models.
    var hasCanary: Bool { isServable || self == .speechToText }

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
