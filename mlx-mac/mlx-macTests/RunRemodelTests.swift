import XCTest

@testable import mlx_workbench

// MARK: - Fakes

private final class CallCounter: @unchecked Sendable {
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
    private(set) var begun = 0

    func beginVerification(recordID: UUID, modelPath: String, signature: String?) {
        begun += 1
    }
}

// MARK: - Factories

private enum Fixture {
    static let gb: Int64 = 1_000_000_000

    static func workflow(
        state: ConversionWorkflowState = .idle,
        serveState: ServeWorkflowState = .idle,
        receipt: String? = nil,
        completedModelPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        let timestamp = Date(timeIntervalSince1970: 1_756_120_000)
        return ConversionWorkflow(
            id: UUID(), sourcePath: "/models/atlas.gguf", sourceModelKey: "atlas", sourceSignature: "signature",
            outputPath: "/models/atlas-mlx", previewHash: nil, jobReceipt: receipt, completedModelPath: completedModelPath,
            state: state, serveState: serveState, message: message, errorMessage: errorMessage,
            createdAt: timestamp, updatedAt: timestamp, lastKnownAgentState: state.rawValue
        )
    }

    static func model(path: String, bytes: Int64 = 4 * gb, parameters: String? = "7B", type: ModelTaskType? = nil, status: String = "ready") -> LibraryModel {
        let task = type.map { ModelTask(type: $0, useCases: [], source: "test", confidence: "high") }
        return LibraryModel(
            item: ModelItem(
                path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes, modifiedAt: 1_756_120_000, shard: nil,
                modelKey: path, architecture: "llama", quantization: "4-bit", parameters: parameters,
                structure: nil, signature: "signature", companion: nil, readable: true, status: status,
                outputs: [], tensorCount: 32, error: nil, task: task
            ),
            normalizedFamilyKey: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    static func server(_ repo: String, port: Int, jit: Bool? = nil, modelState: String? = nil) -> ServerInfo {
        ServerInfo(repo: repo, runtime: "mlx_lm", port: port, pid: port, state: "running", logPath: nil, startedAt: nil,
                   receipt: "receipt-\(port)", jit: jit, modelState: modelState)
    }

    static func presentation(
        _ workflow: ConversionWorkflow, model: LibraryModel?, servers: [ServerInfo] = [],
        runtime: Bool = true, inFlight: Bool = false
    ) -> RunPresentation {
        RunPresentation(workflow: workflow, model: model, servers: servers, runtimeAvailable: runtime, runtimeMessage: "missing", serveInFlight: inFlight)
    }

    static let hardware = HardwareProfile(chip: "M4", model: "Mac16,1", memoryBytes: 32 * gb, macOSVersion: "15.0")

    static func runway(
        memory: MemorySnapshot?, residents: [RunRunway.Resident] = [], next: LibraryModel? = nil,
        contextTokens: Int = 8192, reserveGB: Double = 4
    ) -> RunRunway {
        RunRunway(
            memory: memory, hasProbed: true, reserveGB: reserveGB, contextTokens: contextTokens, hardware: hardware, residents: residents,
            next: next.map { ModelBudgetPresentation.Subject(bytes: $0.item.bytes, parameters: $0.item.parameters, task: $0.item.task?.type) },
            nextName: next?.displayName
        )
    }

    static func resident(_ name: String, model: LibraryModel, contextTokens: Int = 8192) -> RunRunway.Resident {
        RunRunway.Resident(
            id: name, name: name,
            neededBytes: FitAdvisor.neededBytes(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters),
            unknownReason: nil
        )
    }
}

// MARK: - AC1: Run's refresh entry only reads

@MainActor
final class RunRemodelTests: XCTestCase {
    private var gb: Int64 { Fixture.gb }
    private var path: String { "/models/atlas-mlx" }

    private func makeCoordinator(
        counter: CallCounter, servers: [ServerInfo], statusError: Error? = nil
    ) -> ModelWorkflowCoordinator {
        let done = Job(receipt: "r1", repo: nil, source: nil, qBits: 4, out: "/models/atlas-mlx", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "done")
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in counter.hit("convertPreview"); return [:] },
            convertStart: { _, _, _, _ in counter.hit("convertStart"); return [:] },
            convertStatus: { counter.hit("convertStatus"); return [done] },
            servePreview: { _, _, _ in counter.hit("servePreview"); return ["preview_hash": "h"] },
            serveStart: { _, _, _, _ in counter.hit("serveStart"); return ["receipt": "r"] },
            serveStatus: {
                counter.hit("serveStatus")
                if let statusError { throw statusError }
                return servers
            },
            serveStop: { _ in counter.hit("serveStop"); return [:] }
        )
        let persistence = ModelWorkflowPersistence(load: { [] }, upsert: { _ in counter.hit("upsert") })
        return ModelWorkflowCoordinator(api: api, persistence: persistence)
    }

