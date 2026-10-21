import AppKit
import Foundation
import XCTest

@testable import mlx_workbench

final class WorkbenchAPISubprocessTests: XCTestCase {
    private static var taskSummary: [String: Any] {
        ["schema": "task-run/1", "id": "11111111-1111-4111-8111-111111111111", "kind": "music_generation", "state": "starting",
         "model_path": "/Models/MiniMax Music", "created_at": "2026-10-17T12:00:00+00:00", "started_at": NSNull(), "completed_at": NSNull(),
         "cancel_requested": false, "identity": ["backend": "mlx-audio", "backend_version": "1.0.0", "engine_version": "0.7.0", "python_version": "3.12.0", "model_fingerprint": String(repeating: "a", count: 64)],
         "request": ["path": "/tasks/artifacts/11111111-1111-4111-8111-111111111111/request.json", "sha256": String(repeating: "a", count: 64), "bytes": 20],
         "result": NSNull(), "error": NSNull(), "supervisor": NSNull(), "execution": NSNull(), "execution_unresolved": false]
    }

    func testTaskAPIUsesTypedEnvelopesSafeStagingAndReadOnlyModelVerification() async throws {
        let state = URL(fileURLWithPath: "/isolated task state")
        let request = TaskRequest(kind: .musicGeneration, modelPath: "/Models/MiniMax Music", parameters: ["caption": .string("soft piano — रात")])
        let taskJSON = Self.taskSummary
        let recorder = AgentCallRecorder()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", taskEnvelopeCommand: { _, argv, _ in
            recorder.record(path: "/fixture", argv: argv, isScout: false, timeout: 300)
            XCTAssertTrue(argv.contains("--json"))
            if argv.contains("start") {
                let file = URL(fileURLWithPath: argv[argv.firstIndex(of: "--request")! + 1])
                XCTAssertEqual(try JSONDecoder().decode(TaskRequest.self, from: Data(contentsOf: file)), request)
                var info = stat(); XCTAssertEqual(stat(file.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, 0o600)
                return ["status": "ok", "data": ["task": taskJSON]]
            }
            if argv.contains("capabilities") {
                return ["status": "ok", "data": ["schema": "task-capabilities/1", "request_schema": "task-request/1", "run_schema": "task-run/1", "tasks": [["kind": "music_generation", "result_schema": "music-generation/1", "cancellation": true, "requires_local_model": true, "model_verification": true]]]]
            }
            if argv.contains("verify-model") {
                return ["status": "ok", "data": ["id": "11111111-1111-4111-8111-111111111111", "model_path": "/Models/MiniMax Music", "model_fingerprint": String(repeating: "a", count: 64), "matches": true]]
            }
            if argv.contains("list") { return ["status": "ok", "data": ["tasks": [taskJSON], "has_more": true]] }
            if argv.contains("result") { return ["status": "ok", "data": ["task": taskJSON, "artifact": ["path": "/tasks/artifacts/11111111-1111-4111-8111-111111111111/result.json", "sha256": String(repeating: "a", count: 64), "bytes": 20], "inline": false, "result": NSNull()]] }
            if argv.contains("cancel") { return ["status": "ok", "data": ["task": taskJSON]] }
            return ["status": "ok", "data": ["task": taskJSON]]
        }, taskStateDirectory: state)

