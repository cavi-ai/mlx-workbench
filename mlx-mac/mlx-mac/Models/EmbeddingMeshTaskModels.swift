import Foundation

struct EmbeddingTextDraft: Equatable, Identifiable, Sendable {
    let id = UUID()
    var text = ""
}

struct EmbeddingTaskDraft: Equatable, Sendable {
    var inputs = [EmbeddingTextDraft()]
    var maxLength = ""
    static let length = IntegerSetting(title: "Maximum tokens", range: 1...8192)

    var validationError: String? {
        InferenceSettings.problem {
            try Self.validate(["input": .array(inputs.map { .string($0.text) })])
            _ = try Self.length.value(maxLength)
        }
    }

    static func validate(_ parameters: [String: JSONValue]) throws {
        guard Set(parameters.keys).isSubset(of: ["input", "max_length"]),
              let inputs = parameters["input"]?.arrayValue, (1...128).contains(inputs.count),
              inputs.allSatisfy({ value in
                  guard let text = value.stringValue else { return false }
                  return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= 32_768
              }), parameters["max_length"] == nil || parameters["max_length"]?.integerValue.map(length.accepts) == true else {
            throw InferenceSettingError(message: "Enter 1–128 nonempty texts of at most 32,768 characters each and a maximum token count from 1 to 8192.")
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        var parameters: [String: JSONValue] = ["input": .array(inputs.map { .string($0.text) })]
        if let length = try Self.length.value(maxLength) { parameters["max_length"] = .number(Double(length)) }
        let request = TaskRequest(kind: .embedding, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest) throws {
        guard request.kind == .embedding else { throw TaskProtocolError.invalidRequest }
        try request.validate()
        inputs = request.parameters["input"]!.arrayValue!.map { EmbeddingTextDraft(text: $0.stringValue!) }
        maxLength = request.parameters["max_length"]?.integerValue.map(String.init) ?? ""
    }
}

/// Shape metadata from a verified embed/1 payload. Vectors remain in the recorded JSON.
struct EmbeddingTaskResult: Equatable, Sendable {
    let count: Int
    let dimensions: Int

    init(raw: JSONValue) throws {
        guard let fields = raw.objectValue, fields["schema"]?.stringValue == "embed/1",
              let dimensions = fields["dimensions"]?.integerValue, dimensions > 0,
              let vectors = fields["embeddings"]?.arrayValue, (1...128).contains(vectors.count),
              vectors.allSatisfy({ row in
                  guard let values = row.arrayValue, values.count == dimensions else { return false }
                  return values.allSatisfy { $0.numberValue?.isFinite == true }
              }) else { throw TaskArtifactVerificationError.invalidJSON }
        self.count = vectors.count
        self.dimensions = dimensions
    }
}

struct MeshGenerationTaskDraft: Equatable, Sendable {
    var imagePath = ""
    var steps = ""
    var seed = ""
    var resolution = ""
    var guidance = ""
    var maxFaces = ""

    private static let integerSettings: [(String, IntegerSetting)] = [
        ("steps", IntegerSetting(title: "Steps", range: 1...100)),
        ("seed", InferenceSettings.seed),
        ("resolution", IntegerSetting(title: "Resolution", range: 16...4096)),
        ("max_faces", IntegerSetting(title: "Maximum faces", range: 1000...10_000_000)),
    ]
    private static let guidanceSetting = NumberSetting(title: "Guidance", range: 1...20)

    var validationError: String? { InferenceSettings.problem { _ = try parameters() } }

    private func parameters() throws -> [String: JSONValue] {
        let values = ["steps": steps, "seed": seed, "resolution": resolution, "max_faces": maxFaces]
        var parameters: [String: JSONValue] = ["image_path": .string(imagePath)]
        for (name, setting) in Self.integerSettings {
            if let value = try setting.value(values[name] ?? "") { parameters[name] = .number(Double(value)) }
        }
        if let value = try Self.guidanceSetting.value(guidance) { parameters["guidance"] = .number(value) }
        try Self.validate(parameters)
        return parameters
    }

    static func validate(_ parameters: [String: JSONValue]) throws {
        guard Set(parameters.keys).isSubset(of: ["image_path", "steps", "seed", "resolution", "guidance", "max_faces"]),
              let path = parameters["image_path"]?.stringValue, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }),
              ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            throw InferenceSettingError(message: "Choose a local PNG, JPEG or WebP image.")
        }
        for (name, setting) in integerSettings where parameters[name] != nil {
            guard let value = parameters[name]?.integerValue else { throw TaskProtocolError.invalidRequest }
            try setting.check(value)
        }
        if let guidance = parameters["guidance"] {
            guard let value = guidance.numberValue else { throw TaskProtocolError.invalidRequest }
            try guidanceSetting.check(value)
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        let request = TaskRequest(kind: .meshGeneration, modelPath: modelPath, parameters: try parameters())
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest, retainedImagePath: String) throws {
        guard request.kind == .meshGeneration else { throw TaskProtocolError.invalidRequest }
        try request.validate()
        var draft = MeshGenerationTaskDraft(imagePath: retainedImagePath)
        draft.steps = request.parameters["steps"]?.integerValue.map(String.init) ?? ""
        draft.seed = request.parameters["seed"]?.integerValue.map(String.init) ?? ""
        draft.resolution = request.parameters["resolution"]?.integerValue.map(String.init) ?? ""
        draft.guidance = request.parameters["guidance"]?.numberValue.map { String($0) } ?? ""
        draft.maxFaces = request.parameters["max_faces"]?.integerValue.map(String.init) ?? ""
        _ = try draft.parameters()
        self = draft
    }
}
