import Foundation

struct ServingHostSnapshot {
    var inventories: [HostInventory] = []
    var errors: [String: String] = [:]
    var processIDs: [UUID: Int] = [:]
}

enum ServingActionKind: String {
    case unload, stop
    var title: String { self == .unload ? "Unload model" : "Stop server" }
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
    private var engineTask: Task<Void, Never>?
    private var hostTask: Task<Void, Never>?
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
        async let engine: Void = refreshEngine()
        if refreshHosts { await refreshHostConnections() }
        else {
            lastHosts = await fetchHosts(false)
            publish()
        }
        await engine
    }

    private func refreshEngine() async {
        if let engineTask { await engineTask.value; return }
        isRefreshing = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer { engineTask = nil; isRefreshing = hostTask != nil }
            do {
                let result = try await fetchEngine()
                guard !Task.isCancelled else { return }
                lastEngine = result
                lastEngineCapturedAt = now()
                engineError = nil
                supportsEngineDiscovery = result.supportsDiscovery
            } catch {
                guard !Task.isCancelled else { return }
                engineError = AppHost.render(error)
            }
            publish()
            await refreshProcessMemory()
        }
        engineTask = task
        await task.value
    }

    private func refreshHostConnections() async {
        if let hostTask { await hostTask.value; return }
        isRefreshing = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer { hostTask = nil; isRefreshing = engineTask != nil }
            let result = await fetchHosts(true)
            guard !Task.isCancelled else { return }
            lastHosts = result
            publish()
            await refreshProcessMemory()
        }
        hostTask = task
        await task.value
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
              mayChange(fresh), action == .unload ? fresh.canUnload : fresh.canStop else {
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