        let capabilities = try await api.taskCapabilities()
        XCTAssertTrue(capabilities.tasks.first?.modelVerification == true)
        let started = try await api.taskStart(request)
        XCTAssertEqual(started.id, "11111111-1111-4111-8111-111111111111")
        let requestPath = recorder.values.first(where: { $0.argv.contains("start") })!.argv[recorder.values.first(where: { $0.argv.contains("start") })!.argv.firstIndex(of: "--request")! + 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestPath))
        let status = try await api.taskStatus(id: started.id)
        let page = try await api.taskList(limit: 40)
        let result = try await api.taskResult(id: started.id)
        let cancelled = try await api.taskCancel(id: started.id)
        let verification = try await api.taskVerifyModel(id: started.id)
        XCTAssertEqual(status.state, .starting)
        XCTAssertEqual(page.tasks.count, 1)
        XCTAssertFalse(result.inline)
        XCTAssertEqual(cancelled.id, started.id)
        XCTAssertTrue(verification.matches)
        XCTAssertTrue(recorder.values.filter { !$0.argv.contains("capabilities") }.allSatisfy { call in
            guard let index = call.argv.firstIndex(of: "--state-dir") else { return false }
            return call.argv[index + 1] == state.path
        })
        XCTAssertTrue(recorder.values.contains { $0.argv == ["task", "verify-model", "--id", started.id, "--state-dir", state.path, "--json"] })
    }

    func testTaskStartDistinguishesKnownEngineFailureUnknownResponseAndPrelaunchFailure() async throws {
        let request = TaskRequest(kind: .classification, modelPath: "/Models/laya", parameters: [
            "state": .string("refund request"),
            "questions": .object(["route": .object(["type": .string("choice"), "instructions": .string("Route this"), "criteria": .array([.string("billing"), .string("other")])])]),
        ])
        let knownFailure = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", taskEnvelopeCommand: { _, _, _ in
            ["status": "error", "data": ["task": Self.taskSummary], "error": ["code": "task_failed", "message": "No output", "remediation": "Inspect task status."]]
        })
        do { _ = try await knownFailure.taskStart(request); XCTFail("expected engine failure") }
        catch let error as TaskEngineError { XCTAssertEqual(error.task?.id, "11111111-1111-4111-8111-111111111111") }

        let lost = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", taskEnvelopeCommand: { _, _, _ in ["__mlx_cli_response_unreadable": true, "status": "error"] })
        do { _ = try await lost.taskStart(request); XCTFail("expected unknown outcome") }
        catch is TaskStartOutcomeUnknown { }

        let beforeLaunch = WorkbenchAPI(cli: CLIProcess(), agentPath: "/definitely/missing")
        do { _ = try await beforeLaunch.taskStart(request); XCTFail("expected prelaunch error") }
        catch is TaskStartOutcomeUnknown { XCTFail("prelaunch failure cannot have an unknown task outcome") }
        catch { }
    }

    func testTaskCLIInvocationPreservesEnvelopesAndChildLaunchProvenance() throws {
        let success = try FixtureAgent(envelope: ["status": "ok", "data": ["value": "spaces ' quotes ☃"]])
        defer { success.remove() }
        let cli = CLIProcess()
        XCTAssertEqual(try cli.run(agentPath: success.root.path, argv: ["task", "capabilities"])["value"] as? String, "spaces ' quotes ☃")
        var launched = false
        let envelope = try cli.run(agentPath: success.root.path, argv: ["task", "capabilities"], preserveEnvelope: true, onChildLaunched: { launched = true })
        XCTAssertTrue(launched)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        XCTAssertEqual((envelope["data"] as? [String: Any])?["value"] as? String, "spaces ' quotes ☃")

        let failure = try FixtureAgent(envelope: ["status": "error", "data": ["task": ["id": "known"]], "error": ["code": "task_failed", "message": "failed", "remediation": "inspect"]])
        defer { failure.remove() }
        let errorEnvelope = try cli.run(agentPath: failure.root.path, argv: ["task", "start"], preserveEnvelope: true)
        XCTAssertEqual(errorEnvelope["status"] as? String, "error")
        XCTAssertNotNil((errorEnvelope["data"] as? [String: Any])?["task"])

        launched = false
        XCTAssertThrowsError(try cli.run(agentPath: "/missing-task-agent", argv: ["task", "start"], preserveEnvelope: true, onChildLaunched: { launched = true }))
        XCTAssertFalse(launched)
    }

    func testComparisonRecoveryChecksReceiptIdentityAndNeverStopsAReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-receipt-\(UUID().uuidString)")
        let receipt = root.appendingPathComponent(".mlx-agent-receipts/serve/9997.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = ComparisonServerReceipt(port: 9997, pid: 131071, modelIdentity: "/Models/a", previewHash: "owned", startedAt: "original")
        let original: [String: Any] = ["port": 9997, "pid": 131071, "path": "/Models/a", "preview_hash": "owned", "started_at": "original"]
        let base: [String: Any] = ["port": 9997, "pid": 131071, "path": "/Models/a", "started_at": "original",
            "receipt": receipt.path, "alive": true, "argv_match": true]
        for scenario in 0..<9 {
            var row = base, file = original
            if scenario == 1 { file["preview_hash"] = "different" }
            if scenario == 2 { row["started_at"] = "replacement" }
            if scenario == 6 { row["pid"] = 131072 }
            if scenario == 8 { file["started_at"] = "replacement" }
            try JSONSerialization.data(withJSONObject: file).write(to: receipt)
            let recorder = AgentCallRecorder()
            let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", receiptDirectory: root.path, command: { path, argv, scout, timeout in
                recorder.record(path: path, argv: argv, isScout: scout, timeout: timeout)
                if argv.contains("status") {
                    if scenario == 5 { return [:] }
                    return ["servers": scenario == 3 || scenario == 7 ? [] : [row]]
                }
                if scenario == 4 { throw BridgeError.skillOutputUnreadable }
                return ["status": "stopped"]
            })
            let expectFailure = [1, 2, 5, 7, 8].contains(scenario)
            do {
                try await api.recoverComparisonServer(expected, mayBeAlive: { _ in ![3, 4, 5, 6].contains(scenario) })
                XCTAssertFalse(expectFailure, "scenario \(scenario)")
            } catch { XCTAssertTrue(expectFailure, "scenario \(scenario): \(error)") }
            XCTAssertEqual(recorder.values.filter { $0.argv.contains("stop") }.count, [0, 4].contains(scenario) ? 1 : 0)
        }
    }
    func testCancelledInvocationDoesNotLaunchAndCleanupIgnoresTaskCancellation() async throws {
        let token = CLIInvocationCancellation(); token.cancel()
        XCTAssertThrowsError(try CLIProcess().run(agentPath: "/missing", argv: ["convert", "video"], cancellation: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            XCTAssertEqual(argv, ["serve", "stop"])
            return ["stopped": true]
        })
        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.raw(["serve", "stop"])["stopped"] as? Bool
        }
        let stopped = try await cleanup.value
        XCTAssertEqual(stopped, true)
    }
    func testCancelMediaRequestStopsItsAgentAndBackendWithoutStoppingAnotherProcess() async throws {
        try await assertCancellationStopsOwnedProcesses { api, _ in
            _ = try await api.describe(path: "/Models/test", prompt: "test", image: "/test.png", video: nil, maxTokens: 8)
        }
    }
    func testCancelRecommendationStopsItsAgentAndBackendWithoutStoppingAnotherProcess() async throws {
        try await assertCancellationStopsOwnedProcesses { api, state in
            _ = try await api.adoptStart(role: "coding", state: state, fast: true, offline: true)
        }
    }
    func testCancelDiscoveryStopsItsAgentAndBackendWithoutStoppingAnotherProcess() async throws {
        try await assertCancellationStopsOwnedProcesses { api, _ in
            _ = try await api.discover(role: "coding", limit: 3, fast: true, new: false)
        }
    }
    private func assertCancellationStopsOwnedProcesses(
        request: @escaping @Sendable (WorkbenchAPI, String) async throws -> Void
    ) async throws {
        let pids = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-media-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pids) }
        let agent = try FixtureAgent(spawningBackendRecordingPIDsTo: pids)
        defer { agent.remove() }
        let registry = CLIProcessRegistry(notificationCenter: NotificationCenter(), terminationGrace: 0.2)
        defer { registry.terminateAll(grace: 0.2) }
        let other = Process(); other.executableURL = URL(fileURLWithPath: "/bin/sleep"); other.arguments = ["60"]
        try other.run()
        defer {
            if other.isRunning { other.terminate() }
            XCTAssertTrue(processIsGone(other.processIdentifier))
        }
        let api = WorkbenchAPI(cli: CLIProcess(registry: registry, terminationGrace: 0.2), agentPath: agent.root.path)
        let finished = expectation(description: "cancelled invocation returned")
        let task = Task {
            do { try await request(api, pids.appendingPathExtension("state").path)
                XCTFail("Cancelled invocation must not return a result")
            } catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
            finished.fulfill()
        }
        var spawned: SpawnedAgent?
        for _ in 0..<500 where spawned == nil {
            spawned = SpawnedAgent(contentsOf: pids)
            if spawned == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let live = try XCTUnwrap(spawned)
        task.cancel()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(processIsGone(live.agent, within: 0.5))
        XCTAssertTrue(processIsGone(live.backend, within: 0.5))
        XCTAssertTrue(other.isRunning)
        registry.terminateAll(grace: 0.2)
        await task.value
    }
    func testAdoptStartCreatesParentAndStatusReusesTheStateFile() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-adopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = folder.appendingPathComponent("adoption/\(UUID().uuidString).json")
        let record = folder.appendingPathComponent("argv.jsonl")
        let agent = try FixtureAgent(adoptionState: state, recordingTo: record)
        defer { agent.remove() }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.deletingLastPathComponent().path))

        let started = try await api.adoptStart(role: "coding", state: state.path, fast: true, offline: true)
        XCTAssertEqual(started.state, state.path)
        XCTAssertEqual(started.workflowID, "fixture-adoption-workflow")
        XCTAssertNotEqual(started.state, started.workflowID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))

        let refreshed = try await api.adoptStatus(state: try XCTUnwrap(started.state))
        XCTAssertEqual(refreshed, started)
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        let argv = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]) }
        XCTAssertEqual(argv, [
            ["adopt", "start", "--role", "coding", "--state", state.path, "--fast", "--offline", "--json"],
            ["adopt", "status", "--state", state.path, "--json"],
        ])
    }

    func testAdoptDecoderSeparatesStatePathFromWorkflowAndPreservesRecommendationEvidence() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json").path
        let result = WorkbenchAPI.adopt(from: ["state": [
            "workflow_id": "workflow-123", "status": "complete", "phase": "complete",
            "request": ["roles": ["coding"]],
            "recommendations": [
                ["repo": "org/recommended", "evidence_strength": "runtime_measured"],
                ["repo": "org/other", "evidence_strength": "heuristic_only"],
            ],
            "shortlist": [["repo": "org/candidate"]],
        ]], statePath: path)

        XCTAssertEqual(result.state, path)
        XCTAssertEqual(result.workflowID, "workflow-123")
        XCTAssertEqual(result.role, "coding")
        XCTAssertEqual(result.model, "org/recommended")
        XCTAssertEqual(result.status, "complete")
        XCTAssertEqual(result.phase, "complete")
        XCTAssertEqual(result.evidenceStrength, "runtime_measured")
        XCTAssertNil(result.manager)
        XCTAssertNil(result.message)
    }

    func testCompletedAdoptionWithoutRecommendationDoesNotPromoteTheShortlistOrFlatModel() {
        let result = WorkbenchAPI.adopt(from: [
            "model": "org/outer-model",
            "state": [
                "workflow_id": "workflow-empty", "status": "complete", "phase": "complete",
                "model": "org/nested-model", "recommendations": [],
                "shortlist": [["repo": "org/candidate", "evidence_strength": "runtime_measured"]],
            ],
        ])

        XCTAssertNil(result.state)
        XCTAssertNil(result.model)
        XCTAssertNil(result.evidenceStrength)
        XCTAssertEqual(result.workflowID, "workflow-empty")
        XCTAssertEqual(result.status, "complete")
        XCTAssertEqual(result.phase, "complete")
    }

    func testAdoptDecoderPreservesUnknownValuesAndLeavesMissingFieldsAbsent() {
        let unknown = WorkbenchAPI.adopt(from: ["state": [
            "workflow_id": "future-workflow", "status": "future-status", "phase": "future-phase",
            "recommendations": [["repo": "org/model", "evidence_strength": "future-evidence"]],
            "future_field": "ignored",
        ]])
        XCTAssertEqual(unknown.status, "future-status")
        XCTAssertEqual(unknown.phase, "future-phase")
        XCTAssertEqual(unknown.evidenceStrength, "future-evidence")
        XCTAssertNil(unknown.state)
        XCTAssertNil(unknown.role)

        let missing = WorkbenchAPI.adopt(from: ["state": [:], "model": "org/outer-model"])
        XCTAssertEqual(missing, AdoptResult(state: nil, role: nil, model: nil, status: nil, message: nil, manager: nil))
        let incompleteRecommendation = WorkbenchAPI.adopt(from: ["state": [
            "recommendations": [[:], ["repo": "org/second", "evidence_strength": "runtime_measured"]],
            "evidence_strength": "heuristic_only",
        ]])
        XCTAssertNil(incompleteRecommendation.model)
        XCTAssertNil(incompleteRecommendation.evidenceStrength)
    }

    func testAdoptDecoderSupportsLegacyFlatResultsAndExplicitPathTakesPrecedence() throws {
        let payload: [String: Any] = [
            "state": "legacy-state.json", "role": "general", "model": "org/legacy",
            "status": "complete", "message": "Reported message", "manager": "reported-manager",
        ]
        let legacy = WorkbenchAPI.adopt(from: payload)
        XCTAssertEqual(legacy, AdoptResult(
            state: "legacy-state.json", role: "general", model: "org/legacy", status: "complete",
            message: "Reported message", manager: "reported-manager"
        ))
        XCTAssertEqual(WorkbenchAPI.adopt(from: payload, statePath: "explicit-state.json").state, "explicit-state.json")
        let encodedLegacy = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(try JSONDecoder().decode(AdoptResult.self, from: encodedLegacy), legacy)
        XCTAssertEqual(try JSONDecoder().decode(AdoptResult.self, from: JSONEncoder().encode(legacy)), legacy)
    }

    func testScanRunsFixtureAgentAndPreservesReportedBytes() async throws {
        let payload = try fixture(named: "convert-scan-valid")
        let agent = try FixtureAgent(scanPayload: payload)
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.scan(
            ggufRoots: ["/fixtures/gguf"], mlxRoots: [], signatures: true
        )

        XCTAssertEqual(result.models[1].bytes, 29_047_084_448)
        XCTAssertEqual(result.totals.bytes, 29_950_538_400)
    }

    func testFleetRenderSendsAssignmentsAndPortMap() async throws {
        let agent = try FixtureAgent(fleetMode: ())
        defer { agent.remove() }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let assignments = [(role: "coding", repo: "pub/coder", port: 8766)]

        let render = try await api.fleetRender(path: "/tmp/router.yaml", assignments: assignments)
        XCTAssertEqual(render["config"] as? String, "rendered")

        let preview = try await api.fleetApplyPreview(path: "/tmp/router.yaml", assignments: assignments)
        let previewData = try XCTUnwrap(preview["preview"] as? [String: Any])
        XCTAssertEqual(previewData["preview_hash"] as? String, "fleet-hash")

        let applied = try await api.fleetApplyConfirm(
            path: "/tmp/router.yaml",
            assignments: assignments,
            previewHash: "fleet-hash"
        )
        let receipt = try XCTUnwrap(applied["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["status"] as? String, "applied")
    }

    func testALongMediaCallDoesNotBlockOtherAgentCallsOnTheSameAPI() async throws {
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("api-blocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marks) }
        let started = marks.appendingPathComponent("started")
        let release = marks.appendingPathComponent("release")
        let progress = marks.appendingPathComponent("progress")
        let commandStarted = marks.appendingPathComponent("command-started")
        let agent = try FixtureAgent(blockingDescribeStarted: started, release: release, commandStarted: commandStarted, progress: progress)
        defer { agent.remove() }
        defer { try? Data().write(to: release) }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)

        let description = Task {
            try await api.describe(path: "/m/vlm", prompt: "What?", image: "/i.png", video: nil, maxTokens: 16)
        }
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "the describe call reached the agent")

        let quickCall = Task {
            try Data("Awaiting serve status".utf8).write(to: progress)
            _ = try await api.raw(["serve", "status"])
            try Data("Serve status returned; awaiting health".utf8).write(to: progress)
            let health = await api.health()
            // The media fixture can finish successfully only after both calls return.
            // Its timeout bounds a serialized-actor regression, not subprocess speed.
            try Data().write(to: release)
            try Data("Quick calls returned and released media".utf8).write(to: progress)
            return health.ok
        }
        let healthy = try await quickCall.value
        let result = try await description.value

        XCTAssertTrue(healthy)
        XCTAssertEqual(result.text, "A red circle.", "the fixture captures the quick call's stage at timeout")
        XCTAssertEqual(result.generationTokens, 4)
    }

    func testABlockedWatchDiffDoesNotHoldServeStatus() async throws {
        let calls = AgentCallRecorder()
        let release = DispatchSemaphore(value: 0)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture/agent", receiptDirectory: "/fixture/receipts") { path, argv, isScout, timeout in
            calls.record(path: path, argv: argv, isScout: isScout, timeout: timeout)
            guard argv.first == "watch" else { return ["servers": []] }
            calls.mark(.started)
            _ = release.wait(timeout: .now() + 5)
            calls.mark(.finished)
            return ["findings": []]
        }
        defer { release.signal() }

        let watch = Task { try await api.raw(["watch", "diff", "--state-dir", "/fixture/watch"], isScout: true) }
        for _ in 0..<500 where !calls.has(.started) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(calls.has(.started), "watch diff reached the runner")

        let servers = try await api.serveStatus()
        XCTAssertFalse(calls.has(.finished), "serve status returned while watch diff was still blocked")
        XCTAssertTrue(servers.isEmpty)

        release.signal()
        let findings = try await watch.value
        XCTAssertNotNil(findings["findings"])
        XCTAssertEqual(calls.values.map(\.argv), [
            ["watch", "diff", "--state-dir", "/fixture/watch"],
            ["serve", "status", "--receipts-dir", "/fixture/receipts"],
        ])
        XCTAssertEqual(calls.values.map(\.isScout), [true, false])
        XCTAssertEqual(calls.values.map(\.timeout), [nil, nil])
        XCTAssertEqual(Set(calls.values.map(\.path)), ["/fixture/agent"])
    }

    func testConfiguredScanMatchesFilesystemBytesWhenEnabled() async throws {
#if !MLX_WORKBENCH_LIVE_SCAN
        throw XCTSkip("run make test-swift-live-scan to validate the configured local inventory")
#else

        var environment = ProcessInfo.processInfo.environment
        environment["XCTestConfigurationFilePath"] = nil
        let config = ConfigModule(pathOverride: ConfigModule().configPath(environment: environment)).load()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: config.mlxAgentPath)
        let result = try await api.scan(
            ggufRoots: ConfigModule().scanRoots(value: config, home: URL(fileURLWithPath: NSHomeDirectory())),
            mlxRoots: config.mlxRoots,
            signatures: config.signatures
        )
        if result.models.isEmpty {
            throw XCTSkip("no GGUF models exist in the configured scan roots")
        }

        let manager = FileManager.default
        var modelBytes: Int64 = 0
        for model in result.models {
            let attributes = try manager.attributesOfItem(atPath: model.path)
            let filesystemBytes = try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
            XCTAssertGreaterThan(model.bytes, 0, model.path)
            XCTAssertEqual(model.bytes, filesystemBytes, model.path)
            modelBytes += model.bytes
        }
        XCTAssertEqual(result.totals.bytes, modelBytes)
