import Foundation

// MARK: - EndpointSupervisor
//
// Always-on Endpoint (premium spec 06), fleet-shaped internally (spec 09
// P1). Keeps every enabled slot's model serving on its stable loopback port
// by reconciling desired state (persisted fleet config) against
// authoritative serve status on a timer and on app launch.
//
// The legacy single-slot API (`config`, `state`, `restartAttempts`,
// `enable`/`swap`/`disable`) is kept as a shim over the first slot so the
// existing call sites and tests stay green during the transition.
//
// Boundaries: serving goes through mlx-agent's serve preview/confirm/start/
// stop (argv tokens, preview hashes); the supervisor never invents process
// state — `serve status` is the authority. Crash-loop guard: at most
// `maxRestarts` starts per slot inside `restartWindow`, then degraded.

@MainActor
final class EndpointSupervisor: ObservableObject {
    @Published private(set) var fleet: EndpointFleetConfig
    @Published private(set) var state: EndpointState = .disabled
    @Published private(set) var restartAttempts = 0
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?
    /// Per-slot live state and restart counters (fleet surface; P2 UI).
    @Published private(set) var slotStates: [UUID: EndpointState] = [:]
    @Published private(set) var slotRestartAttempts: [UUID: Int] = [:]

    /// Legacy single-slot view: the first slot plus the login-item flag.
    /// Removed when the transition shim is dropped (spec 09 rollout).
    var config: EndpointConfig {
        let slot = fleet.slots.first
        return EndpointConfig(
            enabled: slot?.enabled ?? false,
            port: slot?.port ?? EndpointConfig.defaultPort,
            modelPath: slot?.modelPath ?? "",
            installedAtLogin: fleet.installedAtLogin
        )
    }

    private let lifecycle: ServeLifecycle
    private let statusProvider: @Sendable () async throws -> [ServerInfo]
    private let fleetStore: EndpointFleetStore
    private let now: () -> Date
    private let maxRestarts: Int
    private let restartWindow: TimeInterval

    /// Verification gate: returns true when the model passed the canary
    /// suite. Wired by AppHost; nil means "no gate attached" (allow).
    var isVerified: ((String) -> Bool)?

    private var slotAttemptTimestamps: [UUID: [Date]] = [:]
    private var monitorTask: Task<Void, Never>?

    init(
        lifecycle: ServeLifecycle,
        statusProvider: @escaping @Sendable () async throws -> [ServerInfo],
        store: JSONStore<EndpointConfig>,
        fleetStore: JSONStore<EndpointFleetConfig>? = nil,
        now: @escaping () -> Date = Date.init,
        maxRestarts: Int = 3,
        restartWindow: TimeInterval = 300
    ) {
        self.lifecycle = lifecycle
        self.statusProvider = statusProvider
        self.fleetStore = EndpointFleetStore(
            fleetStore: fleetStore ?? EndpointFleetStore.defaultFleetStore(legacyStore: store),
            legacyStore: store
        )
        self.now = now
        self.maxRestarts = maxRestarts
        self.restartWindow = restartWindow
        let loaded = self.fleetStore.load()
        self.fleet = loaded.config
        self.persistenceError = loaded.problem
    }

    // MARK: - User actions (single-slot shim)

