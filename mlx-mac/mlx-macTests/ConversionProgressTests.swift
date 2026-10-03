import Foundation
import XCTest

@testable import mlx_workbench

final class ConversionProgressTests: XCTestCase {
    func testFractionIsBytesWrittenOverTheEstimateOnceWritingStarts() {
        let loading = ConversionProgressSnapshot(writtenBytes: 0, estimatedBytes: 5_000, logLines: [])
        XCTAssertNil(loading.fraction)
        XCTAssertEqual(loading.phaseTitle, "Loading and quantizing weights")

        let writing = ConversionProgressSnapshot(writtenBytes: 2_000, estimatedBytes: 5_000, logLines: [])
        XCTAssertEqual(writing.fraction ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(writing.phaseTitle, "Writing MLX weights")

        XCTAssertEqual(ConversionProgressSnapshot(writtenBytes: 6_000, estimatedBytes: 5_000, logLines: []).fraction, 1)
        XCTAssertNil(ConversionProgressSnapshot(writtenBytes: 2_000, estimatedBytes: nil, logLines: []).fraction)
    }

    func testLogTailKeepsTheLastStateOfCarriageReturnProgressLines() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = "[INFO] Loading model\nFetching 2 files:   0%|\rFetching 2 files: 100%|\n\n[INFO] Model domain: STT\n"
        try Data(text.utf8).write(to: file)
        XCTAssertEqual(ConversionProgressReader.logTail(at: file.path), [
            "[INFO] Loading model", "Fetching 2 files: 100%|", "[INFO] Model domain: STT",
        ])
        XCTAssertEqual(ConversionProgressReader.logTail(at: file.path, maxLines: 1), ["[INFO] Model domain: STT"])
        XCTAssertEqual(ConversionProgressReader.logTail(at: nil), [])
        XCTAssertEqual(ConversionProgressReader.logTail(at: file.path + ".missing"), [])
    }

    func testWrittenBytesSumsTheOutputTree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 1_000).write(to: directory.appendingPathComponent("model.safetensors"))
        try Data(count: 24).write(to: directory.appendingPathComponent("sub/config.json"))
        XCTAssertEqual(ConversionProgressReader.writtenBytes(at: directory.path), 1_024)
        XCTAssertEqual(ConversionProgressReader.writtenBytes(at: directory.path + "-missing"), 0)
    }

    func testAgentTimestampsParseWithMicroseconds() {
        let date = ConversionProgressReader.date(fromAgentTimestamp: "2026-10-02T21:47:38.955462+00:00")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_790_977_658, accuracy: 1)
        XCTAssertNil(ConversionProgressReader.date(fromAgentTimestamp: nil))
        XCTAssertNil(ConversionProgressReader.date(fromAgentTimestamp: "yesterday"))
        XCTAssertEqual(ConversionProgressReader.elapsedText(seconds: 83), "1:23")
        XCTAssertEqual(ConversionProgressReader.elapsedText(seconds: 3_725), "1:02:05")
    }

    @MainActor
    func testRepoWorkflowCarriesTheIntakeEstimateForTheChosenBits() throws {
        let workflow = ModelWorkflowCoordinator(
            api: ModelWorkflowAPI(
                convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
                servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] }
            ),
            persistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
        )
        let json = """
        {"schema":"intake/1","source":{"input":"org/thing","repo":"org/thing","revision":"main","file":null,"url":"u"},
         "verdict":"convertible","reasons":[],"backend":"mlx-lm","backend_installed":true,"model_type":"qwen2",
         "components":[],"task":null,"custom_code":false,"gated":false,"library_name":null,"pipeline_tag":null,
         "transformers_version":null,"bytes":10,"estimated_output_bytes":{"4":400,"8":800},
         "files":{"safetensors":1,"gguf":[],"python":[]},"warnings":[]}
        """
        let intake = try JSONDecoder().decode(IntakeResolution.self, from: Data(json.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString)").path
        workflow.inspect(intake: intake, outputDirectory: directory, qBits: 4, snapshot: nil)
        XCTAssertEqual(workflow.workflow.estimatedOutputBytes, ["4": 400, "8": 800])
        XCTAssertEqual(ConversionProgressSnapshot.estimate(for: workflow.workflow), 400)
        workflow.selectRepoBits(8)
        XCTAssertEqual(ConversionProgressSnapshot.estimate(for: workflow.workflow), 800)
        XCTAssertEqual(workflow.workflow.modelType, "qwen2")
    }
}
