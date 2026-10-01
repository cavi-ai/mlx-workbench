import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class RepoWorkflowTests: XCTestCase {
    private var repoCalls: [(String, String, Int, String?)] = []

    private func resolution(verdict: IntakeVerdict = .convertible, backend: String? = "mlx-audio") throws -> IntakeResolution {
        let json = """
        {"schema":"intake/1","source":{"input":"openai/whisper-tiny","repo":"openai/whisper-tiny","revision":"main","file":null,"url":"https://huggingface.co/openai/whisper-tiny"},
         "verdict":"\(verdict.rawValue)","reasons":[],"backend":\(backend.map { "\"\($0)\"" } ?? "null"),"backend_installed":true,"model_type":"whisper",
         "components":[],"task":{"type":"speech_to_text","use_cases":["transcription"],"source":"pipeline_tag","confidence":"confirmed"},
         "custom_code":false,"gated":false,"library_name":"transformers","pipeline_tag":"automatic-speech-recognition","transformers_version":null,
         "bytes":151000000,"files":{"safetensors":1,"gguf":[],"python":[]},"warnings":[]}
        """
        return try JSONDecoder().decode(IntakeResolution.self, from: Data(json.utf8))
    }

    private func coordinator() -> ModelWorkflowCoordinator {
        var api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in XCTFail("GGUF preview must not run for a repo source"); return [:] },
            convertStart: { _, _, _, _ in XCTFail("GGUF start must not run for a repo source"); return [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
        api.convertRepoPreview = { [weak self] repo, backend, bits, out in
            self?.repoCalls.append((repo, backend, bits, out))
            return ["preview_hash": "repo-hash"]
        }
        api.convertRepoStart = { _, _, _, _, _ in ["receipt": "repo-receipt"] }
        return ModelWorkflowCoordinator(api: api, persistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }))
    }

    func testRepoWorkflowPreviewsAndConfirmsThroughTheBackend() async throws {
        let workflow = coordinator()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)").path
        workflow.inspect(intake: try resolution(), outputDirectory: output, qBits: 4, snapshot: nil)
        XCTAssertEqual(workflow.workflow.sourceRepo, "openai/whisper-tiny")
        XCTAssertEqual(workflow.workflow.backend, "mlx-audio")
        XCTAssertEqual(workflow.workflow.outputPath, output + "/whisper-tiny-MLX-4bit")
        await workflow.preview(qBits: 4, out: nil)
        XCTAssertEqual(workflow.workflow.state, .readyToConfirm)
        XCTAssertEqual(repoCalls.first?.0, "openai/whisper-tiny")
        XCTAssertEqual(repoCalls.first?.1, "mlx-audio")
        await workflow.confirm(qBits: 4)
        XCTAssertEqual(workflow.workflow.state, .queued)
        XCTAssertEqual(workflow.workflow.jobReceipt, "repo-receipt")
        XCTAssertEqual(workflow.workflow.sourceRepo, "openai/whisper-tiny")
    }

    func testRepoPreviewRefusesAnOccupiedDestination() async throws {
        let workflow = coordinator()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output.appendingPathComponent("whisper-tiny-MLX-4bit"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        workflow.inspect(intake: try resolution(), outputDirectory: output.path, qBits: 4, snapshot: nil)
        await workflow.preview(qBits: 4, out: nil)
        XCTAssertEqual(workflow.workflow.state, .failed)
        XCTAssertTrue(repoCalls.isEmpty)
    }

    func testNonTextCompletionSkipsTheCanary() throws {
        let verifier = RecordingVerifier()
        for (type, expected, calls) in [(ModelTaskType.speechToText, ConversionWorkflowState.completed, 0), (.textLLM, .verifying, 1)] {
            let workflow = coordinator()
            workflow.completionVerifier = verifier
            verifier.calls = 0
            let output = "/models/mlx/out-\(type.rawValue)"
            workflow.restore(Self.record(output: output))
            workflow.resolveCompletionAfterFreshScan(snapshot: Self.snapshot(output: output, type: type))
            XCTAssertEqual(workflow.workflow.state, expected, type.rawValue)
            XCTAssertEqual(verifier.calls, calls, type.rawValue)
            if type == .speechToText {
                XCTAssertTrue(workflow.workflow.message?.contains("Speech-to-text") ?? false)
            }
        }
    }

    func testScanRootsIncludeTheOutputDirectoryOnce() {
        var config = Config.defaults()
        let gguf = ["/models/gguf"]
        config.mlxRoots = ["/models/mlx", "/models/other"]
        config.outputDir = "/models/mlx"
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: gguf), ["/models/mlx", "/models/other"])
        config.outputDir = "/models/converted"
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: gguf), ["/models/mlx", "/models/other", "/models/converted"])
        config.outputDir = ""
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: gguf), ["/models/mlx", "/models/other"])
    }

    /// With no MLX roots configured the agent scans the GGUF roots for MLX
    /// outputs; adding the output directory must not replace that default.
    func testEmptyMLXRootsKeepTheGGUFRootsDefault() {
        var config = Config.defaults()
        config.mlxRoots = []
        config.outputDir = "/models/converted"
        let gguf = ["/models/gguf", "/cache/hub"]
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: gguf), ["/models/gguf", "/cache/hub", "/models/converted"])
        config.outputDir = ""
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: gguf), [])
    }

    func testPrepareServeRefusesNonServableModel() throws {
        let workflow = coordinator()
        let snapshot = Self.snapshot(output: "/models/mlx/asr", type: .speechToText)
        let model = try XCTUnwrap(snapshot.models.first)
        workflow.prepareServe(model: model)
        XCTAssertEqual(workflow.workflow.serveState, .failed)
        XCTAssertTrue(workflow.workflow.errorMessage?.contains("Speech-to-text") ?? false)
    }

    func testCompareCandidatesExcludeNonServable() throws {
        let asr = try XCTUnwrap(Self.snapshot(output: "/m/asr", type: .speechToText).models.first)
        let chat = try XCTUnwrap(Self.snapshot(output: "/m/chat", type: .textLLM).models.first)
        XCTAssertEqual(ComparePresentation.candidates(from: [asr, chat]).map(\.item.path), ["/m/chat"])
    }

    private static func record(output: String) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(), sourcePath: "hf://org/model", sourceModelKey: nil, sourceSignature: nil,
            outputPath: output, previewHash: "h", jobReceipt: "r", completedModelPath: nil,
            state: .running, serveState: .idle, message: nil, errorMessage: nil,
            createdAt: Date(), updatedAt: Date(), lastKnownAgentState: "running",
            sourceRepo: "org/model", backend: "mlx-audio"
        )
    }

    private static func snapshot(output: String, type: ModelTaskType) -> LibrarySnapshot {
        let task = ModelTask(type: type, useCases: [], source: "registry", confidence: "confirmed")
        let scan = ScanResult(
            roots: nil, models: [],
            outputs: [MLXOutput(path: output, name: "out", modelKey: "out", quantization: QuantInfo(bits: 4, groupSize: 64, modelType: nil), provenance: nil, task: task)],
            pending: [], duplicates: [],
            totals: ScanTotals(gguf: 0, pending: 0, converted: 0, unreadable: 0, bytes: 0, reclaimableBytes: 0)
        )
        return ModelLibraryBuilder.build(scan: scan, hardware: HardwareProfile.current(), now: Date())
    }
}

private final class RecordingVerifier: ConversionCompletionVerifying {
    var calls = 0
    func beginVerification(recordID: UUID, modelPath: String, signature: String?) { calls += 1 }
}