    func testRefreshServersNeverReachesConversionServeOrVerification() async {
        let counter = CallCounter()
        let running = [Fixture.server("/models/other-mlx", port: 49461)]
        let coordinator = makeCoordinator(counter: counter, servers: running)
        let verifier = CountingVerifier()
        coordinator.completionVerifier = verifier
        coordinator.restore(Fixture.workflow(state: .running, receipt: "r1"))
        let before = coordinator.workflow

        await coordinator.refreshServers()

        XCTAssertEqual(coordinator.servers, running)
        XCTAssertEqual(counter.count("serveStatus"), 1)
        for name in ["servePreview", "serveStart", "serveStop", "convertStatus", "convertStart", "convertPreview", "upsert"] {
            XCTAssertEqual(counter.count(name), 0, name)
        }
        XCTAssertEqual(verifier.begun, 0)
        XCTAssertEqual(coordinator.workflow, before)
    }

    func testOperationalRefreshReadsConversionJobsWhichRunMustNotDo() async {
        let counter = CallCounter()
        let coordinator = makeCoordinator(counter: counter, servers: [])
        coordinator.restore(Fixture.workflow(state: .running, receipt: "r1"))

        await coordinator.refreshOperationalStatus()

        XCTAssertEqual(counter.count("convertStatus"), 1)
        XCTAssertGreaterThan(counter.count("upsert"), 0)
    }

    func testRefreshFailureIsReportedWithoutTouchingTheWorkflow() async {
        struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
        let counter = CallCounter()
        let coordinator = makeCoordinator(counter: counter, servers: [], statusError: Offline())
        coordinator.restore(Fixture.workflow(state: .completed, completedModelPath: "/models/atlas-mlx", message: "keep", errorMessage: nil))
        let before = coordinator.workflow

        await coordinator.refreshServers()

        XCTAssertEqual(coordinator.serversError, "Serving status unavailable: offline")
        XCTAssertEqual(coordinator.workflow, before)
        XCTAssertEqual(counter.count("upsert"), 0)
    }
}

// MARK: - AC2, AC3, message rule

extension RunRemodelTests {

    func testVerifiedChatModelCanPreview() {
        let model = Fixture.model(path: path)
        let verified = Fixture.presentation(Fixture.workflow(state: .verified, completedModelPath: path), model: model)
        XCTAssertTrue(verified.canPreview)
        XCTAssertEqual(verified.stage, .eligible)
        XCTAssertNil(verified.selectionError)
        let completed = Fixture.presentation(Fixture.workflow(state: .completed, completedModelPath: path), model: model)
        XCTAssertTrue(completed.canPreview)
    }

    func testVerifyingWorkflowIsNotEligible() {
        let model = Fixture.model(path: path)
        let presentation = Fixture.presentation(Fixture.workflow(state: .verifying, completedModelPath: path), model: model)
        XCTAssertFalse(presentation.canPreview)
        XCTAssertEqual(presentation.stage, .notEligible)
        XCTAssertNotNil(presentation.selectionError)
    }

    func testImageGenerationModelIsNonServableWithNoServeActionsAndNoNextSegment() {
        let model = Fixture.model(path: path, type: .imageGeneration)
        let presentation = Fixture.presentation(Fixture.workflow(state: .verified, completedModelPath: path), model: model)
        XCTAssertEqual(presentation.stage, .nonServable)
        XCTAssertFalse(presentation.canPreview)
        XCTAssertFalse(presentation.canConfirm)
        XCTAssertNil(presentation.selectionError)
        XCTAssertNil(presentation.runwayModel)
    }

