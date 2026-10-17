import Foundation
import CryptoKit
import AVFoundation
import XCTest

@testable import mlx_workbench

final class InferenceTaskTests: XCTestCase {
    func testOptInRealEngineClassifierOrMusicTaskAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let kindValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_KIND"],
              let modelPath = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_MODEL"],
              let agentPath = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_AGENT"],
              let evidenceValue = environment["MLX_WORKBENCH_TASK_ACCEPTANCE_EVIDENCE_ROOT"] else {
            throw XCTSkip("Set task kind, absolute model and engine paths, and an isolated evidence root to run local inference.")
        }
        let evidenceRoot = URL(fileURLWithPath: evidenceValue, isDirectory: true)
        guard evidenceRoot.path.hasPrefix("/"), modelPath.hasPrefix("/"), agentPath.hasPrefix("/") else {
            throw XCTSkip("Task acceptance paths must be explicit absolute paths.")
        }
        let kind: TaskKind
        let request: TaskRequest
        switch kindValue {
        case "classification":
            kind = .classification
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: [
                "state": .string("A customer requests a refund for a duplicate monthly charge."),
                "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route the support request to the correct team."), "criteria": .array([.string("billing"), .string("other")])])]),
            ])
        case "music_generation":
            kind = .musicGeneration
            request = TaskRequest(kind: kind, modelPath: modelPath, parameters: ["caption": .string("A short quiet piano instrumental")])
        default:
            throw XCTSkip("Only classification and music-generation acceptance are supported.")
        }
        let stateRoot = evidenceRoot.appendingPathComponent("task-state", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agentPath, taskStateDirectory: stateRoot)
        let started = try await api.taskStart(request)
        XCTAssertEqual(started.kind, kind)
        var receipt = TaskAcceptanceReceipt(kind: kindValue, modelPath: modelPath, agentPath: agentPath,
                                            taskID: started.id, state: started.state.wireValue,
                                            identity: started.identity, requestArtifact: started.request,
                                            resultArtifact: started.result, resultDigest: nil,
                                            outputArtifact: nil, outputDigest: nil, terminal: false)
        try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
        let deadline = Date().addingTimeInterval(20 * 60)
        var current = started
        while current.state.isActive && Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            current = try await api.taskStatus(id: started.id)
            receipt.state = current.state.wireValue
            receipt.identity = current.identity
            receipt.resultArtifact = current.result
            try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
        }
        if current.state.isActive {
            receipt.pendingFailure = "Task exceeded the 20-minute acceptance deadline; cancellation was requested and must settle before state cleanup."
            do {
                current = try await api.taskCancel(id: started.id)
                receipt.state = current.state.wireValue
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
            } catch {
                receipt.pendingFailure = "Task exceeded the deadline and cancellation could not settle: \(error.localizedDescription)"
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
                XCTFail(receipt.pendingFailure ?? "Cancellation did not settle")
                return
            }
            let cancelDeadline = Date().addingTimeInterval(60)
            while current.state.isActive && Date() < cancelDeadline {
                try await Task.sleep(for: .seconds(2))
                do { current = try await api.taskStatus(id: started.id) }
                catch {
                    receipt.pendingFailure = "Cancellation was requested but terminal status remains unknown: \(error.localizedDescription)"
                    try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
                    XCTFail(receipt.pendingFailure ?? "Cancellation status is unknown")
                    return
                }
                receipt.state = current.state.wireValue
                receipt.identity = current.identity
                receipt.resultArtifact = current.result
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
            }
            guard !current.state.isActive else {
                receipt.pendingFailure = "Cancellation was requested, but the engine still reports an active task. State was retained."
                try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
                XCTFail(receipt.pendingFailure ?? "Task cancellation remains active")
                return
            }
        }
        XCTAssertFalse(current.state.isActive, "Task \(started.id) did not reach a terminal state")
        XCTAssertEqual(current.state, .succeeded, current.error?.message ?? "Task failed without an engine error detail")
        let verifiedModel = try await api.taskVerifyModel(id: started.id)
        XCTAssertTrue(verifiedModel.matches)
        XCTAssertEqual(verifiedModel.modelPath, modelPath)

        let savedResult = try await api.taskResult(id: started.id)
        let verifiedJSON = try await TaskArtifactVerifier.verify(reference: savedResult.artifact, taskID: started.id, root: stateRoot)
        XCTAssertNotNil(verifiedJSON.json)
        receipt.resultArtifact = savedResult.artifact
        receipt.resultDigest = savedResult.artifact.sha256
        if kind == .musicGeneration {
            let output = try XCTUnwrap(savedResult.result?.objectValue?["output_artifact"])
            let reference = try JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(output))
            let verifiedAudio = try await TaskArtifactVerifier.verify(reference: reference, taskID: started.id, root: stateRoot)
            XCTAssertEqual(verifiedAudio.url.pathExtension.lowercased(), "wav")
            let audioFile = try AVAudioFile(forReading: verifiedAudio.url)
            XCTAssertGreaterThan(audioFile.length, 0)
            XCTAssertGreaterThan(audioFile.processingFormat.sampleRate, 0)
            XCTAssertGreaterThan(audioFile.processingFormat.channelCount, 0)
            receipt.outputArtifact = reference
            receipt.outputDigest = reference.sha256
        } else {
            let answer = try XCTUnwrap(savedResult.result?.objectValue?["answers"]?.objectValue?["route"]?.objectValue?["choice"]?.stringValue)
            XCTAssertEqual(answer, "billing")
        }
        receipt.state = current.state.wireValue
        receipt.identity = current.identity
        receipt.terminal = !current.state.isActive
        try Self.write(receipt, to: evidenceRoot.appendingPathComponent("receipt-\(started.id).json"))
    }

    private static func write(_ receipt: TaskAcceptanceReceipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }

    func testVersionedTaskContractsDecodeAndPreserveUnsupportedValues() throws {
        let decoder = JSONDecoder()
        let capabilities = try decoder.decode(TaskCapabilities.self, from: Data(#"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[{"kind":"classification","result_schema":"decide/1","cancellation":true,"requires_local_model":true}]}"#.utf8))
        XCTAssertTrue(capabilities.isSupported)
        XCTAssertEqual(capabilities.tasks.first?.kind, .classification)

        let request = try decoder.decode(TaskRequest.self, from: Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"quiet piano","future_setting":{"x":1}}}"#.utf8))
        XCTAssertTrue(request.isSupported)
        XCTAssertEqual(request.kind, .musicGeneration)
        XCTAssertEqual(request.parameters["future_setting"], .object(["x": .number(1)]))

        let unsupported = try decoder.decode(TaskRequest.self, from: Data(#"{"schema":"task-request/9","kind":"video_generation","model_path":"/Models/video","parameters":{}}"#.utf8))
        XCTAssertFalse(unsupported.isSupported)
        XCTAssertEqual(unsupported.kind, .unsupported("video_generation"))

        let record = try decoder.decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        XCTAssertTrue(record.isSupported)
        XCTAssertEqual(record.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(record.state, .starting)

        let unknownRecord = Self.publicSummary
            .replacingOccurrences(of: "\"state\":\"starting\"", with: "\"state\":\"paused\"")
            .replacingOccurrences(of: "\"kind\":\"classification\"", with: "\"kind\":\"video_generation\"")
        let decodedUnknown = try decoder.decode(TaskRecord.self, from: Data(unknownRecord.utf8))
        XCTAssertFalse(decodedUnknown.isSupported)
        XCTAssertEqual(decodedUnknown.state, .unsupported("paused"))
        XCTAssertEqual(decodedUnknown.kind, .unsupported("video_generation"))

        let result = try decoder.decode(TaskResultResponse.self, from: Data(#"{"task":\#(Self.publicSummary),"artifact":{"path":"/tasks/artifacts/11111111-1111-4111-8111-111111111111/result.json","sha256":"\#(String(repeating: "a", count: 64))","bytes":9},"inline":true,"result":{"answers":{"future":{"type":"new","future_metric":2}}}}"#.utf8))
        XCTAssertTrue(result.inline)
        XCTAssertEqual(result.result?.objectValue?["answers"]?.objectValue?["future"]?.objectValue?["future_metric"], .number(2))
    }

    func testResultProjectionKeepsUnknownFieldsAndMissingMetricsUnknown() throws {
        let raw = JSONValue.object([
            "answers": .object([
                "route": .object(["type": .string("choice"), "choice": .string("billing"), "confidence": .number(0.8),
                                  "probabilities": .object(["billing": .number(0.8)]), "future_metric": .number(0.7)]),
                "rating": .object(["type": .string("score"), "score": .number(2.5), "legend": .object(["0": .string("low")]), "probabilities": .object(["0": .number(0.4)])]),
            ]),
            "future_top_level": .array([.string("preserved")]),
        ])
        let projection = TaskResultProjection(raw: raw)
        XCTAssertEqual(projection.raw, raw)
        XCTAssertEqual(projection.answers["route"]?.type, "choice")
        XCTAssertEqual(projection.answers["route"]?.choice, "billing")
        XCTAssertEqual(projection.answers["route"]?.confidence, 0.8)
        XCTAssertEqual(projection.answers["route"]?.probabilities?["billing"], .number(0.8))
        XCTAssertEqual(projection.answers["rating"]?.score, 2.5)
        XCTAssertNil(projection.answers["rating"]?.confidence)
        XCTAssertEqual(projection.answers["rating"]?.legend?["0"], .string("low"))
        XCTAssertEqual(projection.raw.objectValue?["future_top_level"], .array([.string("preserved")]))
    }

    func testClassificationDraftSerializesOrderedChoiceScoreAndNoulQuestions() throws {
        var draft = ClassificationDraft(state: "Refund request", questions: [])
        draft.questions = [
            ClassificationQuestionDraft(name: "route", instructions: "Choose a team", type: .choice, options: ["billing", "support"]),
            ClassificationQuestionDraft(name: "urgency", instructions: "Rate the urgency", type: .score, options: ["low", "medium", "high"]),
            ClassificationQuestionDraft(name: "duplicate", instructions: "Is this duplicated?", type: .noul,
                                        falseDescription: "No duplicate", trueDescription: "Duplicate charge"),
        ]
        let request = try draft.request(modelPath: "/Models/laya")
        XCTAssertEqual(request.parameters["state"], .string("Refund request"))
        let questions = try XCTUnwrap(request.parameters["questions"]?.objectValue)
        XCTAssertEqual(questions["route"]?.objectValue?["criteria"], .array([.string("billing"), .string("support")]))
        XCTAssertEqual(questions["urgency"]?.objectValue?["criteria"], .array([.string("low"), .string("medium"), .string("high")]))
        XCTAssertEqual(questions["duplicate"]?.objectValue?["criteria"]?.objectValue?["true"], .string("Duplicate charge"))
    }

    func testReuseRefusesUnsupportedStructuredStateWithoutReplacingDraft() throws {
        let originalState = "keep this draft"
        var draft = ClassificationDraft(state: originalState)
        let request = TaskRequest(kind: .classification, modelPath: "/Models/laya", parameters: [
            "state": .object(["ticket": .string("refund")]),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route"), "criteria": .array([.string("billing"), .string("other")])])]),
        ])
        XCTAssertThrowsError(try draft.load(request))
        XCTAssertEqual(draft.state, originalState)
        let unknownQuestionValue = TaskRequest(kind: .classification, modelPath: "/Models/laya", parameters: [
            "state": .string("ticket"),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route"), "criteria": .array([.string("billing"), .string("other")]), "future_semantics": .object(["weight": .number(2)])])]),
        ])
        XCTAssertThrowsError(try draft.load(unknownQuestionValue))
        XCTAssertEqual(draft.state, originalState)
    }

    func testMusicDraftUsesEngineInstrumentalDefaultsAndValidatesRanges() throws {
        var draft = MusicTaskDraft(caption: "Quiet piano")
        let request = try draft.request(modelPath: "/Models/music")
        XCTAssertNil(request.parameters["lyrics"])
        XCTAssertEqual(request.parameters["duration"], .number(15))
        XCTAssertEqual(request.parameters["steps"], .number(30))
        XCTAssertEqual(request.parameters["seed"], .number(42))
        draft.duration = 361
        XCTAssertThrowsError(try draft.request(modelPath: "/Models/music"))
    }

    func testInvalidMusicReuseLeavesExistingDraftUntouched() throws {
        var draft = MusicTaskDraft(caption: "Keep this setup", lyrics: "Keep these words", duration: 8, steps: 12, seed: 7)
        let invalid = TaskRequest(kind: .musicGeneration, modelPath: "/Models/music", parameters: [
            "caption": .string("Invalid recorded setup"), "duration": .number(361),
        ])
        XCTAssertThrowsError(try draft.load(invalid))
        XCTAssertEqual(draft.caption, "Keep this setup")
        XCTAssertEqual(draft.lyrics, "Keep these words")
        XCTAssertEqual(draft.duration, 8)
        XCTAssertEqual(draft.steps, 12)
        XCTAssertEqual(draft.seed, 7)
    }

    @MainActor
    func testCoordinatorStartsOnlyReadyMatchingModelAndRetainsDraft() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        coordinator.classificationDraft.state = "Refund request"
        coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
        let model = Self.libraryModel(type: .classification)
        await coordinator.start(kind: .classification, model: model)
        let evidence = await api.startEvidence()
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.parameters["state"], .string("Refund request"))
        let selectedID = coordinator.selectedTask?.id
        let retainedState = coordinator.classificationDraft.state
        XCTAssertEqual(selectedID, record.id)
        XCTAssertEqual(retainedState, "Refund request")

        let wrongType = Self.libraryModel(type: .musicGeneration)
        await coordinator.start(kind: .classification, model: wrongType)
        let afterWrongType = await api.startEvidence()
        XCTAssertEqual(afterWrongType.count, 1)
    }

    @MainActor
    func testCoordinatorKeepsUnknownStartUnownedUntilExplicitRefresh() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, startUnknown: true)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        coordinator.classificationDraft.state = "Refund request"
        coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
        await coordinator.start(kind: .classification, model: Self.libraryModel(type: .classification))
        let unknownBeforeRefresh = coordinator.startOutcomeUnknown
        let selectedBeforeRefresh = coordinator.selectedTask
        let recentBeforeRefresh = coordinator.recent
        XCTAssertTrue(unknownBeforeRefresh)
        XCTAssertNil(selectedBeforeRefresh)
        XCTAssertTrue(recentBeforeRefresh.isEmpty)
        await coordinator.refreshRecent()
        let unknownAfterRefresh = coordinator.startOutcomeUnknown
        let recentAfterRefresh = coordinator.recent
        XCTAssertFalse(unknownAfterRefresh)
        XCTAssertTrue(recentAfterRefresh.isEmpty)
    }

    @MainActor
    func testCancelIntentIsClearedWhenCapabilitiesRejectOrFailBeforeStart() async throws {
        let rejected = try JSONDecoder().decode(TaskCapabilities.self, from: Data(#"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[]}"#.utf8))
        let activeRecord = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        for failure in [FakeInferenceTaskAPI.FirstCapabilityOutcome.rejected, .failed] {
            let api = FakeInferenceTaskAPI(record: activeRecord, capabilities: Self.taskCapabilities,
                                           firstCapabilities: rejected, firstCapabilityOutcome: failure,
                                           gateFirstCapabilities: true)
            let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
            coordinator.classificationDraft.state = "Refund request"
            coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
            let model = Self.libraryModel(type: .classification)
            let attempt = Task { await coordinator.start(kind: .classification, model: model) }
            await api.waitForFirstCapabilities()
            coordinator.requestCancelDuringStart()
            await api.releaseFirstCapabilities()
            await attempt.value

            let pendingAfterFailure = coordinator.cancellationPending
            XCTAssertFalse(pendingAfterFailure)
            let nextAttempt = Task { await coordinator.start(kind: .classification, model: model) }
            await nextAttempt.value
            let cancelledIDs = await api.cancelledIDs()
            XCTAssertTrue(cancelledIDs.isEmpty)
        }
    }

    @MainActor
    func testCancelDuringStartUsesOnlyTheReturnedTaskID() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, gateFirstCapabilities: true)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        coordinator.classificationDraft.state = "Refund request"
        coordinator.classificationDraft.questions[0].instructions = "Choose the correct team"
        let attempt = Task { await coordinator.start(kind: .classification, model: Self.libraryModel(type: .classification)) }
        await api.waitForFirstCapabilities()
        coordinator.requestCancelDuringStart()
        await api.releaseFirstCapabilities()
        await attempt.value

        let cancelledIDs = await api.cancelledIDs()
        XCTAssertEqual(cancelledIDs, [record.id])
    }

    @MainActor
    func testReuseUsesTheClickedRecentRecordWithoutASelectedTask() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let model = Self.libraryModel(type: .classification)
        let request = TaskRequest(kind: .classification, modelPath: model.item.path, parameters: [
            "state": .string("Refund request from the history row"),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Choose a team"), "criteria": .array([.string("billing"), .string("support")])])]),
        ])
        let requestData = try JSONEncoder().encode(request)
        let requestURL = try fixture.write("request.json", data: requestData)
        let reference = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecord(id: fixture.taskID, kind: "classification", state: "succeeded",
                                         modelPath: model.item.path, request: reference)
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)
        await coordinator.refreshRecent()
        let selectionBeforeReuse = coordinator.selectedTask
        XCTAssertNil(selectionBeforeReuse)

        await coordinator.reuse(id: record.id, for: model)

        let reusedState = coordinator.classificationDraft.state
        let error = coordinator.error
        XCTAssertEqual(reusedState, "Refund request from the history row")
        XCTAssertNil(error)
    }

    @MainActor
    func testStatusReadFailureKeepsLastKnownTaskAndShowsReadError() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record], statusFails: true)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        await coordinator.refreshRecent()
        await coordinator.selectTask(id: record.id)

        let selectedID = coordinator.selectedTask?.id
        let readError = coordinator.readError
        XCTAssertEqual(selectedID, record.id)
        XCTAssertNotNil(readError)
        await api.allowStatusReads()
        await coordinator.refresh(id: record.id)
        let recoveredError = coordinator.readError
        XCTAssertNil(recoveredError)
    }

    @MainActor
    func testHistoryReadFailureKeepsLastKnownRowsAndCanRetry() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"))
        await coordinator.refreshRecent()
        await api.failListReads()
        await coordinator.refreshRecent()
        let staleRows = coordinator.recent
        let readError = coordinator.readError
        XCTAssertEqual(staleRows.map(\.id), [record.id])
        XCTAssertNotNil(readError)
        await api.allowListReads()
        await coordinator.refreshRecent()
        let recoveredRows = coordinator.recent
        let recoveredError = coordinator.readError
        XCTAssertEqual(recoveredRows.map(\.id), [record.id])
        XCTAssertNil(recoveredError)
    }

    @MainActor
    func testPollingStopsAfterExplicitDeactivation() async throws {
        let record = try JSONDecoder().decode(TaskRecord.self, from: Data(Self.publicSummary.utf8))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, listedRecords: [record])
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: URL(fileURLWithPath: "/tasks"), pollInterval: .milliseconds(1))
        await coordinator.refreshRecent()
        await coordinator.selectTask(id: record.id)
        let callsBeforePolling = await api.statusCallCount()
        coordinator.startPolling(id: record.id, owner: "model-inspector")
        await api.waitForStatusCall(after: callsBeforePolling)
        coordinator.startPolling(id: record.id, owner: "recent-task-sheet")
        coordinator.stopPolling(owner: "recent-task-sheet")
        let callsAfterSheetCloses = await api.statusCallCount()
        await api.waitForStatusCall(after: callsAfterSheetCloses)
        let callsAfterInspectorContinues = await api.statusCallCount()
        XCTAssertGreaterThan(callsAfterInspectorContinues, callsAfterSheetCloses)
        coordinator.stopPolling(owner: "model-inspector")
        let callsAtStop = await api.statusCallCount()
        try await Task.sleep(for: .milliseconds(20))
        let callsAfterStop = await api.statusCallCount()
        XCTAssertEqual(callsAfterStop, callsAtStop)
    }

    @MainActor
    func testExportAudioCopiesOnlyVerifiedTaskOwnedWAV() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = TaskRequest(kind: .musicGeneration, modelPath: "/Models/music", parameters: ["caption": .string("Quiet piano")])
        let requestData = try JSONEncoder().encode(request)
        let requestURL = try fixture.write("request.json", data: requestData)
        let requestReference = fixture.reference(requestURL, data: requestData)
        let record = try Self.taskRecord(id: fixture.taskID, kind: "music_generation", state: "succeeded",
                                         modelPath: request.modelPath, request: requestReference)
        let audioData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        let audioURL = try fixture.write("output.wav", data: audioData)
        let audioReference = fixture.reference(audioURL, data: audioData)
        let encodedReference = try JSONEncoder().encode(audioReference)
        let outputValue = try JSONDecoder().decode(JSONValue.self, from: encodedReference)
        let resultData = try JSONEncoder().encode(JSONValue.object(["output_artifact": outputValue]))
        let resultURL = try fixture.write("result.json", data: resultData)
        let resultReference = fixture.reference(resultURL, data: resultData)
        let response = TaskResultResponse(task: record, artifact: resultReference, inline: true,
                                          result: .object(["output_artifact": outputValue]))
        let api = FakeInferenceTaskAPI(record: record, capabilities: Self.taskCapabilities, resultResponse: response)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: fixture.root)
        let destination = fixture.root.appendingPathComponent("exports/result.wav")

        try await coordinator.exportAudio(id: record.id, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), audioData)
    }

    private static let taskCapabilities = try! JSONDecoder().decode(TaskCapabilities.self, from: Data(#"{"schema":"task-capabilities/1","request_schema":"task-request/1","run_schema":"task-run/1","tasks":[{"kind":"classification","result_schema":"decide/1","cancellation":true,"requires_local_model":true,"model_verification":true},{"kind":"music_generation","result_schema":"music/1","cancellation":true,"requires_local_model":true,"model_verification":true}]}"#.utf8))

    private static func libraryModel(type: ModelTaskType) -> LibraryModel {
        let item = ModelItem(path: "/Models/\(type.rawValue)", name: "local-model", bytes: 100, modifiedAt: nil,
                             shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil,
                             structure: nil, signature: nil, companion: nil, readable: true, status: "ready",
                             outputs: [], tensorCount: nil, error: nil,
                             task: ModelTask(type: type, useCases: [], source: "test", confidence: "high"))
        return LibraryModel(item: item, readiness: .ready)
    }

    private static func taskRecord(id: String, kind: String, state: String, modelPath: String,
                                   request: TaskArtifactReference) throws -> TaskRecord {
        let summary = #"{"schema":"task-run/1","id":"\#(id)","kind":"\#(kind)","state":"\#(state)","model_path":"\#(modelPath)","created_at":"2026-10-17T12:00:00+00:00","started_at":null,"completed_at":"2026-10-17T12:01:00+00:00","cancel_requested":false,"identity":{"backend":"mlx-embeddings","backend_version":"1.0.0","engine_version":"0.7.0","python_version":"3.12.0","model_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"request":{"path":"\#(request.path)","sha256":"\#(request.sha256)","bytes":\#(request.bytes)},"result":null,"error":null,"supervisor":null,"execution":null,"execution_unresolved":false}"#
        return try JSONDecoder().decode(TaskRecord.self, from: Data(summary.utf8))
    }

    func testArtifactVerifierAcceptsTaskOwnedJSONAndAudioAndDecodesRequest() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let request = Data(#"{"schema":"task-request/1","kind":"classification","model_path":"/Models/laya","parameters":{"state":"refund request","questions":{"route":{"type":"choice","instructions":"Route this request","criteria":["billing","other"]}}}}"#.utf8)
        let result = Data(#"{"answers":{"route":{"type":"choice","choice":"billing","future":true}}}"#.utf8)
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        let requestURL = try fixture.write("request.json", data: request)
        let resultURL = try fixture.write("result.json", data: result)
        let audioURL = try fixture.write("output.wav", data: audio)

        let verifiedRequest = try await TaskArtifactVerifier.verify(reference: fixture.reference(requestURL, data: request), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedRequest.request?.kind, .classification)
        XCTAssertEqual(verifiedRequest.data, request)
        let verifiedResult = try await TaskArtifactVerifier.verify(reference: fixture.reference(resultURL, data: result), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedResult.json?.objectValue?["answers"]?.objectValue?["route"]?.objectValue?["future"], .bool(true))
        let verifiedAudio = try await TaskArtifactVerifier.verify(reference: fixture.reference(audioURL, data: audio), taskID: fixture.taskID, root: fixture.root)
        XCTAssertEqual(verifiedAudio.url, audioURL)
        XCTAssertNil(verifiedAudio.json)
    }

    func testArtifactVerifierRejectsUnownedPathsChangedBytesAndInvalidRequests() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let valid = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"music"}}"#.utf8)
        let path = try fixture.write("request.json", data: valid)
        let reference = fixture.reference(path, data: valid)

        await assertRejected(TaskArtifactReference(path: path.path + "/../request.json", sha256: reference.sha256, bytes: reference.bytes), taskID: fixture.taskID, root: fixture.root)
        await assertRejected(reference, taskID: "../\(fixture.taskID)", root: fixture.root)
        await assertRejected(TaskArtifactReference(path: path.path, sha256: String(repeating: "0", count: 64), bytes: reference.bytes), taskID: fixture.taskID, root: fixture.root)
        await assertRejected(TaskArtifactReference(path: path.path, sha256: reference.sha256, bytes: reference.bytes + 1), taskID: fixture.taskID, root: fixture.root)
        await assertRejected(TaskArtifactReference(path: fixture.root.appendingPathComponent("outside.json").path, sha256: reference.sha256, bytes: reference.bytes), taskID: fixture.taskID, root: fixture.root)

        let invalidRequest = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"relative","parameters":{}}"#.utf8)
        try invalidRequest.write(to: path)
        await assertRejected(fixture.reference(path, data: invalidRequest), taskID: fixture.taskID, root: fixture.root)

        let extraMember = Data(#"{"schema":"task-request/1","kind":"music_generation","model_path":"/Models/music","parameters":{"caption":"music"},"future_semantics":{"mode":"x"}}"#.utf8)
        try extraMember.write(to: path)
        await assertRejected(fixture.reference(path, data: extraMember), taskID: fixture.taskID, root: fixture.root)

        let missing = fixture.root.appendingPathComponent("artifacts/\(fixture.taskID)/missing.json")
        await assertRejected(TaskArtifactReference(path: missing.path, sha256: String(repeating: "a", count: 64), bytes: 0), taskID: fixture.taskID, root: fixture.root)
    }

    func testArtifactVerifierRejectsSymlinkAndNonRegularArtifact() async throws {
        let fixture = try ArtifactFixture()
        defer { fixture.remove() }
        let data = Data("payload".utf8)
        let external = fixture.root.appendingPathComponent("outside")
        try data.write(to: external)
        let link = fixture.artifactDirectory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        await assertRejected(fixture.reference(link, data: data), taskID: fixture.taskID, root: fixture.root)

        let directory = fixture.artifactDirectory.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        await assertRejected(TaskArtifactReference(path: directory.path, sha256: String(repeating: "a", count: 64), bytes: 0), taskID: fixture.taskID, root: fixture.root)

        let pipe = fixture.artifactDirectory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        await assertRejected(TaskArtifactReference(path: pipe.path, sha256: String(repeating: "a", count: 64), bytes: 0), taskID: fixture.taskID, root: fixture.root)

        let intermediate = fixture.root.appendingPathComponent("artifacts/\(fixture.taskID)-link")
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: fixture.artifactDirectory)
        let throughDirectoryLink = intermediate.appendingPathComponent("linked.json")
        await assertRejected(fixture.reference(throughDirectoryLink, data: data), taskID: fixture.taskID, root: fixture.root)
    }

    private func assertRejected(_ reference: TaskArtifactReference, taskID: String, root: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await TaskArtifactVerifier.verify(reference: reference, taskID: taskID, root: root)
            XCTFail("Expected unsafe or invalid artifact to be rejected", file: file, line: line)
        } catch { }
    }

    private static let publicSummary = #"{"schema":"task-run/1","id":"11111111-1111-4111-8111-111111111111","kind":"classification","state":"starting","model_path":"/Models/laya","created_at":"2026-10-17T12:00:00+00:00","started_at":null,"completed_at":null,"cancel_requested":false,"identity":{"backend":"mlx-embeddings","backend_version":"1.0.0","engine_version":"0.7.0","python_version":"3.12.0","model_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"request":{"path":"/tasks/artifacts/11111111-1111-4111-8111-111111111111/request.json","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":100},"result":null,"error":null,"supervisor":null,"execution":null,"execution_unresolved":false}"#
}