#endif
    }

    func testMediaWorkerPreservesAgentFailure() async throws {
        let agent = try FixtureAgent(failingMedia: ())
        defer { agent.remove() }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        do {
            _ = try await api.describe(path: "/m/vlm", prompt: "What?", image: "/i.png", video: nil, maxTokens: 16)
            XCTFail("Expected the agent failure to propagate")
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, "fixture_media_failure")
            XCTAssertEqual(error.message, "Media failed")
        }
    }

    func testConvertPreviewUnwrapsPlanEnvelope() async throws {
        // mlx-agent ≥ 0.5.x wraps previews in {plan, requires_confirmation}.
        let agent = try FixtureAgent(
            convertPreviewPayload: [
                "plan": ["preview_hash": "hash-plan", "out": "/out"],
                "requires_confirmation": true,
            ]
        )
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.convertPreview(ggufPath: "/m/a.gguf", qBits: 4, out: nil)

        XCTAssertEqual(result["preview_hash"] as? String, "hash-plan")
        XCTAssertEqual(result["out"] as? String, "/out")
    }

    func testIntakeCommandsSendExpectedArgv() async throws {
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("argv-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: record) }
        let agent = try FixtureAgent(recordingTo: record, payload: ["plan": ["preview_hash": "h"], "jobs": []])
        defer { agent.remove() }
        let receipts = FileManager.default.temporaryDirectory.appendingPathComponent("receipts-\(UUID().uuidString)").path
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path, receiptDirectory: receipts)

        _ = try await api.backendInstallPreview(id: "mlx-audio")
        _ = try await api.backendInstallStart(id: "mlx-audio", previewHash: "h")
        let request = IntakeFetchRequest(source: "unsloth/Qwen3-8B-GGUF", revision: "main", file: "a.gguf", localDir: "/models/gguf/Qwen3-8B-GGUF")
        _ = try await api.intakeFetchPreview(request)
        _ = try await api.intakeFetchStart(request, previewHash: "h")
        _ = try await api.intakeStatus()
        _ = try await api.convertRepoPreview(repo: "openai/whisper-tiny", qBits: 4, out: "/out", hfCache: nil, backend: "mlx-audio")
        _ = try await api.convertRepoPreview(repo: "convaiinnovations/laya", qBits: 8, out: "/out", hfCache: nil,
                                             backend: "mlx-embeddings", modelType: "laya", subfolder: "multilingual")
        _ = try? await api.decide(path: "/m/laya-MLX-4bit", request: "/tmp/request.json")
        _ = try? await api.generate(path: "/m/qwen", out: "/tmp/a.png", request: ImageRequest(prompt: "a; b", size: 768, steps: 12, seed: 3))
        _ = try await api.intakeFetchPreview(IntakeFetchRequest(source: "convaiinnovations/laya", revision: "main", file: nil, localDir: nil, modelType: "laya"))
        _ = try await api.intakeFetchPreview(IntakeFetchRequest(source: "org/x-GGUF", revision: "main", file: "a.gguf", localDir: nil, modelType: "llama"))

        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        let argv = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]) }
        XCTAssertEqual(argv[0], ["backend", "install", "mlx-audio", "--receipts-dir", receipts, "--json"])
        XCTAssertEqual(argv[1], ["backend", "install", "mlx-audio", "--confirm", "--preview-hash", "h", "--receipts-dir", receipts, "--json"])
        XCTAssertEqual(argv[2], ["intake", "fetch", "unsloth/Qwen3-8B-GGUF", "--revision", "main", "--file", "a.gguf", "--local-dir", "/models/gguf/Qwen3-8B-GGUF", "--receipts-dir", receipts, "--json"])
        XCTAssertEqual(argv[3].suffix(5), ["--confirm", "--preview-hash", "h", "--receipts-dir", receipts, "--json"].suffix(5))
        XCTAssertEqual(argv[4], ["intake", "status", "--receipts-dir", receipts, "--json"])
        XCTAssertTrue(argv[5].contains("--backend") && argv[5].contains("mlx-audio"))
        XCTAssertFalse(argv[5].contains("--model-type"))
        let modelType = try XCTUnwrap(argv[6].firstIndex(of: "--model-type"))
        XCTAssertEqual(argv[6][modelType + 1], "laya")
        let subfolder = try XCTUnwrap(argv[6].firstIndex(of: "--subfolder"))
        XCTAssertEqual(argv[6][subfolder + 1], "multilingual")
        XCTAssertEqual(Array(argv[7].prefix(6)), ["convert", "decide", "--path", "/m/laya-MLX-4bit", "--request", "/tmp/request.json"])
        XCTAssertEqual(Array(argv[8].prefix(16)), ["convert", "generate", "--path", "/m/qwen", "--prompt", "a; b", "--out", "/tmp/a.png",
                                                  "--width", "768", "--height", "768", "--steps", "12", "--seed", "3"])
        XCTAssertEqual(Array(argv[9].prefix(7)), ["intake", "fetch", "convaiinnovations/laya", "--revision", "main", "--model-type", "laya"])
        XCTAssertFalse(argv[10].contains("--model-type"), "a single-file download is not narrowed by type")
    }

    func testSpeechComparisonPassesTheRequestLanguageToTranscribe() async throws {
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("argv-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: record) }
        let agent = try FixtureAgent(recordingTo: record, payload: ["text": "The quick brown fox.", "seconds": 1, "audio_seconds": 3])
        defer { agent.remove() }
        let runner = LiveComparisonMediaRunner(api: WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path))
        let entry = ComparisonMediaFixtures.speechToTextSet.prompts[0]

        for language in [SpeechCanary.language, nil] {
            let output = try await runner.run(MediaRunRequest(
                mode: .speechToText, modelPath: "/m/whisper", entry: entry,
                inputURL: URL(fileURLWithPath: "/tmp/clip.wav"), outputURL: nil, maxTokens: 64, language: language
            ))
            XCTAssertEqual(output.text, "The quick brown fox.")
        }

        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        let argv = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]) }
        XCTAssertEqual(argv.count, 2)
        XCTAssertEqual(Array(argv[0].prefix(8)), ["convert", "transcribe", "--path", "/m/whisper", "--audio", "/tmp/clip.wav", "--language", "en"])
        XCTAssertEqual(Array(argv[1].prefix(6)), ["convert", "transcribe", "--path", "/m/whisper", "--audio", "/tmp/clip.wav"])
        XCTAssertFalse(argv[1].contains("--language"), "a user clip lets the model detect its language")
    }

    func testConvertPreviewAcceptsFlatLegacyShape() async throws {
        let agent = try FixtureAgent(
            convertPreviewPayload: ["preview_hash": "hash-flat", "out": "/out"]
        )
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.convertPreview(ggufPath: "/m/a.gguf", qBits: 4, out: nil)

        XCTAssertEqual(result["preview_hash"] as? String, "hash-flat")
    }

    func testRunPrependsInterpreterDirectoryToPath() async throws {
        let agent = try FixtureAgent(pathProbe: true)
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.raw(["probe"])

        let reported = try XCTUnwrap(result["process_path"] as? String)
        // Expect the interpreter the bridge actually resolves for this agent
        // path (env override → repo .venv → PATH), not a hard-coded python3.
        let resolvedPython = try XCTUnwrap(WorkbenchPython.preferredExecutable(
            repoRoot: WorkbenchPython.repoRoot(agentPath: agent.root.path)
        ))
        let expectedDir = resolvedPython.deletingLastPathComponent().path
        XCTAssertTrue(
            reported.hasPrefix(expectedDir + ":"),
            "agent PATH should start with the interpreter's directory; got \(reported)"
        )
    }

    func testLiveServeLifecycleUsesAutomaticDeclaredRuntime() async throws {
        let agent = try FixtureAgent(expectedServeRuntime: "auto")
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let lifecycle = ServeLifecycle.live(api: api)
        let previewHash = try await lifecycle.preview("mlx-community/Qwen3-0.6B-4bit", 8766)
        try await lifecycle.start("mlx-community/Qwen3-0.6B-4bit", 8766, previewHash)

        XCTAssertEqual(previewHash, "serve-hash")
    }

    func testLiveServeLifecycleUsesExplicitReceiptDirectory() async throws {
        let receiptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-live-receipts-\(UUID().uuidString)", isDirectory: true)
        let agent = try FixtureAgent(expectedReceiptDirectory: receiptDirectory.path)
        defer { agent.remove() }

        let api = WorkbenchAPI(
            cli: CLIProcess(),
            agentPath: agent.root.path,
            receiptDirectory: receiptDirectory.path
        )
        let lifecycle = ServeLifecycle.live(api: api)
        let previewHash = try await lifecycle.preview("mlx-community/Qwen3-0.6B-4bit", 8766)
        try await lifecycle.start("mlx-community/Qwen3-0.6B-4bit", 8766, previewHash)

        XCTAssertEqual(previewHash, "serve-hash")
    }

    /// Regression: without --receipts-dir the agent derives its receipts dir
    /// from the CWD, which for a GUI app is "/" → Errno 30 (read-only) and
    /// "Conversion could not be queued".
    func testConvertCommandsCarryExplicitReceiptDirectory() async throws {
        let receiptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-convert-receipts-\(UUID().uuidString)", isDirectory: true)
        let agent = try FixtureAgent(expectedConvertReceiptDirectory: receiptDirectory.path)
        defer { agent.remove() }

        let api = WorkbenchAPI(
            cli: CLIProcess(),
            agentPath: agent.root.path,
            receiptDirectory: receiptDirectory.path
        )

        _ = try await api.convertPreview(ggufPath: "/models/a.gguf", qBits: 4, out: "/out")
        _ = try await api.convertStart(ggufPath: "/models/a.gguf", qBits: 4, out: "/models/out", previewHash: "h")
        _ = try await api.convertRepoStart(repo: "org/model", qBits: 4, out: nil, hfCache: nil, previewHash: "h")
        _ = try await api.convertStatus()
        _ = try await api.allJobs()
    }

    func testLocalModelPathServesViaPathFlag() async throws {
        let agent = try FixtureAgent(expectedModelFlag: "--path", expectedModelValue: "/models/mlx/qwen3-8b-mlx")
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let lifecycle = ServeLifecycle.live(api: api)
        let previewHash = try await lifecycle.preview("/models/mlx/qwen3-8b-mlx", 8766)
        try await lifecycle.start("/models/mlx/qwen3-8b-mlx", 8766, previewHash)

        XCTAssertEqual(previewHash, "serve-hash")
    }

    func testHFCachePathServesExactSnapshotWithoutResolvingRepo() async throws {
        let cachePath = "/Users/x/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/abc123"
        let agent = try FixtureAgent(expectedModelFlag: "--path", expectedModelValue: cachePath)
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let lifecycle = ServeLifecycle.live(api: api)
        let previewHash = try await lifecycle.preview(cachePath, 8766)
        try await lifecycle.start(cachePath, 8766, previewHash)

        XCTAssertEqual(previewHash, "serve-hash")
    }

    func testTimeoutStopsTheAgentProcessGroupIncludingItsBackend() throws {
        let pids = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pids-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pids) }
        let agent = try FixtureAgent(spawningBackendRecordingPIDsTo: pids)
        defer { agent.remove() }
        let registry = CLIProcessRegistry(notificationCenter: NotificationCenter(), terminationGrace: 0.5)
        let cli = CLIProcess(registry: registry, terminationGrace: 0.5)

        XCTAssertThrowsError(try cli.run(agentPath: agent.root.path, argv: ["convert", "video"], timeout: 4)) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "skill_timeout")
        }

        let spawned = try XCTUnwrap(SpawnedAgent(contentsOf: pids), "the agent started its backend before the timeout")
        XCTAssertEqual(spawned.agentGroup, spawned.agent, "the agent leads its own process group")
        XCTAssertEqual(spawned.backendGroup, spawned.agent, "the backend stays in the agent's group")
        XCTAssertNotEqual(spawned.agentGroup, getpgrp(), "the agent is outside the app's group")
        XCTAssertTrue(processIsGone(spawned.agent), "the timed-out agent \(spawned.agent) is stopped")
        XCTAssertTrue(processIsGone(spawned.backend), "the SIGTERM-ignoring backend \(spawned.backend) is killed after the grace")
    }

    func testAppTerminationStopsLiveAgentProcessGroups() throws {
        let pids = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pids-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pids) }
        let agent = try FixtureAgent(spawningBackendRecordingPIDsTo: pids)
        defer { agent.remove() }
        let center = NotificationCenter()
        let registry = CLIProcessRegistry(notificationCenter: center, terminationGrace: 0.5)
        let cli = CLIProcess(registry: registry, terminationGrace: 0.5)
        let path = agent.root.path
        let finished = DispatchSemaphore(value: 0)
        var failure: Error?
        Thread.detachNewThread {
            do {
                _ = try cli.run(agentPath: path, argv: ["convert", "video"], timeout: 120)
            } catch {
                failure = error
            }
            finished.signal()
        }

        var spawned: SpawnedAgent?
        for _ in 0..<500 where spawned == nil {
            spawned = SpawnedAgent(contentsOf: pids)
            if spawned == nil { usleep(20_000) }
        }
        let live = try XCTUnwrap(spawned, "the agent started its backend")
        XCTAssertEqual(kill(live.agent, 0), 0, "the agent is running before quit")
        XCTAssertEqual(kill(live.backend, 0), 0, "the backend is running before quit")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertTrue(processIsGone(live.agent), "quit stops the agent \(live.agent)")
        XCTAssertTrue(processIsGone(live.backend), "quit kills the SIGTERM-ignoring backend \(live.backend)")
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "the in-flight call returns once its group is stopped")
        XCTAssertNotNil(failure, "a stopped agent call reports a failure")
    }

    func testAgentLaunchedAfterAppTerminationBeganIsStoppedAtOnce() throws {
        let pids = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pids-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pids) }
        let agent = try FixtureAgent(spawningBackendRecordingPIDsTo: pids)
        defer { agent.remove() }
        let center = NotificationCenter()
        let registry = CLIProcessRegistry(notificationCenter: center, terminationGrace: 0.5)
        let cli = CLIProcess(registry: registry, terminationGrace: 0.5)
        center.post(name: NSApplication.willTerminateNotification, object: nil)

        let started = Date()
        XCTAssertThrowsError(try cli.run(agentPath: agent.root.path, argv: ["convert", "video"], timeout: 60))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the call ends with its stopped group, not at the timeout")
        if let spawned = SpawnedAgent(contentsOf: pids) {
            XCTAssertTrue(processIsGone(spawned.agent), "agent \(spawned.agent) is stopped")
            XCTAssertTrue(processIsGone(spawned.backend), "backend \(spawned.backend) is stopped")
        }
    }

    /// True once `pid` no longer exists (exited and reaped), polling up to `seconds`.
    private func processIsGone(_ pid: pid_t, within seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }

    private func fixture(named name: String) throws -> [String: Any] {
        // Shared contract fixtures live at the repo root so the Python
        // suite consumes the same files; see tests/fixtures/README.md.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // mlx-macTests
            .deletingLastPathComponent()  // mlx-mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

/// Agent invocations and blocked-call stages seen by an injected runner.
private final class AgentCallRecorder: @unchecked Sendable {
    enum Stage { case started, finished }
    struct Call { let path: String; let argv: [String]; let isScout: Bool; let timeout: TimeInterval? }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var stages: Set<Stage> = []

    var values: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func record(path: String, argv: [String], isScout: Bool, timeout: TimeInterval?) {
        lock.lock()
        calls.append(Call(path: path, argv: argv, isScout: isScout, timeout: timeout))
        lock.unlock()
    }

    func mark(_ stage: Stage) {
        lock.lock()
        stages.insert(stage)
        lock.unlock()
    }

    func has(_ stage: Stage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stages.contains(stage)
    }
}

/// Process identities the backend-spawning fixture agent records.
private struct SpawnedAgent {
    let agent: pid_t
    let agentGroup: pid_t
    let backend: pid_t
    let backendGroup: pid_t

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let agent = object["agent"], let agentGroup = object["agent_group"],
              let backend = object["backend"], let backendGroup = object["backend_group"] else {
            return nil
        }
        self.agent = pid_t(agent)
        self.agentGroup = pid_t(agentGroup)
        self.backend = pid_t(backend)
        self.backendGroup = pid_t(backendGroup)
    }
}