    func testSpeculativeDraftIsNonServable() {
        let model = Fixture.model(path: path, type: .speculativeDraft)
        let presentation = Fixture.presentation(Fixture.workflow(state: .completed, serveState: .readyToConfirm, completedModelPath: path), model: model)
        XCTAssertEqual(presentation.stage, .nonServable)
        XCTAssertFalse(presentation.canConfirm)
    }

    func testModelWithoutTaskIsServable() {
        let model = Fixture.model(path: path, type: nil)
        XCTAssertTrue(Fixture.presentation(Fixture.workflow(state: .verified, completedModelPath: path), model: model).canPreview)
    }

    func testStagesFollowServeStateAndServers() {
        let model = Fixture.model(path: path)
        func stage(_ serveState: ServeWorkflowState, servers: [ServerInfo] = [], runtime: Bool = true, inFlight: Bool = false) -> RunPresentation.Stage {
            Fixture.presentation(Fixture.workflow(state: .verified, serveState: serveState, completedModelPath: path), model: model, servers: servers, runtime: runtime, inFlight: inFlight).stage
        }
        XCTAssertEqual(Fixture.presentation(Fixture.workflow(), model: nil).stage, .noModel)
        XCTAssertEqual(stage(.idle), .eligible)
        XCTAssertEqual(stage(.idle, runtime: false), .runtimeMissing)
        XCTAssertEqual(stage(.previewing), .starting)
        XCTAssertEqual(stage(.readyToConfirm, inFlight: true), .starting)
        XCTAssertEqual(stage(.readyToConfirm), .readyToConfirm)
        XCTAssertEqual(stage(.failed), .failed)
        XCTAssertEqual(stage(.stopped), .stopped)
        XCTAssertEqual(stage(.running, servers: [Fixture.server(path, port: 8766)]), .running)
        XCTAssertEqual(stage(.running), .eligible)
        XCTAssertEqual(Fixture.presentation(Fixture.workflow(state: .verified, serveState: .readyToConfirm, completedModelPath: path), model: model).stateWords, "Ready to confirm")
        XCTAssertNil(Fixture.presentation(Fixture.workflow(state: .verified, completedModelPath: path), model: model).stateWords)
    }

    func testMessageRuleKeepsConversionMessagesOffRunAndAlwaysShowsErrors() {
        let model = Fixture.model(path: path)
        let idle = Fixture.presentation(Fixture.workflow(state: .verified, serveState: .idle, completedModelPath: path, message: "Verification passed.", errorMessage: "boom"), model: model)
        XCTAssertNil(idle.visibleMessage)
        XCTAssertEqual(idle.visibleError, "boom")
        let serving = Fixture.presentation(Fixture.workflow(state: .verified, serveState: .failed, completedModelPath: path, message: "Serve intent changed after preview."), model: model)
        XCTAssertEqual(serving.visibleMessage, "Serve intent changed after preview.")
    }

    func testSubtitleNamesTheModelThePageShows() {
        let completed = Fixture.workflow(state: .verified, completedModelPath: "/models/atlas-mlx")
        XCTAssertEqual(ContentView.subtitle(route: .run, workflow: completed, selectedModelPath: "/models/other"), "atlas-mlx")
        XCTAssertEqual(ContentView.subtitle(route: .run, workflow: Fixture.workflow(), selectedModelPath: "/models/other"), "other")
        XCTAssertEqual(ContentView.subtitle(route: .run, workflow: Fixture.workflow(), selectedModelPath: nil), "")
        XCTAssertEqual(ContentView.subtitle(route: .run, workflow: Fixture.workflow(), selectedModelPath: ""), "")
    }
}

// MARK: - AC4, AC5: memory owner and runway

extension RunRemodelTests {

    func testNilMemoryIsUnknownEverywhereWithNoFallbackEstimate() {
        let model = Fixture.model(path: "/models/a", bytes: 2 * gb)
        let runway = Fixture.runway(memory: nil, next: model)
        XCTAssertFalse(runway.isLive)
        XCTAssertTrue(runway.segments.isEmpty)
        XCTAssertEqual(runway.budget.reading, .unavailable)
        if case .notEstimated = runway.budget.fit {} else { XCTFail("selected-model fit must be unknown without memory") }
        XCTAssertNil(runway.budget.verdictWord)

        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/a")
        XCTAssertEqual(
            RunFleet.slotFit(slot, servers: [], models: [model], memory: nil, hardware: Fixture.hardware, contextTokens: 8192, reserveGB: 4),
            .verdict(.unknown(reason: "live memory unavailable"))
        )
        XCTAssertEqual(
            RunFleet.verdict(slots: [slot], servers: [], models: [model], adding: nil, memory: nil, contextTokens: 8192, reserveGB: 4),
            .unknown(reason: "live memory unavailable")
        )
    }

