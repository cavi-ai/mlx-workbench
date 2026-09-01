import Foundation

// MARK: - EndpointSupervisor
//
// Always-on Endpoint (premium spec 06). Keeps a chosen model serving on a
// stable loopback port by reconciling desired state (persisted config)
// against authoritative serve status on a timer and on app launch.
//
// Boundaries: serving goes through mlx-agent's serve preview/confirm/start/
// stop (argv tokens, preview hashes); the supervisor never invents process
// state — `serve status` is the authority. Crash-loop guard: at most
// `maxRestarts` starts inside `restartWindow`, then degraded.

@MainActor
final class EndpointSupervisor: ObservableObject {
    @Published private(set) var config: EndpointConfig
    @Published private(set) var state: EndpointState = .disabled
    @Published private(set) var restartAttempts = 0
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?

    private let lifecycle: ServeLifecycle
    private let statusProvider: @Sendable () async throws -> [ServerInfo]
    private let store: JSONStore<EndpointConfig>
    private let now: () -> Date
    private let maxRestarts: Int
    private let restartWindow: TimeInterval

    /// Verification gate: returns true when the model passed the canary
    /// suite. Wired by AppHost; nil means "no gate attached" (allow).
    var isVerified: ((String) -> Bool)?

    private var attemptTimestamps: [Date] = []
    private var monitorTask: Task<Void, Never>?

    init(
        lifecycle: ServeLifecycle,
        statusProvider: @escaping @Sendable () async throws -> [ServerInfo],
        store: JSONStore<EndpointConfig>,
        now: @escaping () -> Date = Date.init,
        maxRestarts: Int = 3,
        restartWindow: TimeInterval = 300
    ) {
        self.lifecycle = lifecycle
        self.statusProvider = statusProvider
        self.store = store
        self.now = now
        self.maxRestarts = maxRestarts
        self.restartWindow = restartWindow
        do {
            config = try store.load().first ?? .disabled
        } catch {
            config = .disabled
            persistenceError = "Saved endpoint config is unavailable: \(AppHost.render(error))"
        }
    }

    // MARK: - User actions

    /// Enable the endpoint for a model. Verified models only, unless the
    /// user explicitly overrides (the same discipline as the quality gate).
    func enable(modelPath: String, port: Int, allowUnverified: Bool = false) async {
        guard !modelPath.isEmpty else {
            lastError = "Choose a model before enabling the endpoint."
            return
        }
        if !allowUnverified, let isVerified, !isVerified(modelPath) {
            lastError = "This model is not verified. Run verification from its details page, or enable anyway."
            return
        }
        config = EndpointConfig(enabled: true, port: port, modelPath: modelPath, installedAtLogin: config.installedAtLogin)
        persist()
        attemptTimestamps = []
        lastError = nil
        await reconcile()
    }

    func disable() async {
        config.enabled = false
        persist()
        await stopServingIfOurs()
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
        if !allowUnverified, let isVerified, !isVerified(modelPath) {
            lastError = "This model is not verified. Run verification first, or swap anyway."
            return
        }
        await stopServingIfOurs()
        config.modelPath = modelPath
        persist()
        await reconcile()
    }

    // MARK: - Reconciliation

    /// Diff desired state against authoritative serve status. Safe to call
    /// repeatedly; only acts when reality diverges from desired.
    func reconcile() async {
        guard config.enabled, !config.modelPath.isEmpty else {
            state = .disabled
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
        if let ours = running.first(where: { $0.port == config.port }) {
            if ours.repo == config.modelPath {
                state = .running(modelPath: config.modelPath, port: config.port)
            } else {
                state = .modelMismatch(
                    servedModel: ours.repo.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown",
                    port: config.port
                )
            }
            return
        }

        // Desired but not running: restart, with a crash-loop guard.
        let cutoff = now().addingTimeInterval(-restartWindow)
        attemptTimestamps = attemptTimestamps.filter { $0 > cutoff }
        guard attemptTimestamps.count < maxRestarts else {
            state = .degraded(reason: "server failed to stay up (\(maxRestarts) restarts in \(Int(restartWindow / 60)) min)")
            return
        }

        state = .starting
        attemptTimestamps.append(now())
        restartAttempts = attemptTimestamps.count
        do {
            let hash = try await lifecycle.preview(config.modelPath, config.port)
            guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
            try await lifecycle.start(config.modelPath, config.port, hash)
            state = .waitingForServer
        } catch {
            state = .degraded(reason: AppHost.render(error))
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
        config.installedAtLogin = installed
        persist()
    }

    private func stopServingIfOurs() async {
        guard let servers = try? await statusProvider(),
              let ours = servers.first(where: {
                  $0.state?.lowercased() == "running" && $0.port == config.port
              }) else { return }
        _ = ours
        try? await lifecycle.stop(config.port)
    }

    private func persist() {
        do {
            try store.replaceAll([config])
        } catch {
            persistenceError = "Endpoint config could not be saved: \(AppHost.render(error))"
        }
    }
}
