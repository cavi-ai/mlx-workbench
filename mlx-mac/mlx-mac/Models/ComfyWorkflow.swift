import Foundation

/// An explicitly imported ComfyUI API graph. Only the chosen checkpoint and text
/// inputs are rebound; sampler, seed, negative prompt and other settings survive.
struct ComfyWorkflow: Codable, Equatable, Sendable {
    let apiJSON: String
    let checkpointNodeID: String
    let promptNodeID: String
    let outputNodeID: String

    func validated() throws { _ = try parsedGraph() }

    func submittedGraph(modelID: String, prompt: String) throws -> Data {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComfyWorkflowError.invalid("Choose a checkpoint and enter a prompt.")
        }
        var graph = try parsedGraph()
        var checkpoint = graph[checkpointNodeID]!
        var checkpointInputs = checkpoint["inputs"] as! [String: Any]
        checkpointInputs["ckpt_name"] = modelID
        checkpoint["inputs"] = checkpointInputs
        graph[checkpointNodeID] = checkpoint
        var text = graph[promptNodeID]!
        var textInputs = text["inputs"] as! [String: Any]
        textInputs["text"] = prompt
        text["inputs"] = textInputs
        graph[promptNodeID] = text
        return try JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys])
    }

    // The first supported format deliberately stays with local core image nodes.
    // Installed custom nodes and cloud/API nodes need their own explicit support.
    private static let supportedClasses: Set<String> = [
        "CheckpointLoaderSimple", "CheckpointLoader", "CLIPTextEncode",
        "KSampler", "KSamplerAdvanced", "EmptyLatentImage", "VAEDecode",
        "VAEEncode", "VAELoader", "LoraLoader", "CLIPSetLastLayer",
        "ConditioningCombine", "ConditioningAverage", "ConditioningConcat",
        "LoadImage", "ImageScale", "ImageScaleBy", "SaveImage"
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
                throw ComfyWorkflowError.invalid("This workflow uses an unsupported node. Use a local core image workflow.")
            }
            for value in inputs.values where value is [Any] {
                guard let link = Self.link(value), graph[link.nodeID] != nil else {
                    throw ComfyWorkflowError.invalid("The workflow contains an invalid node link.")
                }
            }
        }
        guard let checkpoint = graph[checkpointNodeID],
              ["CheckpointLoaderSimple", "CheckpointLoader"].contains(checkpoint["class_type"] as? String ?? ""),
              (checkpoint["inputs"] as? [String: Any])?["ckpt_name"] is String,
              let text = graph[promptNodeID], text["class_type"] as? String == "CLIPTextEncode",
              (text["inputs"] as? [String: Any])?["text"] is String,
              let output = graph[outputNodeID], output["class_type"] as? String == "SaveImage",
              Self.link((output["inputs"] as? [String: Any])?["images"] as Any) != nil else {
            throw ComfyWorkflowError.invalid("Bind a checkpoint loader, a CLIPTextEncode text input and a SaveImage output.")
        }
        var visited = Set<String>()
        var visiting = Set<String>()
        func visit(_ id: String) throws {
            guard !visiting.contains(id) else { throw ComfyWorkflowError.invalid("Workflow node links must not contain cycles.") }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for value in (graph[id]!["inputs"] as! [String: Any]).values {
                if let link = Self.link(value) { try visit(link.nodeID) }
            }
            visiting.remove(id)
            visited.insert(id)
        }
        try visit(outputNodeID)
        guard visited.contains(checkpointNodeID), visited.contains(promptNodeID) else {
            throw ComfyWorkflowError.invalid("The chosen checkpoint and prompt must contribute to the selected output.")
        }
        for id in graph.keys { try visit(id) }
        return graph
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
