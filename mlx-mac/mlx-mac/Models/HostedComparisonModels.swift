import Foundation

enum HostedIntegrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// A comparison lane captures its source; a host identifier is never a local file path.
struct HostedComparisonTarget: Codable, Equatable, Identifiable, Sendable {
    let host: ModelHost?
    let model: HostedModel?
    let localPath: String?
    let localSignature: String?
    let displayName: String
    let capturedAt: Date
    let runtimeVersion: String?
    var deviceSummary: String? = nil

    init(host: ModelHost, model: HostedModel, capturedAt: Date, runtimeVersion: String? = nil) {
        self.host = host; self.model = model; self.capturedAt = capturedAt; self.runtimeVersion = runtimeVersion
        localPath = nil; localSignature = nil; displayName = "\(model.name) · \(host.name)"
    }

    init(local model: LibraryModel, capturedAt: Date) {
        host = nil; self.model = nil; localPath = model.item.path; localSignature = model.item.signature
        displayName = "\(model.displayName) · MLX Workbench"; self.capturedAt = capturedAt; runtimeVersion = nil
    }

    var id: String { model?.id ?? "local:\(localPath ?? "")" }
    var signature: String? { model?.digest ?? localSignature }

    func validate(mode: ComparisonMode) throws {
        if let host, let model {
            _ = try host.validatedURL()
            guard model.hostID == host.id, !model.modelID.isEmpty else {
                throw HostedIntegrationError.invalid("The selected model does not belong to this host. Refresh its inventory.")
            }
            if mode == .imageGeneration {
                guard host.provider == .comfyUI, model.category == "checkpoints" else {
                    throw HostedIntegrationError.invalid("Image workflow comparisons require ComfyUI checkpoints.")
                }
            } else {
                guard mode == .chat, host.provider != .comfyUI,
                      model.category != "embedding", model.category != "embeddings", model.category != "decision",
                      model.capabilities?.contains("decisions output") != true,
                      model.capabilities.map({ !$0.contains("embedding") || $0.contains("completion") || $0.contains("chat") }) ?? true else {
                    throw HostedIntegrationError.invalid("This model is not available for text comparisons.")
                }
            }
        } else {
            guard mode == .chat, host == nil, model == nil, let localPath, localPath.hasPrefix("/"),
                  !localPath.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw HostedIntegrationError.invalid("Select a ready local chat model.")
            }
        }
    }
}

struct HostedWorkflowSubmission: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let targetID: String
    let promptID: String
    let remotePromptID: String
    let graphJSON: String
    let submittedAt: Date
}

struct HostedComparisonRecord: Codable, Equatable, Identifiable, Sendable {
    var run: ComparisonRun
    let targets: [HostedComparisonTarget]
    /// Actual common request settings. Host-managed defaults remain in the captured inventory.
    let temperature: Double
    let workflow: ComfyWorkflow?
    var submissions: [HostedWorkflowSubmission]
    var observedTargets: [HostedComparisonTarget]? = nil
    /// Nil identifies older records; an empty array means no lane reached observation.
    var conditions: [HostedLaneConditions]? = nil
    var id: UUID { run.id }

    var conditionsNotice: String? {
        guard let conditions else { return nil }
        if conditions.contains(where: { !$0.timingCaveats.isEmpty }) {
            return "Recorded activity, other loaded models or limited headroom may affect timings. Review the recorded conditions below."
        }
        if conditions.contains(where: { $0.inventoryCapturedAt != nil && ($0.activity == nil || $0.activity?.state == .unknown) }) {
            return "Other-client activity was unknown before one or more lanes. Review the recorded conditions below."
        }
        return nil
    }
}

/// Independent before-lane observations, never per-model allocation or continuous monitoring.
struct HostedLaneConditions: Codable, Equatable, Sendable {
    let targetID: String
    let memoryCapturedAt: Date
    let systemMemory: MemorySnapshot?
    let reserveBytes: Int64
    let inventoryCapturedAt: Date?
    let activity: HostActivity?
    let loadedModels: [HostedModel]?
    let unknownResidencyCount: Int?
    let inventoryWarnings: [String]?
    var deviceMemory: HostDeviceMemorySnapshot? = nil

    var loadedStateSummary: String {
        guard let loadedModels else { return "Loaded model state unknown" }
        if loadedModels.isEmpty && unknownResidencyCount != 0 { return "Loaded model state unknown" }
        return "\(loadedModels.count) \(loadedModels.count == 1 ? "model" : "models") reported loaded"
    }

    var validMemory: MemorySnapshot? {
        guard let systemMemory, systemMemory.totalBytes > 0,
              (0...systemMemory.totalBytes).contains(systemMemory.availableBytes) else { return nil }
        return systemMemory
    }

    var timingCaveats: [String] {
        var caveats: [String] = []
        if let activity, activity.state == .busy || activity.state == .queued {
            caveats.append("The host reported running or queued work before this lane.")
        }
        if loadedModels?.contains(where: { $0.id != targetID }) == true {
            caveats.append("Other models were also reported loaded on this host.")
        }
        if let memory = validMemory, reserveBytes > 0, memory.availableBytes < reserveBytes {
            caveats.append("System headroom was below the recorded reserve for model fit.")
        }
        return caveats
    }
}
