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
    var id: UUID { run.id }
}
