import Foundation

// MARK: - WatchCoordinator
//
// Watch & Regression Alerts (premium spec 08). Two watches:
//
// 1. Upstream drift — `mlx-agent watch diff` against the stored baseline
//    (argv through the agent boundary; HF access stays inside mlx-agent).
//    First check establishes a baseline without alerting.
// 2. Environment drift — macOS/chip/MLX fingerprint changed since verified
//    models were verified → one batch alert offering re-verification.
//
// Alerts dedupe by fingerprint and never fire twice for the same change-set.
// The feature is deliberately silent about network failure: watch is
// advisory.

@MainActor
final class WatchCoordinator: ObservableObject {
    @Published private(set) var alerts: [WatchAlert] = []
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?

    private let watchDiff: @Sendable () async throws -> [[String: Any]]
    private let watchSnapshot: @Sendable () async throws -> Void
    private let fingerprint: () -> EnvironmentFingerprint
    private let verifiedReports: () -> [VerificationReport]
    private let alertStore: JSONStore<WatchAlert>
    private let stateStore: JSONStore<WatchState>
    private let notify: (WatchAlert) -> Void
    private let now: () -> Date

    /// Re-verify the given model paths (used by the environment-drift alert's
    /// action). Wired by AppHost.
    var reverify: ([String]) -> Void = { _ in }

    private var state: WatchState = .empty
    private var monitorTask: Task<Void, Never>?

    init(
        watchDiff: @escaping @Sendable () async throws -> [[String: Any]],
        watchSnapshot: @escaping @Sendable () async throws -> Void,
        fingerprint: @escaping () -> EnvironmentFingerprint,
        verifiedReports: @escaping () -> [VerificationReport],
        alertStore: JSONStore<WatchAlert>,
        stateStore: JSONStore<WatchState>,
        notify: @escaping (WatchAlert) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.watchDiff = watchDiff
        self.watchSnapshot = watchSnapshot
        self.fingerprint = fingerprint
        self.verifiedReports = verifiedReports
        self.alertStore = alertStore
        self.stateStore = stateStore
        self.notify = notify
        self.now = now
        do {
            alerts = try alertStore.load().sorted { $0.createdAt > $1.createdAt }
        } catch {
            persistenceError = "Saved watch alerts are unavailable: \(AppHost.render(error))"
        }
        do {
            let stored = try stateStore.load()
            state = stored.first ?? .empty
            lastCheckedAt = state.lastCheckedAt
        } catch {
            persistenceError = "Saved watch state is unavailable: \(AppHost.render(error))"
        }
    }

    var activeAlerts: [WatchAlert] {
        alerts.filter { $0.isActive(at: now()) }
    }

    /// The current environment fingerprint, recorded on verification reports.
    var currentFingerprintDescription: String {
        fingerprint().description
    }

