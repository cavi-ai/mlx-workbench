import AppKit
import Foundation
import XCTest

@testable import mlx_workbench

final class WorkbenchAPISubprocessTests: XCTestCase {
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

    func testConfiguredScanMatchesFilesystemBytesWhenEnabled() async throws {
#if !MLX_WORKBENCH_LIVE_SCAN
        throw XCTSkip("run make test-swift-live-scan to validate the configured local inventory")
#else

        let config = ConfigModule().load()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: config.mlxAgentPath)
        let result = try await api.scan(
            ggufRoots: ConfigModule().scanRoots(value: config),
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

    func testLiveServeLifecycleUsesPinnedMLXRuntime() async throws {
        let agent = try FixtureAgent(expectedServeRuntime: "mlx_lm")
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
