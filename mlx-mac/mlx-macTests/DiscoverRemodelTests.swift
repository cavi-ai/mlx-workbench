import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum DiscoverFixtures {
    static let totalBytes: Int64 = 137_438_953_472
    static let hardware = HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: totalBytes, macOSVersion: nil)
    static let reserveGB = 4.0
    static let context = FitAdvisor.defaultContextTokens

    /// A live reading with 100 GB available: a 96 GB budget after the 4 GB reserve.
    static func memory(available: Int64 = 100_000_000_000) -> MemorySnapshot {
        MemorySnapshot(totalBytes: totalBytes, availableBytes: available)
    }

    static func candidate(
        _ repo: String, gb: Double? = 4, fits: Bool? = true, roles: [String] = ["general"],
        license: String? = "apache-2.0", downloads: Int? = 1_200, likes: Int? = 30
    ) -> DiscoverCandidate {
        DiscoverCandidate(
            repo: repo, base: nil, roles: roles, estRamGb: gb, fits: fits, license: license, wiring: nil,
            downloads: downloads, likes: likes
        )
    }

    static func model(_ path: String, bytes: Int64 = 4_000_000_000) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "4bit", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil, task: nil
        )
        return LibraryModel(item: item, readiness: .ready)
    }

    static func snapshot(_ paths: [String]) -> LibrarySnapshot {
        LibrarySnapshot(models: paths.map { model($0) }, groups: [], hardware: hardware, generatedAt: Date(timeIntervalSinceReferenceDate: 1_000_000_000))
    }

    static func presentation(
        _ candidates: [DiscoverCandidate], memory: MemorySnapshot? = memory(), hasProbed: Bool = true, library: LibrarySnapshot? = nil
    ) -> DiscoverPresentation {
        DiscoverPresentation.make(
            candidates: candidates, memory: memory, hasProbed: hasProbed, reserveGB: reserveGB,
            contextTokens: context, hardware: hardware, library: library
        )
    }

    static func fit(_ candidate: DiscoverCandidate, memory: MemorySnapshot? = memory(), hasProbed: Bool = true) -> DiscoverFit {
        presentation([candidate], memory: memory, hasProbed: hasProbed).rows[0].fit
    }

    /// The shape `mlx-agent discover` prints: `roles` keyed by role, only non-empty buckets, in the agent's
    /// DISCOVERY_ROLES order, a repo listed under every role it matches. Copied from the vendored agent's
    /// `DiscoveryService.discover` output (src/mlx_agent/discovery.py) and its unit tests.
    static func agentOutput(roleKeys: [String]? = nil) -> [String: Any] {
        func item(_ repo: String, role: String, roles: [String], ram: Any, fits: Bool) -> [String: Any] {
            [
                "repo": repo, "role": role, "roles": roles, "downloads": 1200, "likes": 40, "trusted": true,
                "base": repo.split(separator: "/").last.map(String.init) ?? repo, "qrank": 3,
                "est_ram_gb": ram, "ram_src": "estimated_from_weight_bytes", "fits": fits, "reasoning": false,
                "reason_src": "name", "gated": false, "license": "apache-2.0", "wiring": "mlx_lm.server",
                "facts": ["repository": repo, "gated": "public"],
            ]
        }
        let buckets: [String: [[String: Any]]] = [
            "vision": [item("mlx-community/Qwen2.5-VL-7B-4bit", role: "vision", roles: ["vision"], ram: 5.4, fits: true)],
            "coding": [
                item("mlx-community/Coder-A-4bit", role: "coding", roles: ["coding"], ram: 4.2, fits: true),
                item("mlx-community/Coder-Tools-4bit", role: "coding", roles: ["coding", "tool-use"], ram: 9.9, fits: true),
            ],
            "general": [item("mlx-community/General-8B-4bit", role: "general", roles: ["general"], ram: NSNull(), fits: true)],
            "tool-use": [
                item("mlx-community/Coder-Tools-4bit", role: "tool-use", roles: ["coding", "tool-use"], ram: 9.9, fits: true),
                item("mlx-community/Tools-Only-4bit", role: "tool-use", roles: ["tool-use"], ram: 3.1, fits: true),
            ],
            "zeta": [item("mlx-community/Zeta-4bit", role: "zeta", roles: ["zeta"], ram: 1.0, fits: true)],
            "alpha": [item("mlx-community/Alpha-4bit", role: "alpha", roles: ["alpha"], ram: 1.0, fits: true)],
        ]
        var roles: [String: Any] = [:]
        for key in roleKeys ?? Array(buckets.keys) { roles[key] = buckets[key] }
        return ["host": ["ram_gb": 128, "chip": "Apple M4 Max"], "fast": false, "roles": roles]
    }
}

