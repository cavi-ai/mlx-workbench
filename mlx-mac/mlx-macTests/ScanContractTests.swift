import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

final class ScanContractTests: XCTestCase {
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
