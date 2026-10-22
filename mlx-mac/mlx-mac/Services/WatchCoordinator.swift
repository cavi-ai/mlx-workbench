import Foundation
import os

/// One in-flight probe per generation. Invalidating a runtime cancels its old
/// process and prevents late results from repopulating the cache.
final class EnvironmentVersionProbe: Sendable {
    private struct Pending: Sendable {
        let generation: UUID
        let cancellation: CLIInvocationCancellation
        let task: Task<String?, Never>
    }
    private enum Request: Sendable {
        case cached(String?)
        case pending(Pending)
    }
    private struct State {
        var generation = UUID()
        var cached: String??
        var pending: Pending?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let run: @Sendable (CLIInvocationCancellation) -> String?

    init(run: @escaping @Sendable (CLIInvocationCancellation) -> String?) { self.run = run }
    var valueIfProbed: String?? { state.withLock { $0.cached } }
    func invalidate() {
        state.withLock { state in
            state.generation = UUID(); state.cached = nil
            state.pending?.cancellation.cancel(); state.pending = nil
        }
    }
    func value(refresh: Bool = false) async -> String? {
        var refreshRequested = refresh
        while !Task.isCancelled {
            let refreshing = refreshRequested
            let request: Request = state.withLock { [run] state in
                if let pending = state.pending { return .pending(pending) }
                if !refreshing, let cached = state.cached { return .cached(cached) }
                state.generation = UUID()
                let cancellation = CLIInvocationCancellation()
                let task = Task { await WorkbenchIO.perform { run(cancellation) } }
                let started = Pending(generation: state.generation, cancellation: cancellation, task: task)
                state.pending = started
                return .pending(started)
            }
            refreshRequested = false
            switch request {
            case .cached(let value): return value
            case .pending(let started):
                let value = await started.task.value
                let accepted = state.withLock { state in
                    guard state.generation == started.generation else { return false }
                    state.cached = .some(value); state.pending = nil
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
    @Published private(set) var isLoadingHistory = true
    @Published private(set) var isChecking = false

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
    private let io = DispatchQueue(label: "watch-history", qos: .utility)
    private var historyTask: Task<Void, Never>?
    private var pendingWrite: Task<Bool, Never>?
    private var alertsLoaded = false
    private var stateLoaded = false
    private var alertPersistenceError: String?
    private var statePersistenceError: String?

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
        historyTask = Task { await loadHistory() }
    }

    func waitForHistory() async { await historyTask?.value }
    func waitForPersistence() async {
        await waitForHistory()
        _ = await pendingWrite?.value
    }

    private func loadHistory() async {
        defer { isLoadingHistory = false; historyTask = nil; refreshPersistenceError() }
        let alertStore = alertStore, stateStore = stateStore
        do {
            alerts = try await WorkbenchIO.perform(on: io) { Result { try alertStore.load() } }.get()
                .sorted { $0.createdAt > $1.createdAt }
            alertsLoaded = true
        } catch {
            alertPersistenceError = "Saved watch alerts are unavailable: \(AppHost.render(error))"
        }
        do {
            let stored = try await WorkbenchIO.perform(on: io) { Result { try stateStore.load() } }.get()
            state = stored.first ?? .empty
            lastCheckedAt = state.lastCheckedAt
            stateLoaded = true
        } catch {
            statePersistenceError = "Saved watch state is unavailable: \(AppHost.render(error))"
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

    nonisolated private static let versionProbe = EnvironmentVersionProbe { runVersionProbe($0) }

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
        await waitForPersistence()
        guard !isChecking, alertsLoaded, stateLoaded, !Task.isCancelled else { return }
        isChecking = true
        defer { isChecking = false }
        var next = state
        var candidates = await checkUpstream(state: &next)
        if let environment = checkEnvironment(state: &next) { candidates.append(environment) }
        guard await persistNewAlerts(candidates).value else { return }
        next.lastCheckedAt = now()
        let captured = next, store = stateStore
        _ = await enqueue {
            do {
                try await WorkbenchIO.perform(on: self.io) { Result { try store.replaceAll([captured]) } }.get()
                self.state = captured
                self.lastCheckedAt = captured.lastCheckedAt
                self.statePersistenceError = nil
                self.refreshPersistenceError()
                return true
            } catch {
                self.statePersistenceError = "Watch state could not be saved: \(AppHost.render(error))"
                self.refreshPersistenceError()
                return false
            }
        }.value
    }

    /// First run establishes the upstream baseline silently; later runs diff.
    private func checkUpstream(state next: inout WatchState) async -> [WatchAlert] {
        do {
            if !next.baselineEstablished {
                try await watchSnapshot()
                next.baselineEstablished = true
                return []
            }
            let findings = try await watchDiff()
            return findings.compactMap { finding in
                guard let repo = finding["repo"] as? String else { return nil }
                let detail = (finding["detail"] as? String) ?? "upstream change detected"
                let code = (finding["code"] as? String) ?? "changed"
                return makeAlert(
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
            return []
        }
    }

    private func checkEnvironment(state next: inout WatchState) -> WatchAlert? {
        let current = fingerprint().description
        guard let previous = next.lastEnvironmentFingerprint else {
            next.lastEnvironmentFingerprint = current
            return nil
        }
        guard previous != current else { return nil }
        next.lastEnvironmentFingerprint = current

        let stalePaths = verifiedReports()
            .filter { $0.environmentFingerprint != nil && $0.environmentFingerprint != current }
            .map(\.modelPath)
        guard !stalePaths.isEmpty else { return nil }
        return makeAlert(
            kind: .environmentDrift,
            fingerprint: "environment|\(previous)|\(current)",
            modelKey: "environment",
            title: "Runtime environment changed",
            body: "\(stalePaths.count) verified model(s) were verified under a previous macOS/MLX. Re-verify to refresh the evidence.",
            route: WatchAlertKind.environmentDrift.route
        )
    }

    // MARK: - Alert actions

    @discardableResult
    func act(on alertID: UUID) -> Task<Bool, Never> {
        guard let alert = alerts.first(where: { $0.id == alertID }) else { return Task { false } }
        if alert.kind == .environmentDrift {
            let current = fingerprint().description
            let stale = verifiedReports()
                .filter { $0.environmentFingerprint != nil && $0.environmentFingerprint != current }
                .map(\.modelPath)
            reverify(stale)
        }
        return dismiss(alertID)
    }

    @discardableResult
    func snooze(_ alertID: UUID, days: Int = 7) -> Task<Bool, Never> {
        let until = now().addingTimeInterval(TimeInterval(days) * 86_400)
        return update(alertID) { $0.snoozedUntil = until }
    }

    @discardableResult
    func mute(_ alertID: UUID) -> Task<Bool, Never> {
        update(alertID) { $0.muted = true }
    }

    @discardableResult
    func dismiss(_ alertID: UUID) -> Task<Bool, Never> {
        let date = now()
        return update(alertID) { $0.dismissedAt = date }
    }

    // MARK: - Scheduling

    var isMonitoring: Bool { monitorTask != nil }

    /// Check on launch when stale (>24h or never), then daily. Idempotent.
    func startMonitoring(intervalNanoseconds: UInt64 = 86_400_000_000_000) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            await self?.waitForHistory()
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

    private func makeAlert(kind: WatchAlertKind, fingerprint: String, modelKey: String, title: String, body: String, route: String,
                           code: String? = nil, detail: String? = nil) -> WatchAlert {
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
        return alert
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = pendingWrite
        let task = Task {
            await waitForHistory()
            _ = await previous?.value
            return await operation()
        }
        pendingWrite = task
        return task
    }

    private func persistNewAlerts(_ candidates: [WatchAlert]) -> Task<Bool, Never> {
        let known = Set(alerts.map(\.fingerprint))
        let candidates = candidates.filter { !known.contains($0.fingerprint) && !WatchAlertPresentation.isUnknownAccess($0) }
        guard !candidates.isEmpty else { return Task { true } }
        let store = alertStore
        return enqueue {
            do {
                let saved = try await WorkbenchIO.perform(on: self.io) { Result {
                    try store.mutate { values -> (all: [WatchAlert], inserted: [WatchAlert]) in
                        var known = Set(values.map(\.fingerprint)), inserted: [WatchAlert] = []
                        for alert in candidates where known.insert(alert.fingerprint).inserted { inserted.append(alert) }
                        values.append(contentsOf: inserted)
                        return (values, inserted)
                    }
                } }.get()
                self.alerts = saved.all.sorted { $0.createdAt > $1.createdAt }
                self.alertPersistenceError = nil
                self.refreshPersistenceError()
                saved.inserted.forEach(self.notify)
                return true
            } catch {
                self.alertPersistenceError = "Watch alerts could not be saved: \(AppHost.render(error))"
                self.refreshPersistenceError()
                return false
            }
        }
    }

    private func update(_ alertID: UUID, mutate: @escaping (inout WatchAlert) -> Void) -> Task<Bool, Never> {
        let store = alertStore
        return enqueue {
            guard let original = self.alerts.first(where: { $0.id == alertID }) else { return false }
            var updated = original
            mutate(&updated)
            let captured = updated
            do {
                guard try await WorkbenchIO.perform(on: self.io, { Result {
                    try store.update(id: alertID, keyPath: \.id) { current in
                        guard current == original else { throw WorkflowEvidenceError.invalid("Saved alert changed; reopen Watch before editing it.") }
                        return captured
                    }
                } }).get() else { throw WorkflowEvidenceError.invalid("Saved alert is no longer available.") }
                if let index = self.alerts.firstIndex(where: { $0.id == alertID }) { self.alerts[index] = updated }
                self.alertPersistenceError = nil
                self.refreshPersistenceError()
                return true
            } catch {
                self.alertPersistenceError = "Watch alert could not be saved: \(AppHost.render(error))"
                self.refreshPersistenceError()
                return false
            }
        }
    }

    private func refreshPersistenceError() { persistenceError = alertPersistenceError ?? statePersistenceError }
}