// MARK: - Parser

final class DiscoverParserTests: XCTestCase {
    private let expectedOrder = [
        "mlx-community/Qwen2.5-VL-7B-4bit",
        "mlx-community/Coder-A-4bit",
        "mlx-community/Coder-Tools-4bit",
        "mlx-community/General-8B-4bit",
        "mlx-community/Tools-Only-4bit",
        "mlx-community/Alpha-4bit",
        "mlx-community/Zeta-4bit",
    ]

    func testRolesMergeInTheAgentsRoleOrderWithOneEntryPerRepo() throws {
        let parsed = try XCTUnwrap(WorkbenchAPI.candidates(from: DiscoverFixtures.agentOutput()))
        XCTAssertEqual(parsed.map(\.repo), expectedOrder)
    }

    func testOrderIsStableAcrossRepeatedParsesAndInsertionOrders() throws {
        let keys = ["zeta", "tool-use", "general", "coding", "vision", "alpha"]
        for attempt in 0..<40 {
            let shuffled = attempt.isMultiple(of: 2) ? keys : keys.reversed()
            let parsed = try XCTUnwrap(WorkbenchAPI.candidates(from: DiscoverFixtures.agentOutput(roleKeys: shuffled)))
            XCTAssertEqual(parsed.map(\.repo), expectedOrder, "attempt \(attempt)")
        }
    }

    func testSelectedRoleKeepsThatBucketsOrder() throws {
        let parsed = try XCTUnwrap(WorkbenchAPI.candidates(from: DiscoverFixtures.agentOutput(roleKeys: ["coding"])))
        XCTAssertEqual(parsed.map(\.repo), ["mlx-community/Coder-A-4bit", "mlx-community/Coder-Tools-4bit"])
    }

    func testAMultiRoleRepoKeepsAllItsRolesAndTheNullSizeStaysUnknown() throws {
        let parsed = try XCTUnwrap(WorkbenchAPI.candidates(from: DiscoverFixtures.agentOutput()))
        let tools = try XCTUnwrap(parsed.first { $0.repo == "mlx-community/Coder-Tools-4bit" })
        XCTAssertEqual(tools.roles, ["coding", "tool-use"])
        XCTAssertNil(try XCTUnwrap(parsed.first { $0.repo == "mlx-community/General-8B-4bit" }).estRamGb)
    }

    func testTheCandidatesKeyShapeIsUnchanged() throws {
        let data: [String: Any] = ["candidates": [["repo": "org/b"], ["repo": "org/a"], ["repo": "org/b"]]]
        XCTAssertEqual(WorkbenchAPI.candidates(from: data)?.map(\.repo), ["org/b", "org/a"])
    }
}

// MARK: - Fit

final class DiscoverFitTests: XCTestCase {
    private typealias F = DiscoverFixtures

    func testFitsTightAndWontFitFollowTheLiveBudget() {
        XCTAssertEqual(F.fit(F.candidate("o/small", gb: 8)).word, "Fits")
        XCTAssertEqual(F.fit(F.candidate("o/mid", gb: 85)).word, "Tight")
        XCTAssertEqual(F.fit(F.candidate("o/huge", gb: 120)).word, "Won't fit")
        XCTAssertEqual(F.fit(F.candidate("o/small", gb: 8)).tone, .fits)
        XCTAssertEqual(F.fit(F.candidate("o/mid", gb: 85)).tone, .tight)
        XCTAssertEqual(F.fit(F.candidate("o/huge", gb: 120)).tone, .wontFit)
        let fills = [8.0, 85, 120].compactMap { F.fit(F.candidate("o/m", gb: $0)).fill }
        XCTAssertEqual(fills.count, 3)
        XCTAssertEqual(fills, fills.sorted())
        XCTAssertEqual(fills.last, 1)
    }

    func testVerdictEqualsOverviewsForTheSameSizeAndBudget() throws {
        for gb in [0.5, 8, 40, 78, 79, 85, 93, 94, 120] {
            let bytes = Int64(gb * 1e9)
            let row = F.fit(F.candidate("o/m", gb: gb))
            let bySubject = ModelBudgetPresentation(
                memory: F.memory(), reserveGB: F.reserveGB, contextTokens: F.context,
                subject: .init(bytes: bytes, parameters: nil, task: nil), hardware: F.hardware
            )
            let overview = ModelBudgetPresentation(
                memory: F.memory(), reserveGB: F.reserveGB, contextTokens: F.context,
                model: F.model("/m/x", bytes: bytes), hardware: F.hardware
            )
            XCTAssertEqual(row.word, bySubject.verdictWord, "\(gb) GB")
            XCTAssertEqual(row.word, overview.verdictWord, "\(gb) GB")
            XCTAssertEqual(row.tone, overview.tone, "\(gb) GB")
            XCTAssertEqual(row.fill, LibraryFitPresentation.quantized(try XCTUnwrap(overview.fitFraction)), "\(gb) GB")
        }
    }