private actor FakeInferenceTaskAPI: InferenceTaskAPI {
    enum FirstCapabilityOutcome { case rejected, failed }

    private let record: TaskRecord
    private let capabilities: TaskCapabilities
    private let startUnknown: Bool
    private let firstCapabilities: TaskCapabilities?
    private let firstCapabilityOutcome: FirstCapabilityOutcome?
    private let gateFirstCapabilities: Bool
    private let listedRecords: [TaskRecord]
    private var statusFails: Bool
    private var listFails = false
    private let resultResponse: TaskResultResponse?
    private var requests: [TaskRequest] = []
    private var capabilityCalls = 0
    private var firstCapabilitiesReached = false
    private var firstCapabilitiesWaiter: CheckedContinuation<Void, Never>?
    private var firstCapabilitiesRelease: CheckedContinuation<Void, Never>?
    private var statusCalls = 0
    private var statusWaiter: CheckedContinuation<Void, Never>?
    private var statusWaitAfter = 0
    private var cancelled: [String] = []

    init(record: TaskRecord, capabilities: TaskCapabilities, startUnknown: Bool = false,
         firstCapabilities: TaskCapabilities? = nil, firstCapabilityOutcome: FirstCapabilityOutcome? = nil,
         gateFirstCapabilities: Bool = false, listedRecords: [TaskRecord] = [], statusFails: Bool = false,
         resultResponse: TaskResultResponse? = nil) {
        self.record = record
        self.capabilities = capabilities
        self.startUnknown = startUnknown
        self.firstCapabilities = firstCapabilities
        self.firstCapabilityOutcome = firstCapabilityOutcome
        self.gateFirstCapabilities = gateFirstCapabilities
        self.listedRecords = listedRecords
        self.statusFails = statusFails
        self.resultResponse = resultResponse
    }

    func taskCapabilities() async throws -> TaskCapabilities {
        capabilityCalls += 1
        if capabilityCalls == 1 && gateFirstCapabilities {
            firstCapabilitiesReached = true
            firstCapabilitiesWaiter?.resume()
            firstCapabilitiesWaiter = nil
            await withCheckedContinuation { firstCapabilitiesRelease = $0 }
        }
        if capabilityCalls == 1, let firstCapabilityOutcome {
            switch firstCapabilityOutcome {
            case .rejected: return firstCapabilities ?? capabilities
            case .failed: throw TaskProtocolError.unsupportedCapability
            }
        }
        return capabilities
    }
    func taskStart(_ request: TaskRequest) async throws -> TaskRecord {
        requests.append(request)
        if startUnknown { throw TaskStartOutcomeUnknown() }
        return record
    }
    func taskStatus(id: String) async throws -> TaskRecord {
        statusCalls += 1
        if statusCalls > statusWaitAfter { statusWaiter?.resume(); statusWaiter = nil }
        if statusFails { throw TaskProtocolError.unsupportedCapability }
        return record
    }
    func taskList(limit: Int) async throws -> TaskPage {
        if listFails { throw TaskProtocolError.unsupportedCapability }
        return TaskPage(tasks: listedRecords, hasMore: false)
    }
    func taskResult(id: String) async throws -> TaskResultResponse {
        guard let resultResponse else { throw TaskProtocolError.unsupportedCapability }
        return resultResponse
    }
    func taskCancel(id: String) async throws -> TaskRecord { cancelled.append(id); return record }
    func taskVerifyModel(id: String) async throws -> TaskModelVerification {
        TaskModelVerification(id: id, modelPath: record.modelPath, modelFingerprint: "test", matches: true)
    }
    func startEvidence() -> [TaskRequest] { requests }
    func cancelledIDs() -> [String] { cancelled }
    func waitForFirstCapabilities() async {
        if firstCapabilitiesReached { return }
        await withCheckedContinuation { firstCapabilitiesWaiter = $0 }
    }
    func releaseFirstCapabilities() { firstCapabilitiesRelease?.resume(); firstCapabilitiesRelease = nil }
    func waitForStatusCall(after previousCount: Int) async {
        if statusCalls > previousCount { return }
        statusWaitAfter = previousCount
        await withCheckedContinuation { statusWaiter = $0 }
    }
    func statusCallCount() -> Int { statusCalls }
    func allowStatusReads() { statusFails = false }
    func failListReads() { listFails = true }
    func allowListReads() { listFails = false }
}