private final class FixtureAgent {
    let root: URL

    private init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-fixture-agent-\(UUID().uuidString)", isDirectory: true)
    }

    convenience init(scanPayload: [String: Any]) throws {
        self.init()
        try write(scriptAssertion: "\"convert\" in sys.argv and \"scan\" in sys.argv", payload: scanPayload)
    }

    convenience init(adoptionState statePath: URL, recordingTo recordPath: URL) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import os
        import sys

        args = sys.argv[1:]
        assert args[0] == "adopt" and args[1] in ("start", "status")
        state_path = args[args.index("--state") + 1]
        assert state_path == \(String(reflecting: statePath.path))
        assert os.path.isabs(state_path)
        assert os.path.isdir(os.path.dirname(state_path))
        if args[1] == "start":
            assert not os.path.exists(state_path)
            assert args[args.index("--role") + 1] == "coding"
            assert "--fast" in args and "--offline" in args
            state = {
                "workflow_id": "fixture-adoption-workflow", "status": "complete", "phase": "complete",
                "request": {"roles": ["coding"]},
                "recommendations": [{"repo": "org/coder", "evidence_strength": "heuristic_only"}],
            }
            with open(state_path, "w") as handle:
                json.dump(state, handle)
        else:
            assert "--role" not in args and "--fast" not in args and "--offline" not in args
            with open(state_path) as handle:
                state = json.load(handle)
        with open(\(String(reflecting: recordPath.path)), "a") as handle:
            handle.write(json.dumps(args) + "\\n")
        print(json.dumps({"status": "ok", "data": {"state": state}}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    /// Appends each invocation's argv (JSON) to `recordPath` and returns `payload`.
    convenience init(recordingTo recordPath: URL, payload: [String: Any]) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let body = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        let script = """
        import json
        import sys

        with open(\(String(reflecting: recordPath.path)), "a") as handle:
            handle.write(json.dumps(sys.argv[1:]) + "\\n")
        print(json.dumps({"status": "ok", "data": \(body)}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    convenience init(envelope: [String: Any]) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let body = String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8) ?? "{}"
        let script = "import json\nprint(json.dumps(\(body)))\n"
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    /// `describe` marks `started`, then waits (up to a minute) for `release` to exist; every other call answers at once.
    convenience init(blockingDescribeStarted started: URL, release: URL, commandStarted: URL, progress: URL) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import os
        import sys
        import time

        data = {}
        if "describe" in sys.argv:
            open(\(String(reflecting: started.path)), "w").close()
            deadline = time.time() + 60
            while not os.path.exists(\(String(reflecting: release.path))) and time.time() < deadline:
                time.sleep(0.02)
            released = os.path.exists(\(String(reflecting: release.path)))
            text = "A red circle."
            if not released:
                try:
                    with open(\(String(reflecting: progress.path))) as handle:
                        stage = handle.read()
                except FileNotFoundError:
                    stage = "quick task not started"
                reached = os.path.exists(\(String(reflecting: commandStarted.path)))
                text = "Media gate timed out: " + stage + "; serve status reached agent: " + str(reached)
            data = {"text": text, "generation_tokens": 4}
        else:
            open(\(String(reflecting: commandStarted.path)), "w").close()
        print(json.dumps({"status": "ok", "data": data}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    /// Starts a backend stand-in that ignores SIGTERM and sleeps (as a media
    /// call's backend Python would run), records both pids and process groups
    /// to `pidsPath`, then sleeps without answering.
    convenience init(spawningBackendRecordingPIDsTo pidsPath: URL) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import os
        import subprocess
        import time

        backend = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec sleep 600"])
        pids = {
            "agent": os.getpid(),
            "agent_group": os.getpgid(0),
            "backend": backend.pid,
            "backend_group": os.getpgid(backend.pid),
        }
        staging = \(String(reflecting: pidsPath.path)) + ".tmp"
        with open(staging, "w") as handle:
            json.dump(pids, handle)
        os.replace(staging, \(String(reflecting: pidsPath.path)))
        time.sleep(600)
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    convenience init(failingMedia: Void) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        print(json.dumps({"status": "error", "error": {"code": "fixture_media_failure", "message": "Media failed"}}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    convenience init(convertPreviewPayload: [String: Any]) throws {
        self.init()
        try write(scriptAssertion: "\"convert\" in sys.argv and \"start\" in sys.argv and \"--confirm\" not in sys.argv", payload: convertPreviewPayload)
    }

    /// Emits the child process PATH in the payload, for the PATH-prepend test.
    convenience init(pathProbe: Bool) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import os
        print(json.dumps({"status": "ok", "data": {"process_path": os.environ.get("PATH", "")}}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    convenience init(expectedServeRuntime: String) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import sys

        runtime_index = sys.argv.index("--runtime") + 1
        assert "serve" in sys.argv and "start" in sys.argv
        assert sys.argv[runtime_index] == "\(expectedServeRuntime)"
        if "--confirm" in sys.argv:
            data = {}
        else:
            data = {"plan": {"preview_hash": "serve-hash"}}
        print(json.dumps({"status": "ok", "data": data}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    convenience init(expectedReceiptDirectory: String) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import sys

        receipts_index = sys.argv.index("--receipts-dir") + 1
        assert "serve" in sys.argv and "start" in sys.argv
        assert sys.argv[receipts_index] == "\(expectedReceiptDirectory)"
        if "--confirm" in sys.argv:
            data = {}
        else:
            data = {"plan": {"preview_hash": "serve-hash"}}
        print(json.dumps({"status": "ok", "data": data}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    /// Asserts every convert invocation (start with/without --confirm, and
    /// status) carries --receipts-dir pointing at the expected directory.
    convenience init(expectedConvertReceiptDirectory: String) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import sys

        assert sys.argv[1] == "convert"
        if "status" in sys.argv:
            receipts_index = sys.argv.index("--receipts-dir") + 1
            assert sys.argv[receipts_index] == "\(expectedConvertReceiptDirectory)"
            data = {"jobs": []}
        else:
            assert "start" in sys.argv
            if "--confirm" in sys.argv:
                receipts_index = sys.argv.index("--receipts-dir") + 1
                assert sys.argv[receipts_index] == "\(expectedConvertReceiptDirectory)"
                data = {}
            else:
                data = {"plan": {"preview_hash": "convert-hash"}}
        print(json.dumps({"status": "ok", "data": data}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    convenience init(expectedModelFlag: String, expectedModelValue: String) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import sys

        assert "serve" in sys.argv and "start" in sys.argv
        assert "--repo" not in sys.argv or "\(expectedModelFlag)" == "--repo"
        assert "--path" not in sys.argv or "\(expectedModelFlag)" == "--path"
        flag_index = sys.argv.index("\(expectedModelFlag)") + 1
        assert sys.argv[flag_index] == "\(expectedModelValue)"
        if "--confirm" in sys.argv:
            data = {}
        else:
            data = {"plan": {"preview_hash": "serve-hash"}}
        print(json.dumps({"status": "ok", "data": data}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    /// Fleet fixture: asserts the argv contract (assignments, port-map,
    /// allow-missing, confirm discipline) and answers per subcommand.
    convenience init(fleetMode: Void) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import sys

        assert "fleet" in sys.argv and "--json" in sys.argv
        assert "--assign" in sys.argv and "coding=pub/coder" in sys.argv
        assert "--port-map" in sys.argv and "coding=8766" in sys.argv
        assert "--allow-missing" in sys.argv
        if "render" in sys.argv:
            data = {"config": "rendered"}
        elif "--confirm" in sys.argv:
            assert "--preview-hash" in sys.argv and "fleet-hash" in sys.argv
            data = {"receipt": {"status": "applied"}}
        else:
            data = {"preview": {"preview_hash": "fleet-hash", "diff": "diff-text"}}
        print(json.dumps({"status": "ok", "data": data}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    private func write(scriptAssertion: String, payload: [String: Any]) throws {
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let envelope: [String: Any] = [
            "status": "ok",
            "data": payload,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
        let script = """
        import base64
        import sys

        assert \(scriptAssertion) and "--json" in sys.argv
        print(base64.b64decode("\(encoded)").decode("utf-8"))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
