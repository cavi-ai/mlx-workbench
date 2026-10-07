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
    @Published private(set) var isUnloading = false
    private var isReconciling = false
    private var activeUserOperations = 0
    /// Per-slot live state and restart counters (fleet surface; P2 UI).
    @Published private(set) var slotStates: [UUID: EndpointState] = [:]
    @Published private(set) var slotRestartAttempts: [UUID: Int] = [:]
    @Published private(set) var slotResidencies: [UUID: String] = [:]

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
    /// Successful explicit user choice of a serving model. Timer reconciliation
    /// and automatic restarts never emit this intentional-usage evidence.
    var onUserServeStarted: ((String) -> Void)?

    private var slotAttemptTimestamps: [UUID: [Date]] = [:]
    private var pendingUserServeBySlot: [UUID: (modelPath: String, port: Int)] = [:]
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
    func enable(modelPath: String, portText: String, allowUnverified: Bool = false, loadOnRequest: Bool? = nil) async {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await enable(modelPath: modelPath, port: EndpointConfig.defaultPort, allowUnverified: allowUnverified, loadOnRequest: loadOnRequest)
            return
        }
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            lastError = "Port must be a number between 1 and 65535."
            return
        }
        await enable(modelPath: modelPath, port: port, allowUnverified: allowUnverified, loadOnRequest: loadOnRequest)
    }

    func enable(modelPath: String, port: Int, allowUnverified: Bool = false, loadOnRequest: Bool? = nil) async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return }
        let initialLoadMode = loadOnRequest ?? (fleet.slots.isEmpty ? lifecycle.jitPreview != nil : nil)
        if let id = fleet.slots.first?.id { pendingUserServeBySlot.removeValue(forKey: id) }
        mutateSlot0 { slot in
            slot.enabled = true
            slot.port = port
            slot.modelPath = modelPath
            if let initialLoadMode { slot.loadOnRequest = initialLoadMode }
        }
        if let id = fleet.slots.first?.id {
            slotAttemptTimestamps[id] = []
        }
        lastError = nil
        persist()
        await reconcile(userRequestedSlotID: fleet.slots.first?.id)
    }

    func disable() async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        if let id = fleet.slots.first?.id { pendingUserServeBySlot.removeValue(forKey: id) }
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
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard config.enabled else {
            await enable(modelPath: modelPath, port: config.port, allowUnverified: allowUnverified)
            return
        }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "swap") else { return }
        if let id = fleet.slots.first?.id { pendingUserServeBySlot.removeValue(forKey: id) }
        await stopServing(on: config.port)
        mutateSlot0 { $0.modelPath = modelPath }
        persist()
        await reconcile(userRequestedSlotID: fleet.slots.first?.id)
    }

    // MARK: - Fleet actions (spec 09; P2 UI consumes these)

    /// Add an enabled slot. Refused (with `lastError`) at the slot cap, on a
    /// duplicate port or role, or when the model fails the verified gate.
    func addSlot(modelPath: String, port: Int, role: UseCase? = nil, allowUnverified: Bool = false, loadOnRequest: Bool? = nil) async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return }
        let candidate = EndpointSlot(enabled: true, port: port, modelPath: modelPath, role: role,
                                     loadOnRequest: loadOnRequest ?? (lifecycle.jitPreview != nil))
        guard validate(candidate, isNew: true) else { return }
        fleet.slots.append(candidate)
        lastError = nil
        persist()
        await reconcile(userRequestedSlotID: candidate.id)
    }

    /// Change a slot's model/port/role without toggling its enabled flag.
    func updateSlot(id: UUID, modelPath: String, port: Int, role: UseCase?) async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        var candidate = fleet.slots[index]
        candidate.modelPath = modelPath
        candidate.port = port
        candidate.role = role
        let servingSelectionChanged = candidate.enabled && (candidate.modelPath != fleet.slots[index].modelPath || candidate.port != fleet.slots[index].port)
        guard validate(candidate, isNew: false) else { return }
        if servingSelectionChanged { pendingUserServeBySlot.removeValue(forKey: id) }
        if candidate.enabled, candidate.modelPath != fleet.slots[index].modelPath {
            await stopServing(on: fleet.slots[index].port)
        }
        fleet.slots[index] = candidate
        lastError = nil
        persist()
        await reconcile(userRequestedSlotID: servingSelectionChanged ? id : nil)
    }

    func setSlotEnabled(id: UUID, _ enabled: Bool) async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        fleet.slots[index].enabled = enabled
        persist()
        if enabled {
            slotAttemptTimestamps[id] = []
            await reconcile(userRequestedSlotID: id)
        } else {
            await stopServing(on: fleet.slots[index].port)
            slotStates[id] = .disabled
            syncShim()
        }
    }

    /// Swap one slot's model on its stable port (same discipline as the
    /// single-slot swap).
    func swapSlot(id: UUID, to modelPath: String, allowUnverified: Bool = false) async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "swap") else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        if fleet.slots[index].enabled {
            await stopServing(on: fleet.slots[index].port)
        }
        fleet.slots[index].modelPath = modelPath
        persist()
        await reconcile(userRequestedSlotID: fleet.slots[index].enabled ? id : nil)
    }

    /// Remove a slot entirely, stopping its server first when it is ours.
    func removeSlot(id: UUID) async {
        guard !isUnloading else { return }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
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

    /// Persist the selected mode before restarting this endpoint. Existing
    /// fleets stay eager until the user changes their mode.
    func setSlotLoadOnRequest(id: UUID, _ enabled: Bool) async {
        guard !isUnloading, !isReconciling, activeUserOperations == 0 else {
            lastError = "Serving is changing. Wait before changing load mode."
            return
        }
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }),
              fleet.slots[index].usesJIT != enabled else { return }
        isUnloading = true
        defer { isUnloading = false }
        do {
            let slot = fleet.slots[index]
            let current = try await statusProvider().first { $0.port == slot.port && $0.state?.lowercased() == "running" }
            if let current {
                guard HFRepoID.matches(current.modelIdentity, slot.modelPath) else {
                    lastError = "A different model is serving on this port. Refresh before changing load mode."
                    return
                }
                guard (current.activeRequests ?? 0) == 0 else {
                    lastError = "Finish active requests before changing load mode."
                    return
                }
            }
            var candidate = fleet
            candidate.slots[index].loadOnRequest = enabled
            try fleetStore.save(candidate)
            fleet = candidate
            persistenceError = nil
            if let current, (current.jit == true) != enabled {
                try await lifecycle.stop(slot.port)
                let after = try await statusProvider()
                guard !after.contains(where: { $0.port == slot.port && $0.state?.lowercased() == "running" }) else {
                    lastError = "Endpoint is still running in its previous mode. Disable and enable it to retry."
                    return
                }
            }
            isUnloading = false
            await reconcile()
        } catch {
            lastError = "Could not change endpoint load mode: \(AppHost.render(error))"
        }
    }

    /// Release a JIT worker while retaining its enabled gateway. Eager
    /// endpoints persist disabled desired state before their server stops.
    /// The agent's receipt/PID fence remains the authority for stopping it.
    func unloadServer(_ expected: ServerInfo) async -> Bool {
        guard !isUnloading, !isReconciling, activeUserOperations == 0 else {
            lastError = "Serving is changing. Wait for it to finish, then retry unload."
            return false
        }
        guard let port = expected.port, expected.state?.lowercased() == "running" else {
            lastError = "This server is not running. Refresh serving status."
            return false
        }
        isUnloading = true
        defer { isUnloading = false }
        do {
            let current = try await statusProvider()
            guard let selected = current.first(where: { $0.sameProcess(as: expected) && $0.state?.lowercased() == "running" }) else {
                lastError = "The serving process changed. Refresh before unloading."
                return false
            }
            if selected.jit == true {
                guard let pid = selected.pid, let unload = lifecycle.unload else {
                    lastError = "JIT unload is unavailable for this runtime."
                    return false
                }
                guard (selected.activeRequests ?? 0) == 0 else {
                    lastError = "Finish active requests before unloading this model."
                    return false
                }
                try await unload(port, pid)
                let after = try await statusProvider()
                guard let alive = after.first(where: { $0.sameProcess(as: selected) }),
                      alive.state?.lowercased() == "running", alive.modelState == "unloaded" else {
                    lastError = "Model unload could not be confirmed; refresh serving status."
                    return false
                }
                lastError = nil
                return true
            }
            var disabled = fleet
            for index in disabled.slots.indices where disabled.slots[index].port == port {
                disabled.slots[index].enabled = false
            }
            // A failed save must leave the process and desired state intact.
            if disabled != fleet {
                try fleetStore.save(disabled)
                fleet = disabled
                persistenceError = nil
            }
            for slot in disabled.slots where slot.port == port {
                pendingUserServeBySlot.removeValue(forKey: slot.id)
                slotStates[slot.id] = .disabled
            }
            syncShim()
            try await lifecycle.stop(port)
            let after = try await statusProvider()
            guard !after.contains(where: { $0.port == port && $0.state?.lowercased() == "running" }) else {
                lastError = "The server is still running. Automatic restart is disabled; retry unload."
                return false
            }
            lastError = nil
            return true
        } catch {
            lastError = "Could not unload the serving model: \(AppHost.render(error))"
            return false
        }
    }

    /// Diff desired state against authoritative serve status. Safe to call
    /// repeatedly; only acts when reality diverges from desired. One status
    /// fetch per pass, then each enabled slot reconciles independently.
    func reconcile() async {
        await reconcile(userRequestedSlotID: nil)
    }

    private func reconcile(userRequestedSlotID: UUID?) async {
        if let id = userRequestedSlotID,
           let slot = fleet.slots.first(where: { $0.id == id && $0.enabled && !$0.modelPath.isEmpty }) {
            pendingUserServeBySlot[id] = (slot.modelPath, slot.port)
        }
        guard !isUnloading, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
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
            pendingUserServeBySlot.removeAll()
            return
        }

        let running = servers.filter { $0.state?.lowercased() == "running" }
        for slot in enabledSlots {
            guard fleet.slots.contains(slot) else { continue }
            await reconcileSlot(slot, running: running)
        }
        syncShim()
    }

    private func reconcileSlot(_ slot: EndpointSlot, running: [ServerInfo]) async {
        if let ours = running.first(where: { $0.port == slot.port }) {
            if HFRepoID.matches(ours.modelIdentity, slot.modelPath) {
                slotResidencies[slot.id] = ours.residencySummary
                guard (ours.jit == true) == slot.usesJIT else {
                    slotStates[slot.id] = .degraded(reason: "Endpoint load mode differs. Disable and enable it to apply the selected mode.")
                    return
                }
                slotStates[slot.id] = .running(modelPath: slot.modelPath, port: slot.port)
                recordIntentionalServe(slot)
            } else {
                pendingUserServeBySlot.removeValue(forKey: slot.id)
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
            pendingUserServeBySlot.removeValue(forKey: slot.id)
            slotAttemptTimestamps[slot.id] = attempts
            slotStates[slot.id] = .degraded(reason: "server failed to stay up (\(maxRestarts) restarts in \(Int(restartWindow / 60)) min)")
            return
        }

        slotStates[slot.id] = .starting
        slotResidencies.removeValue(forKey: slot.id)
        attempts.append(now())
        slotAttemptTimestamps[slot.id] = attempts
        slotRestartAttempts[slot.id] = attempts.count
        do {
            let preview: @Sendable (String, Int) async throws -> String
            let start: @Sendable (String, Int, String) async throws -> Void
            if slot.usesJIT {
                guard let jitPreview = lifecycle.jitPreview, let jitStart = lifecycle.jitStart else {
                    throw WorkflowEvidenceError.invalid("JIT serving is unavailable in this runtime.")
                }
                preview = jitPreview
                start = jitStart
            } else {
                preview = lifecycle.preview
                start = lifecycle.start
            }
            let hash = try await preview(slot.modelPath, slot.port)
            guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
            guard fleet.slots.contains(slot) else { return }
            try await start(slot.modelPath, slot.port, hash)
            slotStates[slot.id] = .waitingForServer
        } catch {
            pendingUserServeBySlot.removeValue(forKey: slot.id)
            slotStates[slot.id] = .degraded(reason: AppHost.render(error))
        }
    }

    private func recordIntentionalServe(_ slot: EndpointSlot) {
        guard let intent = pendingUserServeBySlot[slot.id], intent.modelPath == slot.modelPath, intent.port == slot.port,
              fleet.slots.contains(where: { $0.id == slot.id && $0.enabled && $0.modelPath == slot.modelPath && $0.port == slot.port }) else { return }
        pendingUserServeBySlot.removeValue(forKey: slot.id)
        onUserServeStarted?(slot.modelPath)
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