    func testAnUnknownSizeHasNoBarAndIgnoresTheAgentVerdict() {
        for size in [nil, 0, -3, Double.nan, Double.infinity] as [Double?] {
            let fit = F.fit(F.candidate("o/m", gb: size, fits: true))
            XCTAssertEqual(fit.state, .sizeUnknown)
            XCTAssertEqual(fit.word, "Size unknown")
            XCTAssertNil(fit.fill)
            XCTAssertFalse(fit.showsTrack)
            XCTAssertNil(fit.weightsText)
            XCTAssertNil(fit.agentBasis)
            XCTAssertNil(fit.basisNote)
        }
    }

    func testAnUnreadableBudgetIsUnavailableAndAnUnprobedOneIsRedacted() {
        let unavailable = F.fit(F.candidate("o/m", gb: 8), memory: nil, hasProbed: true)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertNil(unavailable.fill)
        XCTAssertFalse(unavailable.showsTrack)
        XCTAssertEqual(unavailable.tone, .neutral)
        let loading = F.fit(F.candidate("o/m", gb: 8), memory: nil, hasProbed: false)
        XCTAssertEqual(loading.state, .redacted)
        XCTAssertNil(loading.fill)
        XCTAssertTrue(loading.showsTrack)
    }

    func testWeightsAreLabelledAsAnEstimate() {
        XCTAssertEqual(F.fit(F.candidate("o/m", gb: 17.24)).weightsText, "~17.2 GB weights (est.)")
    }

    func testAgentVerdictIsOnlyALabelledBasisAndShowsWhenItDisagrees() {
        let disagree = F.fit(F.candidate("o/m", gb: 120, fits: true))
        XCTAssertEqual(disagree.word, "Won't fit")
        XCTAssertEqual(disagree.basisNote, "Static check: weights under 80% of total memory")
        XCTAssertTrue(disagree.help.contains("Static check"))
        let agree = F.fit(F.candidate("o/m", gb: 8, fits: true))
        XCTAssertEqual(agree.word, "Fits")
        XCTAssertNil(agree.basisNote)
        XCTAssertNotNil(agree.agentBasis)
        let reverse = F.fit(F.candidate("o/m", gb: 8, fits: false))
        XCTAssertEqual(reverse.basisNote, "Static check: weights over 80% of total memory")
        XCTAssertNil(F.fit(F.candidate("o/m", gb: 8, fits: nil)).agentBasis)
    }

    func testBarsMoveInStepsSoProbeDriftLeavesThemStill() {
        let first = F.fit(F.candidate("o/m", gb: 30), memory: F.memory(available: 100_000_000_000))
        let drifted = F.fit(F.candidate("o/m", gb: 30), memory: F.memory(available: 100_400_000_000))
        XCTAssertEqual(first.fill, drifted.fill)
    }

    func testLegendComesFromTheSharedBudgetOwner() {
        let live = DiscoverLegend.make(memory: F.memory(), hasProbed: true, reserveGB: F.reserveGB, contextTokens: F.context, hardware: F.hardware)
        let owner = ModelBudgetPresentation(memory: F.memory(), reserveGB: F.reserveGB, contextTokens: F.context, subject: nil, hardware: F.hardware)
        XCTAssertEqual(live.reading, .live)
        XCTAssertEqual(live.lead, owner.leadText.map { $0 + " GB" })
        XCTAssertEqual(live.caption, owner.caption)
        XCTAssertEqual(live.compactCaption, owner.compactCaption)
        let loading = DiscoverLegend.make(memory: nil, hasProbed: false, reserveGB: F.reserveGB, contextTokens: F.context, hardware: F.hardware)
        XCTAssertEqual(loading.reading, .loading)
        XCTAssertNil(loading.lead)
        let unavailable = DiscoverLegend.make(memory: nil, hasProbed: true, reserveGB: F.reserveGB, contextTokens: F.context, hardware: F.hardware)
        XCTAssertEqual(unavailable.reading, .unavailable)
        XCTAssertEqual(unavailable.caption, "Memory reading unavailable")
        XCTAssertNil(unavailable.lead)
    }

