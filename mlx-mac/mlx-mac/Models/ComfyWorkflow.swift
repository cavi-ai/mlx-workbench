import Foundation

/// Typed parameter overrides applied safely when submitting a ComfyUI workflow.
struct ComfyWorkflowOverrides: Codable, Equatable, Sendable {
    var negativePrompt: String?
    var seed: Int?
    var steps: Int?
    var cfg: Double?
    var width: Int?
    var height: Int?

    init(
        negativePrompt: String? = nil,
        seed: Int? = nil,
        steps: Int? = nil,
        cfg: Double? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.negativePrompt = negativePrompt
        self.seed = seed
        self.steps = steps
        self.cfg = cfg
        self.width = width
        self.height = height
    }
}

/// An explicitly imported ComfyUI API graph. Only the chosen model, prompt, and
/// explicitly bound optional inputs are rebound; other graph settings survive.
struct ComfyWorkflow: Codable, Equatable, Sendable {
    let apiJSON: String
    let checkpointNodeID: String
    let promptNodeID: String
    let outputNodeID: String
    let negativePromptNodeID: String?
    let samplerNodeID: String?
    let latentNodeID: String?

    init(
        apiJSON: String,
        checkpointNodeID: String,
        promptNodeID: String,
        outputNodeID: String,
        negativePromptNodeID: String? = nil,
        samplerNodeID: String? = nil,
        latentNodeID: String? = nil
    ) {
        self.apiJSON = apiJSON
        self.checkpointNodeID = checkpointNodeID
        self.promptNodeID = promptNodeID
        self.outputNodeID = outputNodeID
        self.negativePromptNodeID = negativePromptNodeID
        self.samplerNodeID = samplerNodeID
        self.latentNodeID = latentNodeID
    }

    func validated() throws { _ = try parsedGraph() }

    func submittedGraph(
        modelID: String,
        prompt: String,
        overrides: ComfyWorkflowOverrides? = nil
    ) throws -> Data {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComfyWorkflowError.invalid("Choose a checkpoint and enter a prompt.")
        }
        var graph = try parsedGraph()

        guard var checkpoint = graph[checkpointNodeID],
              let checkpointClass = checkpoint["class_type"] as? String,
              let modelKey = Self.modelInputKey(for: checkpointClass),
              var checkpointInputs = checkpoint["inputs"] as? [String: Any] else {
            throw ComfyWorkflowError.invalid("The bound model loader node is invalid.")
        }
        checkpointInputs[modelKey] = modelID
        checkpoint["inputs"] = checkpointInputs
        graph[checkpointNodeID] = checkpoint

        guard var text = graph[promptNodeID],
              var textInputs = text["inputs"] as? [String: Any] else {
            throw ComfyWorkflowError.invalid("The bound prompt node is invalid.")
        }
        textInputs["text"] = prompt
        text["inputs"] = textInputs
        graph[promptNodeID] = text

        if let overrides {
            try applyOverrides(overrides, to: &graph)
        }

