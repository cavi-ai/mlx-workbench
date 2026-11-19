import Foundation

struct ServingHostSnapshot {
    var inventories: [HostInventory] = []
    var errors: [String: String] = [:]
    var processIDs: [UUID: Int] = [:]
}

enum ServingActionKind: String {
    case unload, stop
    case releaseCache = "reclaim-cache"
    var title: String {
        switch self {
        case .unload: "Unload model"
        case .stop: "Stop server"
        case .releaseCache: "Release MLX cache"
        }
    }
}

struct ServingActionReview: Identifiable {
    let id = UUID()
    let service: ServingServiceObservation
    let action: ServingActionKind
}

/// Shared read-only observations; mutations remain with their engine or provider owner.
@MainActor
final class ServingInventoryCoordinator: ObservableObject {
    @Published private(set) var snapshot = ServingInventorySnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isChanging = false
    @Published private(set) var supportsEngineDiscovery = true
    @Published private(set) var actionReview: ServingActionReview?
    @Published private(set) var actionError: String?
    @Published private(set) var processMemory: [Int: UInt64] = [:]
    @Published private(set) var processMemoryCapturedAt: Date?
    var mayChange: (ServingServiceObservation) -> Bool = { _ in true }
    var mutate: (ServingServiceObservation, ServingActionKind) async throws -> Void = { _, _ in
        throw WorkflowEvidenceError.invalid("Serving controls are unavailable.")
    }
    private let managedReceipts: String
    private let fetchEngine: () async throws -> ServingEngineSnapshot
    private let fetchHosts: (Bool) async -> ServingHostSnapshot
    private let now: () -> Date
    private let readMemory: ([Int]) async -> [Int: UInt64]?
    private var engineTask: Task<Result<ServingEngineSnapshot, Error>?, Never>?
    private var hostTask: Task<ServingHostSnapshot?, Never>?
    private var monitoring: Task<Void, Never>?
    private var lastEngine: ServingEngineSnapshot?
    private var lastEngineCapturedAt: Date?
    private var engineError: String?
    private var lastHosts = ServingHostSnapshot()
    private var readingMemory = false

    init(managedReceipts: String, now: @escaping () -> Date = Date.init,
         fetchEngine: @escaping () async throws -> ServingEngineSnapshot,
         fetchHosts: @escaping (Bool) async -> ServingHostSnapshot = { _ in ServingHostSnapshot() },
         readMemory: @escaping ([Int]) async -> [Int: UInt64]? = { pids in
             let captured = await WorkbenchIO.perform { try? ProcessMemorySnapshot.probe(pids: pids.map(Int32.init)) }
             return captured.map { Dictionary(uniqueKeysWithValues: $0.processes.map { (Int($0.pid), $0.residentBytes) }) }
         }) {
        self.managedReceipts = managedReceipts
        self.now = now
        self.fetchEngine = fetchEngine
        self.fetchHosts = fetchHosts
        self.readMemory = readMemory
    }

    func refresh(refreshHosts: Bool = false) async {
        async let engine = refreshEngine()
        if refreshHosts { _ = await refreshHostConnections() }
        else {
            lastHosts = await fetchHosts(false)
            publish()
        }
        _ = await engine
    }

    /// Use the raw results of the completed refresh, not retained display observations.
    func pathsForRemoval() async throws -> [String] {
        async let engineRead = refreshEngine()
        async let hostRead = refreshHostConnections()
        let (engineResult, hostResult) = await (engineRead, hostRead)
        try Task.checkCancellation()
        guard let engineResult, let hostResult else {
            throw ReclaimError.servingOwnershipUnavailable("Serving ownership refresh was interrupted. Refresh Serving, then retry model removal.")
        }
        switch engineResult {
        case .success(let engine):
            return try Self.pathsForRemoval(engine: engine, engineError: nil, hosts: hostResult, managedReceipts: managedReceipts)
        case .failure(let error):
            return try Self.pathsForRemoval(engine: nil, engineError: AppHost.render(error), hosts: hostResult, managedReceipts: managedReceipts)
        }
    }

    static func pathsForRemoval(engine: ServingEngineSnapshot?, engineError: String?,
                                hosts: ServingHostSnapshot, managedReceipts: String) throws -> [String] {
        var issues = hosts.errors
        if let engineError { issues["engine"] = engineError }
        if let engine { issues.merge(engine.errors) { _, newer in newer } }
        if !issues.isEmpty {
            let details = issues.keys.sorted().map { key in
                let name: String
                if key == "local-listeners" { name = "Local server discovery" }
                else if key == "host-settings" { name = "Saved model sources" }
                else if key == "engine" { name = "Serving engine" }
                else if key.hasPrefix("host:"), let inventory = hosts.inventories.first(where: { "host:" + $0.host.id.uuidString == key }) {
                    name = inventory.host.name + " (" + inventory.host.baseURL + ")"
                } else { name = key }
                return name + ": " + (issues[key] ?? "Unavailable")
            }.joined(separator: "\n")
            throw ReclaimError.servingOwnershipUnavailable("Model removal is paused because serving ownership could not be checked. Resolve these issues in Serving, then retry:\n" + details)
        }
        guard let engine, engine.supportsDiscovery, engine.servers.allSatisfy({ !$0.modelIdentity.isEmpty }) else {
            throw ReclaimError.servingOwnershipUnavailable("Serving engine ownership could not be checked. Update the engine or refresh Serving, then retry model removal.")
        }
        let hostServices = ServingInventorySnapshot.make(engine: [], hosts: hosts.inventories,
            managedReceipts: managedReceipts, capturedAt: Date(), hostProcessIDs: hosts.processIDs).services
        let enginePaths = engine.servers.flatMap { [$0.modelIdentity] + [$0.repo, $0.path].compactMap { $0 } }
        return enginePaths + hostServices.filter(\.isLocal).flatMap { [$0.modelID] + [$0.modelPath].compactMap { $0 } }
    }

