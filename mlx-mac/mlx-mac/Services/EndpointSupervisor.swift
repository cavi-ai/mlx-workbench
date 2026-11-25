import Darwin
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

struct AdapterEndpointLaunch: Sendable {
    var preview: @Sendable (_ receipt: String, _ basePath: String, _ port: Int) async throws -> (hash: String, binding: TrainedAdapterBinding)
    var start: @Sendable (_ receipt: String, _ port: Int, _ hash: String) async throws -> Void
    var jitPreview: (@Sendable (_ receipt: String, _ basePath: String, _ port: Int, _ memoryPolicy: EndpointMemoryPolicy?, _ apiKeySHA256: String?) async throws -> (hash: String, binding: TrainedAdapterBinding))? = nil
    var jitStart: (@Sendable (_ receipt: String, _ port: Int, _ hash: String, _ memoryPolicy: EndpointMemoryPolicy?, _ apiKeySHA256: String?) async throws -> Void)? = nil

    var supportsJIT: Bool { jitPreview != nil && jitStart != nil }
}

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
    var inferenceLifecycle: ((LocalInferenceOptions) throws -> ServeLifecycle)?
    var splashLifecycle: ((String) throws -> ServeLifecycle)?
    var splashPresetLookup: ((String) async throws -> SplashPreset)?
    /// Explicit MLX-LM launch for a trained-adapter endpoint. Nil in tests that do not serve adapters.
    var adapterLaunch: AdapterEndpointLaunch?
    /// Per-model defaults that slots with `overrides != nil` follow. Nil in tests that do not use them.
    var modelDefaultsStore: ModelDefaultsStore?
    /// Resolves a default's serving profile id through the profile owner.
    var profileResolver: ((UUID) -> ServingProfile?)?
    /// Occupancy gate for stopping a slot's model; nil allows it.
    var mayStopSlot: ((EndpointSlot) -> Bool)?
    var generateAPIKey: () throws -> String = EndpointCredentialStore.generate
    var saveAPIKey: (String) throws -> Void = EndpointCredentialStore.save
    var removeAPIKey: (String) throws -> Void = EndpointCredentialStore.remove
    var readAPIKey: (String) throws -> String = EndpointCredentialStore.token(for:)
    /// Restarts the running Workbench API on its new key; true when restarted or not running.
    var restartWorkbenchAPI: ((FrontDoorSettings) async -> Bool)?
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

    private struct FleetFileStamp: Equatable {
        let exists: Bool
        let dev: Int32
        let ino: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
        let ctimeSec: Int
        let ctimeNsec: Int

        static func capture(at url: URL) -> FleetFileStamp {
            var st = stat()
            guard stat(url.path, &st) == 0 else {
                return FleetFileStamp(exists: false, dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0, ctimeSec: 0, ctimeNsec: 0)
            }
            return FleetFileStamp(
                exists: true,
                dev: st.st_dev,
                ino: st.st_ino,
                size: st.st_size,
                mtimeSec: st.st_mtimespec.tv_sec,
                mtimeNsec: st.st_mtimespec.tv_nsec,
                ctimeSec: st.st_ctimespec.tv_sec,
                ctimeNsec: st.st_ctimespec.tv_nsec
            )
        }
    }

    private var slotAttemptTimestamps: [UUID: [Date]] = [:]
    private var pendingUserServeBySlot: [UUID: (modelPath: String, port: Int)] = [:]
    private var queuedUserReconcileIDs: [UUID] = []
    private var cachedFleetLoad: (fleetStamp: FleetFileStamp, legacyStamp: FleetFileStamp, load: EndpointFleetLoad)?
    /// A slot started within this window is waiting for its server, not restarted.
    private static let startGrace: TimeInterval = 30
    /// Status source for periodic reconcile passes; user-requested passes always read live status.
    var reconcileStatus: (@Sendable () async throws -> [ServerInfo])?
    /// Called after a user-requested pass changed serving state.
    var servingChanged: (() -> Void)?

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
        self.cachedFleetLoad = (
            FleetFileStamp.capture(at: self.fleetStore.fleetStore.url),
            FleetFileStamp.capture(at: self.fleetStore.legacyStore.url),
            loaded
        )
    }

    // MARK: - User actions (single-slot shim)

    /// Read durable and in-memory references; disabled slots still own their configuration.
    /// This synchronous check cannot interleave with another main-actor fleet mutation.
    func requireUnreferencedProfile(_ id: UUID) throws {
        guard activeUserOperations == 0, !isReconciling, !isUnloading else {
            throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish before removing a profile.")
        }
        let persisted = loadPersistedFleet()
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
        if slot.modelPath != modelPath { slot.acceleration = nil; slot.accelerationPreviewHash = nil; slot.overrides = [] }
        slot.enabled = true; slot.port = port; slot.modelPath = modelPath
        slot.servingProfile = nil; slot.splashPresetName = nil; slot.profilePreviewHash = nil
        if let mode = loadOnRequest ?? (old == nil ? lifecycle.jitPreview != nil : nil) { slot.loadOnRequest = mode }
        if old == nil, slot.usesJIT { slot.memoryPolicy = .automatic }
        if old == nil { slot.overrides = [] }
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
        candidate.servingProfile = profile; candidate.splashPresetName = nil; candidate.profilePreviewHash = nil
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
        defer { activeUserOperations -= 1; servingChanged?() }
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
    /// Returns the saved slot ID so callers can read its startup state.
    @discardableResult
    func addSlot(modelPath: String, port: Int, role: ServingRole? = nil, allowUnverified: Bool = false, loadOnRequest: Bool? = nil, memoryPolicy: EndpointMemoryPolicy? = nil, requireAPIKey: Bool = false, inference: LocalInferenceOptions = .init(), profile: ServingProfile? = nil, splashPreset: SplashPreset? = nil) async -> UUID? {
        guard beginUserOperation() else { return nil }
        defer { activeUserOperations -= 1 }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "enable") else { return nil }
        if let profile, !profile.hasPassedVerification || profile.modelPath != modelPath || profileLifecycle == nil {
            lastError = "Verify the selected serving profile for this model before enabling it."
            return nil
        }
        let usesJIT = loadOnRequest ?? (lifecycle.jitPreview != nil)
        var candidate = EndpointSlot(enabled: true, port: port, modelPath: modelPath, role: role,
                                     loadOnRequest: usesJIT, memoryPolicy: usesJIT ? (memoryPolicy ?? .automatic) : nil)
        candidate.acceleration = inference.requested ? inference : nil
        candidate.servingProfile = profile
        candidate.overrides = ServingSettings.changedKeys(from: .init(), to: inference)
        if loadOnRequest != nil { candidate.overrides?.insert(.loadOnRequest) }
        if memoryPolicy != nil { candidate.overrides?.insert(.memoryPolicy) }
        if profile != nil { candidate.overrides?.insert(.servingProfile) }
        if splashPreset != nil { candidate.overrides?.insert(.splashPreset) }
        if let splashPreset {
            guard profile == nil, usesJIT, let lookup = splashPresetLookup else { lastError = "Splash presets require a load-on-request endpoint."; return nil }
            do { guard try await lookup(splashPreset.name) == splashPreset else { lastError = "The preset changed. Review it again."; return nil } }
            catch { lastError = AppHost.render(error); return nil }
            candidate.splashPresetName = splashPreset.name
            candidate.memoryPolicy = ServeLaunch.retainedMemoryPolicy(candidate.memoryPolicy, jit: candidate.usesJIT, splashPresetName: splashPreset.name)
        }
        do {
            var draft: (digest: String, created: String?)?
            if requireAPIKey {
                let key = try draftWorkbenchKey()
                draft = key
                candidate.apiKeySHA256 = key.digest
                candidate.loadOnRequest = true
                candidate.memoryPolicy = ServeLaunch.retainedMemoryPolicy(candidate.memoryPolicy ?? .automatic, jit: true, splashPresetName: candidate.splashPresetName)
            }
            guard validate(candidate, isNew: true) else { return nil }
            if inference.requested || profile != nil || splashPreset != nil {
                let before = fleet
                let effective = effectiveSlot(candidate)
                let hash = try await accelerationPreviewHash(effective, pendingKey: try planKey(effective, pending: draft?.created))
                guard !hash.isEmpty, fleet == before else { throw WorkflowEvidenceError.invalid("Endpoint configuration changed. Review the new endpoint again.") }
                if inference.requested { candidate.accelerationPreviewHash = hash }
                if profile != nil || splashPreset != nil { candidate.profilePreviewHash = hash }
            }
            guard validate(candidate, isNew: true), try commit(adding: candidate, key: draft) else { return nil }
        } catch {
            lastError = AppHost.render(error); return nil
        }
        await reconcile(userRequestedSlotID: candidate.id)
        return candidate.id
    }

    /// Save a reviewed adapter as an enabled endpoint. The base model's verdict is never consulted;
    /// allowUnverified is the explicit override. Eager serving remains the safe default; optional JIT
    /// and API-key serving require engine JIT adapter support and fail closed when unavailable.
    func addTrainedAdapterSlot(
        binding: TrainedAdapterBinding,
        port: Int,
        allowUnverified: Bool,
        loadOnRequest: Bool = false,
        requireAPIKey: Bool = false,
        memoryPolicy: EndpointMemoryPolicy? = nil,
        review: TrainedAdapterEndpointReview? = nil
    ) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard allowUnverified else {
            lastError = "This adapter does not inherit the base model's quality verdict. Save it only with the unverified override."
            return
        }
        guard binding.isValid, (1...65535).contains(port) else {
            lastError = "Historical training receipts without a pinned base identity cannot be saved as endpoints."
            return
        }
        let usesJIT = loadOnRequest || requireAPIKey
        if usesJIT && adapterLaunch?.supportsJIT != true {
            lastError = "Load-on-request serving for trained adapters is unavailable in this runtime."
            return
        }
        var candidate = EndpointSlot(
            enabled: true,
            port: port,
            modelPath: binding.basePath,
            loadOnRequest: usesJIT,
            memoryPolicy: usesJIT ? (memoryPolicy ?? .automatic) : nil
        )
        candidate.trainingReceipt = binding.receiptPath
        do {
            var draft: (digest: String, created: String?)?
            if requireAPIKey {
                if let review {
                    // The reviewed plan used this Workbench digest; a key that appeared or changed since is drift.
                    let current = fleet.frontDoor?.apiKeySHA256
                    guard review.keySHA256 != nil, review.workbenchToken == nil ? current == review.keySHA256 : current == nil else {
                        throw WorkflowEvidenceError.invalid("The Workbench key changed. Review the endpoint again.")
                    }
                    draft = (review.keySHA256 ?? "", review.workbenchToken)
                } else {
                    draft = try draftWorkbenchKey()
                }
                candidate.apiKeySHA256 = draft?.digest
            }
            guard validate(candidate, isNew: true) else { return }
            if let review {
                let current = try await reviewTrainedAdapter(candidate)
                guard current.hash == review.hash, current.binding == binding, review.port == port,
                      review.requireAPIKey == requireAPIKey, review.loadOnRequest == usesJIT else {
                    throw WorkflowEvidenceError.invalid("The trained adapter plan changed. Review the endpoint again.")
                }
            }
            guard validate(candidate, isNew: true), try commit(adding: candidate, key: draft) else { return }
        } catch {
            lastError = AppHost.render(error)
            return
        }
        await reconcile(userRequestedSlotID: candidate.id)
    }

    /// Reviews the adapter endpoint as it will be saved, with the Workbench key digest in the plan. Nothing is saved.
    func reviewTrainedAdapterEndpoint(binding: TrainedAdapterBinding, port: Int, loadOnRequest: Bool, requireAPIKey: Bool, memoryPolicy: EndpointMemoryPolicy? = nil) async throws -> TrainedAdapterEndpointReview {
        guard binding.isValid, (1...65535).contains(port) else {
            throw WorkflowEvidenceError.invalid("Historical training receipts without a pinned base identity cannot be saved as endpoints.")
        }
        let usesJIT = loadOnRequest || requireAPIKey
        var candidate = EndpointSlot(enabled: true, port: port, modelPath: binding.basePath, loadOnRequest: usesJIT,
                                     memoryPolicy: usesJIT ? (memoryPolicy ?? .automatic) : nil)
        candidate.trainingReceipt = binding.receiptPath
        let draft = requireAPIKey ? try draftWorkbenchKey() : nil
        candidate.apiKeySHA256 = draft?.digest
        let reviewed = try await reviewTrainedAdapter(candidate)
        guard reviewed.binding == binding else { throw WorkflowEvidenceError.invalid("The training receipt no longer matches this endpoint. Review it again.") }
        return TrainedAdapterEndpointReview(binding: binding, port: port, hash: reviewed.hash, loadOnRequest: usesJIT,
                                            requireAPIKey: requireAPIKey, keySHA256: draft?.digest, workbenchToken: draft?.created)
    }

    /// Change a slot's model/port/role without toggling its enabled flag.
    func updateSlot(id: UUID, modelPath: String, port: Int, role: ServingRole?) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard let old = fleet.slots.first(where: { $0.id == id }) else { return }
        var candidate = old
        if candidate.splashPresetName != nil && candidate.port != port {
            lastError = "Review the Splash preset again before changing this endpoint port."; return
        }
        if candidate.isTrainedAdapter && candidate.modelPath != modelPath {
            lastError = "A trained adapter endpoint stays on its pinned base. Remove it before choosing another model."
            return
        }
        if candidate.modelPath != modelPath {
            candidate.servingProfile = nil; candidate.splashPresetName = nil; candidate.profilePreviewHash = nil
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

    @discardableResult
    func setSlotEnabled(id: UUID, _ enabled: Bool) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        guard var slot = fleet.slots.first(where: { $0.id == id }) else { return false }
        slot.enabled = enabled
        guard commit(replacing: slot) else { return false }
        pendingUserServeBySlot.removeValue(forKey: id)
        if enabled {
            slotAttemptTimestamps[id] = []
            await reconcile(userRequestedSlotID: id)
        } else {
            guard await stopServing(slot) else { syncShim(); return false }
            slotStates[id] = .disabled
            syncShim()
        }
        return true
    }

    /// Swap one slot's model on its stable port (same discipline as the
    /// single-slot swap).
    func swapSlot(id: UUID, to modelPath: String, allowUnverified: Bool = false) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1 }
        guard let old = fleet.slots.first(where: { $0.id == id }) else { return }
        if old.isTrainedAdapter {
            lastError = "A trained adapter endpoint stays on its pinned base. Remove it before choosing another model."
            return
        }
        guard passesGate(modelPath: modelPath, allowUnverified: allowUnverified, action: "swap") else { return }
        var slot = old
        if slot.modelPath != modelPath { slot.acceleration = nil; slot.accelerationPreviewHash = nil; slot.overrides = [] }
        slot.modelPath = modelPath; slot.servingProfile = nil; slot.splashPresetName = nil; slot.profilePreviewHash = nil
        guard commit(replacing: slot) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        if old.enabled, !(await stopServing(old)) { syncShim(); return }
        await reconcile(userRequestedSlotID: slot.enabled ? id : nil)
    }

    /// Remove a slot entirely, stopping its server first when it is ours.
    func removeSlot(id: UUID) async {
        guard beginUserOperation() else { return }
        defer { activeUserOperations -= 1; servingChanged?() }
        guard let slot = fleet.slots.first(where: { $0.id == id }) else { return }
        var candidate = fleet
        candidate.slots.removeAll { $0.id == id }
        guard commit(candidate) else { return }
        pendingUserServeBySlot.removeValue(forKey: id)
        if slot.enabled, !(await stopServing(slot)) { syncShim(); return }
        if let key = slot.apiKeySHA256, !keyInUse(key) {
            do { try removeAPIKey(key) } catch { lastError = AppHost.render(error) }
        }
        slotStates.removeValue(forKey: id)
        slotRestartAttempts.removeValue(forKey: id)
        slotAttemptTimestamps.removeValue(forKey: id)
        syncShim()
    }

    // MARK: - Reconciliation

    /// Replace reviewed model slots on their existing ports. Failed launches keep
    /// the previous files and restore the captured desired state before returning.
    func replaceModelForUpdate(expected: [EndpointSlot], modelPath: String,
                               profileReplacements: [UUID: ServingProfile] = [:]) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        guard Set(expected.map(\.id)).count == expected.count, expected.allSatisfy({ fleet.slots.contains($0) }) else {
            lastError = "Endpoint settings changed. Review the model update again."
            return false
        }
        if expected.contains(where: \.isTrainedAdapter) {
            lastError = "A trained adapter endpoint stays on its pinned base. Remove it before switching that base."
            return false
        }
        if expected.isEmpty || expected.contains(where: { $0.servingProfile == nil }) {
            guard passesGate(modelPath: modelPath, allowUnverified: false, action: "update") else { return false }
        }
        if expected.isEmpty { return true }
        var next = fleet
        let oldProfileIDs = Set(expected.compactMap { $0.servingProfile?.id })
        var replacementIDs: [UUID: UUID] = [:]
        for old in expected {
            guard let index = next.slots.firstIndex(where: { $0.id == old.id }) else { return false }
            next.slots[index].modelPath = modelPath
            next.slots[index].splashPresetName = nil
            next.slots[index].acceleration = nil
            next.slots[index].accelerationPreviewHash = nil
            next.slots[index].profilePreviewHash = nil
            if let previous = old.servingProfile {
                guard previous.modelPath == old.modelPath, modelPath != old.modelPath,
                      let replacement = profileReplacements[previous.id], !oldProfileIDs.contains(replacement.id),
                      replacement.modelPath == modelPath, replacement.options == previous.options,
                      replacement.sourceRunID == nil, replacement.sourceLaneID == nil, replacement.hasPassedVerification,
                      replacement.verification != previous.verification,
                      !replacementIDs.contains(where: { $0.key != previous.id && $0.value == replacement.id }) else {
                    lastError = "Verify a new source-bound replacement for every serving profile before updating its endpoints."
                    return false
                }
                replacementIDs[previous.id] = replacement.id
                next.slots[index].servingProfile = replacement
                do {
                    let candidate = next.slots[index]
                    let selected = try servingLifecycle(candidate)
                    let hash: String
                    if candidate.usesJIT {
                        guard let preview = selected.jitPreview else { throw WorkflowEvidenceError.invalid("Profile JIT serving is unavailable.") }
                        hash = try await preview(modelPath, candidate.port, candidate.memoryPolicy)
                    } else { hash = try await selected.preview(modelPath, candidate.port) }
                    guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
                    guard expected.allSatisfy({ fleet.slots.contains($0) }) else {
                        throw WorkflowEvidenceError.invalid("Endpoint settings changed. Review the model update again.")
                    }
                } catch { lastError = AppHost.render(error); return false }
            }
        }
        do {
            for old in expected where old.servingProfile != nil {
                guard let previous = old.servingProfile, let resolve = profileLifecycle,
                      let updated = next.slots.first(where: { $0.id == old.id }) else {
                    throw WorkflowEvidenceError.invalid("Serving profile is unavailable or changed.")
                }
                _ = try resolve(previous)
                _ = try servingLifecycle(updated)
            }
        } catch { lastError = AppHost.render(error); return false }
        if expected.contains(where: { $0.servingProfile == nil }),
           !passesGate(modelPath: modelPath, allowUnverified: false, action: "update") { return false }
        guard commit(next) else { return false }
        var problem: String?
        var replacementAttempted = false
        for old in expected where old.enabled {
            if !(await stopServing(old)) { problem = lastError ?? "The previous endpoint could not stop."; break }
        }
        if problem == nil {
            replacementAttempted = true
            for slot in next.slots where expected.contains(where: { $0.id == slot.id }) && slot.enabled {
                pendingUserServeBySlot[slot.id] = (slot.modelPath, slot.port)
            }
            await reconcile(userRequestedSlotID: nil)
            for slot in next.slots where expected.contains(where: { $0.id == slot.id }) && slot.enabled {
                let deadline = Date().addingTimeInterval(30)
                var ready = false
                repeat {
                    do {
                        let observed = try await statusProvider()
                        if let server = observed.first(where: { $0.port == slot.port && $0.state == "running" && $0.matchesUnadaptedModel(modelPath) && ($0.jit == true) == slot.usesJIT }) {
                            guard server.apiKeySHA256 == slot.apiKeySHA256 else {
                                problem = "The new endpoint does not match its reviewed authentication."
                                break
                            }
                            guard !slot.usesJIT || server.memoryPolicy == slot.memoryPolicy else {
                                problem = "The new endpoint does not match the reviewed memory policy."
                                break
                            }
                            guard slot.servingProfile == nil || ServingProfile.matchesReceipt(server,
                                previewHash: fleet.slots.first(where: { $0.id == slot.id })?.profilePreviewHash) else {
                                problem = "The new endpoint does not match the confirmed serving profile."
                                break
                            }
                            slotStates[slot.id] = .running(modelPath: modelPath, port: slot.port)
                            slotResidencies[slot.id] = server.modelState
                            ready = true
                            break
                        }
                        if case .degraded(let reason) = slotStates[slot.id] { problem = reason; break }
                        try await Task.sleep(for: .milliseconds(250))
                    } catch { problem = AppHost.render(error); break }
                } while Date() < deadline
                guard ready else {
                    problem = problem ?? lastError ?? "The new endpoint did not become available."
                    break
                }
            }
        }
        if let problem {
            let attempted = fleet.slots.filter { slot in expected.contains { $0.id == slot.id } }
            var restored = fleet
            for old in expected {
                if let index = restored.slots.firstIndex(where: { $0.id == old.id }) { restored.slots[index] = old }
            }
            guard commit(restored) else {
                lastError = problem + " Previous files remain in place; endpoint settings could not be restored."
                return false
            }
            var cleanupFailed = false
            if replacementAttempted {
                do {
                    let observed = try await statusProvider()
                    for slot in attempted where slot.enabled &&
                        observed.contains(where: { $0.port == slot.port && $0.state == "running" && $0.matchesUnadaptedModel(modelPath) }) {
                        if !(await stopServing(slot)) { cleanupFailed = true }
                    }
                } catch { cleanupFailed = true }
            }
            if !cleanupFailed && pendingStops.isEmpty { await reconcile(userRequestedSlotID: nil) }
            lastError = problem + " Previous files were kept. Review endpoint status before retrying."
            return false
        }
        return true
    }

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
        if fleet.slots[index].isTrainedAdapter {
            if enabled && adapterLaunch?.supportsJIT != true {
                lastError = "Load-on-request serving for trained adapters is unavailable in this runtime."
                return
            }
            if !enabled && fleet.slots[index].apiKeySHA256 != nil {
                lastError = "API-key protected endpoints require Load on request."
                return
            }
        }
        guard enabled || fleet.slots[index].splashPresetName == nil else {
            lastError = "Splash presets require Load on request."; return
        }
        isUnloading = true
        defer { isUnloading = false }
        do {
            let slot = fleet.slots[index]
            let current = try await statusProvider().first { $0.port == slot.port && $0.state?.lowercased() == "running" }
            if let current {
                if slot.isTrainedAdapter {
                    guard matchesTrainedAdapter(current, slot: slot) else {
                        lastError = "A different model is serving on this port. Refresh before changing load mode."
                        return
                    }
                } else {
                    guard current.matchesUnadaptedModel(slot.modelPath) else {
                        lastError = "A different model is serving on this port. Refresh before changing load mode."
                        return
                    }
                    _ = try await confirmedAccelerationHash(current, slot: slot)
                }
                guard (current.activeRequests ?? 0) == 0 else {
                    lastError = "Finish active requests before changing load mode."
                    return
                }
            }
            var candidate = fleet
            candidate.slots[index].loadOnRequest = enabled
            candidate.slots[index].overrides?.insert(.loadOnRequest)
            if enabled, candidate.slots[index].memoryPolicy == nil { candidate.slots[index].memoryPolicy = .automatic; candidate.slots[index].overrides?.insert(.memoryPolicy) }
            if !enabled && candidate.slots[index].isTrainedAdapter { candidate.slots[index].memoryPolicy = nil }
            guard validate(candidate.slots[index], isNew: false), commit(candidate) else { return }
            if let current, (current.jit == true) != enabled {
                if let stop = lifecycle.stopObserved { try await stop(current) }
                else { try await lifecycle.stop(slot.port) }
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

    /// Inference setting changes never stop a running endpoint. Disable it first,
    /// review a launch preview, then save the same source-bound configuration.
    func previewSlotInference(id: UUID, options: LocalInferenceOptions) async throws -> EndpointInferencePreview {
        guard beginUserOperation() else { throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish.") }
        defer { activeUserOperations -= 1 }
        guard let slot = fleet.slots.first(where: { $0.id == id }) else {
            throw WorkflowEvidenceError.invalid("Endpoint no longer exists.")
        }
        try await requireStoppedForInference(slot)
        var candidate = slot
        candidate.acceleration = options.requested ? options : nil
        if let current = slot.overrides {
            candidate.overrides = current.union(ServingSettings.changedKeys(from: effectiveSlot(slot).inferenceOptions, to: options))
        }
        let hash = try await accelerationPreviewHash(effectiveSlot(candidate))
        guard !hash.isEmpty, fleet.slots.contains(slot) else {
            throw WorkflowEvidenceError.invalid("Endpoint settings changed. Preview inference settings again.")
        }
        return EndpointInferencePreview(slot: slot, options: options, hash: hash, overrides: candidate.overrides)
    }

    // MARK: - Model defaults

    /// Looks up a model's saved defaults; nil without a store.
    func modelDefaults(for modelPath: String) -> ModelServingDefaults? { modelDefaultsStore?.defaults(for: modelPath) }

    /// The slot with model defaults applied; a slot with `overrides == nil` is returned unchanged.
    func effectiveSlot(_ slot: EndpointSlot) -> EndpointSlot {
        effectiveSlot(slot, defaults: modelDefaults(for: slot.modelPath))
    }

    /// The one merge site: the slot resolved against the given defaults and the profile owner.
    func effectiveSlot(_ slot: EndpointSlot, defaults: ModelServingDefaults?) -> EndpointSlot {
        guard slot.overrides != nil else { return slot }
        let profile = defaults?.servingProfileID.flatMap { id in profileResolver?(id) ?? (slot.servingProfile?.id == id ? slot.servingProfile : nil) }
        return ServingSettings.effective(slot: slot, defaults: defaults, profile: profile)
    }

    /// Lists slots that follow the model's defaults. `restarting` are running ones whose launch plan changes, each with
    /// its post-change plan hash. Refused when the resulting fleet is not legal.
    func previewModelDefaultsChange(modelPath: String, to defaults: ModelServingDefaults?) async throws -> ModelDefaultsChangePreview {
        let following = fleet.slots.filter { $0.overrides != nil && HFRepoID.matches($0.modelPath, modelPath) }
        var resolved = fleet
        for index in resolved.slots.indices where following.contains(where: { $0.id == resolved.slots[index].id }) {
            resolved.slots[index] = effectiveSlot(resolved.slots[index], defaults: defaults)
        }
        try resolved.validated()
        var restarting: [EndpointSlot] = []
        var plans: [UUID: String] = [:]
        for slot in following where slot.enabled {
            guard case .some(.running) = slotStates[slot.id] else { continue }
            let before = effectiveSlot(slot), after = effectiveSlot(slot, defaults: defaults)
            guard before.inferenceOptions != after.inferenceOptions || before.memoryPolicy != after.memoryPolicy
                    || before.loadOnRequest != after.loadOnRequest || before.splashPresetName != after.splashPresetName
                    || before.servingProfile?.id != after.servingProfile?.id else { continue }
            let hash = try await accelerationPreviewHash(after)
            guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
            plans[slot.id] = hash
            restarting.append(slot)
        }
        return ModelDefaultsChangePreview(modelPath: modelPath, defaults: defaults, following: following, restarting: restarting, plans: plans)
    }

    /// Rechecks the preview, stops the listed running endpoints through the occupancy and idle checks, saves the defaults, then
    /// restarts them. Fails, naming the endpoint, when one does not come back.
    func confirmModelDefaultsChange(_ preview: ModelDefaultsChangePreview) async -> Bool {
        guard beginUserOperation() else { lastError = "Wait for the endpoint operation to finish."; return false }
        defer { activeUserOperations -= 1 }
        do {
            guard try await previewModelDefaultsChange(modelPath: preview.modelPath, to: preview.defaults) == preview else {
                throw WorkflowEvidenceError.invalid("Endpoints or launch plans changed. Review the model defaults again.")
            }
            guard let modelDefaultsStore else { throw WorkflowEvidenceError.invalid("Model defaults are unavailable.") }
            try await stopIdleRunning(preview.restarting, purpose: "changing its model defaults")
            try modelDefaultsStore.save(preview.defaults, for: preview.modelPath)
            var failed: [Int] = []
            for slot in preview.restarting {
                pendingUserServeBySlot.removeValue(forKey: slot.id)
                slotAttemptTimestamps[slot.id] = []
                await reconcile(userRequestedSlotID: slot.id)
                let live = (try? await statusProvider()) ?? []
                if !live.contains(where: { $0.port == slot.port && $0.state?.lowercased() == "running" }) { failed.append(slot.port) }
            }
            guard failed.isEmpty else {
                throw WorkflowEvidenceError.invalid("Defaults saved, but did not restart: " + failed.map { ":\($0)" }.joined(separator: ", "))
            }
            lastError = nil
            return true
        } catch { lastError = AppHost.render(error); return false }
    }

    /// Stops the running servers of `slots` through the occupancy and idle checks, then confirms none is still running.
    /// Refuses before stopping anything when one is claimed, busy or not running.
    private func stopIdleRunning(_ slots: [EndpointSlot], purpose: String) async throws {
        guard !slots.isEmpty else { return }
        guard let stop = lifecycle.stopObservedIfIdle else {
            throw WorkflowEvidenceError.invalid("Idle-checked stop is unavailable in this runtime. No endpoint was changed.")
        }
        let live = try await statusProvider()
        var generations: [ServerInfo] = []
        for slot in slots {
            if let mayStopSlot, !mayStopSlot(slot) {
                throw WorkflowEvidenceError.invalid("Finish the operation using :\(slot.port) before \(purpose).")
            }
            guard let server = live.first(where: { $0.port == slot.port && $0.state?.lowercased() == "running" }),
                  (server.activeRequests ?? 0) == 0 else {
                throw WorkflowEvidenceError.invalid("Endpoint :\(slot.port) is not running or has active requests. Review again.")
            }
            generations.append(server)
        }
        for server in generations { try await stop(server) }
        let after = try await statusProvider()
        if let port = generations.compactMap(\.port).first(where: { port in after.contains { $0.port == port && $0.state?.lowercased() == "running" } }) {
            throw WorkflowEvidenceError.invalid("Endpoint :\(port) is still running. Nothing was saved.")
        }
    }

    /// Saves the slot's current values as its model's defaults, previewed like any other defaults change.
    func previewSavingAsModelDefault(id: UUID) async throws -> ModelDefaultsChangePreview {
        guard let slot = fleet.slots.first(where: { $0.id == id }) else { throw WorkflowEvidenceError.invalid("Endpoint no longer exists.") }
        return try await previewModelDefaultsChange(modelPath: slot.modelPath, to: ServingSettings.defaults(from: effectiveSlot(slot)))
    }

    /// Previews returning fields to the model's defaults; `confirmSlotInference` saves it. The endpoint must be stopped.
    func previewResettingOverrides(id: UUID, keys: Set<ServingSettingKey>) async throws -> EndpointInferencePreview {
        guard beginUserOperation() else { throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish.") }
        defer { activeUserOperations -= 1 }
        guard let slot = fleet.slots.first(where: { $0.id == id }), let current = slot.overrides else {
            throw WorkflowEvidenceError.invalid("Endpoint no longer exists.")
        }
        try await requireStoppedForInference(slot)
        var candidate = slot
        candidate.overrides = current.subtracting(keys)
        let resolved = effectiveSlot(candidate)
        candidate.acceleration = resolved.acceleration
        let hash = try await accelerationPreviewHash(resolved)
        guard !hash.isEmpty, fleet.slots.contains(slot) else {
            throw WorkflowEvidenceError.invalid("Endpoint settings changed. Preview again.")
        }
        return EndpointInferencePreview(slot: slot, options: resolved.inferenceOptions, hash: hash, overrides: candidate.overrides)
    }

    func confirmSlotInference(_ preview: EndpointInferencePreview) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        do {
            guard fleet.slots.contains(preview.slot) else {
                throw WorkflowEvidenceError.invalid("Endpoint settings changed. Preview inference settings again.")
            }
            try await requireStoppedForInference(preview.slot)
            var candidate = preview.slot
            candidate.acceleration = preview.options.requested ? preview.options : nil
            candidate.overrides = preview.overrides
            candidate.accelerationPreviewHash = nil
            let hash = try await accelerationPreviewHash(effectiveSlot(candidate))
            guard hash == preview.hash, fleet.slots.contains(preview.slot) else {
                throw WorkflowEvidenceError.invalid("Launch plan changed. Preview inference settings again.")
            }
            try await requireStoppedForInference(preview.slot)
            if candidate.splashPresetName != nil { candidate.profilePreviewHash = hash }
            guard commit(replacing: candidate) else { return false }
            lastError = nil
            return true
        } catch {
            lastError = AppHost.render(error)
            return false
        }
    }

    private func requireStoppedForInference(_ slot: EndpointSlot) async throws {
        guard !slot.enabled, pendingStops[slot.id] == nil else {
            throw WorkflowEvidenceError.invalid("Disable the endpoint and confirm it has stopped before changing inference settings.")
        }
        let servers = try await statusProvider()
        guard !servers.contains(where: { $0.port == slot.port && $0.state?.lowercased() == "running" }) else {
            throw WorkflowEvidenceError.invalid("A server is still using this port. Stop it before changing inference settings.")
        }
    }

    private func servingLifecycle(_ slot: EndpointSlot) throws -> ServeLifecycle {
        let selected = try unauthenticatedLifecycle(slot)
        guard let hash = slot.apiKeySHA256 else { return selected }
        guard slot.usesJIT, let authenticated = selected.authenticated else {
            throw WorkflowEvidenceError.invalid("API key authentication is unavailable for this endpoint. No unprotected endpoint was started.")
        }
        return authenticated(hash)
    }

    private func unauthenticatedLifecycle(_ slot: EndpointSlot) throws -> ServeLifecycle {
        if let name = slot.splashPresetName {
            _ = try ServeLaunch.saved(splashPresetName: name, hasServingProfile: slot.servingProfile != nil, jit: slot.usesJIT, accelerationRequested: slot.inferenceOptions.accelerationRequested, thinkingOff: slot.inferenceOptions.thinkingOff)
            guard let factory = splashLifecycle else { throw WorkflowEvidenceError.invalid("Splash preset is unavailable for this endpoint.") }
            let selected = try factory(name)
            guard slot.inferenceOptions.requested else { return selected }
            guard let configured = selected.configured else { throw WorkflowEvidenceError.invalid("Inference settings are unavailable for this preset.") }
            return configured(slot.inferenceOptions)
        }
        if let profile = slot.servingProfile {
            guard profile.modelPath == slot.modelPath, ServeLaunch.profileAllows(accelerationRequested: slot.inferenceOptions.accelerationRequested, thinkingOff: slot.inferenceOptions.thinkingOff),
                  let factory = profileLifecycle else { throw WorkflowEvidenceError.invalid("Serving profile is unavailable or changed.") }
            let selected = try factory(profile)
            guard slot.inferenceOptions.requested else { return selected }
            guard let configured = selected.configured else { throw WorkflowEvidenceError.invalid("Inference defaults are unavailable for this serving profile.") }
            return configured(slot.inferenceOptions)
        }
        if slot.inferenceOptions.requested {
            guard let factory = inferenceLifecycle else {
                throw WorkflowEvidenceError.invalid("Inference settings are unavailable for this endpoint.")
            }
            return try factory(slot.inferenceOptions)
        }
        return lifecycle
    }

    private func reviewedSplashPreset(slot: EndpointSlot, preset: SplashPreset) async throws -> SplashPresetReview {
        guard fleet.slots.contains(slot), slot.enabled, slot.usesJIT, slot.servingProfile == nil,
              pendingStops[slot.id] == nil, let lookup = splashPresetLookup,
              try await lookup(preset.name) == preset else {
            throw WorkflowEvidenceError.invalid("Endpoint or preset changed. Refresh and review it again.")
        }
        let servers = try await statusProvider()
        guard fleet.slots.contains(slot), let server = servers.first(where: { $0.port == slot.port && $0.state?.lowercased() == "running" }),
              server.runtime == "splash", server.matchesUnadaptedModel(slot.modelPath), server.apiKeySHA256 == slot.apiKeySHA256,
              server.pid != nil, server.processStartedAt != nil, server.receipt != nil else {
            throw WorkflowEvidenceError.invalid("The running Splash endpoint identity is unavailable or changed.")
        }
        guard server.activeRequests == 0 else {
            throw WorkflowEvidenceError.invalid("Wait for active requests to finish, then review this preset again.")
        }
        if slot.splashPresetName != nil || slot.servingProfile != nil {
            guard ServingProfile.matchesReceipt(server, previewHash: slot.profilePreviewHash) else {
                throw WorkflowEvidenceError.invalid("The running endpoint does not match its reviewed settings.")
            }
        } else { _ = try await confirmedAccelerationHash(server, slot: slot) }
        var candidate = slot
        candidate.splashPresetName = preset.name
        candidate.memoryPolicy = ServeLaunch.retainedMemoryPolicy(nil, jit: candidate.usesJIT, splashPresetName: preset.name)
        let hash = try await accelerationPreviewHash(candidate)
        guard !hash.isEmpty, fleet.slots.contains(slot) else { throw WorkflowEvidenceError.invalid("Endpoint settings changed. Review again.") }
        return SplashPresetReview(slot: slot, preset: preset, server: server, previewHash: hash)
    }

    func previewSplashPreset(slot: EndpointSlot, preset: SplashPreset) async throws -> SplashPresetReview {
        guard beginUserOperation() else { throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish.") }
        defer { activeUserOperations -= 1 }
        return try await reviewedSplashPreset(slot: slot, preset: preset)
    }

    func confirmSplashPreset(_ review: SplashPresetReview) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        var saved = false
        do {
            let fresh = try await reviewedSplashPreset(slot: review.slot, preset: review.preset)
            guard fresh.server.sameProcess(as: review.server), fresh.previewHash == review.previewHash,
                  let stop = lifecycle.stopObservedIfIdle else {
                throw WorkflowEvidenceError.invalid("Endpoint generation or launch plan changed. Review again.")
            }
            // The engine atomically checks idleness while stopping this exact generation.
            let latest = try await statusProvider()
            guard fleet.slots.contains(review.slot), let live = latest.first(where: { $0.sameProcess(as: review.server) }),
                  live.activeRequests == 0 else { throw WorkflowEvidenceError.invalid("Wait for active requests to finish, then review again.") }
            try await stop(live)
            guard !(try await statusProvider()).contains(where: { $0.port == review.slot.port && $0.state?.lowercased() == "running" }) else {
                throw WorkflowEvidenceError.invalid("The previous endpoint is still running.")
            }
            var candidate = review.slot
            candidate.splashPresetName = review.preset.name
            candidate.memoryPolicy = nil
            candidate.overrides?.formUnion([.splashPreset, .memoryPolicy])
            candidate.profilePreviewHash = review.previewHash
            guard commit(replacing: candidate) else { return false }
            saved = true
            let selected = try servingLifecycle(candidate)
            guard let start = selected.jitStart else { throw WorkflowEvidenceError.invalid("Splash JIT serving is unavailable.") }
            try await start(candidate.modelPath, candidate.port, review.previewHash, candidate.memoryPolicy)
            let started = try await statusProvider()
            guard let live = started.first(where: { $0.port == candidate.port && $0.state?.lowercased() == "running" }),
                  live.runtime == "splash", live.jit == true, live.matchesUnadaptedModel(candidate.modelPath),
                  live.apiKeySHA256 == candidate.apiKeySHA256, live.processStartedAt != nil,
                  ServingProfile.matchesReceipt(live, previewHash: review.previewHash) else {
                throw WorkflowEvidenceError.invalid("The new endpoint generation could not be verified. Refresh before retrying.")
            }
            slotResidencies[candidate.id] = live.residencySummary
            slotMemoryPolicies[candidate.id] = live.memoryPolicy
            slotStates[candidate.id] = .running(modelPath: candidate.modelPath, port: candidate.port)
            lastError = nil
            return true
        } catch {
            if saved, var candidate = fleet.slots.first(where: { $0.id == review.slot.id }) {
                candidate.enabled = false
                _ = commit(replacing: candidate)
            }
            lastError = saved ? "The endpoint stopped. Review and start it to retry: \(AppHost.render(error))" : "Could not apply the Splash preset: \(AppHost.render(error))"
            return false
        }
    }

    /// Keep the front door's port; its shared key is created once and kept while the fleet records it.
    func configureFrontDoor(port: Int) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        do {
            if let existing = fleet.frontDoor {
                var candidate = fleet
                candidate.frontDoor = FrontDoorSettings(port: port, apiKeySHA256: existing.apiKeySHA256)
                try candidate.validated()
                guard commit(candidate) else { return false }
            } else {
                try ensureWorkbenchKey(port: port)
            }
        } catch { lastError = AppHost.render(error); return false }
        return true
    }

    /// The Workbench key digest: the Workbench API's shared key, created once with its default port.
    @discardableResult
    func ensureWorkbenchKey(port: Int = ServingRole.workbenchAPIDefaultPort) throws -> String {
        let draft = try draftWorkbenchKey()
        guard let created = draft.created else { return draft.digest }
        var next = fleet
        next.frontDoor = FrontDoorSettings(port: port, apiKeySHA256: draft.digest)
        try next.validated()
        guard try commit(next, savingKey: created) else {
            throw WorkflowEvidenceError.invalid(lastError ?? "The Workbench key could not be saved.")
        }
        return draft.digest
    }

    /// The Workbench key for a change under review. Nothing is saved: `created` is a new in-memory key
    /// when none exists yet, and is saved with the change that confirms it.
    private func draftWorkbenchKey() throws -> (digest: String, created: String?) {
        if let existing = fleet.frontDoor { return (existing.apiKeySHA256, nil) }
        let token = try generateAPIKey()
        return (EndpointCredentialStore.digest(token), token)
    }

    /// The key the launch plan needs: the pending key, or the saved one when the plan carries it (shared prefix cache).
    private func planKey(_ slot: EndpointSlot, pending: String?) throws -> String? {
        if let pending { return pending }
        guard slot.inferenceOptions.sharedPrefixCacheRequested, let digest = slot.apiKeySHA256 else { return nil }
        return try readAPIKey(digest)
    }

    /// Saves a key made by `draftWorkbenchKey` before committing, and removes it again if the commit fails.
    private func commit(_ candidate: EndpointFleetConfig, savingKey token: String?) throws -> Bool {
        if let token { try saveAPIKey(token) }
        guard commit(candidate) else {
            if let token { try? removeAPIKey(EndpointCredentialStore.digest(token)) }
            return false
        }
        return true
    }

    /// Commits a slot, and the Workbench API settings when its key was drafted in memory.
    private func commit(adding candidate: EndpointSlot, key draft: (digest: String, created: String?)?) throws -> Bool {
        var next = fleet
        if let index = next.slots.firstIndex(where: { $0.id == candidate.id }) { next.slots[index] = candidate }
        else { next.slots.append(candidate) }
        if let created = draft?.created {
            next.frontDoor = FrontDoorSettings(port: ServingRole.workbenchAPIDefaultPort, apiKeySHA256: EndpointCredentialStore.digest(created))
            try next.validated()
        }
        return try commit(next, savingKey: draft?.created)
    }

    /// Slots that keep their own key digest instead of the Workbench key.
    var slotsWithOwnKey: [EndpointSlot] {
        fleet.slots.filter { $0.apiKeySHA256 != nil && $0.apiKeySHA256 != fleet.frontDoor?.apiKeySHA256 }
    }

    /// Slots protected by the Workbench key, in restart order (ascending port).
    var protectedSlots: [EndpointSlot] {
        guard let digest = fleet.frontDoor?.apiKeySHA256 else { return [] }
        return fleet.slots.filter { $0.apiKeySHA256 == digest }.sorted { $0.port < $1.port }
    }

    private func keyInUse(_ digest: String) -> Bool {
        fleet.frontDoor?.apiKeySHA256 == digest || fleet.slots.contains { $0.apiKeySHA256 == digest }
    }

    /// Protecting an endpoint uses the Workbench key digest; no per-endpoint key is created.
    func previewAuthentication(slot: EndpointSlot, required: Bool) async throws -> EndpointAuthenticationReview {
        guard beginUserOperation() else { throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish.") }
        defer { activeUserOperations -= 1 }
        try await requireStoppedForAuthentication(slot)
        var candidate = slot
        let draft = required ? try draftWorkbenchKey() : nil
        candidate.apiKeySHA256 = draft?.digest
        if required { candidate.loadOnRequest = true; candidate.memoryPolicy = ServeLaunch.retainedMemoryPolicy(candidate.memoryPolicy ?? .automatic, jit: true, splashPresetName: candidate.splashPresetName) }
        let hash = try await accelerationPreviewHash(candidate, pendingKey: try planKey(candidate, pending: draft?.created))
        guard fleet.slots.contains(slot), !hash.isEmpty else { throw WorkflowEvidenceError.invalid("Endpoint settings changed. Review authentication again.") }
        return EndpointAuthenticationReview(slot: slot, keySHA256: candidate.apiKeySHA256, workbenchToken: draft?.created, previewHash: hash)
    }

    func confirmAuthentication(_ review: EndpointAuthenticationReview) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        do {
            try await requireStoppedForAuthentication(review.slot)
            var candidate = review.slot
            candidate.apiKeySHA256 = review.keySHA256
            if review.keySHA256 != nil { candidate.loadOnRequest = true; candidate.memoryPolicy = ServeLaunch.retainedMemoryPolicy(candidate.memoryPolicy ?? .automatic, jit: true, splashPresetName: candidate.splashPresetName) }
            let hash = try await accelerationPreviewHash(candidate, pendingKey: try planKey(candidate, pending: review.workbenchToken))
            guard hash == review.previewHash, fleet.slots.contains(review.slot) else {
                throw WorkflowEvidenceError.invalid("Launch plan changed. Review authentication again.")
            }
            try await requireStoppedForAuthentication(review.slot)
            if review.workbenchToken != nil {
                guard fleet.frontDoor == nil else { throw WorkflowEvidenceError.invalid("The Workbench API key changed. Review authentication again.") }
            } else if let shared = review.keySHA256, fleet.frontDoor?.apiKeySHA256 != shared {
                throw WorkflowEvidenceError.invalid("The Workbench API key changed. Review authentication again.")
            }
            if candidate.inferenceOptions.requested { candidate.accelerationPreviewHash = hash }
            candidate.profilePreviewHash = candidate.splashPresetName == nil ? nil : hash
            guard validate(candidate, isNew: false),
                  try commit(adding: candidate, key: review.keySHA256.map { ($0, review.workbenchToken) }) else { return false }
            if let old = review.slot.apiKeySHA256, !keyInUse(old) {
                do { try removeAPIKey(old) }
                catch {
                    lastError = "Authentication was saved, but the previous unused key could not be removed from Keychain."
                    return true
                }
            }
            lastError = nil
            return true
        } catch { lastError = AppHost.render(error); return false }
    }

    /// Lists every endpoint on the Workbench key, then the Workbench API, in the order a reset restarts them.
    func resetWorkbenchKeyPreview() async throws -> WorkbenchKeyResetReview {
        guard beginUserOperation() else { throw WorkflowEvidenceError.invalid("Wait for the endpoint operation to finish.") }
        defer { activeUserOperations -= 1 }
        guard let door = fleet.frontDoor else { throw WorkflowEvidenceError.invalid("No Workbench key exists yet.") }
        let token = try generateAPIKey()
        let digest = EndpointCredentialStore.digest(token)
        var entries: [WorkbenchKeyResetReview.Endpoint] = []
        for slot in protectedSlots {
            var candidate = slot
            candidate.apiKeySHA256 = digest
            let hash = try await accelerationPreviewHash(candidate, pendingKey: token)
            guard !hash.isEmpty else { throw WorkflowEvidenceError.invalid("Endpoint settings changed. Review the key reset again.") }
            entries.append(.init(slot: slot, previewHash: hash))
        }
        guard fleet.frontDoor == door, protectedSlots == entries.map(\.slot) else {
            throw WorkflowEvidenceError.invalid("Endpoint settings changed. Review the key reset again.")
        }
        return WorkbenchKeyResetReview(oldDigest: door.apiKeySHA256, newDigest: digest, token: token, workbenchAPIPort: door.port, endpoints: entries)
    }

    /// Saves the new key, restarts endpoints by ascending port, then the Workbench API. The old key leaves
    /// Keychain only after every restart succeeded; otherwise it stays and the failed ports are reported.
    func confirmWorkbenchKeyReset(_ review: WorkbenchKeyResetReview) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        guard EndpointCredentialStore.digest(review.token) == review.newDigest,
              let door = fleet.frontDoor, door.apiKeySHA256 == review.oldDigest,
              protectedSlots == review.endpoints.map(\.slot) else {
            lastError = "The Workbench key or its endpoints changed. Review the key reset again."
            return false
        }
        var next = fleet
        var running: [EndpointSlot] = []
        do {
            for entry in review.endpoints {
                var candidate = entry.slot
                candidate.apiKeySHA256 = review.newDigest
                guard try await accelerationPreviewHash(candidate, pendingKey: review.token) == entry.previewHash else {
                    throw WorkflowEvidenceError.invalid("Launch plan changed. Review the key reset again.")
                }
            }
            guard fleet.frontDoor == door, protectedSlots == review.endpoints.map(\.slot) else {
                throw WorkflowEvidenceError.invalid("The Workbench key or its endpoints changed. Review the key reset again.")
            }
            next.frontDoor = FrontDoorSettings(port: door.port, apiKeySHA256: review.newDigest)
            for entry in review.endpoints {
                guard let index = next.slots.firstIndex(where: { $0.id == entry.slot.id }) else { continue }
                next.slots[index].apiKeySHA256 = review.newDigest
                if next.slots[index].accelerationPreviewHash != nil { next.slots[index].accelerationPreviewHash = entry.previewHash }
                if next.slots[index].profilePreviewHash != nil { next.slots[index].profilePreviewHash = entry.previewHash }
            }
            try next.validated()
            let live = try await statusProvider()
            running = review.endpoints.map(\.slot).filter { slot in live.contains { $0.port == slot.port && $0.state?.lowercased() == "running" } }
            try await stopIdleRunning(running, purpose: "resetting the Workbench key")
        } catch {
            // Endpoints already stopped come back on the old key; nothing was saved.
            await restartOnCurrentKey(running)
            lastError = AppHost.render(error)
            return false
        }
        do { guard try commit(next, savingKey: review.token) else { await restartOnCurrentKey(running); return false } }
        catch { await restartOnCurrentKey(running); lastError = AppHost.render(error); return false }
        var failed: [Int] = []
        for slot in running where fleet.slots.contains(where: { $0.id == slot.id && $0.enabled }) {
            await restartOnCurrentKey([slot])
            let live = (try? await statusProvider()) ?? []
            if !live.contains(where: { $0.port == slot.port && $0.state?.lowercased() == "running" && $0.apiKeySHA256 == review.newDigest }) {
                failed.append(slot.port)
            }
        }
        if let restart = restartWorkbenchAPI, !(await restart(FrontDoorSettings(port: door.port, apiKeySHA256: review.newDigest))) {
            failed.append(door.port)
        }
        guard failed.isEmpty else {
            lastError = "The Workbench key was reset, but port \(failed.map(String.init).joined(separator: ", ")) did not restart. The previous key stays in Keychain."
            return false
        }
        if !keyInUse(review.oldDigest) {
            do { try removeAPIKey(review.oldDigest) }
            catch {
                lastError = "The Workbench key was reset, but the previous key could not be removed from Keychain."
                return true
            }
        }
        lastError = nil
        return true
    }

    /// Starts the enabled slots again from the saved fleet, as a user-requested serve.
    private func restartOnCurrentKey(_ slots: [EndpointSlot]) async {
        for slot in slots where fleet.slots.contains(where: { $0.id == slot.id && $0.enabled }) {
            pendingUserServeBySlot.removeValue(forKey: slot.id)
            slotAttemptTimestamps[slot.id] = []
            await reconcile(userRequestedSlotID: slot.id)
        }
    }

    private func requireStoppedForAuthentication(_ slot: EndpointSlot) async throws {
        guard fleet.slots.contains(slot), !slot.enabled, pendingStops[slot.id] == nil else {
            throw WorkflowEvidenceError.invalid("Stop the endpoint before changing authentication or resetting its key.")
        }
        let servers = try await statusProvider()
        guard fleet.slots.contains(slot), !servers.contains(where: {
            $0.port == slot.port && ($0.state?.lowercased() == "running" || ($0.workerPid ?? 0) > 0 || ($0.activeRequests ?? 0) > 0)
        }) else {
            throw WorkflowEvidenceError.invalid("This port is still serving. Confirm it has stopped before changing authentication.")
        }
    }

    private func reviewTrainedAdapter(_ slot: EndpointSlot) async throws -> (hash: String, binding: TrainedAdapterBinding) {
        guard let receipt = slot.trainingReceipt, let launch = adapterLaunch else {
            throw WorkflowEvidenceError.invalid("Trained adapter serving is unavailable.")
        }
        let reviewed: (hash: String, binding: TrainedAdapterBinding)
        if slot.usesJIT || slot.apiKeySHA256 != nil {
            guard let preview = launch.jitPreview, launch.jitStart != nil else {
                throw WorkflowEvidenceError.invalid("Load-on-request serving for trained adapters is unavailable in this runtime.")
            }
            reviewed = try await preview(receipt, slot.modelPath, slot.port, slot.memoryPolicy, slot.apiKeySHA256)
        } else {
            reviewed = try await launch.preview(receipt, slot.modelPath, slot.port)
        }
        guard reviewed.binding.receiptPath == receipt, reviewed.binding.basePath == slot.modelPath,
              reviewed.binding.isValid, TrainedAdapterBinding.isHash(reviewed.hash) else {
            throw WorkflowEvidenceError.invalid("The training receipt no longer matches this endpoint. Review it again.")
        }
        return reviewed
    }

    private func accelerationPreviewHash(_ slot: EndpointSlot, pendingKey: String? = nil) async throws -> String {
        if slot.isTrainedAdapter { return try await reviewTrainedAdapter(slot).hash }
        let selected = try servingLifecycle(slot)
        if slot.inferenceOptions.sharedPrefixCacheRequested, let pendingKey {
            guard EndpointCredentialStore.digest(pendingKey) == slot.apiKeySHA256,
                  let preview = selected.jitPreviewWithKeyFile else {
                throw WorkflowEvidenceError.invalid("The shared prefix cache requires the reviewed endpoint key.")
            }
            let file = try EndpointCredentialStore.materializePrivateKeyFile(pendingKey)
            defer { if file.created { try? FileManager.default.removeItem(atPath: file.path) } }
            return try await preview(slot.modelPath, slot.port, slot.memoryPolicy, file.path)
        }
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
        guard fleet.slots[index].splashPresetName == nil else {
            lastError = "Review a Splash preset to change this endpoint’s memory settings."; return
        }
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
            candidate.slots[index].overrides?.insert(.memoryPolicy)
            guard commit(candidate) else { return }
            saved = true
            if let current, let pid = current.pid {
                guard let configure = lifecycle.configureMemory else {
                    throw WorkflowEvidenceError.invalid("Memory management is unavailable in this runtime.")
                }
                try await configure(slot.port, pid, policy)
                let readback = try await statusProvider()
                guard let fresh = readback.first(where: { $0.sameProcess(as: current) }), fresh.memoryPolicy == policy else {
                    throw WorkflowEvidenceError.invalid("The gateway did not report the reviewed policy. Refresh before another change.")
                }
                slotMemoryPolicies[id] = policy
            }
            lastError = nil
        } catch {
            lastError = "\(saved ? "Memory policy saved, but could not be applied" : "Could not save memory policy"): \(AppHost.render(error))"
        }
    }

    /// Persist disabled desired state before stopping an observed owned server.
    func stopObservedServer(_ expected: ServerInfo, stop: (ServerInfo) async throws -> Void) async -> Bool {
        guard !isUnloading, !isReconciling, activeUserOperations == 0, let port = expected.port else {
            lastError = "Serving is changing. Wait for it to finish, then retry stop."
            return false
        }
        activeUserOperations += 1
        defer { activeUserOperations -= 1 }
        do {
            let current = try await statusProvider()
            guard current.contains(where: { $0.sameProcess(as: expected) && $0.state == "running" }) else {
                throw WorkflowEvidenceError.invalid("The serving process changed. Refresh before stopping it.")
            }
            var disabled = fleet
            for index in disabled.slots.indices where disabled.slots[index].port == port {
                disabled.slots[index].enabled = false
            }
            if disabled != fleet, !commit(disabled) { return false }
            for slot in disabled.slots where slot.port == port {
                pendingUserServeBySlot.removeValue(forKey: slot.id)
                slotStates[slot.id] = .disabled
            }
            syncShim()
            try await stop(expected)
            let after = try await statusProvider()
            guard !after.contains(where: { $0.port == port && $0.state == "running" }) else {
                throw WorkflowEvidenceError.invalid("A server is still running on this port. Refresh before another action.")
            }
            lastError = nil
            return true
        } catch { lastError = AppHost.render(error); return false }
    }

    func unloadObservedServer(_ expected: ServerInfo, unload: (ServerInfo) async throws -> Void) async -> Bool {
        guard beginUserOperation() else { return false }
        defer { activeUserOperations -= 1 }
        do {
            let current = try await statusProvider()
            guard let server = current.first(where: { $0.sameProcess(as: expected) }), server.state == "running",
                  server.jit == true, server.activeRequests == 0 else {
                throw WorkflowEvidenceError.invalid("The model changed or has active requests. Refresh before unloading it.")
            }
            try await unload(expected)
            let after = try await statusProvider()
            guard after.contains(where: { $0.sameProcess(as: expected) && $0.modelState == "unloaded" }) else {
                throw WorkflowEvidenceError.invalid("Model unload could not be confirmed. Refresh serving status.")
            }
            for slot in fleet.slots where slot.port == expected.port { slotResidencies[slot.id] = "unloaded" }
            lastError = nil
            return true
        } catch { lastError = AppHost.render(error); return false }
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
        defer { isUnloading = false; servingChanged?() }
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

    func reconcile(userRequestedSlotID: UUID?) async {
        if let id = userRequestedSlotID,
           let slot = fleet.slots.first(where: { $0.id == id && $0.enabled && !$0.modelPath.isEmpty }) {
            pendingUserServeBySlot[id] = (slot.modelPath, slot.port)
        }
        guard !isUnloading else { return }
        if isReconciling {
            if let id = userRequestedSlotID, !queuedUserReconcileIDs.contains(id) {
                queuedUserReconcileIDs.append(id)
            }
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        var nextTarget: UUID? = userRequestedSlotID
        while true {
            await performReconcilePass(userRequestedSlotID: nextTarget)
            guard !isUnloading, !queuedUserReconcileIDs.isEmpty else { break }
            nextTarget = queuedUserReconcileIDs.removeFirst()
        }
        if userRequestedSlotID != nil { servingChanged?() }
    }

    private func performReconcilePass(userRequestedSlotID: UUID?) async {
        let enabledSlots = fleet.slots.filter { $0.enabled && !$0.modelPath.isEmpty }
        guard !enabledSlots.isEmpty else {
            for slot in fleet.slots where pendingStops[slot.id] == nil { slotStates[slot.id] = .disabled }
            syncShim()
            return
        }
        let servers: [ServerInfo]
        do {
            servers = try await (userRequestedSlotID == nil ? reconcileStatus ?? statusProvider : statusProvider)()
            if pendingStops.isEmpty { lastError = nil }
        } catch {
            // Status is the authority; when it is unavailable, preserve the
            // last known state instead of guessing (mirrors the workflow
            // coordinator's rule).
            lastError = "Serve status unavailable: \(AppHost.render(error))"
            if let userRequestedSlotID {
                pendingUserServeBySlot.removeValue(forKey: userRequestedSlotID)
            } else {
                let queued = Set(queuedUserReconcileIDs)
                pendingUserServeBySlot = pendingUserServeBySlot.filter { queued.contains($0.key) }
            }
            return
        }

        let running = servers.filter { $0.state?.lowercased() == "running" }
        // Explicit starts must not wait behind repairs of other slots.
        let targetSlots = enabledSlots.filter { slot in
            if let userRequestedSlotID, slot.id != userRequestedSlotID { return false }
            return fleet.slots.contains(slot)
        }
        if targetSlots.count <= 1 {
            if let slot = targetSlots.first {
                await reconcileSlot(slot, running: running)
            }
        } else {
            let maxConcurrency = 4
            await withTaskGroup(of: Void.self) { group in
                var iterator = targetSlots.makeIterator()
                for _ in 0..<min(maxConcurrency, targetSlots.count) {
                    if let slot = iterator.next() {
                        group.addTask {
                            await self.reconcileSlot(slot, running: running)
                        }
                    }
                }
                while await group.next() != nil {
                    if let slot = iterator.next() {
                        group.addTask {
                            await self.reconcileSlot(slot, running: running)
                        }
                    }
                }
            }
        }
        syncShim()
    }

    private func reconcileSlot(_ stored: EndpointSlot, running: [ServerInfo]) async {
        guard pendingStops[stored.id] == nil, fleet.slots.contains(stored) else { return }
        let slot = effectiveSlot(stored)
        if let profile = slot.servingProfile, !profile.isValid || profile.modelPath != slot.modelPath || slot.inferenceOptions.accelerationRequested || slot.inferenceOptions.thinkingOff {
            slotStates[slot.id] = .degraded(reason: "The endpoint serving profile is invalid."); return
        }
        if let ours = running.first(where: { $0.port == slot.port }) {
            guard ours.apiKeySHA256 == slot.apiKeySHA256 else {
                slotStates[slot.id] = .degraded(reason: "Endpoint authentication differs from its configuration. Stop it and review authentication before restarting.")
                return
            }
            if slot.isTrainedAdapter {
                guard matchesTrainedAdapter(ours, slot: slot) else {
                    pendingUserServeBySlot.removeValue(forKey: slot.id)
                    let name = ours.modelIdentity.isEmpty ? "unknown" : URL(fileURLWithPath: ours.modelIdentity).lastPathComponent
                    slotStates[slot.id] = .modelMismatch(servedModel: ours.adapterSummary.map { name + " · " + $0 } ?? name, port: slot.port)
                    return
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
                return
            }
            if ours.matchesUnadaptedModel(slot.modelPath) {
                do {
                    if let hash = try await confirmedAccelerationHash(ours, slot: slot), hash != slot.accelerationPreviewHash {
                        guard fleet.slots.contains(stored), let index = fleet.slots.firstIndex(where: { $0.id == slot.id }) else { return }
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
                if (slot.servingProfile != nil || slot.splashPresetName != nil) && !ServingProfile.matchesReceipt(ours, previewHash: slot.profilePreviewHash) {
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
        if case .waitingForServer = slotStates[slot.id], let latest = attempts.last,
           now().timeIntervalSince(latest) < Self.startGrace { return }
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
            if slot.isTrainedAdapter {
                guard let receipt = slot.trainingReceipt, let launch = adapterLaunch else {
                    throw WorkflowEvidenceError.invalid("Trained adapter serving is unavailable.")
                }
                let reviewed = try await reviewTrainedAdapter(slot)
                guard fleet.slots.contains(slot) else {
                    throw WorkflowEvidenceError.invalid("The trained adapter endpoint changed. Review it again.")
                }
                if slot.usesJIT || slot.apiKeySHA256 != nil {
                    guard let start = launch.jitStart else {
                        throw WorkflowEvidenceError.invalid("Load-on-request serving for trained adapters is unavailable in this runtime.")
                    }
                    try await start(receipt, slot.port, reviewed.hash, slot.memoryPolicy, slot.apiKeySHA256)
                } else {
                    try await launch.start(receipt, slot.port, reviewed.hash)
                }
                slotStates[slot.id] = .waitingForServer
                return
            }
            if stored.overrides != nil { try EndpointFleetConfig(slots: [slot], installedAtLogin: false).validated() }
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
            guard fleet.slots.contains(stored) else { return }
            if slot.splashPresetName != nil, let reviewed = slot.profilePreviewHash, reviewed != hash {
                throw WorkflowEvidenceError.invalid("The Splash preset changed. Review it before restarting.")
            }
            if (slot.servingProfile != nil || slot.splashPresetName != nil), let index = fleet.slots.firstIndex(where: { $0.id == slot.id }) {
                var candidate = fleet
                candidate.slots[index].profilePreviewHash = hash
                guard commit(candidate) else {
                    slotStates[slot.id] = .degraded(reason: persistenceError ?? "Endpoint settings could not be saved.")
                    return
                }
            }
            if slot.inferenceOptions.requested, let index = fleet.slots.firstIndex(where: { $0.id == slot.id }) {
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

    private(set) var isMonitoring = false

    /// Reconciles once now, then on every tick of `clock`. Idempotent.
    func startMonitoring(on clock: LiveStateClock) async {
        guard !isMonitoring else { return }
        isMonitoring = true
        clock.addConsumer { [weak self] in
            if self?.isMonitoring == true { await self?.reconcile() }
        }
        await reconcile()
    }

    func stopMonitoring() { isMonitoring = false }

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
            try EndpointFleetConfig(slots: proposed, installedAtLogin: fleet.installedAtLogin, frontDoor: fleet.frontDoor).validated()
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

    private func loadPersistedFleet() -> EndpointFleetLoad {
        let fleetStamp = FleetFileStamp.capture(at: fleetStore.fleetStore.url)
        let legacyStamp = FleetFileStamp.capture(at: fleetStore.legacyStore.url)
        if let cached = cachedFleetLoad,
           cached.fleetStamp == fleetStamp,
           cached.legacyStamp == legacyStamp {
            return cached.load
        }
        let loaded = fleetStore.load()
        cachedFleetLoad = (
            FleetFileStamp.capture(at: fleetStore.fleetStore.url),
            FleetFileStamp.capture(at: fleetStore.legacyStore.url),
            loaded
        )
        return loaded
    }

    /// Publish desired state only after the durable configuration accepts it.
    private func commit(_ candidate: EndpointFleetConfig) -> Bool {
        do {
            let saved = loadPersistedFleet()
            guard saved.problem == nil, saved.config == fleet else {
                throw WorkflowEvidenceError.invalid("Saved endpoint settings changed or are unavailable. Reopen Workbench before editing them.")
            }
            try fleetStore.save(candidate)
            fleet = candidate
            persistenceError = nil
            lastError = nil
            cachedFleetLoad = (
                FleetFileStamp.capture(at: fleetStore.fleetStore.url),
                FleetFileStamp.capture(at: fleetStore.legacyStore.url),
                EndpointFleetLoad(config: candidate, problem: nil)
            )
            return true
        } catch {
            cachedFleetLoad = nil
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
                if slot.isTrainedAdapter {
                    matches = matchesTrainedAdapter(current, slot: slot)
                } else if slot.servingProfile != nil || slot.splashPresetName != nil {
                    matches = ServingProfile.matchesReceipt(current, previewHash: slot.profilePreviewHash)
                } else {
                    matches = current.matchesUnadaptedModel(slot.modelPath)
                    if matches { _ = try await confirmedAccelerationHash(current, slot: slot) }
                }
                guard matches else {
                    throw WorkflowEvidenceError.invalid("A different model is running on port \(slot.port). Refresh before stopping it.")
                }
                if let stop = lifecycle.stopObserved { try await stop(current) }
                else { try await lifecycle.stop(slot.port) }
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

    private func matchesTrainedAdapter(_ server: ServerInfo, slot: EndpointSlot) -> Bool {
        guard let receipt = slot.trainingReceipt, let binding = server.trainingBinding else { return false }
        return server.runtime == "mlx_lm" && binding.receiptPath == receipt && binding.basePath == slot.modelPath
            && binding.isValid && HFRepoID.matches(server.modelIdentity, slot.modelPath)
    }

    private func confirmedAccelerationHash(_ server: ServerInfo, slot: EndpointSlot) async throws -> String? {
        guard server.matchesAcceleration(slot.inferenceOptions) else {
            throw WorkflowEvidenceError.invalid("The running endpoint does not match its saved acceleration settings. Stop it and enable the endpoint again.")
        }
        guard slot.inferenceOptions.requested else { return nil }
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