        return try JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys])
    }

    static func modelInputKey(for classType: String) -> String? {
        switch classType {
        case "CheckpointLoaderSimple", "CheckpointLoader": return "ckpt_name"
        case "UNETLoader": return "unet_name"
        default: return nil
        }
    }

    static let supportedOutputClasses: Set<String> = [
        "SaveImage", "SaveAnimatedWEBP", "SaveAnimatedPNG",
        "SaveVideo", "VHS_VideoCombine"
    ]

    static let supportedSamplerClasses: Set<String> = [
        "KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced",
        "RandomNoise", "BasicScheduler", "CFGGuider", "DualCFGGuider"
    ]

    static let supportedLatentClasses: Set<String> = [
        "EmptyLatentImage", "EmptySD3LatentImage", "EmptyLTXVLatentVideo",
        "EmptyHunyuanLatentVideo", "EmptyMochiLatentVideo"
    ]

    // Strictly local core image, video, LoRA, and ControlNet nodes.
    // Cloud/API nodes remain explicitly blocked here and in server metadata validation.
    static let supportedClasses: Set<String> = [
        // Model & CLIP loaders
        "CheckpointLoaderSimple", "CheckpointLoader",
        "UNETLoader", "DualCLIPLoader", "CLIPLoader", "TripleCLIPLoader",
        "VAELoader", "LoraLoader", "LoraLoaderModelOnly",
        "ControlNetLoader", "DiffControlNetLoader",
        // Conditioning & guidance
        "CLIPTextEncode", "CLIPTextEncodeFlux", "CLIPTextEncodeSD3", "CLIPSetLastLayer",
        "ConditioningCombine", "ConditioningAverage", "ConditioningConcat",
        "FluxGuidance", "BasicGuider", "CFGGuider", "DualCFGGuider",
        "ControlNetApply", "ControlNetApplyAdvanced",
        "ModelSamplingFlux", "ModelSamplingSD3", "ModelSamplingAuraFlow",
        // Sampling & scheduling
        "KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced",
        "RandomNoise", "BasicScheduler", "KSamplerSelect",
        "SplitSigmas", "FlipSigmas",
        // Latents & VAE
        "EmptyLatentImage", "EmptySD3LatentImage",
        "EmptyLTXVLatentVideo", "EmptyHunyuanLatentVideo", "EmptyMochiLatentVideo",
        "LTXVConditioning", "LTXVScheduler", "LTXVImgToVideo", "LTXVPreprocess",
        "WanImageToVideo", "WanFunControlToVideo", "WanVaceToVideo",
        "VAEDecode", "VAEEncode", "VAEDecodeTiled", "VAEEncodeTiled",
        // Image & video I/O
        "LoadImage", "ImageScale", "ImageScaleBy",
        "CreateVideo", "SaveImage", "SaveAnimatedWEBP", "SaveAnimatedPNG",
        "SaveVideo", "VHS_VideoCombine"
    ]

    func parsedGraph() throws -> [String: [String: Any]] {
        let data = Data(apiJSON.utf8)
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw ComfyWorkflowError.invalid("Import an API workflow no larger than 1 MiB.")
        }
        var uniqueKeys = ComfyJSONUniqueKeys(bytes: Array(data))
        try uniqueKeys.validate()
        guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              !graph.isEmpty, graph.count <= 512 else {
            throw ComfyWorkflowError.invalid("Import the API-format graph from ComfyUI, rather than its canvas export.")
        }
        for (id, node) in graph {
            guard !id.isEmpty, id.count <= 128,
                  id.rangeOfCharacter(from: .controlCharacters) == nil,
                  let classType = node["class_type"] as? String,
                  let inputs = node["inputs"] as? [String: Any], inputs.count <= 128 else {
                throw ComfyWorkflowError.invalid("Every workflow node needs an ID, class_type and inputs.")
            }
            guard Self.supportedClasses.contains(classType) else {
                throw ComfyWorkflowError.invalid("This workflow uses an unsupported node (\(classType)). Use a local supported workflow.")
            }
            if classType == "VHS_VideoCombine" {
                let formats: Set<String> = ["image/webp", "video/h264-mp4", "video/h265-mp4", "video/av1-mp4"]
                guard let format = inputs["format"] as? String, formats.contains(format) else {
                    throw ComfyWorkflowError.invalid("Choose WebP or MP4 output for Video Combine.")
                }
            }
            for value in inputs.values where value is [Any] {
                guard let link = Self.link(value), graph[link.nodeID] != nil else {
                    throw ComfyWorkflowError.invalid("The workflow contains an invalid node link.")
                }
            }
        }

        guard let checkpoint = graph[checkpointNodeID],
              let checkpointClass = checkpoint["class_type"] as? String,
              let modelKey = Self.modelInputKey(for: checkpointClass),
              (checkpoint["inputs"] as? [String: Any])?[modelKey] is String,
              let text = graph[promptNodeID],
              text["class_type"] as? String == "CLIPTextEncode",
              (text["inputs"] as? [String: Any])?["text"] is String,
              let output = graph[outputNodeID],
              let outputClass = output["class_type"] as? String,
              Self.supportedOutputClasses.contains(outputClass),
              let outputInputs = output["inputs"] as? [String: Any],
              Self.hasValidOutputLink(classType: outputClass, inputs: outputInputs) else {
            throw ComfyWorkflowError.invalid("Bind a supported model loader, a CLIPTextEncode text input and a supported output node.")
        }

        if let negativePromptNodeID {
            guard let negNode = graph[negativePromptNodeID],
                  negNode["class_type"] as? String == "CLIPTextEncode",
                  (negNode["inputs"] as? [String: Any])?["text"] is String else {
                throw ComfyWorkflowError.invalid("The bound negative prompt node must be a CLIPTextEncode node with a text input.")
            }
        }

        if let samplerNodeID {
            guard let samplerNode = graph[samplerNodeID],
                  let samplerClass = samplerNode["class_type"] as? String,
                  Self.supportedSamplerClasses.contains(samplerClass) else {
                throw ComfyWorkflowError.invalid("The bound sampler node must be a supported sampler or guidance node.")
            }
        }

        if let latentNodeID {
            guard let latentNode = graph[latentNodeID],
                  let latentClass = latentNode["class_type"] as? String,
                  Self.supportedLatentClasses.contains(latentClass),
                  let latentInputs = latentNode["inputs"] as? [String: Any],
                  Self.nonBooleanInt(latentInputs["width"]) != nil,
                  Self.nonBooleanInt(latentInputs["height"]) != nil else {
                throw ComfyWorkflowError.invalid("The bound latent node must be a supported empty latent node with integer width and height.")
            }
        }

        var visited = Set<String>()
        var visiting = Set<String>()
        func visit(_ id: String) throws {
            guard !visiting.contains(id) else {
                throw ComfyWorkflowError.invalid("Workflow node links must not contain cycles.")
            }
            guard !visited.contains(id) else { return }
            guard let node = graph[id], let inputs = node["inputs"] as? [String: Any] else {
                throw ComfyWorkflowError.invalid("The workflow contains a malformed node reference.")
            }
            visiting.insert(id)
            for value in inputs.values {
                if let link = Self.link(value) { try visit(link.nodeID) }
            }
            visiting.remove(id)
            visited.insert(id)
        }
        try visit(outputNodeID)
        guard visited.contains(checkpointNodeID), visited.contains(promptNodeID) else {
            throw ComfyWorkflowError.invalid("The chosen checkpoint and prompt must contribute to the selected output.")
        }
        if let negativePromptNodeID, !visited.contains(negativePromptNodeID) {
            throw ComfyWorkflowError.invalid("The bound negative prompt node must contribute to the selected output.")
        }
        if let samplerNodeID, !visited.contains(samplerNodeID) {
            throw ComfyWorkflowError.invalid("The bound sampler node must contribute to the selected output.")
        }
        if let latentNodeID, !visited.contains(latentNodeID) {
            throw ComfyWorkflowError.invalid("The bound latent node must contribute to the selected output.")
        }
        for id in graph.keys { try visit(id) }
        return graph
    }

    private func applyOverrides(_ overrides: ComfyWorkflowOverrides, to graph: inout [String: [String: Any]]) throws {
        if let negativePrompt = overrides.negativePrompt {
            guard negativePrompt.utf8.count <= 65_536 else {
                throw ComfyWorkflowError.invalid("Negative prompt override exceeds maximum length.")
            }
            guard let negativePromptNodeID,
                  var negNode = graph[negativePromptNodeID],
                  var negInputs = negNode["inputs"] as? [String: Any] else {
                throw ComfyWorkflowError.invalid("Bind a negative prompt node to override negative prompt.")
            }
            negInputs["text"] = negativePrompt
            negNode["inputs"] = negInputs
            graph[negativePromptNodeID] = negNode
        }

        if overrides.seed != nil || overrides.steps != nil || overrides.cfg != nil {
            if let seed = overrides.seed {
                guard seed >= 0 else {
                    throw ComfyWorkflowError.invalid("Seed override must be non-negative.")
                }
            }
            if let steps = overrides.steps {
                guard (1...1_000).contains(steps) else {
                    throw ComfyWorkflowError.invalid("Steps override must be between 1 and 1000.")
                }
            }
            if let cfg = overrides.cfg {
                guard cfg.isFinite, cfg >= 0, cfg <= 100 else {
                    throw ComfyWorkflowError.invalid("CFG override must be a finite number between 0 and 100.")
                }
            }
            guard let samplerNodeID,
                  var samplerNode = graph[samplerNodeID],
                  let samplerClass = samplerNode["class_type"] as? String,
                  var samplerInputs = samplerNode["inputs"] as? [String: Any] else {
                throw ComfyWorkflowError.invalid("Bind a sampler node to override seed, steps, or cfg.")
            }

            if samplerClass == "SamplerCustomAdvanced" {
                if let seed = overrides.seed {
                    try setLinkedInput(
                        from: samplerInputs["noise"],
                        inputKey: "noise_seed",
                        value: seed,
                        in: &graph,
                        errorMessage: "SamplerCustomAdvanced requires a linked noise node with noise_seed to override seed."
                    )
                }
                if let steps = overrides.steps {
                    try setLinkedInput(
                        from: samplerInputs["sigmas"],
                        inputKey: "steps",
                        value: steps,
                        in: &graph,
                        errorMessage: "SamplerCustomAdvanced requires a linked scheduler node with steps to override steps."
                    )
                }
                if let cfg = overrides.cfg {
                    try setLinkedInput(
                        from: samplerInputs["guider"],
                        inputKey: "cfg",
                        value: cfg,
                        in: &graph,
                        errorMessage: "SamplerCustomAdvanced requires a linked CFGGuider node with cfg to override cfg."
                    )
                }
            } else {
                if let seed = overrides.seed {
                    if samplerInputs["seed"] != nil {
                        samplerInputs["seed"] = seed
                    } else if samplerInputs["noise_seed"] != nil {
                        samplerInputs["noise_seed"] = seed
                    } else {
                        throw ComfyWorkflowError.invalid("The bound sampler node does not accept a seed input.")
                    }
                }
                if let steps = overrides.steps {
                    guard samplerInputs["steps"] != nil else {
                        throw ComfyWorkflowError.invalid("The bound sampler node does not accept a steps input.")
                    }
                    samplerInputs["steps"] = steps
                }
                if let cfg = overrides.cfg {
                    guard samplerInputs["cfg"] != nil else {
                        throw ComfyWorkflowError.invalid("The bound sampler node does not accept a cfg input.")
                    }
                    samplerInputs["cfg"] = cfg
                }
                samplerNode["inputs"] = samplerInputs
                graph[samplerNodeID] = samplerNode
            }
        }

        if overrides.width != nil || overrides.height != nil {
            if let width = overrides.width {
                guard (64...16_384).contains(width) else {
                    throw ComfyWorkflowError.invalid("Width override must be between 64 and 16384.")
                }
            }
            if let height = overrides.height {
                guard (64...16_384).contains(height) else {
                    throw ComfyWorkflowError.invalid("Height override must be between 64 and 16384.")
                }
            }
            guard let latentNodeID,
                  var latentNode = graph[latentNodeID],
                  var latentInputs = latentNode["inputs"] as? [String: Any] else {
                throw ComfyWorkflowError.invalid("Bind a latent node to override width or height.")
            }
            let effectiveWidth = overrides.width ?? Self.nonBooleanInt(latentInputs["width"]) ?? 0
            let effectiveHeight = overrides.height ?? Self.nonBooleanInt(latentInputs["height"]) ?? 0
            guard effectiveWidth > 0, effectiveHeight > 0,
                  effectiveWidth * effectiveHeight <= 64_000_000 else {
                throw ComfyWorkflowError.invalid("Latent dimensions exceed maximum supported pixel count.")
            }
            if let width = overrides.width { latentInputs["width"] = width }
            if let height = overrides.height { latentInputs["height"] = height }
            latentNode["inputs"] = latentInputs
            graph[latentNodeID] = latentNode
        }
    }

    private func setLinkedInput(
        from linkValue: Any?,
        inputKey: String,
        value: Any,
        in graph: inout [String: [String: Any]],
        errorMessage: String
    ) throws {
        guard let linkValue,
              let link = Self.link(linkValue),
              var targetNode = graph[link.nodeID],
              var targetInputs = targetNode["inputs"] as? [String: Any],
              targetInputs[inputKey] != nil else {
            throw ComfyWorkflowError.invalid(errorMessage)
        }
        targetInputs[inputKey] = value
        targetNode["inputs"] = targetInputs
        graph[link.nodeID] = targetNode
    }

    private static func hasValidOutputLink(classType: String, inputs: [String: Any]) -> Bool {
        if classType == "SaveVideo" {
            if let video = inputs["video"], Self.link(video) != nil { return true }
            if let images = inputs["images"], Self.link(images) != nil { return true }
            return false
        }
        guard let images = inputs["images"] else { return false }
        return Self.link(images) != nil
    }

    private static func nonBooleanInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let intValue = value as? Int else { return nil }
        return intValue
    }

    static func link(_ value: Any) -> (nodeID: String, index: Int)? {
        guard let array = value as? [Any], array.count == 2,
              let nodeID = array[0] as? String, let number = array[1] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let index = array[1] as? Int, index >= 0, index <= 1024 else { return nil }
        return (nodeID, index)
    }
}