    func testTwoResidentsAndNextThatFits() {
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb)
        let a = Fixture.model(path: "/models/a", bytes: 3 * gb)
        let b = Fixture.model(path: "/models/b", bytes: 2 * gb)
        let next = Fixture.model(path: "/models/next", bytes: gb, parameters: "1B")
        let runway = Fixture.runway(memory: memory, residents: [Fixture.resident("A", model: a), Fixture.resident("B", model: b)], next: next)

        XCTAssertTrue(runway.isLive)
        XCTAssertEqual(runway.segments.map(\.kind), [.resident, .resident, .otherInUse, .reserve, .next, .free])
        let inUse = runway.segments.filter { [.resident, .otherInUse].contains($0.kind) }.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(inUse, memory.unavailableBytes, "resident estimates sit inside the in-use span")
        XCTAssertEqual(runway.segments.first { $0.kind == .reserve }?.bytes, 4 * gb)
        let budgetSpan = runway.segments.filter { [.next, .free].contains($0.kind) }.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(budgetSpan, 16 * gb)
        XCTAssertEqual(runway.segments.first { $0.kind == .next }?.bytes, FitAdvisor.neededBytes(modelBytes: gb, contextTokens: 8192, parameters: "1B"))
        XCTAssertEqual(runway.budget.verdictWord, "Fits")
        XCTAssertEqual(runway.budget.tone, .fits)
        XCTAssertEqual(runway.segments.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
    }

