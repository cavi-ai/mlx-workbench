import Foundation
import XCTest

@testable import mlx_workbench

private actor RenderCalls {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

final class ImageGenerationTests: XCTestCase {
    private func result(width: Int = 512, height: Int = 512, spread: Double? = 83.6, path: String = "/tmp/x.png") -> GenerationResult {
        GenerationResult(path: path, width: width, height: height, steps: 20, seed: 42, seconds: 31.9, loadSeconds: 6, pixelStd: spread)
    }

    func testImageCanaryNeedsAWrittenNonBlankImageAtTheRequestedSize() {
        let pass = ImageCanary.evaluate(result(), fileExists: { _ in true })
        XCTAssertTrue(pass.passed)
        XCTAssertEqual(pass.responseExcerpt, "512 × 512 in 31.9 s, pixel spread 83.6")
        XCTAssertEqual(ImageCanary.evaluate(result(spread: 3), fileExists: { _ in true }).failureReason, "The image is blank (pixel spread 3.0).")
        XCTAssertEqual(ImageCanary.evaluate(result(width: 256), fileExists: { _ in true }).failureReason, "Rendered 256 × 512, expected 512 × 512.")
        XCTAssertEqual(ImageCanary.evaluate(result(), fileExists: { _ in false }).failureReason, "No image was written.")
        XCTAssertFalse(ImageCanary.evaluate(result(spread: nil), fileExists: { _ in true }).passed)
    }

    func testGenerationResultDecodesTheAgentPayload() throws {
        let json = #"{"path":"/p.png","width":768,"height":768,"steps":30,"seed":7,"seconds":57.8,"load_seconds":5.5,"pixel_std":71.1}"#
        let value = try JSONDecoder().decode(GenerationResult.self, from: Data(json.utf8))
        XCTAssertEqual(value, GenerationResult(path: "/p.png", width: 768, height: 768, steps: 30, seed: 7, seconds: 57.8, loadSeconds: 5.5, pixelStd: 71.1))
        XCTAssertEqual(ImageGenerationPresentation.caption(value), "768 × 768 · 30 steps · seed 7 · 57.8 s")
    }

    func testOutputNamesTheModelTimeAndSeed() {
        let date = Date(timeIntervalSince1970: 1_790_977_658)
        let url = ImageGenerationCoordinator.outputURL(directory: URL(fileURLWithPath: "/pics"), modelPath: "/m/qwen-image-MLX-8bit", seed: 7, date: date)
        XCTAssertEqual(url.deletingLastPathComponent().path, "/pics")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("qwen-image-MLX-8bit-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-s7.png"))
    }

    @MainActor
    func testCoordinatorRendersIntoTheOutputDirectoryAndReportsFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = RenderCalls()
        let coordinator = ImageGenerationCoordinator(
            render: { path, out, request in
                await calls.record("\(path)|\(out.deletingLastPathComponent().lastPathComponent)|\(request.prompt)|\(request.size)")
                return GenerationResult(path: out.path, width: request.size, height: request.size, steps: request.steps, seed: request.seed, seconds: 1, loadSeconds: 1, pixelStd: 50)
            },
            outputDirectory: { directory }
        )
        await coordinator.generate(modelPath: "/m/qwen", request: ImageRequest(prompt: "  a lighthouse  ", size: 768))
        guard case let .finished(path, value) = coordinator.state else { return XCTFail("expected a finished render") }
        XCTAssertEqual(path, "/m/qwen")
        XCTAssertEqual(value.width, 768)
        let seen = await calls.values
        XCTAssertEqual(seen, ["/m/qwen|\(directory.lastPathComponent)|a lighthouse|768"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        await coordinator.generate(modelPath: "/m/qwen", request: ImageRequest(prompt: "   "))
        XCTAssertEqual(coordinator.state, ImageGenerationCoordinator.State.failed(modelPath: "/m/qwen", "Describe the image to generate."))

        let failing = ImageGenerationCoordinator(render: { _, _, _ in throw ImageCanaryError.unavailable }, outputDirectory: { directory })
        await failing.generate(modelPath: "/m/qwen", request: ImageRequest(prompt: "x"))
        guard case .failed = failing.state else { return XCTFail("expected a failure") }
        XCTAssertFalse(failing.isGenerating)
    }
}