    func testRowsKeepTheInputOrderAndCompactTheFigures() {
        let candidates = [
            F.candidate("o/z", gb: 120, downloads: 1_234, likes: 9),
            F.candidate("o/a", gb: 2, downloads: 3_400_000, likes: 12_500),
        ]
        let rows = F.presentation(candidates).rows
        XCTAssertEqual(rows.map(\.repo), ["o/z", "o/a"])
        XCTAssertEqual(rows[0].downloadsText, "1.2K")
        XCTAssertEqual(rows[0].likesText, "9")
        XCTAssertEqual(rows[1].downloadsText, "3.4M")
        XCTAssertEqual(rows[1].likesText, "12K")
        XCTAssertEqual(DiscoverRow.compactCount(999), "999")
        XCTAssertEqual(DiscoverRow.compactCount(1_000), "1.0K")
    }
}

// MARK: - Library

final class DiscoverLibraryTests: XCTestCase {
    private typealias F = DiscoverFixtures

    private func marked(_ repo: String, paths: [String]?) -> Bool {
        F.presentation([F.candidate(repo)], library: paths.map(F.snapshot)).rows[0].isInLibrary
    }

    func testAnExactCacheRepoMatchMarksTheRow() {
        let cache = "/Users/test/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-4bit/snapshots/abc123"
        XCTAssertTrue(marked("mlx-community/Qwen3-4B-4bit", paths: [cache]))
        XCTAssertTrue(marked("mlx-community/Qwen3-4B-4bit", paths: ["/other/x.gguf", cache]))
    }

    func testAnotherQuantizationDoesNotMatch() {
        let cache = "/Users/test/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-4bit/snapshots/abc123"
        XCTAssertFalse(marked("mlx-community/Qwen3-4B-8bit", paths: [cache]))
    }

    func testAnOutputDirectoryCopyIsNotMatchedBecauseOnlyCacheLayoutPathsNameARepo() {
        XCTAssertFalse(marked("mlx-community/Qwen3-4B-4bit", paths: ["/Users/test/.models/mlx/Qwen3-4B-4bit"]))
    }

    func testAGGUFRepoDoesNotMatchAnMLXCacheEntry() {
        let cache = "/Users/test/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-4bit/snapshots/abc123"
        XCTAssertFalse(marked("unsloth/Qwen3-4B-GGUF", paths: [cache, "/models/Qwen3-4B-Q4_K_M.gguf"]))
    }

    func testANilSnapshotMarksNothing() {
        XCTAssertFalse(marked("mlx-community/Qwen3-4B-4bit", paths: nil))
        XCTAssertEqual(DiscoverPresentation.libraryRepos(in: nil), [])
    }

    func testMatchingIsCaseExact() {
        let cache = "/Users/test/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-4bit/snapshots/abc123"
        XCTAssertFalse(marked("mlx-community/qwen3-4b-4bit", paths: [cache]))
    }
}

// MARK: - Intake handoff

