import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class WatchCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
    private let fingerprintA = EnvironmentFingerprint(macOSVersion: "26.5", chip: "M4", mlxLMVersion: "0.24.0")
    private let fingerprintB = EnvironmentFingerprint(macOSVersion: "26.6", chip: "M4", mlxLMVersion: "0.24.0")

    // MARK: - Alert lifecycle

    func testAlertActiveRespectsSnoozeMuteDismiss() {
        var alert = makeAlert()
        XCTAssertTrue(alert.isActive(at: now))

        alert.snoozedUntil = now.addingTimeInterval(3600)
        XCTAssertFalse(alert.isActive(at: now))
        XCTAssertTrue(alert.isActive(at: now.addingTimeInterval(7200)))

        alert.snoozedUntil = nil
        alert.muted = true
        XCTAssertFalse(alert.isActive(at: now.addingTimeInterval(7200)))

        alert.muted = false
        alert.dismissedAt = now
        XCTAssertFalse(alert.isActive(at: now.addingTimeInterval(7200)))
    }

    // MARK: - Upstream watch

    func testFirstCheckEstablishesBaselineWithoutAlerting() async {
        let calls = CallRecorder()
        let coordinator = makeCoordinator(
            snapshot: { await calls.record("snapshot") },
            diff: { await calls.record("diff"); return [] }
        )

        await coordinator.checkNow()

        XCTAssertEqual(calls.values, ["snapshot"])
        XCTAssertTrue(coordinator.alerts.isEmpty)

        await coordinator.checkNow()
        XCTAssertEqual(calls.values, ["snapshot", "diff"])
    }

    func testUpstreamFindingsBecomeAlerts() async {
        let coordinator = makeCoordinator(
            snapshot: {},
            diff: { [["repo": "mlx-community/qwen3-8b", "detail": "3 files changed", "code": "files_changed"]] }
        )
        await coordinator.checkNow()  // baseline
        await coordinator.checkNow()  // diff

        XCTAssertEqual(coordinator.alerts.count, 1)
        XCTAssertEqual(coordinator.alerts.first?.kind, .upstreamChange)
        XCTAssertEqual(coordinator.alerts.first?.route, "convert")
        XCTAssertTrue(coordinator.alerts.first?.title.contains("qwen3-8b") == true)
    }

    func testUpstreamAlertsKeepTheFindingCodeAndDropUnknownAccessChanges() async {
        let coordinator = makeCoordinator(
            snapshot: {},
            diff: { [
                ["repo": "mlx-community/qwen3-8b-4bit", "detail": "new tracked repository matching an owned model", "code": "new_quant_of_owned"],
                ["repo": "mlx-community/tts", "detail": "gated changed from public to unknown", "code": "gated_changed"],
            ] }
        )
        await coordinator.checkNow()
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.alerts.map(\.code), ["new_quant_of_owned"])
        XCTAssertEqual(coordinator.alerts.first?.detail, "new tracked repository matching an owned model")
        XCTAssertFalse(coordinator.alerts.first?.body.contains("Re-sync") ?? true)
    }

    /// Every upstream alert carries the action that resolves it; raw finding codes never reach the user.
    func testAlertPresentationOffersAnActionPerFinding() {
        func alert(_ code: String?, _ detail: String?, body: String = "b", repo: String = "org/model") -> WatchAlert {
            var value = WatchAlert(id: UUID(), kind: .upstreamChange, fingerprint: "f", modelKey: repo, title: "t", body: body,
                                   route: "convert", createdAt: now, snoozedUntil: nil, muted: false, dismissedAt: nil)
            value.code = code
            value.detail = detail
            return value
        }
        let fresh = WatchAlertPresentation(alert: alert("new_quant_of_owned", "new tracked repository matching an owned model"))
        XCTAssertEqual(fresh.title, "New upload of a model you have")
        XCTAssertEqual(fresh.primary, WatchAlertPresentation.Action(title: "Add from Hugging Face", kind: .addFromHuggingFace(repo: "org/model")))

        let updated = WatchAlertPresentation(alert: alert("updated_tracked_repo", "weight bytes changed from 1000 to 2000"))
        XCTAssertEqual(updated.primary?.kind, .addFromHuggingFace(repo: "org/model"))
        XCTAssertEqual(updated.primary?.title, "Get update")

        let missing = WatchAlertPresentation(alert: alert("owned_missing", "previously owned via lmstudio; no longer present"))
        XCTAssertEqual(missing.title, "org/model is no longer on this Mac")
        XCTAssertTrue(missing.message.contains("LM Studio"))
        XCTAssertEqual(missing.primary?.title, "Download again")
        XCTAssertEqual(missing.muteTitle, "Stop watching")

        let gated = WatchAlertPresentation(alert: alert("gated_changed", "gated changed from False to manual"))
        XCTAssertEqual(gated.primary?.kind, .openOnHuggingFace(repo: "org/model"))

        let legacy = WatchAlertPresentation(alert: alert(nil, nil, body: "[owned_missing] previously owned via lmstudio; no longer present. Re-sync via Prepare when ready."))
        XCTAssertEqual(legacy.primary?.title, "Download again")
        XCTAssertFalse(legacy.message.contains("["))

        let drift = WatchAlert(id: UUID(), kind: .environmentDrift, fingerprint: "e", modelKey: "environment", title: "Runtime environment changed",
                               body: "2 verified model(s) were verified under a previous macOS/MLX.", route: "models", createdAt: now,
                               snoozedUntil: nil, muted: false, dismissedAt: nil)
        XCTAssertEqual(WatchAlertPresentation(alert: drift).primary?.kind, .reverify)
    }

    func testLegacyUnknownAccessAlertsAreNotActive() {
        var legacy = makeAlert()
        legacy = WatchAlert(id: legacy.id, kind: .upstreamChange, fingerprint: "g", modelKey: "org/tts", title: "t",
                            body: "[gated_changed] gated changed from public to unknown. Re-sync via Prepare when ready.",
                            route: "convert", createdAt: now, snoozedUntil: nil, muted: false, dismissedAt: nil)
        XCTAssertFalse(legacy.isActive(at: now))
    }

    func testUpstreamAlertsDedupeByFingerprint() async {
        let finding = ["repo": "mlx-community/qwen3-8b", "detail": "3 files changed"]
        let coordinator = makeCoordinator(snapshot: {}, diff: { [finding] })
        await coordinator.checkNow()
        await coordinator.checkNow()
        await coordinator.checkNow()

        XCTAssertEqual(coordinator.alerts.count, 1)
    }

    func testOfflineDiffStaysSilent() async {
        struct Offline: Error {}
        let coordinator = makeCoordinator(
            snapshot: {},
            diff: { throw Offline() }
        )
        await coordinator.checkNow()
        await coordinator.checkNow()  // diff throws

        XCTAssertTrue(coordinator.alerts.isEmpty)
        XCTAssertNil(coordinator.lastError)
        XCTAssertNotNil(coordinator.lastCheckedAt)
    }

    // MARK: - Environment drift

    func testEnvironmentChangeAlertsWhenVerifiedEvidenceIsStale() async {
        let notifier = Notifier()
        var current = fingerprintA
        let coordinator = makeCoordinator(
            snapshot: {},
            diff: { [] },
            fingerprint: { current },
            reports: [self.makeReport(path: "/Models/q4", fingerprint: self.fingerprintA.description)],
            notify: { notifier.record($0) }
        )
        await coordinator.checkNow()  // records fingerprintA
        XCTAssertTrue(coordinator.alerts.isEmpty)

        current = fingerprintB
        await coordinator.checkNow()

        XCTAssertEqual(coordinator.alerts.count, 1)
        XCTAssertEqual(coordinator.alerts.first?.kind, .environmentDrift)
        XCTAssertTrue(coordinator.alerts.first?.body.contains("1 verified model") == true)
        XCTAssertEqual(notifier.alerts.count, 1)
    }

    func testEnvironmentChangeWithoutStaleEvidenceStaysQuiet() async {
        var current = fingerprintA
        let coordinator = makeCoordinator(
            snapshot: {},
            diff: { [] },
            fingerprint: { current },
            reports: [self.makeReport(path: "/Models/q4", fingerprint: nil)]  // pre-fingerprint evidence
        )
        await coordinator.checkNow()
        current = fingerprintB
        await coordinator.checkNow()

        XCTAssertTrue(coordinator.alerts.isEmpty)
    }

    func testDriftActionReverifiesStaleModelsAndDismisses() async throws {
        let reverified = PathRecorder()
        var current = fingerprintA
        let coordinator = makeCoordinator(
            snapshot: {},
            diff: { [] },
            fingerprint: { current },
            reports: [
                self.makeReport(path: "/Models/stale", fingerprint: self.fingerprintA.description),
                self.makeReport(path: "/Models/current", fingerprint: self.fingerprintB.description),
            ]
        )
        coordinator.reverify = { reverified.record($0) }
        await coordinator.checkNow()
        current = fingerprintB
        await coordinator.checkNow()
        let alert = try XCTUnwrap(coordinator.alerts.first)

        coordinator.act(on: alert.id)

        XCTAssertEqual(reverified.paths, [["/Models/stale"]])
        XCTAssertTrue(coordinator.activeAlerts.isEmpty)
    }

    func testSnoozeAndMutePersist() async throws {
        let alertStoreURL = temporaryURL("alerts.json")
        let coordinator = makeCoordinator(
            alertStoreURL: alertStoreURL,
            snapshot: {},
            diff: { [["repo": "mlx-community/qwen3-8b", "detail": "changed"]] }
        )
        await coordinator.checkNow()
        await coordinator.checkNow()
        let alert = try XCTUnwrap(coordinator.alerts.first)

        coordinator.snooze(alert.id)
        XCTAssertTrue(coordinator.activeAlerts.isEmpty)

        let reloaded = makeCoordinator(alertStoreURL: alertStoreURL, snapshot: {}, diff: { [] })
        XCTAssertEqual(reloaded.alerts.count, 1)
        XCTAssertTrue(reloaded.activeAlerts.isEmpty)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        alertStoreURL: URL? = nil,
        snapshot: @escaping @Sendable () async throws -> Void,
        diff: @escaping @Sendable () async throws -> [[String: Any]],
        fingerprint: @escaping () -> EnvironmentFingerprint? = { nil },
        reports: [VerificationReport] = [],
        notify: @escaping (WatchAlert) -> Void = { _ in }
    ) -> WatchCoordinator {
        WatchCoordinator(
            watchDiff: diff,
            watchSnapshot: snapshot,
            fingerprint: { fingerprint() ?? self.fingerprintA },
            verifiedReports: { reports },
            alertStore: JSONStore<WatchAlert>(fileURL: alertStoreURL ?? temporaryURL("alerts.json")),
            stateStore: JSONStore<WatchState>(fileURL: temporaryURL("state.json")),
            notify: notify,
            now: { self.now }
        )
    }

    private func makeAlert() -> WatchAlert {
        WatchAlert(
            id: UUID(), kind: .upstreamChange, fingerprint: "f",
            modelKey: "m", title: "t", body: "b", route: "convert",
            createdAt: now, snoozedUntil: nil, muted: false, dismissedAt: nil
        )
    }

    private func makeReport(path: String, fingerprint: String?) -> VerificationReport {
        VerificationReport(
            id: UUID(), modelPath: path, modelSignature: "sig", workflowRecordID: nil,
            suiteVersion: 1, canaries: [], tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
            metricsEstimated: false, startedAt: now, finishedAt: now,
            outcome: .passed, environmentFingerprint: fingerprint
        )
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-watch-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}

private final class Notifier: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WatchAlert] = []
    var alerts: [WatchAlert] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ alert: WatchAlert) {
        lock.lock()
        recorded.append(alert)
        lock.unlock()
    }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var paths: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ value: [String]) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}
