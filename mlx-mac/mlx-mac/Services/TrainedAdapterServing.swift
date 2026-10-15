import Combine
import Foundation

struct TrainedAdapterBinding: Codable, Equatable, Sendable {
    let receiptPath: String
    let receiptSHA256: String
    let runID: String?
    let baseRepo: String
    let basePath: String
    let baseFingerprint: String
    let adapterPath: String
    let adapterIdentity: LabValue

    enum CodingKeys: String, CodingKey {
        case receiptPath = "training_receipt", receiptSHA256 = "training_receipt_sha256", runID = "training_run_id"
        case baseRepo = "base_repo", basePath = "base_path", baseFingerprint = "base_fingerprint"
        case adapterPath = "adapter_path", adapterIdentity = "adapter_identity"
    }
    static func decode(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let binding = try? JSONDecoder().decode(Self.self, from: data), binding.isValid else { return nil }
        return binding
    }
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    var isValid: Bool {
        guard [receiptPath, basePath, adapterPath].allSatisfy({ $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0") }),
              !baseRepo.isEmpty, Self.isHash(receiptSHA256), Self.isHash(baseFingerprint),
              let files = adapterIdentity.object, Set(files.keys) == Set(["adapter_config.json", "adapters.safetensors"]) else { return false }
        return files.values.allSatisfy {
            guard let entry = $0.object, let hash = entry["sha256"]?.text,
                  case .integer(let bytes)? = entry["bytes"], bytes > 0 else { return false }
            return Self.isHash(hash)
        }
    }
    func matches(_ server: ServerInfo) -> Bool {
        server.runtime == "mlx_lm" && HFRepoID.matches(server.modelIdentity, basePath)
            && server.adapterPath == adapterPath && server.adapterIdentity == adapterIdentity && server.trainingBinding == self
    }
}

struct TrainedAdapterServingAPI {
    let preview: (String, Int?) async throws -> [String: Any]
    let start: (String, Int, String) async throws -> [String: Any]
    let status: () async throws -> [ServerInfo]

    static func live(_ api: WorkbenchAPI) -> Self {
        Self(preview: { try await api.trainedAdapterPreview(receipt: $0, port: $1) },
            start: { try await api.trainedAdapterStart(receipt: $0, port: $1, hash: $2) },
            status: { try await api.serveStatus() })
    }
}

struct TrainedAdapterServePreview {
    let binding: TrainedAdapterBinding
    let port: Int
    let hash: String
    let plan: [String: Any]
}

@MainActor
final class TrainedAdapterServingCoordinator: ObservableObject {
    enum Operation: Equatable { case previewing, starting }
    @Published private(set) var selectedJob: TrainingJob?
    @Published private(set) var preview: TrainedAdapterServePreview?
    @Published private(set) var runningServer: ServerInfo?
    @Published private(set) var operation: Operation?
    @Published private(set) var errorMessage: String?
    @Published var portText = "" {
        didSet {
            guard portText != oldValue else { return }
            invalidate()
        }
    }
    private let api: TrainedAdapterServingAPI
    private var revision = 0
    private var confirmed: (preview: TrainedAdapterServePreview, pid: Int, startedAt: String)?

    init(api: TrainedAdapterServingAPI) { self.api = api }
    var isBusy: Bool { operation != nil }
    var portError: String? { RunPortInput(portText).error }
    var canPreview: Bool { selectedJob != nil && !isBusy && portError == nil && runningServer == nil }
    var canConfirm: Bool { !isBusy && preview != nil && portError == nil }

    @discardableResult
    func select(_ job: TrainingJob) -> Bool {
        guard !isBusy else { return false }
        guard job.state == "done", job.adapterIdentity != nil, !job.receipt.isEmpty else {
            errorMessage = "Choose a completed training job with a recorded adapter identity."
            return false
        }
        invalidate()
        selectedJob = job
        return true
    }
    func clear() {
        guard !isBusy else { return }
        invalidate(); selectedJob = nil
    }
    private func invalidate() {
        revision += 1; preview = nil; runningServer = nil; confirmed = nil; errorMessage = nil
    }

    @discardableResult
    func previewServe() -> Task<Void, Never>? {
        guard canPreview, let job = selectedJob else { return nil }
        let revision = revision, requestedPort = RunPortInput(portText).port
        preview = nil; runningServer = nil; confirmed = nil; errorMessage = nil; operation = .previewing
        return Task {
            defer { operation = nil }
            do {
                let plan = try await api.preview(job.receipt, requestedPort)
                guard self.revision == revision else { return }
                guard let binding = TrainedAdapterBinding.decode(plan["training_binding"]),
                      binding.receiptPath == job.receipt, binding.baseRepo == job.repo, binding.adapterIdentity == job.adapterIdentity,
                      let declared = WorkbenchAPI.servers(from: ["servers": [plan]])?.first, binding.matches(declared),
                      let port = plan["port"] as? Int, (1...65535).contains(port), requestedPort == nil || requestedPort == port,
                      let hash = plan["preview_hash"] as? String, TrainedAdapterBinding.isHash(hash) else {
                    throw WorkflowEvidenceError.invalid("The engine did not return the selected training receipt's pinned serving plan. Refresh Training and preview again.")
                }
                let reviewed = TrainedAdapterServePreview(binding: binding, port: port, hash: hash, plan: plan)
                let servers = try await api.status()
                guard self.revision == revision else { return }
                if let existing = servers.first(where: { $0.state == "running" && binding.matches($0) }) {
                    throw WorkflowEvidenceError.invalid("These training artifacts are already serving on port \(existing.port.map(String.init) ?? "unknown"). Manage the existing server below.")
                }
                if servers.contains(where: { $0.port == port && $0.state == "running" }) {
                    throw WorkflowEvidenceError.invalid("Port \(port) is already used by another serving configuration. Choose another port.")
                }
                preview = reviewed
            } catch {
                guard self.revision == revision else { return }
                errorMessage = AppHost.render(error)
            }
        }
    }

    @discardableResult
    func confirmServe() -> Task<Void, Never>? {
        guard canConfirm, let reviewed = preview, let job = selectedJob else { return nil }
        let revision = revision
        preview = nil; errorMessage = nil; operation = .starting
        return Task {
            defer { operation = nil }
            do {
                let response = try await api.start(job.receipt, reviewed.port, reviewed.hash)
                guard self.revision == revision else { return }
                guard let receipt = response["receipt"] as? [String: Any],
                      let declared = WorkbenchAPI.servers(from: ["servers": [receipt]])?.first, reviewed.binding.matches(declared),
                      receipt["preview_hash"] as? String == reviewed.hash,
                      receipt["port"] as? Int == reviewed.port,
                      TrainedAdapterBinding.decode(receipt["training_binding"]) == reviewed.binding,
                      let pid = receipt["pid"] as? Int, pid > 0,
                      let started = receipt["started_at"] as? String, !started.isEmpty else {
                    throw WorkflowEvidenceError.invalid("Server start did not confirm the reviewed trained adapter. Refresh server status before retrying.")
                }
                confirmed = (reviewed, pid, started)
                let servers = try await api.status()
                guard self.revision == revision else { return }
                receiveServers(servers)
                guard runningServer != nil else {
                    throw WorkflowEvidenceError.invalid("The reviewed adapter server was not reported running. Refresh server status before retrying.")
                }
            } catch {
                guard self.revision == revision else { return }
                runningServer = nil; errorMessage = AppHost.render(error)
            }
        }
    }
    func receiveServers(_ servers: [ServerInfo], error: String? = nil) {
        if error != nil { runningServer = nil; return }
        guard let confirmed else { return }
        runningServer = servers.first { $0.state == "running" && $0.port == confirmed.preview.port && $0.pid == confirmed.pid
            && $0.startedAt == confirmed.startedAt && confirmed.preview.binding.matches($0) }
    }
}