    /// Probe the installed mlx-lm version via the configured Python. Returns
    /// nil when unavailable — the fingerprint degrades to "unknown".
    nonisolated static func probeMLXLVersion() -> String? {
        let script = "import importlib.metadata as m; print(m.version('mlx-lm'))"
        let candidates = [
            ProcessInfo.processInfo.environment["MLX_WORKBENCH_PYTHON"],
            ProcessInfo.processInfo.environment["PYTHON"],
            "/usr/bin/python3",
        ].compactMap { $0 }
        guard let python = candidates.first(where: {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Check cycle

    /// Run both watches. Safe to call often; cadence gating lives in
    /// `startMonitoring`.
    func checkNow() async {
        await checkUpstream()
        checkEnvironment()
        state.lastCheckedAt = now()
        lastCheckedAt = state.lastCheckedAt
        persistState()
    }

    /// First run establishes the upstream baseline silently; later runs diff.
    private func checkUpstream() async {
        do {
            if !state.baselineEstablished {
                try await watchSnapshot()
                state.baselineEstablished = true
                return
            }
            let findings = try await watchDiff()
            for finding in findings {
                guard let repo = finding["repo"] as? String else { continue }
                let detail = (finding["detail"] as? String) ?? "upstream change detected"
                let code = (finding["code"] as? String) ?? "changed"
                addAlert(
                    kind: .upstreamChange,
                    fingerprint: "upstream|\(repo)|\(detail)",
                    modelKey: repo,
                    title: "\(repo) changed upstream",
                    body: "[\(code)] \(detail). Re-sync via Prepare when ready.",
                    route: WatchAlertKind.upstreamChange.route
                )
            }
        } catch {
            // Watch is advisory: offline / HF unreachable stays silent.
        }
    }

    private func checkEnvironment() {
        let current = fingerprint().description
        guard let previous = state.lastEnvironmentFingerprint else {
            state.lastEnvironmentFingerprint = current
            return
        }
        guard previous != current else { return }
        state.lastEnvironmentFingerprint = current

        let stalePaths = verifiedReports()
            .filter { $0.environmentFingerprint != nil && $0.environmentFingerprint != current }
            .map(\.modelPath)
        guard !stalePaths.isEmpty else { return }
        addAlert(
            kind: .environmentDrift,
            fingerprint: "environment|\(previous)|\(current)",
            modelKey: "environment",
            title: "Runtime environment changed",
            body: "\(stalePaths.count) verified model(s) were verified under a previous macOS/MLX. Re-verify to refresh the evidence.",
            route: WatchAlertKind.environmentDrift.route
        )
    }

    // MARK: - Alert actions

    func act(on alertID: UUID) {
        guard let alert = alerts.first(where: { $0.id == alertID }) else { return }
        if alert.kind == .environmentDrift {
            let current = fingerprint().description
            let stale = verifiedReports()
                .filter { $0.environmentFingerprint != nil && $0.environmentFingerprint != current }
                .map(\.modelPath)
            reverify(stale)
        }
        dismiss(alertID)
    }

    func snooze(_ alertID: UUID, days: Int = 7) {
        update(alertID) { $0.snoozedUntil = now().addingTimeInterval(TimeInterval(days) * 86_400) }
    }

    func mute(_ alertID: UUID) {
        update(alertID) { $0.muted = true }
    }

    func dismiss(_ alertID: UUID) {
        update(alertID) { $0.dismissedAt = now() }
    }

    // MARK: - Scheduling

    /// Check on launch when stale (>24h or never), then daily. Idempotent.
    func startMonitoring(intervalNanoseconds: UInt64 = 86_400_000_000_000) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let stale = state.lastCheckedAt.map { now().timeIntervalSince($0) > 86_400 } ?? true
                if stale { await checkNow() }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Internals

    private func addAlert(kind: WatchAlertKind, fingerprint: String, modelKey: String, title: String, body: String, route: String) {
        guard !alerts.contains(where: { $0.fingerprint == fingerprint }) else { return }
        let alert = WatchAlert(
            id: UUID(),
            kind: kind,
            fingerprint: fingerprint,
            modelKey: modelKey,
            title: title,
            body: body,
            route: route,
            createdAt: now(),
            snoozedUntil: nil,
            muted: false,
            dismissedAt: nil
        )
        alerts.insert(alert, at: 0)
        persist(alert)
        notify(alert)
    }

    private func update(_ alertID: UUID, mutate: (inout WatchAlert) -> Void) {
        guard let index = alerts.firstIndex(where: { $0.id == alertID }) else { return }
        mutate(&alerts[index])
        persist(alerts[index])
    }

    private func persist(_ alert: WatchAlert) {
        do {
            try alertStore.upsert(alert, id: \.id)
        } catch {
            persistenceError = "Watch alert could not be saved: \(AppHost.render(error))"
        }
    }

    private func persistState() {
        do {
            try stateStore.replaceAll([state])
        } catch {
            persistenceError = "Watch state could not be saved: \(AppHost.render(error))"
        }
    }
}
