import Foundation

struct WorkspaceProfile: Codable, Equatable, Hashable {
    struct GenerationDefaults: Codable, Equatable, Hashable {
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
        let seed: Int?

        init(temperature: Double? = nil, topP: Double? = nil, maxTokens: Int? = nil, seed: Int? = nil) {
            self.temperature = temperature
            self.topP = topP
            self.maxTokens = maxTokens
            self.seed = seed
        }

        private enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case maxTokens = "max_tokens"
            case seed
        }
    }

    let name: String
    let useCase: UseCase
    let modelIdentity: String
    let modelPath: String?
    let runtime: String
    let generationDefaults: GenerationDefaults
    let savedAt: Date

    init(
        name: String,
        useCase: UseCase,
        modelIdentity: String,
        modelPath: String? = nil,
        runtime: String,
        generationDefaults: GenerationDefaults = .init(),
        savedAt: Date
    ) {
        self.name = name
        self.useCase = useCase
        self.modelIdentity = modelIdentity
        self.modelPath = modelPath
        self.runtime = runtime
        self.generationDefaults = generationDefaults
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case useCase
        case modelIdentity = "model_identity"
        case modelPath = "model_path"
        case runtime
        case generationDefaults = "generation_defaults"
        case savedAt = "saved_at"
    }
}