enum ComfyWorkflowError: LocalizedError {
    case invalid(String)
    case ownedPrompt(id: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .ownedPrompt(let id, let reason):
            return "ComfyUI prompt \(id): \(reason) The host may retain this job."
        }
    }
}

/// Foundation keeps the last duplicate JSON object key. Reject duplicates before
/// decoding so an ambiguous imported graph cannot silently change its nodes.
private struct ComfyJSONUniqueKeys {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw malformed }
    }

    private var malformed: ComfyWorkflowError { .invalid("The workflow is not valid, unambiguous JSON.") }
    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw malformed }
        index += 1
    }
    private mutating func string() throws -> String {
        whitespace()
        let start = index
        try consume(34)
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            index += 1
        }
        throw malformed
    }
    private mutating func value(depth: Int) throws {
        whitespace()
        guard depth <= 128, index < bytes.count else { throw malformed }
        switch bytes[index] {
        case 123:
            index += 1
            whitespace()
            var keys = Set<String>()
            if index < bytes.count, bytes[index] != 125 {
                while true {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw malformed }
                    try consume(58)
                    try value(depth: depth + 1)
                    whitespace()
                    guard index < bytes.count else { throw malformed }
                    if bytes[index] != 44 { break }
                    index += 1
                }
            }
            try consume(125)
        case 91:
            index += 1
            whitespace()
            if index < bytes.count, bytes[index] != 93 {
                while true {
                    try value(depth: depth + 1)
                    whitespace()
                    guard index < bytes.count else { throw malformed }
                    if bytes[index] != 44 { break }
                    index += 1
                }
            }
            try consume(93)
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw malformed }
        }
    }
}