@MainActor
final class DiscoverIntakeHandoffTests: XCTestCase {
    private final class Gate {
        var continuation: CheckedContinuation<IntakeResolution, Error>?
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTheHandoffResolvesTheRepoAndNeverFetchesOrInstalls() async throws {
        var resolved: [String] = []
        var fetched = 0
        let api = IntakeAPI.stub(
            resolve: { text in resolved.append(text); return try IntakeCoordinatorTests.resolution(verdict: "convertible", backend: "mlx-lm") },
            installPreview: { _ in fetched += 1; return [:] },
            installStart: { _, _ in fetched += 1; return [:] },
            fetchPreview: { _ in fetched += 1; return [:] },
            fetchStart: { _, _ in fetched += 1; return [:] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        var opened = 0
        XCTAssertTrue(DiscoverIntakeAction.perform(repo: "org/name", intake: intake, openWindow: { opened += 1 }))
        try await waitUntil { intake.resolution != nil }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(intake.sourceText, "org/name")
        XCTAssertEqual(resolved, ["org/name"])
        XCTAssertEqual(fetched, 0)
        XCTAssertNil(intake.downloadedPath)
    }

    func testABusyIntakeIsLeftUntouchedAndTheActionReportsDisabled() async throws {
        let gate = Gate()
        let api = IntakeAPI.stub(resolve: { _ in
            try await withCheckedThrowingContinuation { gate.continuation = $0 }
        })
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        var opened = 0
        XCTAssertTrue(DiscoverIntakeAction.perform(repo: "org/first", intake: intake, openWindow: { opened += 1 }))
        try await waitUntil { intake.isBusy && gate.continuation != nil }
        XCTAssertTrue(intake.isBusy)
        XCTAssertFalse(DiscoverIntakeAction.isEnabled(intakeIsBusy: intake.isBusy))
        XCTAssertFalse(DiscoverIntakeAction.perform(repo: "org/second", intake: intake, openWindow: { opened += 1 }))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(intake.sourceText, "org/first")
        gate.continuation?.resume(throwing: IntakeStubError.unused)
        try await waitUntil { !intake.isBusy }
    }

    func testTheActionExplainsWhyItIsDisabled() {
        XCTAssertTrue(DiscoverIntakeAction.isEnabled(intakeIsBusy: false))
        XCTAssertEqual(DiscoverIntakeAction.help(intakeIsBusy: true), "An intake is in progress")
        XCTAssertNotEqual(DiscoverIntakeAction.help(intakeIsBusy: false), DiscoverIntakeAction.busyHelp)
        XCTAssertEqual(DiscoverIntakeAction.title, "Add from Hugging Face…")
    }
}

// MARK: - States, controls and layout

@MainActor
final class DiscoverySessionTests: XCTestCase {
    @MainActor private final class Gate {
        var continuation: CheckedContinuation<[DiscoverCandidate], Error>?
        var requests: [DiscoveryRequest] = []
        func fetch(_ request: DiscoveryRequest) async throws -> [DiscoverCandidate] {
            requests.append(request)
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ result: Result<[DiscoverCandidate], Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }
    private struct Failed: LocalizedError { var errorDescription: String? { "Discovery connection failed" } }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }

    func testStopKeepsTheRequestBusyUntilItExitsAndRejectsItsLateResult() async {
        let gate = Gate()
        let session = DiscoverySession(fetch: gate.fetch)
        let request = DiscoveryRequest(role: "coding", limit: 3, fast: true)
        XCTAssertTrue(gate.requests.isEmpty)
        session.start(request)
        await settle { gate.continuation != nil }
        session.stop()
        XCTAssertTrue(session.isStopping)
        XCTAssertTrue(session.state.isRunning)
        session.start(request)
        session.clear()
        XCTAssertEqual(gate.requests, [request])
        gate.finish(.success([DiscoverFixtures.candidate("o/late")]))
        await settle { !session.state.isRunning }
        XCTAssertEqual(session.state, .stopped)
        XCTAssertNil(session.result)
        XCTAssertFalse(session.isStopping)
        XCTAssertEqual(session.resultToken, 0)
        session.start(request)
        await settle { gate.continuation != nil }
        gate.finish(.success([DiscoverFixtures.candidate("o/retried")]))
        await settle { !session.state.isRunning }
        XCTAssertEqual(session.result?.candidates.first?.repo, "o/retried")
    }

    func testRefreshFailureRetainsCandidatesAndTheirOriginalSearchSettings() async {
        let gate = Gate()
        let session = DiscoverySession(fetch: gate.fetch)
        let original = DiscoveryRequest(role: "coding", limit: 3, fast: true)
        session.start(original)
        await settle { gate.continuation != nil }
        let candidates = [DiscoverFixtures.candidate("o/previous")]
        gate.finish(.success(candidates))
        await settle { !session.state.isRunning }
        let next = DiscoveryRequest(role: "reasoning", limit: 5, fast: false)
        session.start(next)
        await settle { gate.continuation != nil }
        XCTAssertEqual(session.result?.candidates, candidates)
        XCTAssertEqual(session.result?.request, original)
        XCTAssertEqual(session.request, next)
        gate.finish(.failure(Failed()))
        await settle { !session.state.isRunning }
        XCTAssertTrue(session.state.isFailed)
        XCTAssertEqual(session.result?.request, original)
        XCTAssertEqual(session.resultToken, 1)
        session.clear()
        XCTAssertNil(session.result)
        XCTAssertEqual(session.state, .notRun)
    }

    func testSuccessfulEmptySearchReplacesOlderCandidates() async {
        let gate = Gate()
        let session = DiscoverySession(initialState: .completed([DiscoverFixtures.candidate("o/old")]), fetch: gate.fetch)
        XCTAssertNil(session.result?.request, "Render inputs must not invent recorded search settings")
        session.start(DiscoveryRequest(role: "", limit: 50, fast: false))
        await settle { gate.continuation != nil }
        gate.finish(.success([]))
        await settle { !session.state.isRunning }
        XCTAssertEqual(session.result?.candidates, [])
        XCTAssertEqual(session.state, .completed([]))
        XCTAssertEqual(session.result?.request?.role, nil)
    }
}

final class DiscoverStateAndControlTests: XCTestCase {
    func testEachStateHasASymbolAndOneSentence() {
        let idle = DiscoverStatePresentation.make(.notRun)
        XCTAssertEqual(idle.kind, .idle)
        XCTAssertEqual(idle.sentence, DiscoveryState.notRun.message)
        let running = DiscoverStatePresentation.make(.running)
        XCTAssertEqual(running.kind, .running)
        XCTAssertTrue(running.sentence.contains("lists and inspects"))
        XCTAssertTrue(running.sentence.contains("few minutes"))
        let fastRunning = DiscoverStatePresentation.make(.running, fast: true)
        XCTAssertEqual(fastRunning.sentence, "Discovering models. This lists Hugging Face repositories without inspecting them, so sizes may be missing.")
        XCTAssertFalse(fastRunning.sentence.contains("inspects"))
        let empty = DiscoverStatePresentation.make(.completed([]))
        XCTAssertEqual(empty.kind, .empty)
        XCTAssertEqual(empty.sentence, "No candidates matched. Try another role or adjust the limit, then Discover again.")
        let failed = DiscoverStatePresentation.make(.failed("Fixture discovery failed: catalog unavailable."))
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertTrue(failed.sentence.contains("Fixture discovery failed"))
        let populated = DiscoverStatePresentation.make(.completed([DiscoverFixtures.candidate("o/m")]))
        XCTAssertEqual(populated.kind, .populated)
        for state in [idle, running, empty, failed, populated] { XCTAssertFalse(state.symbol.isEmpty) }
    }

    func testTheLimitIsBoundedAndPerRole() {
        XCTAssertEqual(DiscoverLimit.range, 1...50)
        XCTAssertEqual(DiscoverLimit.clamped(0), 1)
        XCTAssertEqual(DiscoverLimit.clamped(-7), 1)
        XCTAssertEqual(DiscoverLimit.clamped(51), 50)
        XCTAssertEqual(DiscoverLimit.clamped(25), 25)
        XCTAssertTrue(DiscoverLimit.range.contains(DiscoverLimit.initial))
        XCTAssertEqual(DiscoverRole.choices, ["", "vision", "embedding", "coding", "reasoning", "general", "tool-use"])
        XCTAssertEqual(DiscoverRole.choices.map(DiscoverRole.title),
                       ["Any", "Vision", "Embedding", "Coding", "Reasoning", "General", "Tool use"])
    }

    func testRoleChoicesAreExactlyTheRolesTheVendoredAgentAccepts() throws {
        let models = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/mlx-agent/providers/codex/src/mlx_agent/models.py")
        let source = try String(contentsOf: models, encoding: .utf8)
        let block = try XCTUnwrap(source.range(of: #"(?s)\nROLES = \[(.*?)\n\]"#, options: .regularExpression))
        let names = try NSRegularExpression(pattern: #"^\s*\("([a-z-]+)""#, options: .anchorsMatchLines)
        let text = String(source[block])
        let roles = names.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        XCTAssertTrue(source.contains(#"DISCOVERY_ROLES = tuple(role for role, _keywords, _label in ROLES) + ("tool-use",)"#))
        XCTAssertEqual(WorkbenchAPI.discoveryRoleOrder, roles + ["tool-use"])
    }

    func testPlaceholderRowsImplyNoCountOrFit() {
        let row = DiscoverRow.placeholder(0)
        XCTAssertEqual(row.fit.state, .redacted)
        XCTAssertNil(row.fit.fill)
        XCTAssertNotEqual(DiscoverRow.placeholder(0).id, DiscoverRow.placeholder(1).id)
    }

    func testLayoutFlipsAtTheMeasuredViewports() {
        let compact = DiscoverLayout(viewportWidth: 514)
        XCTAssertEqual(compact.headerMode, .roleOwnLine)
        XCTAssertFalse(compact.isWideRow)
        XCTAssertTrue(compact.legendWraps)
        let medium = DiscoverLayout(viewportWidth: 824)
        XCTAssertEqual(medium.headerMode, .oneLine)
        XCTAssertFalse(medium.isWideRow, "a 1050 window keeps repo ids whole in compact rows")
        XCTAssertFalse(medium.legendWraps)
        let wide = DiscoverLayout(viewportWidth: 1220)
        XCTAssertEqual(wide.contentWidth, WorkbenchSize.Discover.contentMaxWidth)
        XCTAssertEqual(DiscoverLayout(viewportWidth: 4000).contentWidth, WorkbenchSize.Discover.contentMaxWidth)
        XCTAssertTrue(wide.isWideRow)
        let zero = DiscoverLayout(viewportWidth: 0)
        XCTAssertEqual(zero.contentWidth, 0)
        XCTAssertEqual(zero.headerMode, .stacked)
        XCTAssertFalse(zero.isWideRow)
        XCTAssertTrue(zero.legendWraps)
    }

    func testLayoutFlipsAtEachThresholdWithAndWithoutAPreviousLayout() {
        let inset = WorkbenchSpacing.pageInset * 2
        func viewport(content: CGFloat) -> CGFloat { content + inset }
        let hysteresis = WorkbenchSize.Discover.hysteresis

        let header = WorkbenchSize.Discover.headerThreshold
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: header)).headerMode, .oneLine)
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: header - 1)).headerMode, .roleOwnLine)
        let off = DiscoverLayout(viewportWidth: viewport(content: header - 1))
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: header + 1), previous: off).headerMode, .roleOwnLine)
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: header + hysteresis), previous: off).headerMode, .oneLine)

        let stack = WorkbenchSize.Discover.headerStackThreshold
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: stack - 1)).headerMode, .stacked)
        let stacked = DiscoverLayout(viewportWidth: viewport(content: stack - 1))
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: stack + 1), previous: stacked).headerMode, .stacked)
        XCTAssertEqual(DiscoverLayout(viewportWidth: viewport(content: stack + hysteresis), previous: stacked).headerMode, .roleOwnLine)

        let row = WorkbenchSize.Discover.rowThreshold
        XCTAssertTrue(DiscoverLayout(viewportWidth: viewport(content: row)).isWideRow)
        XCTAssertFalse(DiscoverLayout(viewportWidth: viewport(content: row - 1)).isWideRow)
        let narrow = DiscoverLayout(viewportWidth: viewport(content: row - 1))
        XCTAssertFalse(DiscoverLayout(viewportWidth: viewport(content: row + 1), previous: narrow).isWideRow)
        XCTAssertTrue(DiscoverLayout(viewportWidth: viewport(content: row + hysteresis), previous: narrow).isWideRow)

        let legend = WorkbenchSize.Discover.legendThreshold
        XCTAssertFalse(DiscoverLayout(viewportWidth: viewport(content: legend)).legendWraps)
        XCTAssertTrue(DiscoverLayout(viewportWidth: viewport(content: legend - 1)).legendWraps)
        let wraps = DiscoverLayout(viewportWidth: viewport(content: legend - 1))
        XCTAssertTrue(DiscoverLayout(viewportWidth: viewport(content: legend + 1), previous: wraps).legendWraps)
        XCTAssertFalse(DiscoverLayout(viewportWidth: viewport(content: legend + hysteresis), previous: wraps).legendWraps)
    }

    func testTheWideRowThresholdIsTheSumOfItsColumns() {
        let size = WorkbenchSize.Discover.self
        XCTAssertEqual(
            size.rowThreshold,
            size.symbolColumn + size.nameMinimum + size.barWidth + size.figuresWidth + size.actionWidth + size.columnGap * 4
        )
    }
}

