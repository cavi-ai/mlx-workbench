import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

final class ScanContractTests: XCTestCase {
    func testLocalHostDiscoveryUsesTheListeningPortAndRecognizedProcess() {
        let listeners = "p42\ncPython\nn127.0.0.1:19080\np43\ncLM Studio\nn*:2345\np44\ncOther\nn127.0.0.1:9999\n"
        let processes = "42 python /engine/src/mlx_agent/jit_serve.py --config /service/config.json\n43 /Applications/LM Studio.app/Contents/MacOS/LM Studio\n44 unrelated-app\n"
        let candidates = LocalModelHostDiscovery.candidates(listeners: listeners, processes: processes)
        XCTAssertEqual(candidates.map(\.host.baseURL).sorted(), ["http://127.0.0.1:19080", "http://127.0.0.1:2345"])
        XCTAssertEqual(candidates.first { $0.processID == 43 }?.host.provider, .lmStudio)
    }

    func testDiscoveredStrataGatewayKeepsResidencyPathsAndMemoryPolicy() throws {
        let server = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [[
            "path": "/Models/Strata", "port": 19080, "pid": 42, "alive": true, "argv_match": true,
            "jit": true, "model_state": "unloaded", "receipts_dir": "/Services/Strata",
            "process_started_at": "Sat Nov 7 10:00:00 2026", "service_id": "service-a",
            "memory_policy": ["idle_timeout_seconds": 300, "keep_loaded": false,
                              "minimum_headroom_gb": 24, "model_memory_budget_gb": 24, "unload_under_pressure": true],
        ]]])?.first)
        XCTAssertEqual(server.receiptsDirectory, "/Services/Strata")
        XCTAssertEqual(server.processStartedAt, "Sat Nov 7 10:00:00 2026")
        XCTAssertEqual(server.memoryPolicy?.modelMemoryBudgetGB, 24)
        XCTAssertEqual(server.memoryPolicy?.unloadUnderPressure, true)
        let result = ServingInventorySnapshot.make(engine: [server], hosts: [], managedReceipts: "/Workbench", capturedAt: Date())
        XCTAssertEqual(result.services.count, 1)
        XCTAssertEqual(result.services[0].residency, .unloaded)
        XCTAssertEqual(result.services[0].modelPath, "/Models/Strata")
        XCTAssertFalse(result.services[0].isWorkbenchManaged)
        XCTAssertFalse(result.services[0].canUnload)
    }

    func testServeStatusCarriesWhyTheGatewayModelFailed() throws {
        let server = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [[
            "path": "/Models/Strata", "runtime": "strata", "port": 8766, "pid": 42, "alive": true, "argv_match": true,
            "jit": true, "model_state": "failed", "last_error": "Agent memory guard stopped the owned model worker.",
        ]]])?.first)
        XCTAssertEqual(server.modelState, "failed")
        XCTAssertEqual(server.lastError, "Agent memory guard stopped the owned model worker.")
    }

    func testHostedModelListingDoesNotInventResidencyOrLocalMemory() throws {
        let host = ModelHost(name: "Local", provider: .openAICompatible, baseURL: "http://127.0.0.1:8080")
        let model = HostedModel(hostID: host.id, modelID: "org/model", name: "Model")
        let inventory = HostInventory(host: host, models: [model], capturedAt: Date())
        let result = ServingInventorySnapshot.make(engine: [], hosts: [inventory], managedReceipts: "/Workbench", capturedAt: Date())
        XCTAssertEqual(result.services[0].residency, .unknown)
        XCTAssertTrue(result.services[0].isLocal)
        XCTAssertNil(result.services[0].reportedMemoryBytes)
        XCTAssertFalse(result.services[0].canUnload)
    }

    func testLoadedJITGatewayWithoutWorkerIdentityDoesNotUseGatewayAsModelMemory() throws {
        let server = ServerInfo(path: "/Models/A", runtime: "strata", port: 9000, pid: 7, state: "running", jit: true, modelState: "loaded")
        let result = ServingInventorySnapshot.make(engine: [server, server], hosts: [], managedReceipts: "/Workbench", capturedAt: Date())
        XCTAssertEqual(result.services.count, 1)
        XCTAssertNil(result.services[0].modelProcessID)
        XCTAssertEqual(result.services[0].residency, .loaded)
    }

    func testOutputBackendDecodesAndAMissingBackendNeedsRuntime() throws {
        var payload = fixture(named: "convert-scan-valid")
        payload["outputs"] = [[
            "path": "/Models/whisper-base-MLX-4bit", "name": "whisper-base-MLX-4bit",
            "quantization": ["bits": 4, "group_size": 64], "provenance": NSNull(),
            "task": ["type": "speech_to_text", "use_cases": ["transcription"], "source": "registry", "confidence": "confirmed"],
            "backend": ["id": "mlx-audio", "installed": false],
        ]]
        let result = try WorkbenchAPI.decodeScan(payload)
        XCTAssertEqual(result.outputs.first?.backend, OutputBackend(id: "mlx-audio", installed: false))
        let snapshot = ModelLibraryBuilder.build(scan: result,
            hardware: HardwareProfile(chip: "Apple Silicon", model: "Mac", memoryBytes: 128 * 1_024 * 1_024 * 1_024, macOSVersion: "26"), now: Date())
        XCTAssertEqual(snapshot.models.first { $0.item.path == "/Models/whisper-base-MLX-4bit" }?.readiness, .needsRuntime)
    }

    @MainActor
    func testStrataOutputKeepsItsRuntimeAndTextOnlyTask() throws {
        var payload = fixture(named: "convert-scan-valid")
        payload["outputs"] = [[
            "path": "/Models/Qwen3.8-Flash-Next-Strata-Q2_0", "name": "Qwen3.8-Flash-Next-Strata-Q2_0",
            "runtime": "strata", "quantization": NSNull(), "provenance": NSNull(),
            "task": ["type": "text_llm", "use_cases": ["general_chat"], "source": "config", "confidence": "confirmed"],
        ]]
        let result = try WorkbenchAPI.decodeScan(payload)
        XCTAssertEqual(result.outputs.first?.runtime, "strata")
        XCTAssertEqual(result.outputs.first?.task?.type, .textLLM)
        XCTAssertNil(result.outputs.first?.quantization)
        let snapshot = ModelLibraryBuilder.build(scan: result,
            hardware: HardwareProfile(chip: "Apple Silicon", model: "Mac", memoryBytes: 128 * 1_024 * 1_024 * 1_024, macOSVersion: "26"), now: Date())
        let model = try XCTUnwrap(snapshot.models.first { $0.item.path == result.outputs.first?.path })
        XCTAssertEqual(model.item.servingRuntime, "strata")
        let rows = ModelDetailsPresentation.displayRows(for: model, prepareDestination: nil)
        XCTAssertTrue(rows.contains { $0.label == "Runtime" && $0.value == "Strata (text only)" })
        XCTAssertEqual(ModelDetailsPresentation.readinessExplanation(for: model), "A local GGUF profile is prepared for the Strata runtime.")
        let view = NSHostingView(rootView: DetailGrid(rows: rows).padding().frame(width: 520, height: 260)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Strata model details"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testServeMemoryPolicyAndAdmissionFailureDecodeWithoutInventingDefaults() throws {
        let servers = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [
            ["jit": true, "memory_policy": ["idle_timeout_seconds": 600, "keep_loaded": false, "minimum_headroom_gb": 2],
             "load_blocked_reason": "Insufficient headroom"],
            ["jit": true],
            ["memory_policy": ["idle_timeout_seconds": -1, "keep_loaded": false]],
        ]]))
        XCTAssertEqual(servers[0].memoryPolicy, .automatic)
        XCTAssertEqual(servers[0].loadBlockedReason, "Insufficient headroom")
        XCTAssertNil(servers[1].memoryPolicy)
        XCTAssertNil(servers[2].memoryPolicy)
        XCTAssertEqual(EndpointMemoryPolicy.automatic.arguments, ["--idle-timeout", "600", "--min-headroom-gb", "2.0"])
        XCTAssertEqual(EndpointMemoryPolicy(idleTimeoutSeconds: 0, keepLoaded: true, minimumHeadroomGB: nil).arguments,
                       ["--idle-timeout", "0", "--keep-loaded"])
    }
    func testServeStatusDerivesOwnedProcessStateAndKeepsResidencySeparate() throws {
        let servers = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [
            ["path": "/Models/a", "port": 8766, "pid": 42, "alive": true, "argv_match": true,
             "jit": true, "model_state": "unloaded", "active_requests": 0],
            ["path": "/Models/b", "port": 8767, "alive": true, "argv_match": false],
        ]]))
        XCTAssertEqual(servers[0].state, "running")
        XCTAssertEqual(servers[0].modelState, "unloaded")
        XCTAssertNil(servers[0].workerPid)
        XCTAssertEqual(servers[1].state, "mismatch")
    }
    func testDecodeScanPreservesLargeModelAndTotalByteCounts() throws {
        let result = try WorkbenchAPI.decodeScan(fixture(named: "convert-scan-valid"))

        XCTAssertEqual(result.models.map(\.bytes), [903_453_952, 29_047_084_448])
        XCTAssertEqual(result.totals.bytes, 29_950_538_400)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(result.models[0].task?.type, .textLLM)
        XCTAssertEqual(result.models[0].task?.useCases, ["coding", "general_chat"])
        XCTAssertEqual(result.outputs[0].task?.type, .speechToText)
    }

    func testDecodeScanCarriesTheSplashFamilyOfEachOutput() throws {
        var payload = fixture(named: "convert-scan-valid")
        var outputs = try XCTUnwrap(payload["outputs"] as? [[String: Any]])
        outputs[0]["splash"] = ["family": "Qwen3.8-27B"]
        payload["outputs"] = outputs + [outputs[0].merging(["path": "/Models/other", "splash": ["family": NSNull(), "reason": "refused"]]) { $1 }]

        let result = try WorkbenchAPI.decodeScan(payload)

        XCTAssertEqual(result.outputs.map(\.splashFamily), ["Qwen3.8-27B", nil])
    }

    func testDecodeScanCarriesDrafterFacts() throws {
        var payload = fixture(named: "convert-scan-valid")
        var models = try XCTUnwrap(payload["models"] as? [[String: Any]])
        models[1]["draft"] = ["port": "deepseek_v4_dspark", "target": "DeepSeek-V4-Flash-0731", "block_size": 5]
        models[1]["task"] = ["type": "speculative_draft", "use_cases": ["speculative_decoding"], "source": "gguf_architecture", "confidence": "confirmed"]
        payload["models"] = models

        let result = try WorkbenchAPI.decodeScan(payload)

        XCTAssertNil(result.models[0].draft)
        XCTAssertEqual(result.models[1].draft, ModelDraft(port: "deepseek_v4_dspark", target: "DeepSeek-V4-Flash-0731", blockSize: 5))
        XCTAssertEqual(result.models[1].task?.type, .speculativeDraft)
    }

    func testDecodeScanRejectsMissingRequiredModelBytes() throws {
        XCTAssertThrowsError(try WorkbenchAPI.decodeScan(fixture(named: "convert-scan-missing-bytes"))) { error in
            XCTAssertEqual(error as? ScanContractError, .invalidRequiredField("models[0].bytes"))
        }
    }

    func testDecodeScanAcceptsOlderPayloadWithoutReclaimableBytes() throws {
        var payload = fixture(named: "convert-scan-valid")
        var totals = try XCTUnwrap(payload["totals"] as? [String: Any])
        totals.removeValue(forKey: "reclaimable_bytes")
        payload["totals"] = totals

        let result = try WorkbenchAPI.decodeScan(payload)

        XCTAssertEqual(result.totals.reclaimableBytes, 0)
    }

    private func fixture(named name: String) -> [String: Any] {
        // Shared contract fixtures live at the repo root so the Python
        // suite consumes the same files; see tests/fixtures/README.md.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // mlx-macTests
            .deletingLastPathComponent()  // mlx-mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
