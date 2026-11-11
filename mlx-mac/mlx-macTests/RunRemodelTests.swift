import XCTest
import AppKit
import SwiftUI
import Vision

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
        inFlight: Bool = false
    ) -> RunPresentation {
        RunPresentation(workflow: workflow, model: model, servers: servers, serveInFlight: inFlight)
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
    func testExistingStrataModelCanReachARealPreviewWithTheBaseRuntimeMissing() async throws {
        guard let manifest = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RUN_PREVIEW_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_RUN_PREVIEW_MANIFEST for a local model preview; no server is started.")
        }
        struct Inputs: Decodable { let agentPath: String; let modelPath: String; let evidenceRoot: String }
        let input = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let root = URL(fileURLWithPath: input.evidenceRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = Config.defaults(ggufRoots: [])
        config.mlxAgentPath = input.agentPath; config.mlxRoots = [input.modelPath]
        config.outputDir = root.appendingPathComponent("outputs").path; config.watchEnabled = false
        let store = ModelWorkflowStore(fileURL: root.appendingPathComponent("workflows-\(UUID().uuidString).json"))
        let app = AppHost(config: config, discoveredRoots: [], vendorAgentPath: input.agentPath,
            configPath: root.appendingPathComponent("config.json").path, modelWorkflowPersistence: .live(store: store))
        XCTAssertFalse(app.runtimeReport.serve.ok, "This acceptance requires the base mlx-lm check to be unavailable.")
        await app.rescan()
        let model = try XCTUnwrap(app.librarySnapshot?.models.first { $0.item.path == input.modelPath })
        XCTAssertEqual(model.item.servingRuntime, "strata")
        app.selectedModelPath = model.item.path
        let before = try await app.api.serveStatus()
        guard !before.contains(where: { HFRepoID.matches($0.modelIdentity, input.modelPath) }) else {
            throw XCTSkip("The selected model already has a server; its ownership is left unchanged.")
        }
        let initial = RunPresentation(workflow: app.modelWorkflow.workflow, model: model, servers: before)
        XCTAssertTrue(initial.canPrepareSelection)
        XCTAssertTrue(initial.canPreview)
        XCTAssertFalse(initial.canConfirm)
        let host = NSHostingView(rootView: ServeView(appHost: app, onRouteSelection: { _ in })
            .environment(\.isRouteActive, true).frame(width: 1190, height: 1100)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1190, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name))
        }
        try await Task.sleep(for: .milliseconds(200)); try capture("before-preview.png")
        app.modelWorkflow.prepareServe(model: model)
        await app.modelWorkflow.previewServe(runtime: "auto", port: nil)
        XCTAssertEqual(app.modelWorkflow.workflow.serveState, .readyToConfirm, app.modelWorkflow.workflow.errorMessage ?? "")
        let prepared = RunPresentation(workflow: app.modelWorkflow.workflow, model: model, servers: app.modelWorkflow.servers)
        XCTAssertTrue(prepared.canConfirm)
        XCTAssertTrue(try store.load().isEmpty, "Preparing a serving target must not create a conversion receipt.")
        let after = try await app.api.serveStatus()
        XCTAssertFalse(after.contains { HFRepoID.matches($0.modelIdentity, input.modelPath) })
        try await Task.sleep(for: .milliseconds(200)); try capture("preview-ready.png")
        let result: [String: Any] = ["baseRuntimeAvailable": app.runtimeReport.serve.ok, "modelRuntime": model.item.servingRuntime!,
            "previewState": app.modelWorkflow.workflow.serveState.rawValue, "canConfirm": prepared.canConfirm,
            "serverStarted": false, "modelPath": model.item.path]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("result.json"))
    }

    func testOptionalPortDistinguishesAutomaticValidAndInvalidInput() {
        XCTAssertEqual(RunPortInput(" \n"), .automatic)
        XCTAssertNil(RunPortInput("").error)
        for port in [1, 8765, 65535] {
            XCTAssertEqual(RunPortInput(" \(port)\n").port, port)
            XCTAssertNil(RunPortInput(String(port)).error)
        }
        for invalid in ["abc", "0", "-1", "65536", "9.5", "999999999999999999999999999"] {
            XCTAssertEqual(RunPortInput(invalid), .invalid, invalid)
            XCTAssertNotNil(RunPortInput(invalid).error, invalid)
        }
    }

    func testTrainingRejectsInvalidIterationsWithoutPreviewCalls() {
        var calls = 0
        let session = TrainingSession(preview: { _ in calls += 1; return [:] }, start: { _, _ in })
        session.draft.repo = "org/model"
        session.draft.data = "/data"
        for value in ["", " ", "abc", "0", "-1", "2.5", "999999999999999999999999999"] {
            session.draft.iterations = value
            XCTAssertNotNil(session.draft.iterationsError)
            XCTAssertFalse(session.canPreview)
            XCTAssertNil(session.previewTraining())
        }
        XCTAssertEqual(calls, 0)
    }

    func testTrainingPreviewCapturesRequestAndEditsInvalidateConfirmation() async {
        var requested: [TrainingRequest] = []
        let session = TrainingSession(preview: { requested.append($0); return ["preview_hash": "h"] }, start: { _, _ in XCTFail("Must preview edited fields again") })
        let original = TrainingDraft(repo: " org/model ", data: " /data ", iterations: " 100 ", output: " /out ")
        session.draft = original
        await session.previewTraining()?.value
        XCTAssertEqual(session.preview?.request, TrainingRequest(repo: "org/model", data: "/data", iterations: 100, output: "/out"))
        XCTAssertTrue(session.canConfirm)
        for field in [\TrainingDraft.repo, \.data, \.iterations, \.output] {
            session.draft = original
            await session.previewTraining()?.value
            session.draft[keyPath: field] += "1"
            XCTAssertNil(session.preview)
            XCTAssertFalse(session.canConfirm)
            XCTAssertNil(session.confirmTraining())
        }
        XCTAssertEqual(requested.count, 5)
    }

    func testTrainingFencesDelayedPreviewAndLocksDuplicateActionsSynchronously() async {
        var continuation: CheckedContinuation<[String: Any], Never>?
        let started = expectation(description: "preview started")
        var calls = 0
        let session = TrainingSession(preview: { _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0; started.fulfill() }
        }, start: { _, _ in XCTFail("No confirmation before preview finishes") })
        session.draft = TrainingDraft(repo: "org/model", data: "/data")
        let task = session.previewTraining()
        XCTAssertTrue(session.isBusy)
        XCTAssertNil(session.previewTraining())
        XCTAssertNil(session.confirmTraining())
        await fulfillment(of: [started], timeout: 1)
        session.draft.output = "/new-output"
        continuation?.resume(returning: ["preview_hash": "old"])
        await task?.value
        XCTAssertEqual(calls, 1)
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.canConfirm)
        XCTAssertTrue(session.canPreview)
    }

    func testTrainingConfirmationUsesCapturedPlanAndFailureCanRetry() async {
        struct Rejected: LocalizedError { var errorDescription: String? { "training rejected" } }
        var starts: [(TrainingRequest, String)] = []
        let session = TrainingSession(preview: { _ in ["plan": ["preview_hash": "captured-hash"]] }, start: { request, hash in
            starts.append((request, hash))
            if starts.count == 1 { throw Rejected() }
        })
        session.draft = TrainingDraft(repo: "org/model", data: "/data", iterations: "300", output: "/out")
        await session.previewTraining()?.value
        let request = session.preview?.request
        let first = session.confirmTraining()
        XCTAssertTrue(session.isBusy)
        XCTAssertNil(session.confirmTraining())
        XCTAssertNil(session.previewTraining())
        await first?.value
        XCTAssertEqual(session.errorMessage, "training rejected")
        XCTAssertTrue(session.canConfirm)
        await session.confirmTraining()?.value
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].0, request)
        XCTAssertEqual(starts[1].0, request)
        XCTAssertEqual(starts.map { $0.1 }, ["captured-hash", "captured-hash"])
        XCTAssertNil(session.preview)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.notice, "Training submitted. See Activity.")
    }

    func testTrainingCannotConfirmAnExplicitlyMissingCachedBase() async {
        var starts = 0
        var missing = true
        let session = TrainingSession(preview: { _ in
            missing ? ["preview_hash": "missing", "base_identity": NSNull()] : ["preview_hash": "legacy"]
        }, start: { _, _ in starts += 1 })
        session.draft = TrainingDraft(repo: "org/model", data: "/data")
        await session.previewTraining()?.value
        XCTAssertNotNil(session.preview)
        XCTAssertFalse(session.canConfirm)
        XCTAssertNil(session.confirmTraining())
        XCTAssertEqual(starts, 0)
        missing = false
        await session.previewTraining()?.value
        XCTAssertTrue(session.canConfirm, "Older previews without base identity retain their confirmation contract")
    }

    func testTrainingMissingHashAndPreviewFailureRemainRetryable() async {
        struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
        var attempts = 0
        let session = TrainingSession(preview: { _ in
            attempts += 1
            if attempts == 1 { throw Offline() }
            if attempts == 2 { return [:] }
            return ["preview_hash": "h"]
        }, start: { _, _ in })
        session.draft = TrainingDraft(repo: "org/model", data: "/data")
        await session.previewTraining()?.value
        XCTAssertEqual(session.errorMessage, "offline")
        XCTAssertTrue(session.canPreview)
        await session.previewTraining()?.value
        XCTAssertNil(session.preview)
        XCTAssertNotNil(session.errorMessage)
        await session.previewTraining()?.value
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.canConfirm)
    }

    func testTrainingGuidancePrioritizesBusyThenMissingFieldsThenIterations() {
        var draft = TrainingDraft(repo: " \n", data: " \t", iterations: "0")
        XCTAssertEqual(TrainingPreviewGuidance.resolve(draft: draft, operation: nil)?.field, .repo)
        draft.repo = "org/model"
        XCTAssertEqual(TrainingPreviewGuidance.resolve(draft: draft, operation: nil)?.field, .data)
        draft.data = "/data"
        let invalid = TrainingPreviewGuidance.resolve(draft: draft, operation: nil)
        XCTAssertEqual(invalid?.field, .iterations)
        XCTAssertEqual(invalid?.message, draft.iterationsError)
        draft.iterations = " 100 "
        XCTAssertNil(TrainingPreviewGuidance.resolve(draft: draft, operation: nil))
        for operation in [TrainingSession.Operation.previewing, .submitting] {
            let busy = TrainingPreviewGuidance.resolve(draft: TrainingDraft(), operation: operation)
            XCTAssertNotNil(busy)
            XCTAssertNil(busy?.field, "Busy guidance must never offer field recovery")
        }
    }

    func testTrainingCollectionFailuresAreIndependentAndRetainLastSuccessfulRows() async {
        struct Unavailable: LocalizedError { var errorDescription: String? { "CLI unavailable" } }
        let job = TrainingJob(receipt: "adapter", repo: "org/model", out: "/adapter", pid: 17,
                              state: "done", logPath: nil, adapterIdentity: .string("identity"))
        let record: LabValue = .object(["id": .string("evaluation")])
        var jobsFail = true
        var historyFail = false
        var jobReads = 0
        var historyReads = 0
        let collections = TrainingLoader(jobs: {
            jobReads += 1
            if jobsFail { throw Unavailable() }
            return [job]
        }, history: {
            historyReads += 1
            if historyFail { throw Unavailable() }
            return [record]
        }, inspect: { _ in LabResponse() })

        await collections.refresh()
        XCTAssertEqual(jobReads, 1)
        XCTAssertEqual(historyReads, 1, "History must still be attempted when jobs fails")
        XCTAssertEqual(collections.jobsPhase, .failed)
        XCTAssertFalse(collections.hasLoadedJobs)
        XCTAssertEqual(collections.jobsError, "CLI unavailable")
        XCTAssertEqual(collections.evaluations, [record])
        XCTAssertEqual(collections.historyPhase, .populated)

        jobsFail = false
        historyFail = true
        await collections.refresh()
        XCTAssertEqual(collections.jobs.map(\.id), ["adapter"])
        XCTAssertNil(collections.jobsError)
        XCTAssertEqual(collections.evaluations, [record])
        XCTAssertEqual(collections.historyError, "CLI unavailable")
        XCTAssertEqual(collections.historyPhase, .populated)

        jobsFail = true
        await collections.refresh()
        XCTAssertEqual(collections.jobs.map(\.id), ["adapter"])
        XCTAssertEqual(collections.jobsError, "CLI unavailable")
        XCTAssertEqual(collections.evaluations, [record])
        jobsFail = false
        historyFail = false
        await collections.refresh()
        XCTAssertNil(collections.jobsError)
        XCTAssertNil(collections.historyError)
        XCTAssertEqual(jobReads, 4)
        XCTAssertEqual(historyReads, 4)
    }

    func testTrainingRefreshLocksAreIndependentAndEmptyRequiresSuccessfulRead() async {
        let jobsStarted = expectation(description: "jobs started")
        let historyStarted = expectation(description: "history started")
        var jobsContinuation: CheckedContinuation<[TrainingJob], Never>?
        var historyContinuation: CheckedContinuation<[LabValue], Never>?
        var jobReads = 0
        var historyReads = 0
        let collections = TrainingLoader(jobs: {
            jobReads += 1
            return await withCheckedContinuation { jobsContinuation = $0; jobsStarted.fulfill() }
        }, history: {
            historyReads += 1
            return await withCheckedContinuation { historyContinuation = $0; historyStarted.fulfill() }
        }, inspect: { _ in LabResponse() })
        XCTAssertEqual(collections.jobsPhase, .loading)
        XCTAssertEqual(collections.historyPhase, .loading)
        let jobsTask = collections.refreshJobs()
        XCTAssertTrue(collections.isLoadingJobs)
        XCTAssertNil(collections.refreshJobs(), "Duplicate jobs read must lock synchronously")
        let historyTask = collections.refreshHistory()
        XCTAssertTrue(collections.isLoadingHistory, "Jobs loading must not block history")
        XCTAssertNil(collections.refreshHistory())
        await fulfillment(of: [jobsStarted, historyStarted], timeout: 1)
        historyContinuation?.resume(returning: [])
        await historyTask?.value
        XCTAssertEqual(collections.historyPhase, .empty)
        XCTAssertTrue(collections.hasLoadedHistory)
        XCTAssertTrue(collections.isLoadingJobs)
        jobsContinuation?.resume(returning: [])
        await jobsTask?.value
        XCTAssertEqual(collections.jobsPhase, .empty)
        XCTAssertTrue(collections.hasLoadedJobs)
        XCTAssertEqual(jobReads, 1)
        XCTAssertEqual(historyReads, 1)
    }

    func testTrainingRefreshKeepsPopulatedRowsDuringRead() async {
        let record: LabValue = .object(["id": .string("prior")])
        var continuation: CheckedContinuation<[LabValue], Never>?
        let started = expectation(description: "refresh started")
        var reads = 0
        let collections = TrainingLoader(jobs: { [] }, history: {
            reads += 1
            if reads == 1 { return [record] }
            return await withCheckedContinuation { continuation = $0; started.fulfill() }
        }, inspect: { _ in LabResponse() })
        await collections.refreshHistory()?.value
        let refresh = collections.refreshHistory()
        XCTAssertTrue(collections.isLoadingHistory)
        XCTAssertEqual(collections.historyPhase, .populated)
        XCTAssertEqual(collections.evaluations, [record])
        await fulfillment(of: [started], timeout: 1)
        continuation?.resume(returning: [])
        await refresh?.value
        XCTAssertEqual(collections.historyPhase, .empty)
        XCTAssertTrue(collections.evaluations.isEmpty)
    }

    func testTrainingInspectionLocksRequestsAndRetainsOwningReportAfterFailure() async {
        struct Rejected: LocalizedError { var errorDescription: String? { "inspection rejected" } }
        let started = expectation(description: "inspection started")
        var continuation: CheckedContinuation<LabResponse, Error>?
        var calls: [String] = []
        let collections = TrainingLoader(jobs: { [] }, history: { [] }, inspect: { id in
            calls.append(id)
            if calls.count == 2 {
                return try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
            }
            return LabResponse(report: .string("report-" + id), artifactSHA256: "hash-" + id)
        })
        await collections.inspect("first")?.value
        XCTAssertEqual(collections.inspection?.recordID, "first")
        let pending = collections.inspect("second")
        XCTAssertEqual(collections.inspectingID, "second")
        XCTAssertNil(collections.inspect("third"), "No concurrent inspection may overwrite the pending request")
        XCTAssertEqual(collections.inspection?.recordID, "first")
        await fulfillment(of: [started], timeout: 1)
        continuation?.resume(throwing: Rejected())
        await pending?.value
        XCTAssertNil(collections.inspectingID)
        XCTAssertEqual(collections.inspection?.recordID, "first")
        XCTAssertEqual(collections.inspection?.response.report, .string("report-first"))
        XCTAssertEqual(collections.inspection?.response.artifactSHA256, "hash-first")
        XCTAssertEqual(collections.inspectionError, "Could not inspect second: inspection rejected")
        XCTAssertNil(collections.historyError)
        await collections.inspect("second")?.value
        XCTAssertEqual(collections.inspection?.recordID, "second")
        XCTAssertEqual(collections.inspection?.response.artifactSHA256, "hash-second")
        XCTAssertNil(collections.inspectionError)
        XCTAssertEqual(calls, ["first", "second", "second"])
    }

    private var gb: Int64 { Fixture.gb }
    private var path: String { "/models/atlas-mlx" }

    private func makeCoordinator(
        counter: CallCounter, servers: [ServerInfo], statusError: Error? = nil, previewError: Error? = nil
    ) -> ModelWorkflowCoordinator {
        let done = Job(receipt: "r1", repo: nil, source: nil, qBits: 4, out: "/models/atlas-mlx", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "done")
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in counter.hit("convertPreview"); return [:] },
            convertStart: { _, _, _, _ in counter.hit("convertStart"); return [:] },
            convertStatus: { counter.hit("convertStatus"); return [done] },
            servePreview: { _, _, _ in
                counter.hit("servePreview")
                if let previewError { throw previewError }
                return ["preview_hash": "h"]
            },
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

    func testRejectedRuntimePreviewCannotConfirmOrStartServing() async {
        struct MissingRuntime: LocalizedError { var errorDescription: String? { "Selected runtime is unavailable." } }
        let counter = CallCounter()
        let coordinator = makeCoordinator(counter: counter, servers: [], previewError: MissingRuntime())
        coordinator.restore(Fixture.workflow(state: .completed, completedModelPath: path))
        await coordinator.previewServe(runtime: "auto", port: nil)
        let presentation = Fixture.presentation(coordinator.workflow, model: Fixture.model(path: path))
        XCTAssertEqual(presentation.stage, .failed)
        XCTAssertFalse(presentation.canConfirm)
        XCTAssertEqual(coordinator.workflow.errorMessage, "Selected runtime is unavailable.")
        await coordinator.confirmServe(runtime: "auto", port: nil)
        XCTAssertEqual(counter.count("servePreview"), 1)
        XCTAssertEqual(counter.count("serveStart"), 0)
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

    func testRuntimeValidationBelongsToTheServePreviewBeforeConfirmation() {
        let model = Fixture.model(path: path)
        let presentation = Fixture.presentation(Fixture.workflow(state: .completed, completedModelPath: path), model: model)
        XCTAssertTrue(presentation.canPreview)
        XCTAssertEqual(presentation.stage, .eligible)
        XCTAssertFalse(presentation.canConfirm)
    }

    func testReadyLibrarySelectionCanPreviewWithoutAConversionRecord() {
        let model = Fixture.model(path: path)
        let presentation = Fixture.presentation(Fixture.workflow(), model: model)
        XCTAssertTrue(presentation.canPrepareSelection)
        XCTAssertTrue(presentation.canPreview)
        XCTAssertFalse(presentation.canConfirm)
        XCTAssertNil(presentation.selectionError)
        XCTAssertFalse(Fixture.presentation(Fixture.workflow(), model: model, inFlight: true).canPrepareSelection)
        for state: ConversionWorkflowState in [.queued, .running, .verifying, .verificationFailed, .failed] {
            let blocked = Fixture.presentation(Fixture.workflow(state: state, completedModelPath: path), model: model)
            XCTAssertTrue(blocked.needsWorkflowReview, state.rawValue)
            XCTAssertFalse(blocked.canPrepareSelection, state.rawValue)
            XCTAssertFalse(blocked.canPreview, state.rawValue)
            XCTAssertNotNil(blocked.selectionError, state.rawValue)
        }
    }

    func testVerifyingWorkflowIsNotEligible() {
        let model = Fixture.model(path: path)
        let presentation = Fixture.presentation(Fixture.workflow(state: .verifying, completedModelPath: path), model: model)
        XCTAssertFalse(presentation.canPreview)
        XCTAssertEqual(presentation.stage, .notEligible)
        XCTAssertNotNil(presentation.selectionError)
    }

    func testImageGenerationModelCanPreviewItsTypedEndpoint() {
        let model = Fixture.model(path: path, type: .imageGeneration)
        let presentation = Fixture.presentation(Fixture.workflow(state: .verified, completedModelPath: path), model: model)
        XCTAssertTrue(presentation.canPreview)
        XCTAssertFalse(presentation.canConfirm)
        XCTAssertNil(presentation.selectionError)
        XCTAssertNotNil(presentation.runwayModel)
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
        func stage(_ serveState: ServeWorkflowState, servers: [ServerInfo] = [], inFlight: Bool = false) -> RunPresentation.Stage {
            Fixture.presentation(Fixture.workflow(state: .verified, serveState: serveState, completedModelPath: path), model: model, servers: servers, inFlight: inFlight).stage
        }
        XCTAssertEqual(Fixture.presentation(Fixture.workflow(), model: nil).stage, .noModel)
        XCTAssertEqual(stage(.idle), .eligible)
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
    func testOnlyRunsThatServeTheModelBlockStop() {
        let server = Fixture.server("/models/verifying-mlx", port: 8766)
        var occupancy = ModelOccupancy()
        XCTAssertFalse(occupancy.blocksStop(server))
        for holder in [ModelOccupancy.Holder.runningServer, .endpoint, .preference, .inferenceTask, .conversion] {
            occupancy.add(["/models/verifying-mlx"], for: holder)
        }
        XCTAssertFalse(occupancy.blocksStop(server))
        for holder in [ModelOccupancy.Holder.verification, .comparison, .hostedComparison] {
            var held = ModelOccupancy()
            held.add(["/models/other-mlx"], for: holder)
            XCTAssertFalse(held.blocksStop(server), "\(holder)")
            held.add(["/models/verifying-mlx"], for: holder)
            XCTAssertTrue(held.blocksStop(server), "\(holder)")
        }
    }

    func testProtectionMatchesCacheRepoIdentityAcrossPathForms() {
        let snapshot = "/Users/x/.cache/huggingface/hub/models--pub--coder/snapshots/rev"
        var occupancy = ModelOccupancy()
        occupancy.add([snapshot], for: .verification)
        XCTAssertTrue(occupancy.blocksStop(Fixture.server("pub/coder", port: 8766)))
        XCTAssertTrue(occupancy.blocksStop(modelIdentity: "pub/coder"))
    }

    func testReclaimProtectsEveryLibraryCopyOfAClaimedRepo() {
        let snapshots = ["/hub/models--pub--coder/snapshots/a", "/hub/models--pub--coder/snapshots/b"]
        var repoClaim = ModelOccupancy(libraryPaths: snapshots + ["/models/other"])
        repoClaim.add(["pub/coder"], for: .runningServer)
        XCTAssertEqual(repoClaim.protectedPaths, Set(["pub/coder"] + snapshots))
        var pathClaim = ModelOccupancy(libraryPaths: snapshots)
        pathClaim.add([snapshots[0]], for: .preference)
        XCTAssertEqual(pathClaim.protectedPaths, [snapshots[0]], "One revision's path never claims another revision")
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

    func testAddEndpointSupportsTypedModelsAndRequiresASelection() {
        let chat = Fixture.presentation(Fixture.workflow(), model: Fixture.model(path: "/models/chat"))
        XCTAssertTrue(chat.canAddEndpoint)
        XCTAssertNil(chat.addEndpointBlockedReason)

        let image = Fixture.presentation(Fixture.workflow(), model: Fixture.model(path: "/models/image", type: .imageGeneration))
        XCTAssertTrue(image.canAddEndpoint)
        XCTAssertNil(image.addEndpointBlockedReason)

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
        let hostedComparison = HostedComparisonCoordinator(
            store: JSONStore(fileURL: directory.appendingPathComponent("hosted-runs.json")),
            outputStore: ComparisonOutputStore(root: directory.appendingPathComponent("hosted-outputs")),
            nativeProbe: probe, readToken: { _ in nil })
        let host = AppHost(
            config: Config.defaults(),
            modelWorkflowAPI: api,
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }),
            verification: verification,
            hostedComparison: hostedComparison,
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
        XCTAssertTrue(host.occupancy.blocksStop(server))

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

    func testHostedComparisonNativeLaneIsRefusedByBothStopPaths() async throws {
        let counter = CallCounter()
        let endpointCalls = CallCounter()
        let server = Fixture.server(path, port: 8766)
        let (host, gate) = makeProtectedHost(counter: counter, endpointCalls: endpointCalls, server: server)
        await host.modelWorkflow.refreshServers()
        host.hostedComparison.validateTarget = { _, _ in }
        await host.hostedComparison.waitForHistory()
        try await host.hostedComparison.start(
            targets: [HostedComparisonTarget(local: Fixture.model(path: path), capturedAt: Date())],
            promptSet: PromptSet(id: "lane", name: "Lane", useCase: nil, prompts: [PromptEntry(id: "a", text: "Hi")], origin: .userCreated))

        let selected = await host.stopSelectedServer(modelPath: path)
        let unloaded = await host.unloadServing(server)

        XCTAssertFalse(selected)
        XCTAssertFalse(unloaded)
        XCTAssertEqual(counter.count("serveStop"), 0)
        XCTAssertEqual(endpointCalls.count("stop"), 0)

        await gate.open()
        let deadline = Date().addingTimeInterval(5)
        while host.hostedComparison.activeRunID != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testUnloadedHistoryProtectsTheExactReclaimRoots() {
        let (host, _) = makeProtectedHost(counter: CallCounter(), endpointCalls: CallCounter(), server: Fixture.server(path, port: 8766))
        host.reclaim.ggufRoots = { ["/fixture/discovered-gguf"] }
        host.reclaim.mlxRoots = { ["/fixture/selected-mlx"] }
        XCTAssertFalse(host.comparison.hasLoadedHistory)
        let protected = host.reclaim.protectedPaths()
        XCTAssertTrue(protected.contains("/fixture/discovered-gguf"))
        XCTAssertTrue(protected.contains("/fixture/selected-mlx"))
    }

    func testUnprotectedServerStopsThroughTheSelectedPath() async {
        let counter = CallCounter()
        let server = Fixture.server(path, port: 8766)
        let (host, _) = makeProtectedHost(counter: counter, endpointCalls: CallCounter(), server: server)
        await host.comparison.waitForHistory()
        await host.modelWorkflow.refreshServers()

        let stopped = await host.stopSelectedServer(modelPath: path)

        XCTAssertTrue(stopped)
        XCTAssertEqual(counter.count("serveStop"), 1)
    }
}

// MARK: - Serving surface fixtures

/// One enabled endpoint (Alder), one third-party local service (Birch) and one launched server with
/// no endpoint (Cedar), all behind fakes; nothing starts a process or touches real state.
@MainActor
enum ServingWorld {
    /// Hosts a view in a window of the given size and returns the text recognised in its rendering.
    static func renderedLines<Content: View>(_ content: Content, size: CGSize) async throws -> [String] {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(WorkbenchColor.canvas).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try recognizedLines(in: try XCTUnwrap(bitmap.cgImage))
    }

    /// Reads text in overlapping horizontal bands, top to bottom, so tall renders keep a legible text size
    /// at any backing scale. A band keeps the lines centred in its share, with a margin for the centre each band
    /// measures; text an earlier band already kept at the same place is not kept again.
    static func recognizedLines(in image: CGImage, band: Int = 600, overlap: Int = 100) throws -> [String] {
        let margin = Double(overlap) / 4
        var lines: [(y: Double, x: Double, text: String, box: CGRect)] = []
        var top = 0
        while top < image.height {
            let earlier = lines.count
            let height = min(band, image.height - top)
            let last = top + height >= image.height
            let slice = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: slice).perform([request])
            let lower = top == 0 ? -Double.infinity : Double(top + overlap / 2)
            let upper = last ? Double.infinity : Double(top + band - overlap / 2)
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let centre = Double(top) + (1 - observation.boundingBox.midY) * Double(height)
                guard centre >= lower - margin && centre < upper + margin else { continue }
                let unit = observation.boundingBox
                let box = CGRect(x: unit.minX * Double(image.width), y: Double(top) + (1 - unit.maxY) * Double(height),
                                 width: unit.width * Double(image.width), height: unit.height * Double(height))
                let seen = lines[..<earlier].contains { kept in
                    let shared = kept.box.intersection(box)
                    return !shared.isNull && shared.width > 0 && shared.height > min(kept.box.height, box.height) / 2
                }
                if !seen { lines.append((centre, unit.minX, text, box)) }
            }
            if last { break }
            top += band - overlap
        }
        return lines.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text)
    }

    static let managed = "/receipts/workbench"
    static let other = "/receipts/other"
    static let selectedModel = "/models/Dune"

    static func model(_ name: String, path: String, bytes: Int64 = 4_000_000_000, signature: String? = nil) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path, name: name, bytes: bytes, modifiedAt: nil,
            shard: nil, modelKey: name, architecture: "llama", quantization: "4-bit", parameters: "7B", structure: nil,
            signature: signature ?? "weights-\(name)", companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil))
    }

    static func server(_ name: String, port: Int, pid: Int, managedByWorkbench: Bool) -> ServerInfo {
        ServerInfo(path: "/models/\(name)", runtime: "mlx_lm", port: port, pid: pid, state: "running", jit: false, modelState: "loaded",
                   receiptsDirectory: managedByWorkbench ? managed : other, processStartedAt: "2026-01-01T00:00:00Z")
    }

    /// `accelerated` gives the endpoint a role and acceleration facts; `onEngineFetch` runs on each inventory read;
    /// `extraModels` adds Library models by name and size in bytes.
    static func host(populated: Bool = true, serversError: Bool = false, accelerated: Bool = false,
                     verification: VerificationCoordinator? = nil, extraModels: [(String, Int64)] = [],
                     onEngineFetch: @escaping @Sendable () -> Void = {}) async throws -> AppHost {
        let root = WorkbenchStatePaths.hostedTestRoot
        var slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/Alder")
        if accelerated {
            slot.role = UseCase.allCases.first
            slot.acceleration = LocalInferenceOptions(m5Prefill: true, promptLookup: true)
        }
        let endpointServer = server("Alder", port: 8766, pid: 101, managedByWorkbench: true)
        let third = server("Birch", port: 11434, pid: 102, managedByWorkbench: false)
        let bare = server("Cedar", port: 9001, pid: 103, managedByWorkbench: true)
        let world = FakeServeWorld()
        if populated { world.preload(repo: slot.modelPath, port: slot.port) }
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: root.appendingPathComponent("serving-fleet-\(UUID().uuidString).json"))
        try fleet.replaceAll([EndpointFleetConfig(slots: populated ? [slot] : [], installedAtLogin: false)])
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore(fileURL: root.appendingPathComponent("serving-endpoint-\(UUID().uuidString).json")), fleetStore: fleet)
        let workflowServers = populated ? [endpointServer, bare] : []
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
            servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] },
            serveStatus: { if serversError { throw WorkflowEvidenceError.invalid("Serving status is offline.") }; return workflowServers },
            serveStop: { _ in [:] })
        let inventory = ServingInventoryCoordinator(managedReceipts: managed,
            fetchEngine: {
                onEngineFetch()
                return ServingEngineSnapshot(servers: populated ? [endpointServer, bare, third] : [],
                    errors: serversError ? ["engine:\(other)": "Receipts are unreadable."] : [:])
            },
            readMemory: { _ in nil })
        // The setup assistant reads its own suite, so a fresh machine and a configured one host the same window.
        let setupDefaults = try XCTUnwrap(UserDefaults(suiteName: "serving-world-setup-\(UUID().uuidString)"))
        setupDefaults.set(true, forKey: SetupCoordinator.completionKey)
        let setup = SetupCoordinator(defaults: setupDefaults)
        let app = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", agentHealth: .notConfigured,
            runtimeReport: .checking, modelWorkflowAPI: api,
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }),
            verification: verification, servingInventory: inventory, endpoint: supervisor, setup: setup)
        await supervisor.reconcile()
        let library = ([("Dune", selectedModel, 4_000_000_000), ("Alder", "/models/Alder", 4_000_000_000)]
            + extraModels.map { ($0.0, "/models/\($0.0)", $0.1) }).map { name, path, bytes in
            model(name, path: path, bytes: bytes)
        }
        app.librarySnapshot = LibrarySnapshot(models: library, groups: [], hardware: app.hardwareProfile, generatedAt: Date())
        app.selectedModelPath = selectedModel
        await app.modelWorkflow.refreshServers()
        await inventory.refresh()
        return app
    }
}