// MARK: - Source

final class DiscoverSourceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDiscoverViewCodeHasNoFileProcessOrNetworkCalls() throws {
        for name in ["ScoutView.swift", "DiscoverViews.swift", "DiscoverPresentation.swift"] {
            let text = try source(name)
            for banned in ["FileManager", "Process(", "Process.", "URLSession", "NSTask", "posix_spawn"] {
                XCTAssertFalse(text.contains(banned), "\(name) contains \(banned)")
            }
        }
    }

    func testTheCandidatesAreNotAListAndDiscoverIsTheOnlyProminentButton() throws {
        let scout = try source("ScoutView.swift")
        let views = try source("DiscoverViews.swift")
        XCTAssertFalse(views.contains("List("))
        XCTAssertEqual(scout.components(separatedBy: "List(").count - 1, 1, "only the catalog entries keep a List")
        XCTAssertEqual((scout + views).components(separatedBy: "workbenchPrimary").count - 1, 1)
        XCTAssertEqual(scout.components(separatedBy: "Button(\"Discover\")").count - 1, 1)
    }

    func testThePinnedUITestStringsStayInSource() throws {
        let scout = try source("ScoutView.swift")
        XCTAssertTrue(scout.contains("Text(\"Discovery\")"))
        XCTAssertTrue(scout.contains("Button(\"Discover\")"))
        XCTAssertTrue(scout.contains("Details and catalog entries"))
        XCTAssertTrue(scout.contains("Refresh Metadata"))
        XCTAssertTrue(scout.contains("Catalog metadata"))
        XCTAssertTrue(scout.contains("Metadata only. Local installation truth comes from the Library scan, not this catalog cache."))
        XCTAssertTrue(try source("DiscoverViews.swift").contains("Button(\"Clear\""))
    }
}

