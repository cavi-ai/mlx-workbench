import AppKit
import XCTest

@testable import mlx_workbench

// MARK: - Fakes

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func hit(_ name: String) {
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name, default: 0]
    }
}

@MainActor
private final class CountingVerifier: ConversionCompletionVerifying {
    private(set) var calls: [UUID] = []

    func beginVerification(recordID: UUID, modelPath: String, signature: String?) {
        calls.append(recordID)
    }
}

// MARK: - Fixtures

private enum Fixture {
    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    static func workflow(
        id: UUID = UUID(),
        state: ConversionWorkflowState,
        sourcePath: String = "/models/atlas.gguf",
        outputPath: String = "/models/atlas-MLX-4bit",
        previewHash: String? = nil,
        receipt: String? = nil,
        completedModelPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil,
        agentState: String? = nil,
        confirmed: Bool? = nil,
        created: Date = stamp,
        updated: Date = stamp
    ) -> ConversionWorkflow {
        var record = ConversionWorkflow(
            id: id, sourcePath: sourcePath, sourceModelKey: "atlas", sourceSignature: "signature",
            outputPath: outputPath, previewHash: previewHash, jobReceipt: receipt, completedModelPath: completedModelPath,
            state: state, serveState: .idle, message: message, errorMessage: errorMessage,
            createdAt: created, updatedAt: updated, lastKnownAgentState: agentState
        )
        record.reclaimSourceAfterVerification = confirmed
        return record
    }

    static func card(_ workflow: ConversionWorkflow, snapshot: LibrarySnapshot? = nil, log: String? = nil) -> ActivityWorkflowCardPresentation {
        let job = log.map { Job(receipt: workflow.jobReceipt, repo: nil, source: nil, qBits: 4, out: nil, pid: nil, logPath: $0, startedAt: nil, completedAt: nil, state: "done") }
        return ActivityWorkflowCardPresentation(workflow: workflow, job: job, snapshot: snapshot)
    }

    static func row(_ workflow: ConversionWorkflow, snapshot: LibrarySnapshot? = nil, verification: VerificationStatus? = nil, now: Date = stamp) -> ActivityRowPresentation {
        ActivityRowPresentation(card: card(workflow, snapshot: snapshot), snapshot: snapshot, verification: verification, now: now)
    }

    static func model(path: String, type: ModelTaskType?) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1_000, modifiedAt: nil, shard: nil,
            modelKey: path, architecture: nil, quantization: "4-bit", parameters: nil,
            structure: nil, signature: "signature", companion: nil, readable: true, status: "ready",
            outputs: [], tensorCount: nil, error: nil,
            task: type.map { ModelTask(type: $0, useCases: [], source: "test", confidence: "high") }
        )
        return LibraryModel(item: item, readiness: .ready)
    }

    static func snapshot(_ models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: HardwareProfile(chip: "M4"), generatedAt: stamp)
    }

    static func report(_ path: String) -> VerificationReport {
        VerificationReport(
            id: UUID(), modelPath: path, modelSignature: nil, workflowRecordID: nil,
            suiteVersion: CanarySuite.version, canaries: [], tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
            metricsEstimated: false, startedAt: stamp, finishedAt: stamp, outcome: .passed
        )
    }

    static func server(
        repo: String? = nil, path: String? = nil, port: Int? = 59699, state: String = "stopped",
        startedAt: String? = "2026-10-02T22:09:57.872974+00:00", log: String? = "/tmp/serve.log"
    ) -> ServerInfo {
        ServerInfo(repo: repo, path: path, runtime: "mlx_lm", port: port, pid: 4242, state: state, logPath: log, startedAt: startedAt, receipt: "serve-receipt")
    }
}

// MARK: - AC1: Activity never starts verification except through the done transition

@MainActor
final class ActivityRemodelTests: XCTestCase {
    private nonisolated static func scanResult() -> ScanResult {
        let source = ModelItem(
            path: "/models/atlas.gguf", name: "atlas", bytes: 1, modifiedAt: nil, shard: nil,
            modelKey: "atlas", architecture: nil, quantization: nil, parameters: nil,
            structure: nil, signature: "signature", companion: nil, readable: true,
            status: "pending", outputs: [], tensorCount: nil, error: nil
        )
        let output = MLXOutput(path: "/models/atlas-MLX-4bit", name: "atlas", modelKey: "atlas", quantization: nil, provenance: "signature")
        return ScanResult(
            roots: nil, models: [source], outputs: [output], pending: [source.path], duplicates: [],
            totals: ScanTotals(gguf: 1, pending: 1, converted: 1, unreadable: 0, bytes: 1, reclaimableBytes: 0)
        )
    }