    /// Enable the endpoint for a model. Verified models only, unless the
    /// user explicitly overrides (the same discipline as the quality gate).
    /// Enable from raw UI text: an empty field means the default port; a
    /// non-numeric or out-of-range value is refused with an error instead of
    /// being silently coerced onto the default port.
    func enable(modelPath: String, portText: String, allowUnverified: Bool = false) async {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await enable(modelPath: modelPath, port: EndpointConfig.defaultPort, allowUnverified: allowUnverified)
            return
        }
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            lastError = "Port must be a number between 1 and 65535."
            return
        }
        await enable(modelPath: modelPath, port: port, allowUnverified: allowUnverified)
    }

    func enable(modelPath: String, port: Int, allowUnverified: Bool = false) async {
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return }
        mutateSlot0 { slot in
            slot.enabled = true
            slot.port = port
            slot.modelPath = modelPath
        }
        if let id = fleet.slots.first?.id {
            slotAttemptTimestamps[id] = []
        }
        lastError = nil
        persist()
        await reconcile()
    }

    func disable() async {
        mutateSlot0 { $0.enabled = false }
        persist()
        await stopServing(on: config.port)
        if let id = fleet.slots.first?.id {
            slotStates[id] = .disabled
        }
        state = .disabled
    }

    /// Swap the served model: stop the current server, update the desired
    /// model, and let reconcile start the new one on the same port — clients
    /// never reconfigure.
    func swap(to modelPath: String, allowUnverified: Bool = false) async {
        guard config.enabled else {
            await enable(modelPath: modelPath, port: config.port, allowUnverified: allowUnverified)
            return
        }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "swap") else { return }
        await stopServing(on: config.port)
        mutateSlot0 { $0.modelPath = modelPath }
        persist()
        await reconcile()
    }

    // MARK: - Fleet actions (spec 09; P2 UI consumes these)

    /// Add an enabled slot. Refused (with `lastError`) at the slot cap, on a
    /// duplicate port or role, or when the model fails the verified gate.
    func addSlot(modelPath: String, port: Int, role: UseCase? = nil, allowUnverified: Bool = false) async {
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return }
        let candidate = EndpointSlot(enabled: true, port: port, modelPath: modelPath, role: role)
        guard validate(candidate, isNew: true) else { return }
        fleet.slots.append(candidate)
        lastError = nil
        persist()
        await reconcile()
    }

    /// Change a slot's model/port/role without toggling its enabled flag.
    func updateSlot(id: UUID, modelPath: String, port: Int, role: UseCase?) async {
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        var candidate = fleet.slots[index]
        candidate.modelPath = modelPath
        candidate.port = port
        candidate.role = role
        guard validate(candidate, isNew: false) else { return }
        if candidate.enabled, candidate.modelPath != fleet.slots[index].modelPath {
            await stopServing(on: fleet.slots[index].port)
        }
        fleet.slots[index] = candidate
        lastError = nil
        persist()
        await reconcile()
    }

    func setSlotEnabled(id: UUID, _ enabled: Bool) async {
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        fleet.slots[index].enabled = enabled
        persist()
        if enabled {
            slotAttemptTimestamps[id] = []
            await reconcile()
        } else {
            await stopServing(on: fleet.slots[index].port)
            slotStates[id] = .disabled
            syncShim()
        }
    }

    /// Swap one slot's model on its stable port (same discipline as the
    /// single-slot swap).
    func swapSlot(id: UUID, to modelPath: String, allowUnverified: Bool = false) async {
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "swap") else { return }
        if fleet.slots[index].enabled {
            await stopServing(on: fleet.slots[index].port)
        }
        fleet.slots[index].modelPath = modelPath
        persist()
        await reconcile()
    }

    /// Remove a slot entirely, stopping its server first when it is ours.
    func removeSlot(id: UUID) async {
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        let slot = fleet.slots[index]
        if slot.enabled {
            await stopServing(on: slot.port)
        }
        fleet.slots.remove(at: index)
        slotStates.removeValue(forKey: id)
        slotRestartAttempts.removeValue(forKey: id)
        slotAttemptTimestamps.removeValue(forKey: id)
        persist()
        syncShim()
    }

    // MARK: - Reconciliation

    /// Diff desired state against authoritative serve status. Safe to call
    /// repeatedly; only acts when reality diverges from desired. One status
    /// fetch per pass, then each enabled slot reconciles independently.
    func reconcile() async {
        let enabledSlots = fleet.slots.filter { $0.enabled && !$0.modelPath.isEmpty }
        guard !enabledSlots.isEmpty else {
            for slot in fleet.slots { slotStates[slot.id] = .disabled }
            syncShim()
            return
        }
        let servers: [ServerInfo]
        do {
            servers = try await statusProvider()
            lastError = nil
        } catch {
            // Status is the authority; when it is unavailable, preserve the
            // last known state instead of guessing (mirrors the workflow
            // coordinator's rule).
            lastError = "Serve status unavailable: \(AppHost.render(error))"
            return
        }

        let running = servers.filter { $0.state?.lowercased() == "running" }
        for slot in enabledSlots {
            await reconcileSlot(slot, running: running)
        }
        syncShim()
    }

    private func reconcileSlot(_ slot: EndpointSlot, running: [ServerInfo]) async {
        if let ours = running.first(where: { $0.port == slot.port }) {
            if HFRepoID.serveIdentity(for: ours.modelIdentity) == HFRepoID.serveIdentity(for: slot.modelPath) {
                slotStates[slot.id] = .running(modelPath: slot.modelPath, port: slot.port)
            } else {
                slotStates[slot.id] = .modelMismatch(
                    servedModel: ours.modelIdentity.isEmpty
                        ? "unknown"
                        : URL(fileURLWithPath: ours.modelIdentity).lastPathComponent,
                    port: slot.port
                )
            }
            return
        }

        // Desired but not running: restart, with a per-slot crash-loop guard.
        let cutoff = now().addingTimeInterval(-restartWindow)
        var attempts = (slotAttemptTimestamps[slot.id] ?? []).filter { $0 > cutoff }
        guard attempts.count < maxRestarts else {
            slotAttemptTimestamps[slot.id] = attempts
            slotStates[slot.id] = .degraded(reason: "server failed to stay up (\(maxRestarts) restarts in \(Int(restartWindow / 60)) min)")
            return
        }

        slotStates[slot.id] = .starting
        attempts.append(now())
        slotAttemptTimestamps[slot.id] = attempts
        slotRestartAttempts[slot.id] = attempts.count
        do {
            let hash = try await lifecycle.preview(slot.modelPath, slot.port)
            guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
            try await lifecycle.start(slot.modelPath, slot.port, hash)
            slotStates[slot.id] = .waitingForServer
        } catch {
            slotStates[slot.id] = .degraded(reason: AppHost.render(error))
        }
    }

    // MARK: - Monitoring

    /// Poll authoritative status on a slow timer. Idempotent.
    func startMonitoring(intervalNanoseconds: UInt64 = 30_000_000_000) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Internals

    /// Record whether the login LaunchAgent is installed (installed/removed
    /// via LaunchAgentManager from the Serve tab).
    func markLoginItemInstalled(_ installed: Bool) {
        fleet.installedAtLogin = installed
        persist()
    }

    private func passesGate(modelPath: String, allowUnverified: Bool, action: String) -> Bool {
        guard !modelPath.isEmpty else {
            lastError = "Choose a model before enabling the endpoint."
            return false
        }
        if !allowUnverified, let isVerified, !isVerified(modelPath) {
            lastError = action == "swap"
                ? "This model is not verified. Run verification first, or swap anyway."
                : "This model is not verified. Run verification from its details page, or enable anyway."
            return false
        }
        return true
    }

    /// Fleet-invariant check ahead of mutation; sets `lastError` on failure.
    private func validate(_ candidate: EndpointSlot, isNew: Bool) -> Bool {
        if isNew, fleet.slots.count >= EndpointFleetConfig.maxSlots {
            lastError = EndpointFleetValidation.tooManySlots(fleet.slots.count + 1).localizedDescription
            return false
        }
        do {
            var proposed = fleet.slots.filter { $0.id != candidate.id }
            proposed.append(candidate)
            try EndpointFleetConfig(slots: proposed, installedAtLogin: fleet.installedAtLogin).validated()
            return true
        } catch {
            lastError = AppHost.render(error)
            return false
        }
    }

    private func mutateSlot0(_ mutation: (inout EndpointSlot) -> Void) {
        if fleet.slots.isEmpty {
            var slot = EndpointSlot(
                enabled: false,
                port: EndpointConfig.defaultPort,
                modelPath: "",
                role: nil
            )
            mutation(&slot)
            fleet.slots.append(slot)
        } else {
            mutation(&fleet.slots[0])
        }
    }

    /// Keep the legacy single-slot published surface in sync with slot 0.
    private func syncShim() {
        guard let first = fleet.slots.first, first.enabled, !first.modelPath.isEmpty else {
            state = .disabled
            restartAttempts = 0
            return
        }
        state = slotStates[first.id] ?? state
        restartAttempts = slotRestartAttempts[first.id] ?? 0
    }

    private func stopServing(on port: Int) async {
        guard let servers = try? await statusProvider(),
              let ours = servers.first(where: {
                  $0.state?.lowercased() == "running" && $0.port == port
              }) else { return }
        _ = ours
        try? await lifecycle.stop(port)
    }

    private func persist() {
        do {
            try fleetStore.save(fleet)
        } catch {
            persistenceError = "Endpoint fleet could not be saved: \(AppHost.render(error))"
        }
    }
}
