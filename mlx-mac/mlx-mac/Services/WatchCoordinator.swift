import Foundation

/// One in-flight probe per generation. Invalidating a runtime cancels its old
/// process and prevents late results from repopulating the cache.
final class EnvironmentVersionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let run: @Sendable (CLIInvocationCancellation) -> String?
    private var generation = UUID()
    private var cached: String??
    private struct Pending {
        let generation: UUID
        let cancellation: CLIInvocationCancellation
        let task: Task<String?, Never>
    }
    private enum Request {
        case cached(String?)
        case pending(Pending)
    }
    private var pending: Pending?

    init(run: @escaping @Sendable (CLIInvocationCancellation) -> String?) { self.run = run }
    var valueIfProbed: String?? { lock.withLock { cached } }
    func invalidate() {
        lock.withLock {
            generation = UUID(); cached = nil
            pending?.cancellation.cancel(); pending = nil
        }
    }
    func value(refresh: Bool = false) async -> String? {
        var refreshRequested = refresh
        while !Task.isCancelled {
            let request: Request = lock.withLock {
                if let pending { return .pending(pending) }
                if !refreshRequested, let cached { return .cached(cached) }
                generation = UUID()
                let cancellation = CLIInvocationCancellation(), run = run
                let task = Task { await WorkbenchIO.perform { run(cancellation) } }
                let started = Pending(generation: generation, cancellation: cancellation, task: task)
                pending = started
                return .pending(started)
            }
            refreshRequested = false
            switch request {
            case .cached(let value): return value
            case .pending(let started):
                let value = await started.task.value
                let accepted = lock.withLock {
                    guard generation == started.generation else { return false }
                    cached = .some(value); pending = nil
                    return true
                }
                if accepted { return value }
            }
        }
        return nil
    }
}

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

    /// The current environment fingerprint; the mlx-lm version reads the prewarmed cache and is nil until it is warm.
    var currentFingerprint: EnvironmentFingerprint {
        fingerprint()
    }

    /// The current environment fingerprint, recorded on verification reports.
    var currentFingerprintDescription: String {
        fingerprint().description
    }

    /// View evaluation reads only the cached result; cold probes run on an I/O worker.
    nonisolated static func probeMLXLVersion() -> String? { versionProbe.valueIfProbed ?? nil }

    nonisolated static func prewarmEnvironmentProbe() {
        Task(priority: .utility) { _ = await versionProbe.value() }
    }

    nonisolated static func invalidateEnvironmentProbe() {
        versionProbe.invalidate()
        prewarmEnvironmentProbe()
    }

    nonisolated static func refreshEnvironmentProbe() async {
        _ = await versionProbe.value(refresh: true)
    }

    nonisolated private static let versionProbe = EnvironmentVersionProbe(run: runVersionProbe)

    nonisolated private static func runVersionProbe(_ cancellation: CLIInvocationCancellation) -> String? {
        let script = "import importlib.metadata as m; print(m.version('mlx-lm'))"
        var candidates: [URL] = []
        if let preferred = WorkbenchPython.preferredExecutable() {
            candidates.append(preferred)
        }
        candidates.append(URL(fileURLWithPath: "/usr/bin/python3"))
        for python in candidates {
            if cancellation.isRequested { return nil }
            guard let output = try? BoundedProcessCapture.run(executable: python, arguments: ["-c", script],
                timeout: 5, outputLimit: 16 * 1024, cancellation: cancellation), output.status == 0 else { continue }
            let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
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
                    body: detail,
                    route: WatchAlertKind.upstreamChange.route,
                    code: code,
                    detail: detail
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

    var isMonitoring: Bool { monitorTask != nil }

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

    private func addAlert(kind: WatchAlertKind, fingerprint: String, modelKey: String, title: String, body: String, route: String,
                          code: String? = nil, detail: String? = nil) {
        guard !alerts.contains(where: { $0.fingerprint == fingerprint }) else { return }
        var alert = WatchAlert(
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
        alert.code = code
        alert.detail = detail
        guard !WatchAlertPresentation.isUnknownAccess(alert) else { return }
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