    func testNextThatDoesNotFitFillsTheBudgetAndReadsWontFit() {
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 6 * gb)
        let next = Fixture.model(path: "/models/big", bytes: 10 * gb)
        let runway = Fixture.runway(memory: memory, next: next)
        XCTAssertEqual(runway.budget.verdictWord, "Won't fit")
        XCTAssertEqual(runway.segments.first { $0.kind == .next }?.bytes, 2 * gb)
        XCTAssertNil(runway.segments.first { $0.kind == .free })
    }

    func testResidentWithoutLibraryModelIsUnknownWithAReasonAndNoWidth() {
        let servers = [Fixture.server("/models/gone", port: 8766)]
        let residents = RunRunway.residents(servers: servers, models: [], contextTokens: 8192)
        XCTAssertEqual(residents.count, 1)
        XCTAssertNil(residents[0].neededBytes)
        XCTAssertEqual(residents[0].unknownReason, "not in the Library")
        let runway = Fixture.runway(memory: MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb), residents: residents)
        XCTAssertEqual(runway.unknownResidents.count, 1)
        XCTAssertFalse(runway.segments.contains { $0.kind == .resident })
        let zeroSize = RunRunway.residents(servers: servers, models: [Fixture.model(path: "/models/gone", bytes: 0)], contextTokens: 8192)
        XCTAssertEqual(zeroSize.first?.unknownReason, "size unavailable")
    }

    func testJITServerWithUnloadedModelHoldsNothing() {
        let model = Fixture.model(path: "/models/jit")
        let unloaded = Fixture.server("/models/jit", port: 8766, jit: true, modelState: "unloaded")
        let loaded = Fixture.server("/models/jit", port: 8767, jit: true, modelState: "loaded")
        XCTAssertTrue(RunRunway.residents(servers: [unloaded], models: [model], contextTokens: 8192).isEmpty)
        XCTAssertEqual(RunRunway.residents(servers: [loaded], models: [model], contextTokens: 8192).count, 1)
        XCTAssertFalse(RunModels.isResident(unloaded))
    }

    func testResidentsAreClippedToTheInUseSpan() {
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 28 * gb)
        let heavy = Fixture.model(path: "/models/heavy", bytes: 20 * gb)
        let runway = Fixture.runway(memory: memory, residents: [Fixture.resident("heavy", model: heavy)])
        XCTAssertEqual(runway.segments.first { $0.kind == .resident }?.bytes, memory.unavailableBytes)
        XCTAssertNil(runway.segments.first { $0.kind == .otherInUse })
    }

    func testNonServableAndNoModelHaveNoNextSegment() {
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb)
        XCTAssertNil(Fixture.runway(memory: memory, next: nil).segments.first { $0.kind == .next })
        let image = Fixture.model(path: "/models/image", type: .imageGeneration)
        let runway = Fixture.runway(memory: memory, next: image)
        XCTAssertNil(runway.segments.first { $0.kind == .next }, "media pipelines carry no fit estimate")
        XCTAssertNil(runway.budget.verdictWord)
    }

    func testWidthsKeepKnownSpansAtTheMinimumTakenFromFree() {
        let memory = MemorySnapshot(totalBytes: 100 * gb, availableBytes: 60 * gb)
        let tiny = Fixture.model(path: "/models/tiny", bytes: 1)
        let runway = Fixture.runway(memory: memory, residents: [Fixture.resident("tiny", model: tiny)])
        let widths = runway.widths(barWidth: 400, minimum: 8)
        XCTAssertEqual(widths.count, runway.segments.count)
        let resident = runway.segments.firstIndex { $0.kind == .resident }!
        XCTAssertGreaterThanOrEqual(widths[resident], 8)
        XCTAssertEqual(widths.reduce(0, +), 400, accuracy: 0.01)
    }

    func testSegmentsLayoutTilesEveryProposedWidthWithoutExceedingIt() {
        let memory = MemorySnapshot(totalBytes: 100 * gb, availableBytes: 60 * gb)
        let tiny = Fixture.model(path: "/models/tiny", bytes: 1)
        let runway = Fixture.runway(memory: memory, residents: [Fixture.resident("tiny", model: tiny)])
        for width in [CGFloat(1060), 752, 472, 120] {
            let spans = RunSegmentsLayout.spans(width: width) { runway.widths(barWidth: $0, minimum: 8) }
            XCTAssertEqual(spans.count, runway.segments.count)
            XCTAssertEqual(spans.reduce(0) { $0 + $1.width }, width, accuracy: 0.01)
            XCTAssertLessThanOrEqual((spans.last?.x ?? 0) + (spans.last?.width ?? 0), width + 0.01)
        }
    }

    func testSegmentsLayoutScalesOverwideWidthsDownToTheProposal() {
        let spans = RunSegmentsLayout.spans(width: 100) { _ in [80, 80] }
        XCTAssertEqual(spans.reduce(0) { $0 + $1.width }, 100, accuracy: 0.01)
        XCTAssertEqual(spans[1].x, 50, accuracy: 0.01)
    }

    func testLabelsStayUnderSegmentsOnlyWhenEveryLabelledSegmentIsWideEnough() {
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb)
        let a = Fixture.model(path: "/models/a", bytes: 3 * gb)
        let runway = Fixture.runway(memory: memory, residents: [Fixture.resident("A", model: a)], next: Fixture.model(path: "/models/n", bytes: gb, parameters: "1B"))
        let wide = runway.widths(barWidth: 1000, minimum: 8)
        XCTAssertTrue(runway.labelsFitUnderSegments(widths: wide, minimum: 72))
        let narrow = runway.widths(barWidth: 200, minimum: 8)
        XCTAssertFalse(runway.labelsFitUnderSegments(widths: narrow, minimum: 72))
    }
}

// MARK: - Fleet and slots

extension RunRemodelTests {