/// Whether the hosted route is the one the window shows.
@MainActor
final class RouteFlag: ObservableObject {
    @Published var active = true
}

private struct RunPage: View {
    let app: AppHost
    @ObservedObject var route: RouteFlag
    let review: EndpointChangeReview?
    let hold: FleetOverrideHold?

    var body: some View {
        ServeView(appHost: app, initialReview: review, fleetHold: hold)
            .environment(\.isRouteActive, route.active)
    }
}

extension RunRemodelTests {
    /// The Run page as the window shows it: the route alone below the toolbar.
    private func hostRun(_ app: AppHost, detail: CGSize, dark: Bool, route: RouteFlag? = nil,
                         review: EndpointChangeReview? = nil, hold: FleetOverrideHold? = nil) -> (NSWindow, NSHostingView<AnyView>) {
        let content = RunPage(app: app, route: route ?? RouteFlag(), review: review, hold: hold)
        .frame(width: detail.width, height: detail.height)
        .background(WorkbenchColor.canvas)
        .preferredColorScheme(dark ? .dark : .light)
        let hosting = NSHostingView(rootView: AnyView(content))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: detail), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return (window, hosting)
    }

    private func pngData(_ hosting: NSView) throws -> Data {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func saveCapture(_ data: Data, name: String) throws {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let folder = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDER_OUTPUT"] {
            let url = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent(name + ".png"))
        }
    }

    /// Text recognised in the rendered page, one entry per line of text.
    private func renderedLines(_ data: Data) throws -> [String] {
        try ServingWorld.recognizedLines(in: try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage))
    }

    func testRunRendersTheServingFixtureForReview() async throws {
        guard ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1" else {
            throw XCTSkip("Set MLX_WORKBENCH_RENDERS=1 to write Run captures.")
        }
        let app = try await ServingWorld.host()
        for (size, label) in [(CGSize(width: 1220, height: 848), "1220x848"), (CGSize(width: 520, height: 508), "520x508")] {
            for dark in [false, true] {
                let (window, hosting) = hostRun(app, detail: size, dark: dark)
                try await Task.sleep(for: .milliseconds(400))
                try saveCapture(try pngData(hosting), name: "run-\(label)-\(dark ? "dark" : "light")")
                window.close()
            }
        }
        // Served models scrolled to the top of the viewport, at the minimum and the 740 detail widths.
        for (size, label) in [(CGSize(width: 520, height: 508), "520x508"), (CGSize(width: 740, height: 508), "740x508")] {
            let (window, hosting) = hostRun(app, detail: size, dark: false)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            await showServingEndpoints(app, hosting: hosting)
            try saveCapture(try pngData(hosting), name: "run-\(label)-rows-light")
        }
        // Save as endpoint, with the model unverified.
        do {
            let (window, hosting) = hostRun(app, detail: CGSize(width: 520, height: 508), dark: false)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            try selectSaveAsEndpoint(hosting)
            try await Task.sleep(for: .milliseconds(300))
            try saveCapture(try pngData(hosting), name: "run-520x508-save-endpoint-light")
        }
        // Empty, and a failing status read.
        do {
            let empty = try await ServingWorld.host(populated: false)
            let (window, hosting) = hostRun(empty, detail: CGSize(width: 1220, height: 848), dark: false)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            await showServingEndpoints(empty, hosting: hosting)
            try saveCapture(try pngData(hosting), name: "run-1220x848-empty-light")
        }
        // A failing status read together with a refused action.
        do {
            let failing = try await ServingWorld.host(serversError: true)
            let (window, hosting) = hostRun(failing, detail: CGSize(width: 1220, height: 848), dark: true)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            failing.servingInventory.mayChange = { _ in false }
            await failing.servingInventory.prepare(.stop, service: try cedarService(app))
            try await Task.sleep(for: .milliseconds(500))
            try saveCapture(try pngData(hosting), name: "run-1220x848-error-dark")
        }
        // Open Serving from another page, naming the launched server's row, on a page already scrolled.
        do {
            let (window, hosting) = hostRun(app, detail: CGSize(width: 740, height: 508), dark: false)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            try scroll(hosting, to: 40)
            app.handoffs.send(ServingFocusRequest(rowID: try serverRowID(app)), as: .openServing)
            try await Task.sleep(for: .milliseconds(500))
            try saveCapture(try pngData(hosting), name: "run-740x508-handoff-light")
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func scrollView(in hosting: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
    }

    private func selectSaveAsEndpoint(_ hosting: NSView) throws {
        let control = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSSegmentedControl }.first)
        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        hosting.layoutSubtreeIfNeeded()
    }

    /// Scrolls the hosted page so the Served models header is at the top of the viewport.
    private func showServingEndpoints(_ app: AppHost, hosting: NSView) async {
        app.handoffs.send(ServingFocusRequest(), as: .openServing)
        await settle(400)
        hosting.layoutSubtreeIfNeeded()
    }

    func testNewEndpointPortsStayInRangeAndUnclaimed() {
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/Alder")
        let server = ServingWorld.server("Cedar", port: 9001, pid: 103, managedByWorkbench: true)
        for port in [80, 1023, 65536, 8766, 9001] {
            XCTAssertFalse(ServeView.isUsablePort(port, slots: [slot], servers: [server]), "\(port)")
        }
        for port in [1024, 8767, 65535] {
            XCTAssertTrue(ServeView.isUsablePort(port, slots: [slot], servers: [server]), "\(port)")
        }
    }

    /// Open Serving selects an endpoint and completes the handoff.
    func testOpenServingSelectsAnEndpointAndFinishesTheRequest() async throws {
        let app = try await ServingWorld.host()
        let (window, hosting) = hostRun(app, detail: CGSize(width: 520, height: 508), dark: false)
        defer { window.close() }
        await settle(400)
        app.handoffs.send(ServingFocusRequest(), as: .openServing)
        await settle()
        XCTAssertNil(app.handoffs[.openServing])
        let text = try renderedLines(try pngData(hosting)).joined(separator: " ")
        XCTAssertTrue(text.contains("8766"), text)
    }

    func testRunListsEachServedThingExactlyOnce() async throws {
        let app = try await ServingWorld.host()
        let (window, hosting) = hostRun(app, detail: CGSize(width: 1220, height: 2600), dark: false)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let lines = try renderedLines(try pngData(hosting))
        // A row's header is its state pill (when it has one) and its name alone on a line.
        func rows(named name: String) -> Int {
            lines.filter { $0.lowercased().range(of: "^\\W*(running\\s+)?\(name)\\W*$", options: .regularExpression) != nil }.count
        }
        XCTAssertTrue(lines.contains { $0.lowercased().contains("serve a model") }, "The newly selected Library model keeps its setup workspace")
        XCTAssertEqual(rows(named: "alder"), 1, "The endpoint and its running server are one row")
        XCTAssertEqual(rows(named: "birch"), 1, "The third-party local service has a row")
        XCTAssertEqual(rows(named: "cedar"), 1, "A launched server without an endpoint has one row")
    }

    func testRunWithNothingServingSaysSo() async throws {
        let app = try await ServingWorld.host(populated: false)
        let (window, hosting) = hostRun(app, detail: CGSize(width: 1220, height: 1800), dark: false)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let lines = try renderedLines(try pngData(hosting)).map { $0.lowercased() }
        XCTAssertTrue(lines.contains { $0.contains("no endpoints") })
    }

    // MARK: Endpoint changes

    private func persistedSlots(_ app: AppHost) throws -> [EndpointSlot] {
        try JSONStore<EndpointFleetConfig>(fileURL: app.endpoint.fleetFileURL).load().first?.slots ?? []
    }

    private func libraryModel(_ app: AppHost, _ path: String) throws -> LibraryModel {
        try XCTUnwrap(app.librarySnapshot?.models.first { $0.item.path == path })
    }

    private func replaceLibrary(_ app: AppHost, _ transform: ([LibraryModel]) -> [LibraryModel]) throws {
        let snapshot = try XCTUnwrap(app.librarySnapshot)
        app.librarySnapshot = LibrarySnapshot(models: transform(snapshot.models), groups: [], hardware: snapshot.hardware, generatedAt: snapshot.generatedAt)
    }

    private func settle(_ milliseconds: Int = 500) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func endSheets(_ window: NSWindow) {
        for sheet in window.sheets { window.endSheet(sheet) }
    }

    private func makeVerification(passing: [(path: String, signature: String)], gate: ProtectionGate) async throws -> VerificationCoordinator {
        let store = VerificationStore(fileURL: WorkbenchStatePaths.hostedTestRoot.appendingPathComponent("run-flows-\(UUID().uuidString).json"))
        for entry in passing {
            try store.upsert(VerificationReport(id: UUID(), modelPath: entry.path, modelSignature: entry.signature, workflowRecordID: nil,
                suiteVersion: CanarySuite.version, canaries: [], tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
                metricsEstimated: false, startedAt: Date(), finishedAt: Date(), outcome: .passed))
        }
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in }, stop: { _ in }),
            prober: GatedProber(gate: gate), readyPollIntervalNanoseconds: 1_000_000, pickPort: { 9999 })
        let verification = VerificationCoordinator(probe: probe, store: store)
        await verification.waitForHistory()
        return verification
    }

    private func addReview(_ app: AppHost, model path: String, port: String) throws -> EndpointChangeReview {
        let outcome = EndpointChanges(appHost: app).reviewAdd(model: try libraryModel(app, path), portText: port, suggestedPort: 8767,
            role: nil, loadOnRequest: true, keepLoaded: false, requireKey: false)
        guard case .review(let review) = outcome else {
            XCTFail("Expected a review for port \(port)")
            throw CancellationError()
        }
        return review
    }

    /// Save as endpoint: a model that left the Library between review and confirmation adds nothing.
    func testAddedEndpointIsNotSavedWhenTheModelLeftTheLibraryBeforeConfirm() async throws {
        let app = try await ServingWorld.host()
        await app.comparison.waitForHistory()
        let review = try addReview(app, model: ServingWorld.selectedModel, port: "9100")
        XCTAssertEqual(try persistedSlots(app).map(\.modelPath), ["/models/Alder"], "Reviewing saves nothing")
        try replaceLibrary(app) { $0.filter { $0.item.path != ServingWorld.selectedModel } }
        let error = await EndpointChanges(appHost: app).confirm(review) { _, _ in }
        XCTAssertEqual(error, "Model, port or memory conditions changed; review the endpoint again.")
        XCTAssertEqual(try persistedSlots(app).map(\.modelPath), ["/models/Alder"])
    }

    /// Save as endpoint: the memory verdict read at review no longer holds at confirmation.
    func testAddedEndpointIsNotSavedWhenTheMemoryVerdictChangedBeforeConfirm() async throws {
        let app = try await ServingWorld.host(extraModels: [("Whale", 900_000_000_000)])
        await app.comparison.waitForHistory()
        let review = try addReview(app, model: "/models/Whale", port: "9100")
        await app.resources.refreshMemory()
        let error = await EndpointChanges(appHost: app).confirm(review) { _, _ in }
        XCTAssertEqual(error, "Model, port or memory conditions changed; review the endpoint again.")
        XCTAssertEqual(try persistedSlots(app).map(\.modelPath), ["/models/Alder"])
    }

    /// Save as endpoint: a port that is out of range or already used is refused with the inline message.
    func testAddedEndpointPortOutsideTheRangeOrInUseIsRefusedAndNothingIsSaved() async throws {
        let app = try await ServingWorld.host()
        await app.comparison.waitForHistory()
        let changes = EndpointChanges(appHost: app)
        let dune = try libraryModel(app, ServingWorld.selectedModel)
        for port in ["80", "70000", "8766", "9001", "11434"] {
            let outcome = changes.reviewAdd(model: dune, portText: port, suggestedPort: 8767, role: nil, loadOnRequest: true, keepLoaded: false, requireKey: false)
            guard case .portRejected(let message) = outcome else { XCTFail("Port \(port) was not refused"); continue }
            XCTAssertEqual(message, "Choose a port from 1024 to 65535 that no endpoint or server uses.", port)
        }
        XCTAssertEqual(try persistedSlots(app).map(\.modelPath), ["/models/Alder"])
        guard case .review = changes.reviewAdd(model: dune, portText: "9100", suggestedPort: 8767, role: nil, loadOnRequest: true, keepLoaded: false, requireKey: false) else {
            return XCTFail("A free port gives a review")
        }
    }

    /// Remove…: the review sheet is up and the saved fleet is untouched until the user confirms.
    func testRemoveChangesTheFleetOnlyWhenConfirmed() async throws {
        let app = try await ServingWorld.host()
        await app.comparison.waitForHistory()
        let changes = EndpointChanges(appHost: app)
        let review = changes.review(slot: try XCTUnwrap(app.endpoint.fleet.slots.first), remove: true)
        let (window, _) = hostRun(app, detail: CGSize(width: 1220, height: 848), dark: false, review: review)
        defer { endSheets(window); window.close() }
        await settle()
        XCTAssertEqual(window.sheets.count, 1, "The removal waits on its confirmation sheet")
        XCTAssertEqual(try persistedSlots(app).map(\.modelPath), ["/models/Alder"])
        let error = await changes.confirm(review) { _, _ in }
        XCTAssertNil(error)
        XCTAssertEqual(try persistedSlots(app), [])
    }

    /// Start…: verification is read again at confirmation, and a changed answer leaves the endpoint stopped.
    func testStartRechecksVerificationAtConfirmationBeforeEnabling() async throws {
        let verification = try await makeVerification(passing: [("/models/Alder", "weights-Alder")], gate: ProtectionGate())
        let app = try await ServingWorld.host(verification: verification)
        await app.comparison.waitForHistory()
        XCTAssertTrue(app.isModelVerified("/models/Alder"))
        let changes = EndpointChanges(appHost: app)
        await app.endpoint.setSlotEnabled(id: try XCTUnwrap(app.endpoint.fleet.slots.first).id, false)
        let stopped = try XCTUnwrap(app.endpoint.fleet.slots.first)
        XCTAssertFalse(stopped.enabled)

        let stale = changes.review(slot: stopped, remove: false)
        XCTAssertFalse(stale.unverified)
        try replaceLibrary(app) { $0.map { $0.item.path == "/models/Alder" ? ServingWorld.model("Alder", path: "/models/Alder", signature: "weights-Alder-changed") : $0 } }
        let refused = await changes.confirm(stale) { _, _ in }
        XCTAssertEqual(refused, "Verification changed; review the endpoint again.")
        XCTAssertEqual(try persistedSlots(app).first?.enabled, false)

        let current = changes.review(slot: stopped, remove: false)
        XCTAssertTrue(current.unverified)
        let started = await changes.confirm(current) { _, _ in }
        XCTAssertNil(started)
        XCTAssertEqual(try persistedSlots(app).first?.enabled, true)
    }

    /// Stop is refused while work holds the model, for the Stop button and for a confirmed removal alike.
    func testStopIsRefusedWhileWorkHoldsTheModel() async throws {
        let gate = ProtectionGate()
        let verification = try await makeVerification(passing: [], gate: gate)
        let app = try await ServingWorld.host(verification: verification)
        await app.comparison.waitForHistory()
        let changes = EndpointChanges(appHost: app)
        let alder = try XCTUnwrap(app.endpoint.fleet.slots.first)
        app.verification.verifyNow(modelPath: alder.modelPath, signature: nil)
        XCTAssertTrue(app.occupancy.blocksStop(modelIdentity: alder.modelPath))

        let message = "Finish the operation using this model before stopping or removing its endpoint."
        let stopped = await changes.stop(alder)
        XCTAssertEqual(stopped, message)
        let removed = await changes.confirm(changes.review(slot: alder, remove: true)) { _, _ in }
        XCTAssertEqual(removed, message)
        XCTAssertEqual(try persistedSlots(app).map(\.enabled), [true])

        await gate.open()
        let deadline = Date().addingTimeInterval(5)
        while app.verification.activeModelPath != nil, Date() < deadline { await settle(20) }
        let released = await changes.stop(alder)
        XCTAssertNil(released)
        XCTAssertEqual(try persistedSlots(app).map(\.enabled), [false])
    }

    // MARK: Pages that are not shown

    /// A confirmation raised on a page the window is not showing waits until that page is shown.
    func testHiddenRunPresentsNoSheetUntilItIsShown() async throws {
        let app = try await ServingWorld.host()
        await app.comparison.waitForHistory()
        let review = EndpointChanges(appHost: app).review(slot: try XCTUnwrap(app.endpoint.fleet.slots.first), remove: true)
        let route = RouteFlag()
        route.active = false
        let (window, _) = hostRun(app, detail: CGSize(width: 1220, height: 848), dark: false, route: route, review: review)
        defer { endSheets(window); window.close() }
        await settle()
        XCTAssertTrue(window.sheets.isEmpty, "A hidden page presents nothing")
        route.active = true
        await settle()
        XCTAssertEqual(window.sheets.count, 1, "The same confirmation appears once the page is shown")
    }

    /// The serving review belongs to the window, so one sheet appears whichever page is shown, and dismissing it cancels and refreshes.
    func testInventoryReviewPresentsExactlyOneSheetFromAnyPageAndDismissRefreshes() async throws {
        let fetches = CallCounter()
        let app = try await ServingWorld.host(onEngineFetch: { fetches.hit("fetch") })
        let suite = try XCTUnwrap(UserDefaults(suiteName: "run-remodel-\(UUID().uuidString)"))
        suite.set(AppRoute.library.rawValue, forKey: AppRoute.selectionStorageKey)
        let hosting = NSHostingView(rootView: AnyView(ContentView(appHost: app).defaultAppStorage(suite).frame(width: 1220, height: 848)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 848), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { endSheets(window); window.close() }
        await settle(800)
        XCTAssertTrue(window.sheets.isEmpty)

        await app.servingInventory.prepare(.stop, service: try cedarService(app))
        XCTAssertNotNil(app.servingInventory.actionReview)
        await settle(800)
        XCTAssertEqual(window.sheets.count, 1)

        let before = fetches.count("fetch")
        window.endSheet(try XCTUnwrap(window.sheets.first))
        await settle(800)
        XCTAssertNil(app.servingInventory.actionReview, "Dismissing cancels the review")
        XCTAssertGreaterThan(fetches.count("fetch"), before, "Dismissing refreshes the serving inventory")
    }

    private func cedarService(_ app: AppHost) throws -> ServingServiceObservation {
        try XCTUnwrap(app.servingInventory.snapshot.services.first { $0.server?.port == 9001 })
    }

    // MARK: Reveals

    private func scroll(_ hosting: NSView, to offset: CGFloat) throws {
        let scroll = try scrollView(in: hosting)
        let flipped = scroll.documentView?.isFlipped ?? true
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? offset : max(0, documentHeight - offset - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.layoutSubtreeIfNeeded()
    }

    private func offset(_ hosting: NSView) throws -> CGFloat {
        let scroll = try scrollView(in: hosting)
        let flipped = scroll.documentView?.isFlipped ?? true
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        let y = scroll.contentView.bounds.origin.y
        return flipped ? y : max(0, documentHeight - y - scroll.contentView.bounds.height)
    }

    private func rowIDs(_ app: AppHost) -> [String] {
        ServingRows.build(slots: app.endpoint.fleet.slots, servers: app.modelWorkflow.servers, snapshot: app.servingInventory.snapshot).map(\.id)
    }

    private func serverRowID(_ app: AppHost) throws -> String {
        try XCTUnwrap(rowIDs(app).first { $0.hasPrefix("server-") })
    }

    /// An explicit handoff selects its endpoint and displays that endpoint’s API address.
    func testOpenServingSelectsEachNamedEndpoint() async throws {
        let app = try await ServingWorld.host()
        let (window, hosting) = hostRun(app, detail: CGSize(width: 520, height: 508), dark: false)
        defer { window.close() }
        await settle(400)
        app.handoffs.send(ServingFocusRequest(rowID: try XCTUnwrap(rowIDs(app).first)), as: .openServing)
        await settle()
        XCTAssertNil(app.handoffs[.openServing])
        XCTAssertTrue(try renderedLines(try pngData(hosting)).joined(separator: " ").contains("8766"))
        app.handoffs.send(ServingFocusRequest(rowID: try serverRowID(app)), as: .openServing)
        await settle()
        XCTAssertNil(app.handoffs[.openServing])
        let text = try renderedLines(try pngData(hosting)).joined(separator: " ")
        XCTAssertTrue(text.contains("9001"), text)
        XCTAssertTrue(text.lowercased().contains("cedar"), text)
    }

    /// A hidden page preserves its pending handoff until it becomes active.
    func testOpenServingWaitsForTheRouteBeforeSelectingAnEndpoint() async throws {
        let app = try await ServingWorld.host()
        let route = RouteFlag(); route.active = false
        let (window, hosting) = hostRun(app, detail: CGSize(width: 520, height: 508), dark: false, route: route)
        defer { window.close() }
        await settle(400)
        app.handoffs.send(ServingFocusRequest(), as: .openServing)
        await settle()
        XCTAssertNotNil(app.handoffs[.openServing])
        route.active = true
        await settle()
        XCTAssertNil(app.handoffs[.openServing])
        XCTAssertTrue(try renderedLines(try pngData(hosting)).joined(separator: " ").contains("8766"))
    }

    /// Memory overrides remain visible alongside the model workspace.
    func testRaisedFleetOverrideStaysVisibleAboveTheWorkspace() async throws {
        let app = try await ServingWorld.host()
        let hold = FleetOverrideHold()
        let (window, hosting) = hostRun(app, detail: CGSize(width: 520, height: 508), dark: false, hold: hold)
        defer { window.close() }
        await settle(400)
        hold.hold("needs 40.0 GB, 12.0 GB short") {}
        await settle()
        let text = try renderedLines(try pngData(hosting)).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("enable anyway"), text)
        XCTAssertTrue(text.contains("40.0"), text)
        XCTAssertNotNil(hold.pending)
    }

    /// Action failures remain visible without moving the model settings.
    func testActionErrorsStayVisibleAboveTheWorkspace() async throws {
        let app = try await ServingWorld.host()
        let (window, hosting) = hostRun(app, detail: CGSize(width: 520, height: 508), dark: false)
        defer { window.close() }
        await settle(400)
        app.servingInventory.mayChange = { _ in false }
        await app.servingInventory.prepare(.stop, service: try cedarService(app))
        await settle()
        XCTAssertNotNil(app.servingInventory.actionError)
        let text = try renderedLines(try pngData(hosting)).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("in use"), text)
    }

    // MARK: Wide rows

    /// The connection remains readable while inference settings retain their saved values.
    func testEndpointWorkspaceKeepsConnectionAndSettingsReadable() async throws {
        let app = try await ServingWorld.host(accelerated: true)
        let (window, hosting) = hostRun(app, detail: CGSize(width: 800, height: 900), dark: false)
        defer { window.close() }
        await settle(400)
        app.handoffs.send(ServingFocusRequest(rowID: try XCTUnwrap(rowIDs(app).first)), as: .openServing)
        await settle()
        let text = try renderedLines(try pngData(hosting)).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("8766"), text)
        XCTAssertTrue(text.contains("inference"), text)
        XCTAssertTrue(text.contains("security"), text)
        XCTAssertTrue(try XCTUnwrap(app.endpoint.fleet.slots.first).inferenceOptions.promptLookup)
    }
}
