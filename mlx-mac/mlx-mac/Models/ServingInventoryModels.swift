import Foundation

struct ServingMemoryAllocation: Codable, Equatable {
    var budgetBytes: Int64?
    var estimatedResidentBytes: Int64?
    var expertMemoryGB: Double?
    var mode: String?

    enum CodingKeys: String, CodingKey {
        case budgetBytes = "budget_bytes"
        case estimatedResidentBytes = "estimated_resident_bytes"
        case expertMemoryGB = "expert_memory_gb"
        case mode
    }
}

enum ServingResidency: String, Equatable {
    case loaded, unloaded, loading, unloading, failed, unknown

    var title: String {
        switch self {
        case .loaded: "Loaded"
        case .unloaded: "Available · unloaded"
        case .loading: "Loading"
        case .unloading: "Unloading"
        case .failed: "Model failed"
        case .unknown: "Residency unknown"
        }
    }
}

struct ServingServiceObservation: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let providerName: String
    let modelID: String
    let modelPath: String?
    let baseURL: String?
    let runtime: String?
    let residency: ServingResidency
    let isLocal: Bool
    let isWorkbenchManaged: Bool
    let modelProcessID: Int?
    let reportedMemoryBytes: Int64?
    let server: ServerInfo?
    let host: ModelHost?
    let hostedModel: HostedModel?
    let capturedAt: Date
    var hostProcessID: Int? = nil
    var stale = false

    var canUnload: Bool {
        guard !stale else { return false }
        if let server {
            return residency == .loaded && server.state == "running" && server.jit == true && server.activeRequests == 0 &&
                (server.pid.map { $0 > 0 && $0 <= Int(Int32.max) } ?? false) && server.processStartedAt != nil && server.receiptsDirectory != nil
        }
        guard let host, let model = hostedModel else { return false }
        switch host.provider.adapter.releaseScope {
        case .model: return model.isLoaded == true
        case .instance: return model.isLoaded == true && model.loadedInstanceIDs?.count == 1
        case .host: return true
        case nil: return false
        }
    }

    var canStop: Bool {
        !stale && server?.state == "running" && (server?.pid.map { $0 > 0 && $0 <= Int(Int32.max) } ?? false) &&
        server?.processStartedAt != nil && server?.receiptsDirectory != nil
    }

    var name: String {
        if modelID == "__inventory__" { return "Model inventory" }
        return hostedModel?.name ?? modelPath.map {
            ManagedModelInstallStore.presentationIdentity(path: $0)?.displayName ?? URL(fileURLWithPath: $0).lastPathComponent
        } ?? modelID
    }

    var statusText: String {
        if modelID == "__inventory__" { return stale ? "Inventory unavailable" : "No models reported" }
        if stale { return "Last seen · " + residency.title.lowercased() }
        if let server, server.state != "running" { return server.state == "stopped" ? "Stopped" : "Process identity unconfirmed" }
        return residency.title
    }
}

struct ServingEngineSnapshot {
    let servers: [ServerInfo]
    var errors: [String: String] = [:]
    var supportsDiscovery = true
}

struct ServingInventorySnapshot: Equatable {
    var services: [ServingServiceObservation]
    var sourceErrors: [String: String] = [:]
    var capturedAt: Date?

    static let empty = ServingInventorySnapshot(services: [])
    var loadedCount: Int { services.filter { $0.isLocal && !$0.stale && $0.residency == .loaded }.count }
    /// Local services bound to a model path: the ones a Library row marks Serving, loaded or not.
    var servingCount: Int { services.filter { $0.isLocal && $0.modelPath != nil }.count }
    var unknownCount: Int { services.filter { $0.isLocal && $0.modelID != "__inventory__" && ($0.stale || $0.residency == .unknown) }.count }

    static func make(engine: [ServerInfo], hosts: [HostInventory], managedReceipts: String, capturedAt: Date,
                     hostProcessIDs: [UUID: Int] = [:]) -> Self {
        var rows: [ServingServiceObservation] = []
        var seen = Set<String>()
        let normalized: (String) -> String = { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let ordered = engine.sorted { left, right in
            (left.receiptsDirectory.map(normalized) == normalized(managedReceipts) ? 0 : 1) <
            (right.receiptsDirectory.map(normalized) == normalized(managedReceipts) ? 0 : 1)
        }
        for server in ordered {
            guard !server.modelIdentity.isEmpty else { continue }
            let root = server.receiptsDirectory ?? "unscoped"
            let process = server.processStartedAt ?? server.receipt ?? root
            let id = "engine:\(server.pid ?? 0):\(process):\(server.port ?? 0):\(server.modelIdentity)"
            guard seen.insert(id).inserted else { continue }
            let managed = server.receiptsDirectory != nil && normalized(root) == normalized(managedReceipts)
            let residency = server.state == "running" ? (server.modelState.flatMap(ServingResidency.init(rawValue:)) ?? .unknown) : .unknown
            rows.append(ServingServiceObservation(
                id: id, sourceID: "engine:" + normalized(root), providerName: managed ? "MLX Workbench" : "MLX Agent",
                modelID: server.modelIdentity, modelPath: server.path, baseURL: server.port.map { "http://127.0.0.1:\($0)/v1" },
                runtime: server.runtime, residency: residency, isLocal: true, isWorkbenchManaged: managed,
                modelProcessID: server.jit == true ? server.workerPid : server.pid, reportedMemoryBytes: nil,
                server: server, host: nil, hostedModel: nil, capturedAt: capturedAt))
        }
        for inventory in hosts {
            let host = inventory.host
            guard let url = try? host.validatedURL() else { continue }
            if let pid = hostProcessIDs[host.id], engine.contains(where: { $0.pid == pid && $0.port == url.port && $0.state == "running" }) { continue }
            let local = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
            let models = inventory.models + (inventory.runningModels ?? []).filter { running in
                !inventory.models.contains { $0.modelID == running.modelID && $0.digest == running.digest }
            }
            if models.isEmpty {
                rows.append(ServingServiceObservation(id: "host:\(host.id.uuidString):inventory", sourceID: "host:" + host.id.uuidString,
                    providerName: host.name, modelID: "__inventory__", modelPath: nil, baseURL: url.absoluteString,
                    runtime: host.provider.rawValue, residency: .unknown, isLocal: local, isWorkbenchManaged: false,
                    modelProcessID: nil, reportedMemoryBytes: nil, server: nil, host: host, hostedModel: nil,
                    capturedAt: inventory.capturedAt, hostProcessID: hostProcessIDs[host.id]))
            }
            for model in models {
                let id = "host:\(url.absoluteString):\(host.provider.rawValue):\(model.modelID):\(model.digest ?? "")"
                guard seen.insert(id).inserted else { continue }
                let residency: ServingResidency = model.isLoaded.map { $0 ? .loaded : .unloaded } ?? .unknown
                rows.append(ServingServiceObservation(
                    id: id, sourceID: "host:" + host.id.uuidString, providerName: host.name,
                    modelID: model.modelID, modelPath: nil, baseURL: url.absoluteString + ([.comfyUI, .systemOne].contains(host.provider) ? "" : "/v1"), runtime: host.provider.rawValue,
                    residency: residency, isLocal: local, isWorkbenchManaged: false, modelProcessID: nil,
                    reportedMemoryBytes: model.memoryBytes, server: nil, host: host, hostedModel: model,
                    capturedAt: inventory.capturedAt, hostProcessID: hostProcessIDs[host.id]))
            }
        }
        return Self(services: rows.sorted { ($0.providerName, $0.name, $0.id) < ($1.providerName, $1.name, $1.id) }, capturedAt: capturedAt)
    }
}