    func testResidentSlotReportsResidencyInsteadOfAVerdict() {
        let model = Fixture.model(path: "/models/a", bytes: 20 * gb)
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/a")
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 5 * gb)
        let fit = RunFleet.slotFit(slot, servers: [Fixture.server("/models/a", port: 8766)], models: [model], memory: memory, hardware: Fixture.hardware, contextTokens: 8192, reserveGB: 4)
        XCTAssertEqual(fit, .resident)
        let cold = RunFleet.slotFit(slot, servers: [], models: [model], memory: memory, hardware: Fixture.hardware, contextTokens: 8192, reserveGB: 4)
        guard case .verdict(.wontFit)? = cold else { return XCTFail("a model that is not loaded is judged against available memory") }
    }

    func testFleetVerdictSumsOnlySlotsThatAreNotYetResident() {
        let a = Fixture.model(path: "/models/a", bytes: 3 * gb)
        let b = Fixture.model(path: "/models/b", bytes: 3 * gb)
        let slots = [
            EndpointSlot(enabled: true, port: 8766, modelPath: "/models/a"),
            EndpointSlot(enabled: true, port: 8767, modelPath: "/models/b"),
            EndpointSlot(enabled: false, port: 8768, modelPath: "/models/b"),
        ]
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb)
        let residentA = [Fixture.server("/models/a", port: 8766)]
        let one = RunFleet.verdict(slots: slots, servers: residentA, models: [a, b], adding: nil, memory: memory, contextTokens: 8192, reserveGB: 4)
        let expectedOne = FleetFitAdvisor.verdict(
            estimates: [.known(modelBytes: 3 * gb, contextTokens: 8192, parameters: "7B")],
            availableBytes: memory.availableBytes, reserveBytes: 4 * gb)
        XCTAssertEqual(one, expectedOne)
        let none = RunFleet.verdict(slots: slots, servers: residentA + [Fixture.server("/models/b", port: 8767)], models: [a, b], adding: nil, memory: memory, contextTokens: 8192, reserveGB: 4)
        XCTAssertNil(none)
        let adding = RunFleet.verdict(slots: [], servers: [], models: [a], adding: "/models/a", memory: memory, contextTokens: 8192, reserveGB: 4)
        XCTAssertNotNil(adding)
    }

    func testFleetVerdictWithUnknownSizeIsUnknown() {
        let slots = [EndpointSlot(enabled: true, port: 8766, modelPath: "/models/unlisted")]
        let verdict = RunFleet.verdict(slots: slots, servers: [], models: [], adding: nil,
                                       memory: MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb), contextTokens: 8192, reserveGB: 4)
        guard case .unknown? = verdict else { return XCTFail("expected unknown") }
    }
}

// MARK: - AC6: context

extension RunRemodelTests {
    func testSuggestionMapsToTheLargestToolbarOptionNotAbove() {
        XCTAssertEqual(RunContext.option(atMost: 4096), 4096)
        XCTAssertEqual(RunContext.option(atMost: 5000), 4096)
        XCTAssertEqual(RunContext.option(atMost: 100_000), 65536)
        XCTAssertEqual(RunContext.option(atMost: 512), 2048)
        XCTAssertEqual(RunContext.suggestion(from: .wontFit(deficitGB: 1, suggestedMaxContext: 8192)), 8192)
        XCTAssertNil(RunContext.suggestion(from: .wontFit(deficitGB: 1, suggestedMaxContext: nil)))
        XCTAssertNil(RunContext.suggestion(from: .fits(headroomGB: 3)))
        XCTAssertNil(RunContext.suggestion(from: nil))
    }

    func testEveryAdvisorSuggestionIsAnOption() {
        let verdict = FitAdvisor.verdict(
            modelBytes: 14_000_000_000, contextTokens: 65536, parameters: "8B",
            availableBytes: 24_000_000_000, reserveBytes: 4_000_000_000)
        guard case .wontFit(_, let suggested?) = verdict else { return XCTFail("expected a won't-fit suggestion") }
        XCTAssertTrue(RunContext.options.contains(RunContext.suggestion(from: verdict) ?? 0))
        XCTAssertLessThanOrEqual(RunContext.suggestion(from: verdict) ?? .max, suggested)
    }

    func testSelectedModelVerdictUsesTheSharedContext() {
        let memory = MemorySnapshot(totalBytes: 32 * Fixture.gb, availableBytes: 12 * Fixture.gb)
        let model = Fixture.model(path: "/models/m", bytes: 6 * Fixture.gb, parameters: "8B")
        let small = Fixture.runway(memory: memory, next: model, contextTokens: 2048)
        let large = Fixture.runway(memory: memory, next: model, contextTokens: 65536)
        XCTAssertNotEqual(
            small.segments.first { $0.kind == .next }?.bytes,
            large.segments.first { $0.kind == .next }?.bytes)
        XCTAssertEqual(large.budget.verdictWord, "Won't fit")
    }
}

// MARK: - AC8: stop and unload protection

extension RunRemodelTests {
    func testProtectedModelIsRefusedBySharedOwner() {
        let server = Fixture.server("/models/verifying-mlx", port: 8766)
        XCTAssertTrue(AppHost.isProtectedServer(server, protected: ["/models/verifying-mlx"]))
        XCTAssertFalse(AppHost.isProtectedServer(server, protected: ["/models/other-mlx"]))
        XCTAssertFalse(AppHost.isProtectedServer(server, protected: []))
    }