    private func refreshEngine() async -> Result<ServingEngineSnapshot, Error>? {
        if let engineTask { return await engineTask.value }
        isRefreshing = true
        let task = Task<Result<ServingEngineSnapshot, Error>?, Never> { [weak self] in
            guard let self else { return nil }
            defer { engineTask = nil; isRefreshing = hostTask != nil }
            let outcome: Result<ServingEngineSnapshot, Error>
            do {
                let result = try await fetchEngine()
                guard !Task.isCancelled else { return nil }
                lastEngine = result
                lastEngineCapturedAt = now()
                engineError = nil
                supportsEngineDiscovery = result.supportsDiscovery
                outcome = .success(result)
            } catch {
                guard !Task.isCancelled else { return nil }
                engineError = AppHost.render(error)
                outcome = .failure(error)
            }
            publish()
            await refreshProcessMemory()
            return Task.isCancelled ? nil : outcome
        }
        engineTask = task
        return await task.value
    }

    private func refreshHostConnections() async -> ServingHostSnapshot? {
        if let hostTask { return await hostTask.value }
        isRefreshing = true
        let task = Task<ServingHostSnapshot?, Never> { [weak self] in
            guard let self else { return nil }
            defer { hostTask = nil; isRefreshing = engineTask != nil }
            let result = await fetchHosts(true)
            guard !Task.isCancelled else { return nil }
            lastHosts = result
            publish()
            await refreshProcessMemory()
            return Task.isCancelled ? nil : result
        }
        hostTask = task
        return await task.value
    }

    private func publish() {
        var next = ServingInventorySnapshot.make(engine: engineError == nil ? lastEngine?.servers ?? [] : [],
            hosts: lastHosts.inventories, managedReceipts: managedReceipts,
            capturedAt: lastEngineCapturedAt ?? now(), hostProcessIDs: lastHosts.processIDs)
        next.capturedAt = now()
        next.sourceErrors = lastHosts.errors.merging(lastEngine?.errors ?? [:]) { _, newer in newer }
        if let engineError { next.sourceErrors["engine"] = engineError }
        let freshIDs = Set(next.services.map(\.id))
        for prior in snapshot.services where !freshIDs.contains(prior.id) {
            let engineFailed = prior.sourceID.hasPrefix("engine:") &&
                (engineError != nil || lastEngine?.errors.isEmpty == false || lastEngine?.supportsDiscovery == false && !prior.isWorkbenchManaged)
            if engineFailed || next.sourceErrors[prior.sourceID] != nil {
                var stale = prior; stale.stale = true; next.services.append(stale)
            }
        }
        for index in next.services.indices where next.sourceErrors[next.services[index].sourceID] != nil {
            next.services[index].stale = true
        }
        snapshot = next
    }

    private func refreshProcessMemory() async {
        guard !readingMemory else { return }
        readingMemory = true
        defer { readingMemory = false }
        let pids = Set((snapshot.services.compactMap(\.modelProcessID) + lastHosts.processIDs.values + snapshot.services.compactMap { $0.server?.pid }).filter { $0 > 0 && $0 <= Int(Int32.max) })
        let captured = await readMemory(Array(pids))
        if let captured {
            processMemory = captured
            processMemoryCapturedAt = now()
        }
    }

    func prepare(_ action: ServingActionKind, service: ServingServiceObservation) async {
        guard !isChanging else { return }
        actionError = nil
        actionReview = nil
        await refresh()
        guard let fresh = snapshot.services.first(where: { $0.id == service.id }), !fresh.stale,
              mayChange(fresh), fresh.allows(action) else {
            actionError = "The service changed or is in use. Refresh and review it again."
            return
        }
        actionReview = ServingActionReview(service: fresh, action: action)
    }

    func cancelReview() { if !isChanging { actionReview = nil } }

    func confirm() async {
        guard !isChanging, let review = actionReview else { return }
        guard mayChange(review.service) else { actionError = "Finish work using this model before changing its server."; return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await mutate(review.service, review.action)
            actionReview = nil
            actionError = nil
        } catch { actionError = AppHost.render(error) }
        await refresh()
    }

    func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.refresh(refreshHosts: tick % 3 == 0)
                tick += 1
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    func stopMonitoring() { monitoring?.cancel(); monitoring = nil; engineTask?.cancel(); hostTask?.cancel() }
}
