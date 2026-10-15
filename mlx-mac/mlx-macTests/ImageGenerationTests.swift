import Foundation
import AppKit
import SwiftUI
import XCTest

@testable import mlx_workbench

private actor RenderCalls {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor RenderGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

final class ImageGenerationTests: XCTestCase {
    @MainActor
    func testCallerCancellationReachesTheRenderAndAllowsAFreshAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = RenderCalls()
        let coordinator = ImageGenerationCoordinator(render: { path, out, request in
            await calls.record(request.prompt)
            if request.prompt == "wait" { try await Task.sleep(for: .seconds(60)) }
            return GenerationResult(path: out.path, width: 512, height: 512, steps: 40, seed: 42,
                seconds: 1, loadSeconds: 1, pixelStd: 50)
        }, outputDirectory: { directory })
        let task = Task { await coordinator.generate(modelPath: "/m/qwen", request: ImageRequest(prompt: "wait")) }
        for _ in 0..<100 {
            if await calls.values.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel(); await task.value
        XCTAssertEqual(coordinator.state, .cancelled(modelPath: "/m/qwen"))
        await coordinator.generate(modelPath: "/m/qwen", request: ImageRequest(prompt: "retry"))
        guard case .finished = coordinator.state else { return XCTFail("A settled cancellation must allow a fresh render") }
        let seen = await calls.values
        XCTAssertEqual(seen, ["wait", "retry"])
    }

    @MainActor
    func testNativeCancelControlRetainsBusyStateAndIsScopedToItsModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RenderGate()
        let coordinator = ImageGenerationCoordinator(render: { _, _, _ in
            await gate.wait(); throw CancellationError()
        }, outputDirectory: { directory })
        let task = Task { await coordinator.generate(modelPath: "/m/qwen", request: ImageRequest(prompt: "test")) }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let other = NSHostingView(rootView: ImageGenerationCancelButton(coordinator: coordinator, modelPath: "/m/other").buttonStyle(.borderless))
        window.contentView = other; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150)); other.layoutSubtreeIfNeeded()
        XCTAssertNil(nativeButton(other))
        let control = NSHostingView(rootView: ImageGenerationCancelButton(coordinator: coordinator, modelPath: "/m/qwen").buttonStyle(.borderless))
        window.contentView = control
        try await Task.sleep(for: .milliseconds(150)); control.layoutSubtreeIfNeeded()
        try await capturePanel(coordinator, state: "rendering", window: window)
        window.contentView = control
        try XCTUnwrap(nativeButton(control)).performClick(nil)
        try await Task.sleep(for: .milliseconds(150)); control.layoutSubtreeIfNeeded()
        XCTAssertTrue(coordinator.isGenerating); XCTAssertTrue(coordinator.isCancelling)
        XCTAssertFalse(try XCTUnwrap(nativeButton(control)).isEnabled)
        try await capturePanel(coordinator, state: "cancelling", window: window)
        await gate.open(); await task.value
        try await capturePanel(coordinator, state: "cancelled", window: window)
        window.contentView = control
        try await Task.sleep(for: .milliseconds(150)); control.layoutSubtreeIfNeeded()
        XCTAssertNil(nativeButton(control))
    }

    @MainActor
    private func nativeButton(_ view: NSView) -> NSButton? {
        (view as? NSButton) ?? view.subviews.compactMap { nativeButton($0) }.first
    }

    @MainActor
    private func capturePanel(_ coordinator: ImageGenerationCoordinator, state: String, window: NSWindow) async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_IMAGE_RENDER_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: ImageGenerationPanel(coordinator: coordinator, modelPath: "/m/qwen")
            .padding(20).frame(width: 420, height: 440).background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(state).png"))
    }

    @MainActor
    func testLocalImageCancellationWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_IMAGE_CANCEL_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_IMAGE_CANCEL_MANIFEST for real image-worker cancellation acceptance.")
        }
        struct Manifest: Decodable { let agentPath: String; let modelPath: String; let evidenceRoot: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: manifest.evidenceRoot), model = URL(fileURLWithPath: manifest.modelPath)
        let before = try Data(contentsOf: model.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("existing.png"), kept = Data("existing output".utf8)
        try kept.write(to: existing)
        let registry = CLIProcessRegistry(notificationCenter: NotificationCenter())
        defer { registry.terminateAll(grace: CLIProcess.terminationGrace) }
        let api = WorkbenchAPI(cli: CLIProcess(registry: registry), agentPath: manifest.agentPath, receiptDirectory: root.path)
        let coordinator = ImageGenerationCoordinator(render: { path, out, request in
            try await api.generate(path: path, out: out.path, request: request)
        }, outputDirectory: { root })
        let finished = expectation(description: "real image worker cancelled")
        let task = Task {
            await coordinator.generate(modelPath: manifest.modelPath, request: ImageRequest(prompt: "A lighthouse on a rocky coast", size: 512, steps: 40))
            finished.fulfill()
        }
        try await Task.sleep(for: .seconds(20))
        XCTAssertTrue(coordinator.isGenerating, "\(coordinator.state)")
        let control = NSHostingView(rootView: ImageGenerationCancelButton(coordinator: coordinator, modelPath: manifest.modelPath).buttonStyle(.borderless))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = control; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); control.layoutSubtreeIfNeeded()
        try XCTUnwrap(nativeButton(control)).performClick(nil)
        await fulfillment(of: [finished], timeout: 30)
        guard !coordinator.isGenerating else {
            task.cancel()
            return XCTFail("The image worker did not return after cancellation")
        }
        XCTAssertEqual(coordinator.state, .cancelled(modelPath: manifest.modelPath))
        XCTAssertFalse(coordinator.isGenerating)
        XCTAssertEqual(try Data(contentsOf: existing), kept)
        XCTAssertEqual(try Data(contentsOf: model.appendingPathComponent("config.json")), before)
        try Data("cancelled".utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
        await task.value
    }

    @MainActor
    func testCancellationKeepsOwnershipUntilRenderReturnsAndRejectsALateImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RenderGate(), calls = RenderCalls()
        let coordinator = ImageGenerationCoordinator(render: { path, out, request in
            await calls.record(path)
            await gate.wait()
            try Data("partial output".utf8).write(to: out)
            return GenerationResult(path: out.path, width: 512, height: 512, steps: 40, seed: 42,
                seconds: 1, loadSeconds: 1, pixelStd: 50)
        }, outputDirectory: { directory })
        let task = Task { await coordinator.generate(modelPath: "/m/first", request: ImageRequest(prompt: "test")) }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.cancel(modelPath: "/m/other")
        XCTAssertFalse(coordinator.isCancelling)
        coordinator.cancel(modelPath: "/m/first")
        coordinator.cancel(modelPath: "/m/first")
        XCTAssertTrue(coordinator.isGenerating); XCTAssertTrue(coordinator.isCancelling)
        await coordinator.generate(modelPath: "/m/second", request: ImageRequest(prompt: "other"))
        let seen = await calls.values
        XCTAssertEqual(seen, ["/m/first"])
        await gate.open(); await task.value
        XCTAssertFalse(coordinator.isGenerating); XCTAssertFalse(coordinator.isCancelling)
        XCTAssertEqual(coordinator.state, .cancelled(modelPath: "/m/first"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), Data("partial output".utf8))
    }

    func testBackToBackOutputsHaveIndependentNames() {
        let directory = URL(fileURLWithPath: "/pics"), date = Date(timeIntervalSince1970: 1_790_977_658)
        let first = ImageGenerationCoordinator.outputURL(directory: directory, modelPath: "/m/qwen", seed: 42, date: date)
        let second = ImageGenerationCoordinator.outputURL(directory: directory, modelPath: "/m/qwen", seed: 42, date: date)
        XCTAssertNotEqual(first, second)
    }

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