    func testProtectionMatchesCacheRepoIdentityAcrossPathForms() {
        let snapshot = "/Users/x/.cache/huggingface/hub/models--pub--coder/snapshots/rev"
        let server = Fixture.server("pub/coder", port: 8766)
        XCTAssertTrue(AppHost.isProtectedServer(server, protected: [snapshot]))
    }
}

// MARK: - Review fixes

private actor ProtectionGate {
    private var isOpen = false
    func wait() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    func open() { isOpen = true }
}

private struct GatedProber: EndpointProbing {
    let gate: ProtectionGate

    func listModels(baseURL: URL) async -> [String] { [] }
    func isReady(baseURL: URL) async -> Bool { true }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        await gate.wait()
        return ProbeSample(text: "ok", completionTokens: 1, timeToFirstTokenSeconds: 0.1, durationSeconds: 1, metricsEstimated: false)
    }
}

extension RunRemodelTests {
    func testPortsRenderWithoutGroupingSeparators() {
        XCTAssertEqual(RunFormat.endpoint(port: 49461), "127.0.0.1:49461")
        XCTAssertEqual(RunFormat.port(8766), ":8766")
        XCTAssertFalse(RunFormat.endpoint(port: 1_234_567).contains(","))
    }

    func testRunAndToolbarShareOneContextOptionList() {
        XCTAssertEqual(RunContext.options, SystemResourceMonitor.contextOptions)
        XCTAssertEqual(SystemResourceMonitor.contextOptions, SystemResourceMonitor.contextOptions.sorted())
        XCTAssertTrue(SystemResourceMonitor.contextOptions.contains(FitAdvisor.defaultContextTokens))
    }

    func testAddEndpointIsOfferedOnlyForAServableShownModel() {
        let chat = Fixture.presentation(Fixture.workflow(), model: Fixture.model(path: "/models/chat"))
        XCTAssertTrue(chat.canAddEndpoint)
        XCTAssertNil(chat.addEndpointBlockedReason)

        let image = Fixture.presentation(Fixture.workflow(), model: Fixture.model(path: "/models/image", type: .imageGeneration))
        XCTAssertFalse(image.canAddEndpoint)
        XCTAssertEqual(image.addEndpointBlockedReason, "Endpoints serve chat and vision models. Select one in Library.")

        let none = Fixture.presentation(Fixture.workflow(), model: nil)
        XCTAssertFalse(none.canAddEndpoint)
        XCTAssertNotNil(none.addEndpointBlockedReason)
    }

    func testStateWordNamesJITResidencyAndPlainRunning() {
        XCTAssertEqual(RunStateWord.word(state: "running", jit: nil, modelState: nil), "running")
        XCTAssertEqual(RunStateWord.word(state: "running", jit: false, modelState: "loaded"), "running")
        XCTAssertEqual(RunStateWord.word(state: "running", jit: true, modelState: "loaded"), "loaded")
        XCTAssertEqual(RunStateWord.word(state: "running", jit: true, modelState: "unloaded"), "unloaded")
        XCTAssertEqual(RunStateWord.word(state: "running", jit: true, modelState: "loading"), "loading")
        XCTAssertEqual(RunStateWord.word(state: "Stopped", jit: true, modelState: "loading"), "stopped")
        XCTAssertTrue(RunStateWord.isLoading(Fixture.server("/models/a", port: 8766, jit: true, modelState: "loading")))
        XCTAssertFalse(RunStateWord.isLoading(Fixture.server("/models/a", port: 8766, jit: true, modelState: "loaded")))
    }

    func testRunwayLegendNamesReserveOnceAndMarksSizesAsEstimates() {
        let memory = MemorySnapshot(totalBytes: 32 * gb, availableBytes: 20 * gb)
        let model = Fixture.model(path: "/models/m", bytes: 4 * gb, parameters: "7B")
        let runway = Fixture.runway(memory: memory, residents: [Fixture.resident("mlx-community/Qwen3-4B-4bit", model: model)], reserveGB: 4)
        let reserve = runway.segments.first { $0.kind == .reserve }
        let resident = runway.segments.first { $0.kind == .resident }
        XCTAssertEqual(reserve.map(runway.legendName), "Reserve 4 GB")
        XCTAssertNil(reserve.flatMap(runway.legendSize))
        XCTAssertEqual(resident.map(runway.legendName), "mlx-community/Qwen3-4B-4bit")
        XCTAssertTrue(resident.flatMap(runway.legendSize)?.hasPrefix("~") == true)
        XCTAssertFalse(runway.caption.contains("reserve"))
        XCTAssertTrue(runway.caption.hasPrefix("of 32.0 GB unified memory"))
    }

