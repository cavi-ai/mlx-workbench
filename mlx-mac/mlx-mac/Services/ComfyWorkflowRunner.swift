import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ComfyWorkflowOutput: Sendable {
    let imageData: Data
    let fileExtension: String
    let promptID: String
    let submittedGraph: Data
    let durationSeconds: Double
    let queueInclusive: Bool
}

/// Submits an explicit local image or video workflow and observes only its returned job.
/// Cancellation stops local observation; it never interrupts a shared host.
struct ComfyWorkflowRunner: Sendable {
    private static let maxImageBytes = 32 * 1024 * 1024
    private static let maxVideoBytes = 128 * 1024 * 1024
    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "mp4"]

    private let http: HostHTTPClient
    private let pollIntervalNanoseconds: UInt64
    private let timeoutSeconds: TimeInterval

    init(http: HostHTTPClient = HostHTTPClient(), pollIntervalNanoseconds: UInt64 = 1_000_000_000,
         timeoutSeconds: TimeInterval = 900) {
        self.http = http
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.timeoutSeconds = timeoutSeconds
    }

    func run(host: ModelHost, token: String?, modelID: String, prompt: String, workflow: ComfyWorkflow,
             overrides: ComfyWorkflowOverrides? = nil,
             onSubmitted: @escaping @Sendable (String, Data) async throws -> Void) async throws -> ComfyWorkflowOutput {
        guard host.provider == .comfyUI else { throw ComfyWorkflowError.invalid("Choose a ComfyUI host.") }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 86_400 else {
            throw ComfyWorkflowError.invalid("Choose a finite ComfyUI timeout of at most one day.")
        }
        try Task.checkCancellation()
        _ = try host.validatedURL()
        let graphData = try workflow.submittedGraph(modelID: modelID, prompt: prompt, overrides: overrides)
        let graph = try dictionary(graphData)
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let definitions = try dictionary(await request(host: host, path: "/object_info", token: token, deadline: deadline))
        try validateAdvertisedGraph(graph, definitions: definitions, workflow: workflow, modelID: modelID)
        try Task.checkCancellation()
        let payload = try JSONSerialization.data(withJSONObject: ["prompt": graph])
        let started = ProcessInfo.processInfo.systemUptime
        let submission = try dictionary(await request(host: host, path: "/prompt", method: "POST", body: payload, token: token, deadline: deadline))
        guard let promptID = submission["prompt_id"] as? String,
              !promptID.isEmpty, promptID.count <= 128,
              promptID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            throw ComfyWorkflowError.invalid("ComfyUI did not return a valid prompt ID; check its queue before retrying.")
        }
        // Always attempt durable publication after acceptance, even if cancellation
        // arrived with the response. Never report this accepted job as unsubmitted.
        do { try await onSubmitted(promptID, graphData) }
        catch { throw ComfyWorkflowError.ownedPrompt(id: promptID, reason: "The submitted workflow could not be saved.") }
        if submission["error"] != nil || !(submission["node_errors"] as? [String: Any] ?? [:]).isEmpty {
            throw ComfyWorkflowError.ownedPrompt(id: promptID, reason: "The server reported workflow validation errors.")
        }

        while true {
            try Task.checkCancellation()
            let history = try dictionary(await request(host: host, path: "/history/\(promptID)", token: token, deadline: deadline, promptID: promptID))
            if let owned = history[promptID] as? [String: Any], let status = owned["status"] as? [String: Any] {
                if status["status_str"] as? String == "error" {
                    throw ComfyWorkflowError.ownedPrompt(id: promptID, reason: "Workflow execution failed. Inspect the job in ComfyUI.")
                }
                if status["completed"] as? Bool == true, status["status_str"] as? String == "success" {
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    let reference = try mediaReference(owned, outputNodeID: workflow.outputNodeID, promptID: promptID)
                    let maxBytes = reference.fileExtension == "mp4" ? Self.maxVideoBytes : Self.maxImageBytes
                    let media = try await request(host: host, path: "/view", token: token,
                        query: [URLQueryItem(name: "filename", value: reference.filename),
                                URLQueryItem(name: "subfolder", value: reference.subfolder),
                                URLQueryItem(name: "type", value: "output")],
                        maximumBytes: maxBytes, deadline: deadline, promptID: promptID)
                    try validateMedia(media, fileExtension: reference.fileExtension)
                    return ComfyWorkflowOutput(imageData: media, fileExtension: reference.fileExtension,
                        promptID: promptID, submittedGraph: graphData, durationSeconds: elapsed, queueInclusive: true)
                }
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw timeout(promptID) }
            try await Task.sleep(nanoseconds: min(max(pollIntervalNanoseconds, 1_000_000), UInt64(remaining * 1_000_000_000)))
        }
    }

    private func request(host: ModelHost, path: String, method: String = "GET", body: Data? = nil,
                         token: String?, query: [URLQueryItem] = [], maximumBytes: Int = 8_388_608,
                         deadline: TimeInterval, promptID: String? = nil) async throws -> Data {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw timeout(promptID) }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await http.request(host: host, path: path, method: method, body: body,
                    query: query, token: token, maximumBytes: maximumBytes)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw timeout(promptID)
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else {
                throw timeout(promptID)
            }
            return data
        }
    }

    private func timeout(_ promptID: String?) -> ComfyWorkflowError {
        if let promptID { return .ownedPrompt(id: promptID, reason: "Timed out waiting for completion.") }
        return .invalid("The ComfyUI request timed out. Check its queue before retrying a submission.")
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComfyWorkflowError.invalid("ComfyUI returned an invalid response.")
        }
        return value
    }

    private func validateAdvertisedGraph(_ graph: [String: Any], definitions: [String: Any],
                                         workflow: ComfyWorkflow, modelID: String) throws {
        for value in graph.values {
            guard let node = value as? [String: Any],
                  let classType = node["class_type"] as? String else {
                throw ComfyWorkflowError.invalid("The workflow contains a malformed node definition.")
            }
            guard let definition = definitions[classType] as? [String: Any],
                  definition["api_node"] as? Bool != true,
                  !(definition["category"] as? String ?? "").lowercased().contains("api"),
                  !(definition["python_module"] as? String ?? "").lowercased().contains("api"),
                  let advertisedInputs = definition["input"] as? [String: Any],
                  let required = advertisedInputs["required"] as? [String: Any] else {
                throw ComfyWorkflowError.invalid("ComfyUI does not advertise all required local workflow nodes.")
            }
            let optional = advertisedInputs["optional"] as? [String: Any] ?? [:]
            guard let inputs = node["inputs"] as? [String: Any] else {
                throw ComfyWorkflowError.invalid("The workflow node is missing an inputs dictionary.")
            }
            guard required.keys.allSatisfy({ inputs[$0] != nil }) else {
                throw ComfyWorkflowError.invalid("The workflow is missing a required node input.")
            }
            for (name, input) in inputs {
                guard let specification = (required[name] ?? optional[name]) as? [Any], let inputType = specification.first else {
                    throw ComfyWorkflowError.invalid("The workflow contains an unadvertised node input.")
                }
                if let link = ComfyWorkflow.link(input) {
                    guard let source = graph[link.nodeID] as? [String: Any],
                          let sourceClass = source["class_type"] as? String,
                          let sourceDefinition = definitions[sourceClass] as? [String: Any],
                          let outputs = sourceDefinition["output"] as? [String], link.index < outputs.count,
                          let expected = inputType as? String,
                          expected == "*" || outputs[link.index] == expected else {
                        throw ComfyWorkflowError.invalid("A workflow link does not match the server's advertised ports.")
                    }
                } else if let choices = inputType as? [Any] {
                    guard choices.contains(where: { ($0 as? NSObject)?.isEqual(input) == true }) else {
                        throw ComfyWorkflowError.invalid("A workflow input is not among the server's advertised choices.")
                    }
                } else if let type = inputType as? String {
                    let number = input as? NSNumber
                    let isBoolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                    let valid: Bool
                    switch type {
                    case "STRING": valid = input is String
                    case "INT": valid = !isBoolean && input is Int
                    case "FLOAT": valid = !isBoolean && number != nil
                    case "BOOLEAN": valid = isBoolean
                    default: valid = false // Core tensor/model inputs must be links.
                    }
                    guard valid else { throw ComfyWorkflowError.invalid("A workflow input does not match the server's advertised type.") }
                } else { throw ComfyWorkflowError.invalid("ComfyUI returned an unsupported input definition.") }
            }
        }

        guard let modelNode = graph[workflow.checkpointNodeID] as? [String: Any],
              let modelClassType = modelNode["class_type"] as? String,
              let modelKey = ComfyWorkflow.modelInputKey(for: modelClassType),
              let modelDefinition = definitions[modelClassType] as? [String: Any],
              let promptNode = graph[workflow.promptNodeID] as? [String: Any],
              let promptClassType = promptNode["class_type"] as? String,
              let promptDefinition = definitions[promptClassType] as? [String: Any],
              let outputNode = graph[workflow.outputNodeID] as? [String: Any],
              let outputClassType = outputNode["class_type"] as? String,
              let outputDefinition = definitions[outputClassType] as? [String: Any] else {
            throw ComfyWorkflowError.invalid("ComfyUI does not advertise the bound model, prompt, or output nodes.")
        }

        let modelInput = ((modelDefinition["input"] as? [String: Any])?["required"] as? [String: Any])?[modelKey] as? [Any]
        let promptInput = ((promptDefinition["input"] as? [String: Any])?["required"] as? [String: Any])?["text"] as? [Any]
        guard (modelInput?.first as? [String])?.contains(modelID) == true,
              promptInput?.first as? String == "STRING",
              outputDefinition["output_node"] as? Bool == true else {
            throw ComfyWorkflowError.invalid("ComfyUI does not advertise the selected checkpoint, text binding or media output.")
        }
    }

    private func mediaReference(_ history: [String: Any], outputNodeID: String, promptID: String) throws
        -> (filename: String, subfolder: String, fileExtension: String) {
        guard let outputs = history["outputs"] as? [String: Any],
              let output = outputs[outputNodeID] as? [String: Any] else {
            throw ComfyWorkflowError.ownedPrompt(id: promptID, reason: "The selected output has no safe media artifact.")
        }
        let mediaArrays = ["images", "videos", "gifs"].compactMap { output[$0] as? [[String: Any]] }
        guard let item = mediaArrays.first(where: { !$0.isEmpty })?.first,
              let filename = item["filename"] as? String,
              let subfolder = item["subfolder"] as? String,
              item["type"] as? String == "output",
              safePath(filename, allowDirectories: false), safePath(subfolder, allowDirectories: true) else {
            throw ComfyWorkflowError.ownedPrompt(id: promptID, reason: "The selected output has no safe media artifact.")
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else {
            throw ComfyWorkflowError.ownedPrompt(id: promptID, reason: "The selected output has an unsupported media extension.")
        }
        return (filename, subfolder, ext)
    }

    private func safePath(_ path: String, allowDirectories: Bool) -> Bool {
        guard path.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains(":"), !path.contains("%"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        if path.isEmpty { return allowDirectories }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return (allowDirectories || components.count == 1)
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func validateMedia(_ data: Data, fileExtension: String) throws {
        let ext = fileExtension.lowercased()
        if ext == "mp4" {
            try validateMP4(data)
            return
        }
        guard !data.isEmpty, data.count <= Self.maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              let utType = UTType(type as String),
              Self.matchesImageType(utType, fileExtension: ext),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 64_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw ComfyWorkflowError.invalid("ComfyUI returned an invalid or oversized image.")
        }
    }

    private static func matchesImageType(_ utType: UTType, fileExtension: String) -> Bool {
        switch fileExtension {
        case "png": return utType.conforms(to: .png)
        case "jpg", "jpeg": return utType.conforms(to: .jpeg)
        case "webp": return utType.conforms(to: .webP)
        default: return false
        }
    }

    private func validateMP4(_ data: Data) throws {
        guard data.count >= 12, data.count <= Self.maxVideoBytes else {
            throw ComfyWorkflowError.invalid("ComfyUI returned an invalid or oversized MP4 video.")
        }
        let bytes = [UInt8](data.prefix(12))
        let boxSize = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        // ISO BMFF ftyp box: size >= 12 and <= data.count (or 1 for 64-bit extended size), type == "ftyp"
        let validSize = (boxSize >= 12 && Int(boxSize) <= data.count) || (boxSize == 1 && data.count >= 20)
        let isFtyp = bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70
        let validBrand = bytes[8..<12].allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        guard validSize, isFtyp, validBrand else {
            throw ComfyWorkflowError.invalid("ComfyUI returned an invalid or oversized MP4 video.")
        }
    }
}
