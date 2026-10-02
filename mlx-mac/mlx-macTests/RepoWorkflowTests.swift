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

    /// The destination opened at the configured bit width; an 8-bit preview
    /// must name its own folder, not write 8-bit weights into "-MLX-4bit".
    func testRepoPreviewNamesTheDestinationForTheChosenBits() async throws {
        let workflow = coordinator()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)").path
        workflow.inspect(intake: try resolution(), outputDirectory: output, qBits: 4, snapshot: nil)
        await workflow.preview(qBits: 8, out: nil)
        XCTAssertEqual(workflow.workflow.state, .readyToConfirm)
        XCTAssertEqual(repoCalls.first?.2, 8)
        XCTAssertEqual(repoCalls.first?.3, output + "/whisper-tiny-MLX-8bit")
        XCTAssertEqual(workflow.workflow.outputPath, output + "/whisper-tiny-MLX-8bit")
        await workflow.confirm(qBits: 8)
        XCTAssertEqual(workflow.workflow.state, .queued)
    }

    /// A 4-bit output already in the library must not block an 8-bit
    /// conversion: the picker moves the destination, and moving back offers
    /// the existing model again.
    func testBitPickerOffersAnotherWidthWhenOneIsConverted() async throws {
        let workflow = coordinator()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)").path
        let existing = directory + "/whisper-tiny-MLX-4bit"
        workflow.inspect(intake: try resolution(), outputDirectory: directory, qBits: 4, snapshot: Self.snapshot(output: existing, type: .speechToText))
        XCTAssertEqual(workflow.workflow.state, .existingModelFound)
        let id = workflow.workflow.id

        workflow.selectRepoBits(8)
        XCTAssertEqual(workflow.workflow.state, .inspectingSource)
        XCTAssertEqual(workflow.workflow.outputPath, directory + "/whisper-tiny-MLX-8bit")
        XCTAssertNil(workflow.workflow.completedModelPath)
        XCTAssertEqual(workflow.workflow.id, id)
        await workflow.preview(qBits: 8, out: nil)
        XCTAssertEqual(workflow.workflow.state, .readyToConfirm)
        XCTAssertEqual(repoCalls.first?.3, directory + "/whisper-tiny-MLX-8bit")

        workflow.selectRepoBits(4)
        XCTAssertEqual(workflow.workflow.state, .readyToConfirm, "a previewed intent is not rewritten by the picker")
        let fresh = coordinator()
        fresh.inspect(intake: try resolution(), outputDirectory: directory, qBits: 8, snapshot: Self.snapshot(output: existing, type: .speechToText))
        fresh.selectRepoBits(4)
        XCTAssertEqual(fresh.workflow.state, .existingModelFound)
        XCTAssertEqual(fresh.workflow.completedModelPath, existing)
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

    func testCompletionRunsTheCanaryOnlyForTypesThatHaveOne() throws {
        let verifier = RecordingVerifier()
        for (type, expected, calls) in [
            (ModelTaskType.textToSpeech, ConversionWorkflowState.completed, 0),
            (.speechToText, .verifying, 1),
            (.textLLM, .verifying, 1),
        ] {
            let workflow = coordinator()
            workflow.completionVerifier = verifier
            verifier.calls = 0
            let output = "/models/mlx/out-\(type.rawValue)"
            workflow.restore(Self.record(output: output))
            workflow.resolveCompletionAfterFreshScan(snapshot: Self.snapshot(output: output, type: type))
            XCTAssertEqual(workflow.workflow.state, expected, type.rawValue)
            XCTAssertEqual(verifier.calls, calls, type.rawValue)
            if type == .textToSpeech {
                XCTAssertTrue(workflow.workflow.message?.contains("Text-to-speech") ?? false)
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

    /// An output directory under a scanned root is already covered; a second
    /// root for it listed every converted model twice. Containment is by file
    /// identity, so a case-variant spelling of the root counts as that root.
    func testOutputInsideARootIsNotScannedTwice() {
        var config = Config.defaults()
        config.mlxRoots = []
        config.outputDir = "/Users/f/models/mlx"
        let sameDirectory = NSString(string: "inode-1")
        let identity: (String) -> NSObject? = { ["/Users/f/Models": sameDirectory, "/Users/f/models": sameDirectory][$0] }
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: ["/Users/f/Models", "/cache/hub"], fileIdentity: identity), ["/Users/f/Models", "/cache/hub"])
        config.outputDir = "/models/gguf/mlx"
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: ["/models/gguf"]), ["/models/gguf"])
        config.outputDir = "/models/ggufs"
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: ["/models/gguf"]), ["/models/gguf", "/models/ggufs"])
    }

    func testFileIdentityTreatsACaseVariantAsTheSameRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("scan-roots-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mlx"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let variant = base.appendingPathComponent("models").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: variant), "case-sensitive volume")
        var config = Config.defaults()
        config.mlxRoots = []
        config.outputDir = variant + "/mlx"
        XCTAssertEqual(AppHost.scanMLXRoots(config, ggufRoots: [root.path]), [root.path])
    }

    func testPrepareRefreshesStatusOnlyWhileAConversionIsInFlight() {
        let inFlight = [ConversionWorkflowState.queued, .running, .verifying]
        for state in [ConversionWorkflowState.idle, .inspectingSource, .existingModelFound, .previewingConversion, .readyToConfirm,
                      .queued, .running, .completed, .verifying, .verified, .verificationFailed, .failed] {
            XCTAssertEqual(state.isInFlight, inFlight.contains(state), state.rawValue)
        }
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
