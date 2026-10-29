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
    /// Servers whose stop could not be confirmed remain visible after removal.
    @Published private(set) var pendingStops: [UUID: EndpointSlot] = [:]
    @Published private(set) var isUnloading = false
    @Published private var isReconciling = false
    @Published private var activeUserOperations = 0
    var isChanging: Bool { activeUserOperations > 0 || isUnloading || isReconciling }
    /// Per-slot live state and restart counters (fleet surface; P2 UI).
    @Published private(set) var slotStates: [UUID: EndpointState] = [:]
    @Published private(set) var slotRestartAttempts: [UUID: Int] = [:]
    @Published private(set) var slotResidencies: [UUID: String] = [:]
    @Published private(set) var slotMemoryPolicies: [UUID: EndpointMemoryPolicy] = [:]
    @Published private(set) var slotLoadBlockedReasons: [UUID: String] = [:]

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

    var profileLifecycle: ((ServingProfile) throws -> ServeLifecycle)?
    var accelerationLifecycle: ((LocalAccelerationOptions) throws -> ServeLifecycle)?
    private let lifecycle: ServeLifecycle
    private let statusProvider: @Sendable () async throws -> [ServerInfo]
    private let fleetStore: EndpointFleetStore
    var fleetFileURL: URL { fleetStore.fleetStore.url }
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

    /// Read durable and in-memory references; disabled slots still own their configuration.
    /// This synchronous check cannot interleave with another main-actor fleet mutation.
    func requireUnreferencedProfile(_ id: UUID) throws {
        guard activeUserOperations == 0, !isReconciling, !isUnloading else {
            throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish before removing a profile.")
        }
        let persisted = fleetStore.load()
        guard persisted.problem == nil, persistenceError == nil else {
            throw WorkflowEvidenceError.invalid("Endpoint configuration is unavailable. The profile was kept.")
        }
        let references = (fleet.slots + persisted.config.slots).filter { $0.servingProfile?.id == id }
        guard references.isEmpty else {
            let ports = Set(references.map(\.port)).sorted().map(String.init).joined(separator: ", ")
            throw WorkflowEvidenceError.invalid("Endpoints on ports \(ports) use this profile. Replace their profile or remove those slots first; disabling them keeps the reference.")
        }
    }

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
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return }
        let old = fleet.slots.first
        var slot = old ?? EndpointSlot(enabled: false, port: port, modelPath: modelPath)
        if slot.modelPath != modelPath { slot.acceleration = nil; slot.accelerationPreviewHash = nil }
        slot.enabled = true; slot.port = port; slot.modelPath = modelPath
        slot.servingProfile = nil; slot.profilePreviewHash = nil
        if let mode = loadOnRequest ?? (old == nil ? lifecycle.jitPreview != nil : nil) { slot.loadOnRequest = mode }
        if old == nil, slot.usesJIT { slot.memoryPolicy = .automatic }
        guard validate(slot, isNew: old == nil), commit(replacing: slot) else { return }
        pendingUserServeBySlot.removeValue(forKey: slot.id)
        slotAttemptTimestamps[slot.id] = []
        if let old, old.servingProfile != nil, !(await stopServing(old)) { return }
        await reconcile(userRequestedSlotID: slot.id)
    }

    func enableProfile(_ profile: ServingProfile, port: Int, loadOnRequest: Bool) async {
        guard !isUnloading, profile.hasPassedVerification, profileLifecycle != nil, (1...65535).contains(port) else {
            lastError = "Verify the serving profile and choose a valid port before enabling it."; return
        }
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        do {
            let selected = try profileLifecycle!(profile)
            if loadOnRequest {
                guard let preview = selected.jitPreview else { throw WorkflowEvidenceError.invalid("Profile JIT serving is unavailable.") }
                _ = try await preview(profile.modelPath, port, .automatic)
            } else { _ = try await selected.preview(profile.modelPath, port) }
        } catch { lastError = AppHost.render(error); return }
        var candidate = fleet.slots.first ?? EndpointSlot(enabled: false, port: port, modelPath: profile.modelPath)
        candidate.enabled = true; candidate.port = port; candidate.modelPath = profile.modelPath
        candidate.loadOnRequest = loadOnRequest; candidate.memoryPolicy = loadOnRequest ? .automatic : nil
        candidate.servingProfile = profile; candidate.profilePreviewHash = nil
        candidate.acceleration = nil; candidate.accelerationPreviewHash = nil
        guard validate(candidate, isNew: fleet.slots.isEmpty) else { return }
        let old = fleet.slots.first
        guard commit(replacing: candidate) else { return }
        if let old, old.enabled, !(await stopServing(old)) { syncShim(); return }
        slotAttemptTimestamps[candidate.id] = []
        await reconcile(userRequestedSlotID: candidate.id)
    }

    func disable() async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard var slot = fleet.slots.first else { return }
        slot.enabled = false
        guard commit(replacing: slot) else { return }
        pendingUserServeBySlot.removeValue(forKey: slot.id)
        guard await stopServing(slot) else { syncShim(); return }
        slotStates[slot.id] = .disabled
        syncShim()
    }

    /// Swap the served model: stop the current server, update the desired
    /// model, and let reconcile start the new one on the same port — clients
    /// never reconfigure.
    func swap(to modelPath: String, allowUnverified: Bool = false) async {
        guard config.enabled, let id = fleet.slots.first?.id else {
            await enable(modelPath: modelPath, port: config.port, allowUnverified: allowUnverified)
            return
        }
        await swapSlot(id: id, to: modelPath, allowUnverified: allowUnverified)
    }

    // MARK: - Fleet actions (spec 09; P2 UI consumes these)

    /// Add an enabled slot. Refused (with `lastError`) at the slot cap, on a
    /// duplicate port or role, or when the model fails the verified gate.
    func addSlot(modelPath: String, port: Int, role: UseCase? = nil, allowUnverified: Bool = false, loadOnRequest: Bool? = nil) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return }
        let usesJIT = loadOnRequest ?? (lifecycle.jitPreview != nil)
        let candidate = EndpointSlot(enabled: true, port: port, modelPath: modelPath, role: role,
                                     loadOnRequest: usesJIT, memoryPolicy: usesJIT ? .automatic : nil)
        guard validate(candidate, isNew: true), commit(replacing: candidate) else { return }
        await reconcile(userRequestedSlotID: candidate.id)
    }

    /// Change a slot's model/port/role without toggling its enabled flag.
    func updateSlot(id: UUID, modelPath: String, port: Int, role: UseCase?) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard let old = fleet.slots.first(where: { $0.id == id }) else { return }
        var candidate = old
        if candidate.modelPath != modelPath {
            candidate.servingProfile = nil; candidate.profilePreviewHash = nil
            candidate.acceleration = nil; candidate.accelerationPreviewHash = nil
        }
        candidate.modelPath = modelPath; candidate.port = port; candidate.role = role
        let selectionChanged = candidate.enabled && (old.modelPath != modelPath || old.port != port)
        guard validate(candidate, isNew: false), commit(replacing: candidate) else { return }
        if selectionChanged {
            pendingUserServeBySlot.removeValue(forKey: id)
            guard await stopServing(old) else { syncShim(); return }
        }
        await reconcile(userRequestedSlotID: selectionChanged ? id : nil)
    }

    func setSlotEnabled(id: UUID, _ enabled: Bool) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard var slot = fleet.slots.first(where: { $0.id == id }) else { return }
        slot.enabled = enabled
        guard commit(replacing: slot) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        if enabled {
            slotAttemptTimestamps[id] = []
            await reconcile(userRequestedSlotID: id)
        } else {
            guard await stopServing(slot) else { syncShim(); return }
            slotStates[id] = .disabled
            syncShim()
        }
    }

    /// Swap one slot's model on its stable port (same discipline as the
    /// single-slot swap).
    func swapSlot(id: UUID, to modelPath: String, allowUnverified: Bool = false) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard let old = fleet.slots.first(where: { $0.id == id }),
              passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "swap") else { return }
        var slot = old
        if slot.modelPath != modelPath { slot.acceleration = nil; slot.accelerationPreviewHash = nil }
        slot.modelPath = modelPath; slot.servingProfile = nil; slot.profilePreviewHash = nil
        guard commit(replacing: slot) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        if old.enabled, !(await stopServing(old)) { syncShim(); return }
        await reconcile(userRequestedSlotID: slot.enabled ? id : nil)
    }

    /// Remove a slot entirely, stopping its server first when it is ours.
    func removeSlot(id: UUID) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard let slot = fleet.slots.first(where: { $0.id == id }) else { return }
        var candidate = fleet
        candidate.slots.removeAll { $0.id == id }
        guard commit(candidate) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        if slot.enabled, !(await stopServing(slot)) { syncShim(); return }
        slotStates.removeValue(forKey: id)
        slotRestartAttempts.removeValue(forKey: id)
        slotAttemptTimestamps.removeValue(forKey: id)
        syncShim()
    }

    // MARK: - Reconciliation

    func retryPendingStops() async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        for slot in Array(pendingStops.values) {
            if await stopServing(slot), let desired = fleet.slots.first(where: { $0.id == slot.id && $0.enabled }) {
                pendingUserServeBySlot[desired.id] = (desired.modelPath, desired.port)
            }
        }
        if pendingStops.isEmpty {
            lastError = nil
            await reconcile(userRequestedSlotID: nil)
        }
        syncShim()
    }

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
                guard current.matchesUnadaptedModel(slot.modelPath) else {
                    lastError = "A different model is serving on this port. Refresh before changing load mode."
                    return
                }
                _ = try await confirmedAccelerationHash(current, slot: slot)
                guard (current.activeRequests ?? 0) == 0 else {
                    lastError = "Finish active requests before changing load mode."
                    return
                }
            }
            var candidate = fleet
            candidate.slots[index].loadOnRequest = enabled
            if enabled, candidate.slots[index].memoryPolicy == nil { candidate.slots[index].memoryPolicy = .automatic }
            guard commit(candidate) else { return }
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

    /// Acceleration changes never stop a running endpoint. Disable it first,
    /// review a launch preview, then save the same source-bound configuration.
    func previewSlotAcceleration(id: UUID, options: LocalAccelerationOptions) async throws -> EndpointAccelerationPreview {
        guard beginUserOperation() else { throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish.") }
        defer { activeUserOperations -= 1 }
        guard let slot = fleet.slots.first(where: { $0.id == id }) else {
            throw WorkflowEvidenceError.invalid("Endpoint no longer exists.")
        }
        try await requireStoppedForAcceleration(slot)
        var candidate = slot
        candidate.acceleration = options.requested ? options : nil
        let hash = try await accelerationPreviewHash(candidate)
        guard !hash.isEmpty, fleet.slots.contains(slot) else {
            throw WorkflowEvidenceError.invalid("Endpoint settings changed. Preview acceleration again.")
        }
        return EndpointAccelerationPreview(slot: slot, options: options, hash: hash)
    }

    func confirmSlotAcceleration(_ preview: EndpointAccelerationPreview) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        do {
            guard fleet.slots.contains(preview.slot) else {
                throw WorkflowEvidenceError.invalid("Endpoint settings changed. Preview acceleration again.")
            }
            try await requireStoppedForAcceleration(preview.slot)
            var candidate = preview.slot
            candidate.acceleration = preview.options.requested ? preview.options : nil
            candidate.accelerationPreviewHash = nil
            let hash = try await accelerationPreviewHash(candidate)
            guard hash == preview.hash, fleet.slots.contains(preview.slot) else {
                throw WorkflowEvidenceError.invalid("Launch plan changed. Preview acceleration again.")
            }
            try await requireStoppedForAcceleration(preview.slot)
            guard commit(replacing: candidate) else { return false }
            lastError = nil
            return true
        } catch {
            lastError = AppHost.render(error)
            return false
        }
    }

    private func requireStoppedForAcceleration(_ slot: EndpointSlot) async throws {
        guard !slot.enabled, pendingStops[slot.id] == nil, slot.servingProfile == nil else {
            throw WorkflowEvidenceError.invalid("Disable the endpoint and confirm it has stopped before changing acceleration. Strata profiles use their own settings.")
        }
        let servers = try await statusProvider()
        guard !servers.contains(where: { $0.port == slot.port && $0.state?.lowercased() == "running" }) else {
            throw WorkflowEvidenceError.invalid("A server is still using this port. Stop it before changing acceleration.")
        }
    }

    private func servingLifecycle(_ slot: EndpointSlot) throws -> ServeLifecycle {
        if slot.accelerationOptions.requested {
            guard slot.servingProfile == nil, let factory = accelerationLifecycle else {
                throw WorkflowEvidenceError.invalid("Local acceleration is unavailable for this endpoint.")
            }
            return try factory(slot.accelerationOptions)
        }
        if let profile = slot.servingProfile {
            guard profile.modelPath == slot.modelPath, let factory = profileLifecycle else {
                throw WorkflowEvidenceError.invalid("Serving profile is unavailable or changed.")
            }
            return try factory(profile)
        }
        return lifecycle
    }

    private func accelerationPreviewHash(_ slot: EndpointSlot) async throws -> String {
        let selected = try servingLifecycle(slot)
        if slot.usesJIT {
            guard let preview = selected.jitPreview else { throw WorkflowEvidenceError.invalid("JIT serving is unavailable in this runtime.") }
            return try await preview(slot.modelPath, slot.port, slot.memoryPolicy)
        }
        return try await selected.preview(slot.modelPath, slot.port)
    }

    /// Save desired policy before applying it to the receipt-owned gateway.
    /// Policy updates do not stop the endpoint or interrupt inference leases.
    func setSlotMemoryPolicy(id: UUID, _ policy: EndpointMemoryPolicy) async {
        guard !isUnloading, !isReconciling, activeUserOperations == 0 else {
            lastError = "Serving is changing. Wait before changing memory management."
            return
        }
        guard let index = fleet.slots.firstIndex(where: { $0.id == id }), fleet.slots[index].usesJIT else { return }
        isUnloading = true
        defer { isUnloading = false }
        var saved = false
        do {
            let slot = fleet.slots[index]
            let current = try await statusProvider().first { $0.port == slot.port && $0.state?.lowercased() == "running" }
            if let current {
                guard current.matchesUnadaptedModel(slot.modelPath), current.jit == true,
                      let pid = current.pid, pid > 0 else {
                    throw WorkflowEvidenceError.invalid("Endpoint identity changed. Refresh before changing memory management.")
                }
                _ = try await confirmedAccelerationHash(current, slot: slot)
            }
            var candidate = fleet
            candidate.slots[index].memoryPolicy = policy
            guard commit(candidate) else { return }
            saved = true
            if let current, let pid = current.pid {
                guard let configure = lifecycle.configureMemory else {
                    throw WorkflowEvidenceError.invalid("Memory management is unavailable in this runtime.")
                }
                try await configure(slot.port, pid, policy)
                slotMemoryPolicies[id] = policy
            }
            lastError = nil
        } catch {
            lastError = "\(saved ? "Memory policy saved, but could not be applied" : "Could not save memory policy"): \(AppHost.render(error))"
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
                guard commit(disabled) else { return false }
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
        guard activeUserOperations == 0 else { return }
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
            for slot in fleet.slots where pendingStops[slot.id] == nil { slotStates[slot.id] = .disabled }
            syncShim()
            return
        }
        let servers: [ServerInfo]
        do {
            servers = try await statusProvider()
            if pendingStops.isEmpty { lastError = nil }
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
        guard pendingStops[slot.id] == nil else { return }
        if let profile = slot.servingProfile, !profile.isValid || profile.modelPath != slot.modelPath || slot.accelerationOptions.requested {
            slotStates[slot.id] = .degraded(reason: "The endpoint serving profile is invalid."); return
        }
        if let ours = running.first(where: { $0.port == slot.port }) {
            if ours.matchesUnadaptedModel(slot.modelPath) {
                do {
                    if let hash = try await confirmedAccelerationHash(ours, slot: slot), hash != slot.accelerationPreviewHash {
                        guard fleet.slots.contains(slot), let index = fleet.slots.firstIndex(where: { $0.id == slot.id }) else { return }
                        var candidate = fleet
                        candidate.slots[index].accelerationPreviewHash = hash
                        guard commit(candidate) else {
                            throw WorkflowEvidenceError.invalid(persistenceError ?? "Endpoint receipt identity could not be saved.")
                        }
                    }
                } catch {
                    slotStates[slot.id] = .degraded(reason: AppHost.render(error))
                    return
                }
                if slot.servingProfile != nil && !ServingProfile.matchesReceipt(ours, previewHash: slot.profilePreviewHash) {
                    slotStates[slot.id] = .degraded(reason: "The running endpoint does not match the confirmed serving profile. Re-enable the profile."); return
                }
                slotResidencies[slot.id] = ours.residencySummary
                slotMemoryPolicies[slot.id] = ours.memoryPolicy
                slotLoadBlockedReasons[slot.id] = ours.loadBlockedReason
                guard (ours.jit == true) == slot.usesJIT else {
                    slotStates[slot.id] = .degraded(reason: "Endpoint load mode differs. Disable and enable it to apply the selected mode.")
                    return
                }
                if slot.usesJIT, let policy = slot.memoryPolicy, ours.memoryPolicy != policy {
                    do {
                        guard let configure = lifecycle.configureMemory, let pid = ours.pid, pid > 0 else {
                            throw WorkflowEvidenceError.invalid("Memory management is unavailable in this runtime.")
                        }
                        try await configure(slot.port, pid, policy)
                        slotMemoryPolicies[slot.id] = policy
                    } catch {
                        slotStates[slot.id] = .degraded(reason: "Could not apply memory policy: \(AppHost.render(error))")
                        return
                    }
                }
                slotStates[slot.id] = .running(modelPath: slot.modelPath, port: slot.port)
                recordIntentionalServe(slot)
            } else {
                pendingUserServeBySlot.removeValue(forKey: slot.id)
                let name = ours.modelIdentity.isEmpty ? "unknown" : URL(fileURLWithPath: ours.modelIdentity).lastPathComponent
                slotStates[slot.id] = .modelMismatch(
                    servedModel: ours.adapterSummary.map { name + " · " + $0 } ?? name,
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
        slotMemoryPolicies.removeValue(forKey: slot.id)
        slotLoadBlockedReasons.removeValue(forKey: slot.id)
        attempts.append(now())
        slotAttemptTimestamps[slot.id] = attempts
        slotRestartAttempts[slot.id] = attempts.count
        do {
            let lifecycle = try servingLifecycle(slot)
            let preview: @Sendable (String, Int) async throws -> String
            let start: @Sendable (String, Int, String) async throws -> Void
            if slot.usesJIT {
                guard let jitPreview = lifecycle.jitPreview, let jitStart = lifecycle.jitStart else {
                    throw WorkflowEvidenceError.invalid("JIT serving is unavailable in this runtime.")
                }
                preview = { model, port in try await jitPreview(model, port, slot.memoryPolicy) }
                start = { model, port, hash in try await jitStart(model, port, hash, slot.memoryPolicy) }
            } else {
                preview = lifecycle.preview
                start = lifecycle.start
            }
            let hash = try await preview(slot.modelPath, slot.port)
            guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
            guard fleet.slots.contains(slot) else { return }
            if slot.servingProfile != nil, let index = fleet.slots.firstIndex(where: { $0.id == slot.id }) {
                var candidate = fleet
                candidate.slots[index].profilePreviewHash = hash
                guard commit(candidate) else {
                    slotStates[slot.id] = .degraded(reason: persistenceError ?? "Endpoint settings could not be saved.")
                    return
                }
            }
            if slot.accelerationOptions.requested, let index = fleet.slots.firstIndex(where: { $0.id == slot.id }) {
                var candidate = fleet
                candidate.slots[index].accelerationPreviewHash = hash
                guard commit(candidate) else {
                    slotStates[slot.id] = .degraded(reason: persistenceError ?? "Endpoint settings could not be saved.")
                    return
                }
            }
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

    var isMonitoring: Bool { monitorTask != nil }

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
        // This synchronous metadata edit preserves slot identities during an in-flight stop.
        var candidate = fleet
        candidate.installedAtLogin = installed
        _ = commit(candidate)
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

    private func beginUserOperation() -> Bool {
        guard !isChanging else {
            lastError = "Serving is changing. Wait for the current operation to finish."
            return false
        }
        activeUserOperations += 1
        return true
    }

    private func commit(replacing slot: EndpointSlot) -> Bool {
        var candidate = fleet
        if let index = candidate.slots.firstIndex(where: { $0.id == slot.id }) { candidate.slots[index] = slot }
        else { candidate.slots.append(slot) }
        return commit(candidate)
    }

    /// Publish desired state only after the durable configuration accepts it.
    private func commit(_ candidate: EndpointFleetConfig) -> Bool {
        do {
            let saved = fleetStore.load()
            guard saved.problem == nil, saved.config == fleet else {
                throw WorkflowEvidenceError.invalid("Saved endpoint settings changed or are unavailable. Reopen Workbench before editing them.")
            }
            try fleetStore.save(candidate)
            fleet = candidate
            persistenceError = nil
            lastError = nil
            return true
        } catch {
            persistenceError = "Endpoint fleet could not be saved: \(AppHost.render(error))"
            lastError = persistenceError
            return false
        }
    }

    /// Keep the legacy single-slot published surface in sync with slot 0.
    private func syncShim() {
        if let pending = pendingStops.values.sorted(by: { $0.port < $1.port }).first {
            state = slotStates[pending.id] ?? .degraded(reason: "Server stop has not been confirmed.")
            return
        }
        guard let first = fleet.slots.first, first.enabled, !first.modelPath.isEmpty else {
            state = .disabled
            restartAttempts = 0
            return
        }
        state = slotStates[first.id] ?? state
        restartAttempts = slotRestartAttempts[first.id] ?? 0
    }

    private func stopServing(_ slot: EndpointSlot) async -> Bool {
        do {
            let servers = try await statusProvider()
            if let current = servers.first(where: { $0.state?.lowercased() == "running" && $0.port == slot.port }) {
                let matches: Bool
                if slot.servingProfile != nil {
                    matches = ServingProfile.matchesReceipt(current, previewHash: slot.profilePreviewHash)
                } else {
                    matches = current.matchesUnadaptedModel(slot.modelPath)
                    if matches { _ = try await confirmedAccelerationHash(current, slot: slot) }
                }
                guard matches else {
                    throw WorkflowEvidenceError.invalid("A different model is running on port \(slot.port). Refresh before stopping it.")
                }
                try await lifecycle.stop(slot.port)
                let after = try await statusProvider()
                guard !after.contains(where: { $0.state?.lowercased() == "running" && $0.port == slot.port }) else {
                    throw WorkflowEvidenceError.invalid("The server is still running on port \(slot.port).")
                }
            }
            pendingStops.removeValue(forKey: slot.id)
            slotStates[slot.id] = .disabled
            return true
        } catch {
            pendingStops[slot.id] = slot
            let reason = "Server stop could not be confirmed on port \(slot.port): \(AppHost.render(error))"
            slotStates[slot.id] = .degraded(reason: reason)
            lastError = reason
            return false
        }
    }

    private func confirmedAccelerationHash(_ server: ServerInfo, slot: EndpointSlot) async throws -> String? {
        guard server.matchesAcceleration(slot.accelerationOptions) else {
            throw WorkflowEvidenceError.invalid("The running endpoint does not match its saved acceleration settings. Stop it and enable the endpoint again.")
        }
        guard slot.accelerationOptions.requested else { return nil }
        if let hash = slot.accelerationPreviewHash,
           ServingProfile.matchesReceipt(server, previewHash: hash, startedAt: server.startedAt) { return hash }
        // A reinstalled login command can launch a new, equally configured receipt
        // after policy or runtime updates. Require its exact fresh plan before adoption.
        let hash = try await accelerationPreviewHash(slot)
        guard !hash.isEmpty, ServingProfile.matchesReceipt(server, previewHash: hash, startedAt: server.startedAt) else {
            throw WorkflowEvidenceError.invalid("The running endpoint does not match the current launch preview. Stop it and enable the endpoint again.")
        }
        return hash
    }
}