    private func makeHost(counter: Counter, jobs: [Job]) -> AppHost {
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in counter.hit("convertPreview"); return [:] },
            convertStart: { _, _, _, _ in counter.hit("convertStart"); return [:] },
            convertStatus: { counter.hit("convertStatus"); return jobs },
            servePreview: { _, _, _ in counter.hit("servePreview"); return [:] },
            serveStart: { _, _, _, _ in counter.hit("serveStart"); return [:] },
            serveStatus: { counter.hit("serveStatus"); return [] },
            serveStop: { _ in counter.hit("serveStop"); return [:] }
        )
        let persistence = ModelWorkflowPersistence(load: { [] }, upsert: { _ in counter.hit("upsert") })
        return AppHost(
            config: Config.defaults(),
            scanOperation: { _, _, _, _ in counter.hit("scan"); return Self.scanResult() },
            modelWorkflowAPI: api,
            modelWorkflowPersistence: persistence
        )
    }

    private func job(_ receipt: String, _ state: String) -> Job {
        Job(receipt: receipt, repo: nil, source: nil, qBits: 4, out: "/models/atlas-MLX-4bit", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: state)
    }

    func testActivityRefreshOverSettledRecordsStartsNothingAndWritesNothing() async {
        let counter = Counter()
        let jobs = [job("f1", "failed"), job("c1", "done"), job("v1", "done"), job("x1", "done")]
        let host = makeHost(counter: counter, jobs: jobs)
        let verifier = CountingVerifier()
        host.modelWorkflow.completionVerifier = verifier
        var terminal = 0
        host.modelWorkflow.onTerminalState = { _ in terminal += 1 }
        host.modelWorkflow.restore(Fixture.workflow(
            state: .failed, receipt: "f1", message: "Conversion failed.", errorMessage: "Conversion failed.", agentState: "failed"))
        host.modelWorkflow.restore(Fixture.workflow(state: .completed, receipt: "c1", completedModelPath: "/models/atlas-MLX-4bit", agentState: "done"))
        host.modelWorkflow.restore(Fixture.workflow(state: .verified, receipt: "v1", completedModelPath: "/models/atlas-MLX-4bit", agentState: "done"))
        host.modelWorkflow.restore(Fixture.workflow(state: .verificationFailed, receipt: "x1", completedModelPath: "/models/atlas-MLX-4bit", agentState: "done"))
        let before = host.modelWorkflow.history
        let writesBefore = counter.count("upsert")

        await host.refreshWorkflowStatus(jobs: jobs)

        XCTAssertEqual(verifier.calls.count, 0)
        XCTAssertEqual(counter.count("scan"), 0)
        XCTAssertEqual(counter.count("upsert"), writesBefore)
        XCTAssertEqual(host.modelWorkflow.history, before)
        XCTAssertEqual(terminal, 0)
    }

    func testDoneJobForRunningRecordBeginsVerificationExactlyOnce() async {
        let counter = Counter()
        let jobs = [job("r1", "done")]
        let host = makeHost(counter: counter, jobs: jobs)
        let verifier = CountingVerifier()
        host.modelWorkflow.completionVerifier = verifier
        let record = Fixture.workflow(state: .running, receipt: "r1", agentState: "running")
        host.modelWorkflow.restore(record)

        await host.refreshWorkflowStatus(jobs: jobs)
        await host.refreshWorkflowStatus(jobs: jobs)

        XCTAssertEqual(verifier.calls, [record.id])
        XCTAssertEqual(host.modelWorkflow.history.first { $0.id == record.id }?.state, .verifying)
        XCTAssertEqual(counter.count("scan"), 1)
    }

    func testActivityViewSourceReachesStatusOnlyThroughRefreshAndNeverOnActivation() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/JobsView.swift")
        let file = try String(contentsOf: source, encoding: .utf8)
        let text = try XCTUnwrap(file.components(separatedBy: "struct LogSheet").first)
        let calls = text.components(separatedBy: "refreshWorkflowStatus").count - 1
        XCTAssertEqual(calls, 2, "both branches of refresh() and nothing else")
        let refreshBody = try XCTUnwrap(text.range(of: "private func refresh() async {"))
        let lastCall = try XCTUnwrap(text.range(of: "refreshWorkflowStatus", options: .backwards))
        XCTAssertTrue(refreshBody.lowerBound < lastCall.lowerBound)
        XCTAssertFalse(text.contains("onChange(of: isRouteActive"))
        XCTAssertFalse(text.contains(".onAppear"))
        XCTAssertFalse(text.contains("lastKnownJobs"))
    }

    func testActivityViewAnchorsTopWithoutScrollingCode() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/JobsView.swift")
        let file = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(file.contains("scrollTo("))
        XCTAssertFalse(file.contains("ScrollViewReader"))
        XCTAssertTrue(file.contains(".defaultScrollAnchor(.top)"))
    }

    // MARK: - AC2: poll keyed to in-flight ids

    func testPollIsKeyedToTheInFlightRecordIDs() {
        let counter = Counter()
        let host = makeHost(counter: counter, jobs: [])
        let coordinator = host.modelWorkflow
        XCTAssertEqual(ActivityPoll.inFlightIDs(workflow: coordinator.workflow, history: coordinator.history), [])

        let done = Fixture.workflow(state: .completed, receipt: "c1")
        coordinator.restore(done)
        XCTAssertEqual(ActivityPoll.inFlightIDs(workflow: coordinator.workflow, history: coordinator.history), [])

        let running = Fixture.workflow(state: .running, receipt: "r1")
        coordinator.restore(running)
        let verifying = Fixture.workflow(state: .verifying, receipt: "v1")
        coordinator.restore(verifying)
        XCTAssertEqual(
            ActivityPoll.inFlightIDs(workflow: coordinator.workflow, history: coordinator.history),
            [running.id, verifying.id]
        )

        coordinator.dismiss(recordID: running.id)
        XCTAssertEqual(ActivityPoll.inFlightIDs(workflow: coordinator.workflow, history: coordinator.history), [verifying.id])
    }

    func testCurrentWorkflowNotYetInHistoryKeysThePoll() {
        let current = Fixture.workflow(state: .queued, receipt: "q1")
        XCTAssertEqual(ActivityPoll.inFlightIDs(workflow: current, history: []), [current.id])
        XCTAssertEqual(ActivityPoll.inFlightIDs(workflow: Fixture.workflow(state: .failed), history: []), [])
    }

    // MARK: - AC3: stage fixtures through the stage owner

    private func stages(_ workflow: ConversionWorkflow, type: ModelTaskType? = nil, verification: VerificationStatus? = nil) -> [ModelFlightStageState] {
        let snapshot = type.map { Fixture.snapshot([Fixture.model(path: "/models/atlas-MLX-4bit", type: $0)]) }
        return Fixture.row(workflow, snapshot: snapshot, verification: verification).nodes.map(\.state)
    }

    private func completedRecord(message: String? = nil) -> ConversionWorkflow {
        Fixture.workflow(state: .completed, receipt: "c1", completedModelPath: "/models/atlas-MLX-4bit", message: message)
    }

    func testCompletedNoCanaryTypeSkipsVerifyAndIsReady() {
        typealias S = ModelFlightStageState
        let record = completedRecord()
        XCTAssertEqual(stages(record, type: .embedding), [S.complete, .complete, .complete, .pending, .complete])
        let row = Fixture.row(record, snapshot: Fixture.snapshot([Fixture.model(path: "/models/atlas-MLX-4bit", type: .embedding)]))
        XCTAssertEqual(row.nodes.map(\.isNotApplicable), [false, false, false, true, false])
        XCTAssertEqual(row.trackLabel, "Ready, verification not applicable")
        XCTAssertEqual(FlightTrackView.accessibilityLabel(for: row.nodes[3]), "Verify: Not applicable")
        XCTAssertEqual(FlightTrackView.accessibilityLabel(for: row.nodes[4]), "Ready: Complete")
    }

    func testCompletedNoCanaryMessageSkipsVerifyWhenTheTypeIsUnknown() {
        typealias S = ModelFlightStageState
        let message = "Conversion completed; Embedding models have no canary, so the output was confirmed by a fresh scan only."
        XCTAssertEqual(stages(completedRecord(message: message)), [S.complete, .complete, .complete, .pending, .complete])
    }

    func testCoordinatorsNoCanaryMessageIsWhatTheStageOwnerRecognises() {
        let counter = Counter()
        let host = makeHost(counter: counter, jobs: [])
        let coordinator = host.modelWorkflow
        coordinator.restore(Fixture.workflow(state: .running, receipt: "r1"))
        let snapshot = Fixture.snapshot([Fixture.model(path: "/models/atlas-MLX-4bit", type: .embedding)])

        coordinator.resolveCompletionAfterFreshScan(snapshot: snapshot)

        XCTAssertEqual(coordinator.workflow.state, .completed)
        XCTAssertTrue(PrepareWorkflowPresentation(workflow: coordinator.workflow).verificationNotApplicable)
    }

    func testCompletedWithCanaryTypeOrUnverifiableStaysPending() {
        typealias S = ModelFlightStageState
        XCTAssertEqual(stages(completedRecord(), type: .textLLM), [S.complete, .complete, .complete, .pending, .pending])
        let unverifiable = completedRecord(message: "Verification could not run (runtime missing); the output is complete but unverified.")
        XCTAssertEqual(stages(unverifiable), [S.complete, .complete, .complete, .pending, .pending])
        XCTAssertEqual(Fixture.row(unverifiable).trackLabel, "Reached Convert")
        XCTAssertFalse(Fixture.row(unverifiable).nodes.contains(where: \.isNotApplicable))
    }

    func testVerifiedAndEvidenceCompleteEveryStage() {
        typealias S = ModelFlightStageState
        let all = Array(repeating: S.complete, count: 5)
        XCTAssertEqual(stages(Fixture.workflow(state: .verified, receipt: "v1")), all)
        let passed = VerificationStatus.verified(Fixture.report("/models/atlas-MLX-4bit"))
        XCTAssertEqual(stages(completedRecord(), type: .textLLM, verification: passed), all)
        XCTAssertEqual(Fixture.row(Fixture.workflow(state: .verified, receipt: "v1")).trackLabel, "Ready")
    }

    func testFailedStopsAtTheStageItsPersistedFieldsProve() {
        typealias S = ModelFlightStageState
        XCTAssertEqual(stages(Fixture.workflow(state: .failed, previewHash: "h", receipt: "f1")), [S.complete, .complete, .failed, .pending, .pending])
        XCTAssertEqual(stages(Fixture.workflow(state: .failed, previewHash: "h")), [S.complete, .failed, .pending, .pending, .pending])
        XCTAssertEqual(stages(Fixture.workflow(state: .failed)), [S.failed, .pending, .pending, .pending, .pending])
        XCTAssertEqual(Fixture.row(Fixture.workflow(state: .failed)).trackLabel, "Stopped at Source")
    }

    func testFailedWithConfirmEvidenceButNoReceiptOrHashFailsAtConvert() {
        typealias S = ModelFlightStageState
        for confirmed in [true, false] {
            let record = Fixture.workflow(state: .failed, confirmed: confirmed)
            XCTAssertEqual(stages(record), [S.complete, .complete, .failed, .pending, .pending], "confirmed=\(confirmed)")
            XCTAssertEqual(Fixture.row(record).trackLabel, "Stopped at Convert")
        }
    }

    func testVerificationFailedAndInFlightStates() {
        typealias S = ModelFlightStageState
        XCTAssertEqual(stages(Fixture.workflow(state: .verificationFailed, receipt: "x1")), [S.complete, .complete, .complete, .failed, .pending])
        XCTAssertEqual(Fixture.row(Fixture.workflow(state: .verificationFailed, receipt: "x1")).trackLabel, "Stopped at Verify")
        for state in [ConversionWorkflowState.queued, .running] {
            XCTAssertEqual(stages(Fixture.workflow(state: state, receipt: "r1")), [S.complete, .complete, .active, .pending, .pending])
            XCTAssertEqual(Fixture.row(Fixture.workflow(state: state, receipt: "r1")).trackLabel, "In progress at Convert")
        }
        let verifying = Fixture.row(Fixture.workflow(state: .verifying, receipt: "v1"))
        XCTAssertEqual(verifying.nodes.map(\.state), [S.complete, .complete, .complete, .active, .pending])
        XCTAssertEqual(verifying.nodes.filter(\.pulses).count, 1)
    }

    func testPrepareAndActivityDrawTheSameNodesFromOnePresentation() {
        let record = Fixture.workflow(state: .failed, confirmed: true)
        let prepare = PrepareWorkflowPresentation(workflow: record).stageNodes(hasVerificationEvidence: false)
        XCTAssertEqual(Fixture.row(record).nodes, prepare)
    }

    // MARK: - AC5: one priority rule, one relative-time owner

    func testPrimaryActionRuleIsRunThenLibraryThenTheStatesOwnAction() {
        let record = Fixture.workflow(state: .completed, receipt: "c1", completedModelPath: "/models/atlas-MLX-4bit")
        let library = ActivityWorkflowAction.openInLibrary("/models/atlas-MLX-4bit")
        let run = ActivityWorkflowAction.runModel(record)
        let retry = ActivityWorkflowAction.retryPreview(record)
        let keep = ActivityWorkflowAction.keepAnyway(record)
        XCTAssertEqual(ActivityWorkflowAction.primary(among: [library, run]), run)
        XCTAssertEqual(ActivityWorkflowAction.primary(among: [library]), library)
        XCTAssertEqual(ActivityWorkflowAction.primary(among: [retry]), retry)
        XCTAssertEqual(ActivityWorkflowAction.primary(among: [keep]), keep)
        XCTAssertNil(ActivityWorkflowAction.primary(among: []))
    }

    func testRowAndPrepareChooseTheSamePrimary() throws {
        let path = "/models/atlas-MLX-4bit"
        let record = Fixture.workflow(state: .verified, receipt: "v1", completedModelPath: path)
        let snapshot = Fixture.snapshot([Fixture.model(path: path, type: .textLLM)])
        let row = Fixture.row(record, snapshot: snapshot)
        XCTAssertEqual(row.primary, .runModel(record))
        XCTAssertEqual(row.overflow, [.openInLibrary(path)])

        let plan = PrepareActionPlan.make(
            presentation: PrepareWorkflowPresentation(workflow: record),
            onward: row.card.actions, existing: nil, isSubmitting: false
        )
        XCTAssertEqual(plan.items.first?.action, .onward(try XCTUnwrap(row.primary)))
        XCTAssertEqual(plan.items.first?.isProminent, true)
        XCTAssertEqual(plan.items.last?.action, .onward(.openInLibrary(path)))
    }

    func testRowsOfTheOtherStatesCarryTheirOwnPrimaryAndNeverARunWithoutALibraryModel() {
        let kept = Fixture.row(Fixture.workflow(state: .verificationFailed, receipt: "x1"))
        XCTAssertEqual(kept.primary?.title, "Keep anyway (unverified)")
        XCTAssertEqual(kept.overflow, [])
        let failed = Fixture.row(Fixture.workflow(state: .failed))
        XCTAssertNil(failed.primary)
    }

    func testOneRelativeTimeOwnerFeedsLibraryAndActivity() {
        let now = Fixture.stamp
        let date = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(LibraryTablePresentation.modifiedText(date, now: now), WorkbenchRelativeTime.text(for: date, style: .abbreviated, now: now))
        let row = Fixture.row(Fixture.workflow(state: .failed, created: date), now: now)
        XCTAssertEqual(row.relativeTime, WorkbenchRelativeTime.text(for: date, style: .abbreviated, now: now))
    }

    // MARK: - AC6: dates

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testRecordCreatedOctoberSecondIsFiledUnderItsCreatedDayEvenWhenUpdatedToday() {
        let now = date(8, 20, 30)
        let normalised = Fixture.workflow(state: .failed, created: date(2, 22, 9), updated: date(8, 20, 25))
        let today = Fixture.workflow(state: .failed, created: date(8, 20, 18), updated: date(8, 20, 18))
        let yesterday = Fixture.workflow(state: .completed, receipt: "c1", created: date(7, 9), updated: date(7, 9))
        let cards = [normalised, today, yesterday].map { Fixture.card($0) }

        let page = ActivityTimeline.page(cards: cards, snapshot: nil, verification: [:], now: now, calendar: calendar)

        XCTAssertEqual(Array(page.groups.map(\.title).prefix(2)), ["Today", "Yesterday"])
        XCTAssertTrue(page.groups[2].title.contains("Oct 2"), page.groups[2].title)
        XCTAssertEqual(page.groups[2].rows.map(\.id), [normalised.id])
        let row = page.groups[2].rows[0]
        XCTAssertFalse(row.relativeTime.contains("min"), row.relativeTime)
        XCTAssertEqual(row.relativeTime, WorkbenchRelativeTime.text(for: date(2, 22, 9), style: .abbreviated, now: now))
        XCTAssertFalse(row.createdText.isEmpty)
        XCTAssertNotEqual(row.createdText, row.updatedText)
    }

    func testInFlightRecordsLeadAndAppearOnlyOnce() {
        let now = date(8, 20, 30)
        let running = Fixture.workflow(state: .running, receipt: "r1", created: date(8, 20, 20))
        let failed = Fixture.workflow(state: .failed, created: date(8, 19, 0))
        let page = ActivityTimeline.page(cards: [failed, running].map { Fixture.card($0) }, snapshot: nil, verification: [:], now: now, calendar: calendar)
        XCTAssertEqual(page.inFlight.map(\.id), [running.id])
        XCTAssertEqual(page.groups.flatMap(\.rows).map(\.id), [failed.id])
    }

    // MARK: - AC7: one state, no generic second line

    func testGenericConversionMessagesAreSuppressedAndKeptInDetails() {
        let failed = Fixture.workflow(state: .failed, message: "Conversion failed.", errorMessage: "Conversion failed.", agentState: "failed")
        let row = Fixture.row(failed)
        XCTAssertNil(row.line)
        XCTAssertEqual(row.recordedMessages, ["Conversion failed."])
        XCTAssertNil(Fixture.row(Fixture.workflow(state: .queued, receipt: "q1", message: "Conversion queued.")).line)
        XCTAssertNil(Fixture.row(Fixture.workflow(state: .running, receipt: "r1", message: "Conversion running.")).line)
    }

    func testSpecificMessagesShowAsOneLine() {
        let cancelled = Fixture.workflow(state: .failed, message: "Conversion cancelled.", errorMessage: "Conversion cancelled.")
        XCTAssertEqual(Fixture.row(cancelled).line, .failure("Conversion cancelled."))
        let detailed = Fixture.workflow(state: .failed, errorMessage: "Destination already exists.\nChoose another folder.")
        XCTAssertEqual(Fixture.row(detailed).line, .failure("Destination already exists.\nChoose another folder."))
        let noCanary = completedRecord(message: "Conversion completed; Embedding models have no canary, so the output was confirmed by a fresh scan only.")
        XCTAssertEqual(Fixture.row(noCanary).line, .note("Embedding models have no canary, so the output was confirmed by a fresh scan only."))
        let unverifiable = completedRecord(message: "Verification could not run (runtime missing); the output is complete but unverified.")
        XCTAssertEqual(Fixture.row(unverifiable).line, .note("Verification could not run (runtime missing); the output is complete but unverified."))
        let verification = Fixture.workflow(state: .verificationFailed, receipt: "x1", message: "Verification failed. echo canary did not pass.")
        XCTAssertEqual(Fixture.row(verification).line, .failure("echo canary did not pass."))
    }

    func testVerifiedRowDoesNotRestateThePassAndKeepsMeasurements() {
        let passed = Fixture.workflow(state: .verified, receipt: "v1", message: "\(VerificationOutcome.passedLead) \(VerificationOutcome.passedSummary)")
        XCTAssertNil(Fixture.row(passed).line)
        let measured = Fixture.workflow(
            state: .verified, receipt: "v1",
            message: "\(VerificationOutcome.passedLead) \(VerificationOutcome.passedSummary) · 42.0 tok/s · TTFT 0.20s"
        )
        XCTAssertEqual(Fixture.row(measured).line, .note("42.0 tok/s · TTFT 0.20s"))
        XCTAssertNil(Fixture.row(Fixture.workflow(state: .completed, message: "Conversion completed.")).line)
    }

    func testQueueFailureFromTheStoreStopsAtConvert() {
        let queued = Fixture.workflow(
            state: .failed, message: "Conversion could not be queued: The agent refused the request.",
            errorMessage: "Conversion could not be queued: The agent refused the request.", confirmed: nil
        )
        XCTAssertEqual(Fixture.row(queued).trackLabel, "Stopped at Convert")
        let noReceipt = Fixture.workflow(
            state: .failed, message: PrepareWorkflowPresentation.missingReceiptMessage,
            errorMessage: PrepareWorkflowPresentation.missingReceiptMessage
        )
        XCTAssertEqual(Fixture.row(noReceipt).trackLabel, "Stopped at Convert")
        XCTAssertEqual(Fixture.row(Fixture.workflow(state: .failed, errorMessage: "Source unreadable.")).trackLabel, "Stopped at Source")
    }

    func testFailedRowsCaptionWhereTheyStoppedAndOfferTheLogInlineOnlyWithoutAMessage() {
        let silent = Fixture.workflow(state: .failed, receipt: "f1", message: "Conversion failed.", errorMessage: "Conversion failed.")
        let silentRow = ActivityRowPresentation(card: Fixture.card(silent, log: "/logs/f1.log"), snapshot: nil, verification: nil, now: Fixture.stamp)
        XCTAssertTrue(silentRow.showsTrackCaption)
        XCTAssertTrue(silentRow.showsInlineLog)
        let spoken = Fixture.workflow(state: .failed, receipt: "f2", errorMessage: "Disk full.")
        let spokenRow = ActivityRowPresentation(card: Fixture.card(spoken, log: "/logs/f2.log"), snapshot: nil, verification: nil, now: Fixture.stamp)
        XCTAssertTrue(spokenRow.showsTrackCaption)
        XCTAssertFalse(spokenRow.showsInlineLog)
        let verifiedRow = ActivityRowPresentation(card: Fixture.card(Fixture.workflow(state: .verified, receipt: "v"), log: "/logs/v.log"), snapshot: nil, verification: nil, now: Fixture.stamp)
        XCTAssertFalse(verifiedRow.showsTrackCaption)
        XCTAssertFalse(verifiedRow.showsInlineLog)
        let logless = Fixture.row(Fixture.workflow(state: .failed, message: "Conversion failed."))
        XCTAssertTrue(logless.showsTrackCaption)
        XCTAssertFalse(logless.showsInlineLog)
    }

    func testToolbarWorkflowBadgeIsSuppressedOnActivity() {
        XCTAssertFalse(ContentView.showsWorkflowBadge(route: .activity, state: .failed))
        XCTAssertFalse(ContentView.showsWorkflowBadge(route: .activity, state: .verified))
        XCTAssertFalse(ContentView.showsWorkflowBadge(route: .prepare, state: .running))
        XCTAssertTrue(ContentView.showsWorkflowBadge(route: .library, state: .failed))
        XCTAssertTrue(ContentView.showsWorkflowBadge(route: .run, state: .running))
        XCTAssertFalse(ContentView.showsWorkflowBadge(route: .library, state: .idle))
    }

    // MARK: - Layout

    func testRowWidthIsDerivedFromTheOfferedViewport() {
        XCTAssertEqual(ActivityLayout(viewportWidth: 560).rowWidth, 480)
        XCTAssertEqual(ActivityLayout(viewportWidth: 840).rowWidth, 760)
        XCTAssertEqual(ActivityLayout(viewportWidth: 1220).rowWidth, 1068)
        XCTAssertEqual(ActivityLayout(viewportWidth: 2000).rowWidth, 1068)
    }

    func testRowFlipsAtTheThresholdWithHysteresis() {
        let threshold = WorkbenchSize.Activity.rowThreshold
        let hysteresis = WorkbenchSize.Library.tierHysteresis
        XCTAssertTrue(ActivityLayout.isCompact(rowWidth: threshold - 1, wasCompact: false))
        XCTAssertFalse(ActivityLayout.isCompact(rowWidth: threshold, wasCompact: false))
        XCTAssertTrue(ActivityLayout.isCompact(rowWidth: threshold + hysteresis - 1, wasCompact: true))
        XCTAssertFalse(ActivityLayout.isCompact(rowWidth: threshold + hysteresis, wasCompact: true))
    }

    func testActionColumnHoldsTheWidestActionAndTheThresholdFitsEveryWideColumn() {
        let title = ActivityWorkflowAction.keepAnyway(Fixture.workflow(state: .verificationFailed)).title
        let titleWidth = NSAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))]
        ).size().width
        let activity = WorkbenchSize.Activity.self
        XCTAssertGreaterThanOrEqual(activity.actionColumn, titleWidth + WorkbenchSpacing.xs + activity.overflow)
        let columns = activity.stateWord + activity.trackWidth + activity.nameMinimum + activity.timeColumn + activity.actionColumn
        XCTAssertEqual(activity.rowThreshold, columns + WorkbenchSpacing.sm * 4)
    }

    // MARK: - Servers

    func testServerServedFromAPathReadsItsFolderNameAndAPlainPort() {
        let row = ActivityServerRow(server: Fixture.server(path: "/models/Qwen3-4B-MLX-4bit"), index: 0, models: [], now: Fixture.stamp)
        XCTAssertEqual(row.name, "Qwen3-4B-MLX-4bit")
        XCTAssertNotEqual(row.name, "Unknown model")
        XCTAssertEqual(row.endpoint, "127.0.0.1:59699")
        XCTAssertFalse(row.endpoint.contains(","))
        XCTAssertEqual(row.stateWord, "Stopped")
        XCTAssertFalse(row.isRunning)
    }

    func testServerNameComesFromTheLibraryModelWhenListed() {
        let model = Fixture.model(path: "/models/atlas-MLX-4bit", type: .textLLM)
        let row = ActivityServerRow(server: Fixture.server(path: "/models/atlas-MLX-4bit", state: "running"), index: 0, models: [model], now: Fixture.stamp)
        XCTAssertEqual(row.name, model.displayName)
        XCTAssertTrue(row.isRunning)
        XCTAssertEqual(row.stateWord, "Running")
    }

    func testServerStartTimeParsesMicrosecondsAndFallsBackToTheRawValue() {
        let now = ISO8601DateFormatter().date(from: "2026-10-05T22:09:57Z")!
        let parsed = ActivityServerRow(server: Fixture.server(path: "/models/m"), index: 0, models: [], now: now)
        XCTAssertEqual(parsed.startedText, WorkbenchRelativeTime.text(for: ISO8601DateFormatter().date(from: "2026-10-02T22:09:57Z")!, style: .abbreviated, now: now))
        XCTAssertNotNil(parsed.startedAbsolute)
        XCTAssertFalse(parsed.startedText?.contains("2026") ?? true)

        let raw = ActivityServerRow(server: Fixture.server(path: "/models/m", startedAt: "not-a-timestamp"), index: 0, models: [], now: now)
        XCTAssertEqual(raw.startedText, "not-a-timestamp")
        XCTAssertNil(raw.startedAbsolute)

        let none = ActivityServerRow(server: Fixture.server(path: "/models/m", startedAt: nil), index: 0, models: [], now: now)
        XCTAssertNil(none.startedText)
    }

    func testRunningServersSplitFromEarlierOnesAndKeepEveryDatum() {
        let servers = [
            Fixture.server(repo: "org/old", port: 8001, state: "stopped"),
            Fixture.server(repo: "org/live", port: 8002, state: "running"),
        ]
        let split = ActivityServerRow.split(servers, models: [], now: Fixture.stamp)
        XCTAssertEqual(split.running.map(\.name), ["live"])
        XCTAssertEqual(split.earlier.map(\.name), ["old"])
        XCTAssertEqual(split.running.map(\.identity), ["org/live"])
        XCTAssertEqual(split.running[0].pid, "4242")
        XCTAssertEqual(split.running[0].receipt, "serve-receipt")
        XCTAssertEqual(split.running[0].logPath, "/tmp/serve.log")
        XCTAssertNotEqual(split.running[0].id, split.earlier[0].id)
    }
}