    private func makeProtectedHost(counter: CallCounter, endpointCalls: CallCounter, server: ServerInfo) -> (AppHost, ProtectionGate) {
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { counter.hit("convertStatus"); return [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { counter.hit("serveStatus"); return [server] },
            serveStop: { _ in counter.hit("serveStop"); return [:] }
        )
        let gate = ProtectionGate()
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in }, stop: { _ in }),
            prober: GatedProber(gate: gate),
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9999 }
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("run-protect-\(UUID().uuidString)", isDirectory: true)
        let verification = VerificationCoordinator(probe: probe, store: VerificationStore(fileURL: directory.appendingPathComponent("reports.json")))
        let endpoint = EndpointSupervisor(
            lifecycle: ServeLifecycle(
                preview: { _, _ in endpointCalls.hit("preview"); return "hash" },
                start: { _, _, _ in endpointCalls.hit("start") },
                stop: { _ in endpointCalls.hit("stop") }
            ),
            statusProvider: { endpointCalls.hit("status"); return [server] },
            store: JSONStore<EndpointConfig>(fileURL: directory.appendingPathComponent("endpoint.json"))
        )
        let host = AppHost(
            config: Config.defaults(),
            modelWorkflowAPI: api,
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }),
            verification: verification,
            endpoint: endpoint
        )
        return (host, gate)
    }

    func testLayoutThresholdsFollowTheOfferedViewportWidth() {
        let narrow = RunLayout(viewportWidth: 540)
        XCTAssertEqual(narrow.innerWidth, 452)
        XCTAssertTrue(narrow.isCompact)
        XCTAssertTrue(narrow.isTwoLine)

        let medium = RunLayout(viewportWidth: 840)
        XCTAssertEqual(medium.innerWidth, 752)
        XCTAssertFalse(medium.isCompact)
        XCTAssertFalse(medium.isTwoLine)

        let wide = RunLayout(viewportWidth: 1220)
        XCTAssertEqual(wide.innerWidth, WorkbenchSize.Run.contentMaxWidth - WorkbenchSize.Run.surfaceChrome)
        XCTAssertFalse(wide.isCompact)
        XCTAssertFalse(wide.isTwoLine)
    }

    func testProtectedServerIsRefusedByBothStopPathsBeforeAnyCall() async {
        let counter = CallCounter()
        let endpointCalls = CallCounter()
        let server = Fixture.server(path, port: 8766)
        let (host, gate) = makeProtectedHost(counter: counter, endpointCalls: endpointCalls, server: server)
        await host.modelWorkflow.refreshServers()
        let statusBefore = counter.count("serveStatus")

        host.verification.verifyNow(modelPath: path, signature: nil)
        XCTAssertTrue(AppHost.isProtectedServer(server, protected: host.protectedServingModels))

        let selected = await host.stopSelectedServer(modelPath: path)
        let unloaded = await host.unloadServing(server)

        XCTAssertFalse(selected)
        XCTAssertFalse(unloaded)
        XCTAssertEqual(counter.count("serveStop"), 0)
        XCTAssertEqual(counter.count("serveStatus"), statusBefore)
        XCTAssertEqual(counter.count("convertStatus"), 0)
        for name in ["status", "preview", "start", "stop"] {
            XCTAssertEqual(endpointCalls.count(name), 0, name)
        }

        await gate.open()
        let deadline = Date().addingTimeInterval(5)
        while host.verification.activeModelPath != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testUnprotectedServerStopsThroughTheSelectedPath() async {
        let counter = CallCounter()
        let server = Fixture.server(path, port: 8766)
        let (host, _) = makeProtectedHost(counter: counter, endpointCalls: CallCounter(), server: server)
        await host.modelWorkflow.refreshServers()

        let stopped = await host.stopSelectedServer(modelPath: path)

        XCTAssertTrue(stopped)
        XCTAssertEqual(counter.count("serveStop"), 1)
    }
}
