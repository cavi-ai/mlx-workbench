import AppKit
import SwiftUI
import XCTest
@testable import mlx_workbench

@MainActor
final class HostedModelsRenderTests: XCTestCase {
    func testNativeRequestsReturnFromHostedWorkspaceWithoutStartingWork() async throws {
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: "/state/config.json",
            agentHealth: .notConfigured, runtimeReport: report())
        host.compareHostedModels = true
        let hosting = NSHostingView(rootView: ComparisonWorkspace(appHost: host).frame(width: 1100, height: 820))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let model = LibraryModel(item: ModelItem(path: "/Models/native", name: "Native", bytes: 100, modifiedAt: nil,
            shard: nil, modelKey: "native", architecture: nil, quantization: "q4", parameters: nil, structure: nil,
            signature: "sha", companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil,
            task: ModelTask(type: .textLLM, useCases: [], source: "registry", confidence: "confirmed")), readiness: .ready)
        host.librarySnapshot = LibrarySnapshot(models: [model], groups: [], hardware: .current(), generatedAt: Date())
        host.modelComparisonRequest = try XCTUnwrap(ComparisonModelRequest(model: model))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(host.compareHostedModels)
        XCTAssertNil(host.modelComparisonRequest)
        XCTAssertNil(host.comparison.activeRunID)
        host.compareHostedModels = true
        let baseline = ServingProfile(id: UUID(), name: "Baseline", modelPath: model.item.path, options: StrataComparisonOptions())
        let candidate = ServingProfile(id: UUID(), name: "Candidate", modelPath: model.item.path, options: StrataComparisonOptions(speculation: true))
        host.servingProfileComparisonRequest = try ServingProfileComparisonSetup(baseline: baseline, candidate: candidate)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(host.compareHostedModels)
        XCTAssertNil(host.comparison.activeRunID)
        XCTAssertNil(host.hostedComparison.activeRunID)
    }

    func testHostInventoryAndComparisonStatesRender() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = ModelHost(name: "Ollama", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        let inventory = HostInventory(host: connection, models: (1...12).map { index in
            HostedModel(hostID: connection.id, modelID: "model-\(index):q4", name: "Qwen model \(index)", digest: "digest-\(index)",
                family: "qwen", parameters: "8B", quantization: "Q4_K_M", format: "gguf", sizeBytes: 4_500_000_000,
                isLoaded: index == 1, contextLength: index == 1 ? 8192 : nil, memoryBytes: index == 1 ? 5_000_000_000 : nil)
        }, capturedAt: Date(timeIntervalSince1970: 1_792_512_000), runtimeVersion: "0.12")
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { _, _ in inventory })
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: root.appendingPathComponent("config.json").path,
            agentHealth: .notConfigured, runtimeReport: report(), modelHosts: hosts)
        for dark in [false, true] {
            try await capture(HostedModelsView(appHost: host), name: "hosts-empty", dark: dark)
        }
        try hosts.save(connection, token: nil, replaceToken: false)
        for dark in [false, true] {
            try await capture(HostedModelsView(appHost: host), name: "hosts-unrefreshed", dark: dark)
        }
        await hosts.refresh(connection.id)
        host.hostedComparisonTargets = inventory.models.prefix(2).map { HostedComparisonTarget(host: connection, model: $0, capturedAt: inventory.capturedAt) }
        for dark in [false, true] {
            try await capture(HostedModelsView(appHost: host), name: "hosts-populated", dark: dark)
            try await capture(HostedModelsView(appHost: host), name: "hosts-minimum", dark: dark, width: 740)
            try await capture(HostedComparisonView(appHost: host), name: "hosted-compare-setup", dark: dark)
            try await capture(QuantView(appHost: host), name: "native-compare-preserved", dark: dark)
        }
    }

    private func report() -> RuntimeReport {
        RuntimeReport(convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready"),
            serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready"), install: "make install", ok: true)
    }

    private func capture<Content: View>(_ view: Content, name: String, dark: Bool, width: CGFloat = 1100) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 820).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let filename = "\(name)-\(dark ? "dark" : "light")-\(Int(width))"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = filename; attachment.lifetime = .keepAlways; add(attachment)
        if let destination = ProcessInfo.processInfo.environment["MLX_HOST_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename + ".png"))
        }
    }
}