// MARK: - Renders

@MainActor
final class DiscoverRenderTests: XCTestCase {
    private typealias F = DiscoverFixtures

    private final class Gate {
        var continuation: CheckedContinuation<IntakeResolution, Error>?
    }

    private func config() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: ["/m"], mlxRoots: [], outputDir: "/out/mlx",
            mlxAgentPath: "/agent", quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: F.reserveGB, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    private func host(intakeAPI: IntakeAPI, library: [String]) -> AppHost {
        let host = AppHost(
            config: config(), discoveredRoots: [], configPath: "/state/config.json", agentHealth: .notConfigured,
            runtimeReport: RuntimeReport(
                convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready."),
                serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready."),
                install: "make install", ok: true
            ), hardwareProfile: F.hardware,
            modelWorkflowAPI: ModelWorkflowAPI(
                convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
                servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] }
            ),
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }),
            intakeAPI: intakeAPI
        )
        host.librarySnapshot = F.snapshot(library)
        return host
    }

    private func monitor() async -> SystemResourceMonitor {
        let reading = F.memory(available: 60_000_000_000)
        let monitor = SystemResourceMonitor(probe: { reading })
        await monitor.refreshMemory()
        return monitor
    }

    private let candidates = [
        F.candidate("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", gb: 17.2, roles: ["coding", "tool-use"], downloads: 182_000, likes: 640),
        F.candidate("mlx-community/Llama-3.2-3B-Instruct-4bit", gb: 1.9, roles: ["general"], downloads: 96_000, likes: 210),
        F.candidate("mlx-community/Qwen3-32B-Thinking-4bit", gb: 46.0, roles: ["reasoning"], license: "other", downloads: 21_400, likes: 88),
        F.candidate("mlx-community/GLM-4.5-Air-6bit", gb: 58.0, fits: true, roles: ["general", "tool-use"], downloads: 7_300, likes: 51),
        F.candidate("mlx-community/Qwen3-235B-A22B-4bit", gb: 132.0, fits: false, roles: ["general"], license: "apache-2.0", downloads: 15_800, likes: 301),
        F.candidate("mlx-community/Fast-Mode-Model-4bit", gb: nil, roles: ["coding"], downloads: 940, likes: 12),
    ]

    private let library = ["/render/.cache/huggingface/hub/models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit/snapshots/abc123"]

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 1500) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: viewport, height: height).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(dark ? "dark" : "light")-\(Int(viewport))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let widths: [CGFloat] = [1220, 824, 514]
        let states: [(name: String, state: DiscoveryState)] = [
            ("populated", .completed(candidates)),
            ("running", .running),
            ("empty", .completed([])),
            ("failed", .failed("Fixture discovery failed: catalog unavailable.")),
            ("idle", .notRun),
        ]
        let resources = await monitor()
        for scenario in states {
            for dark in [true, false] {
                for width in widths {
                    let page = ScoutView(
                        appHost: host(intakeAPI: IntakeAPI.stub(), library: library), resources: resources, initialState: scenario.state
                    )
                    try await attach(page.environment(\.isRouteActive, true), name: scenario.name, viewport: width, dark: dark)
                }
            }
        }
    }

    func testIntakeBusyRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let resources = await monitor()
        let gate = Gate()
        let host = host(intakeAPI: IntakeAPI.stub(resolve: { _ in
            try await withCheckedThrowingContinuation { gate.continuation = $0 }
        }), library: library)
        host.intake.open(with: "mlx-community/Llama-3.2-3B-Instruct-4bit")
        for _ in 0..<400 where !(host.intake.isBusy && gate.continuation != nil) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(host.intake.isBusy)
        defer { gate.continuation?.resume(throwing: IntakeStubError.unused) }
        for dark in [true, false] {
            for width in [CGFloat(1220), 824, 514] {
                let page = ScoutView(appHost: host, resources: resources, initialState: .completed(candidates))
                try await attach(page.environment(\.isRouteActive, true), name: "intake-busy", viewport: width, dark: dark)
            }
        }
    }
}