private struct TaskAcceptanceReceipt: Codable {
    let kind: String
    let modelPath: String
    let agentPath: String
    let taskID: String
    var state: String
    var identity: TaskIdentitySummary
    let requestArtifact: TaskArtifactReference
    var resultArtifact: TaskArtifactReference?
    var resultDigest: String?
    var outputArtifact: TaskArtifactReference?
    var outputDigest: String?
    var terminal: Bool
    var pendingFailure: String?

    init(kind: String, modelPath: String, agentPath: String, taskID: String, state: String,
         identity: TaskIdentitySummary, requestArtifact: TaskArtifactReference,
         resultArtifact: TaskArtifactReference?, resultDigest: String?, outputArtifact: TaskArtifactReference?,
         outputDigest: String?, terminal: Bool, pendingFailure: String? = nil) {
        self.kind = kind
        self.modelPath = modelPath
        self.agentPath = agentPath
        self.taskID = taskID
        self.state = state
        self.identity = identity
        self.requestArtifact = requestArtifact
        self.resultArtifact = resultArtifact
        self.resultDigest = resultDigest
        self.outputArtifact = outputArtifact
        self.outputDigest = outputDigest
        self.terminal = terminal
        self.pendingFailure = pendingFailure
    }
}

private struct ArtifactFixture {
    let root: URL
    let taskID = "11111111-1111-4111-8111-111111111111"
    let artifactDirectory: URL

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/mlx-workbench-tests", isDirectory: true)
            .appendingPathComponent("mlx-task-artifact-test-\(UUID().uuidString)", isDirectory: true)
        artifactDirectory = root.appendingPathComponent("artifacts/\(taskID)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func write(_ name: String, data: Data) throws -> URL {
        let path = artifactDirectory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return path
    }

    func reference(_ path: URL, data: Data) -> TaskArtifactReference {
        TaskArtifactReference(path: path.path, sha256: data.sha256Hex, bytes: data.count)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
