import Foundation
import AppKit
import SwiftUI
import XCTest

@testable import mlx_workbench

final class MenuBarTests: XCTestCase {
    private func slot(_ path: String, port: Int = 8080, enabled: Bool = true) -> EndpointSlot {
        EndpointSlot(enabled: enabled, port: port, modelPath: path)
    }

    func testModelNameIsTheLastComponentOfANonexistentPath() {
        XCTAssertEqual(MenuBarPresentation.modelName("/nonexistent/models/Qwen3-8B-4bit"), "Qwen3-8B-4bit")
        XCTAssertEqual(MenuBarPresentation.modelName("/nonexistent/models/Qwen3-8B-4bit/"), "Qwen3-8B-4bit")
        XCTAssertEqual(MenuBarPresentation.modelName("org-model"), "org-model")
        XCTAssertEqual(MenuBarPresentation.modelName(""), "No model")
        XCTAssertEqual(MenuBarPresentation.slotTitle(slot("", port: 8080, enabled: false)), "Start No model · :8080")
    }

    func testServingChoiceReusesSavedModelsAndUsesInventoryNames() {
        let item = ModelItem(path: "/cache/snapshots/hash", name: "Qwen3-8B", bytes: 4, modifiedAt: nil,
            shard: nil, modelKey: "qwen3", architecture: nil, quantization: nil, parameters: nil,
            structure: nil, signature: "s", companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil)
        let model = LibraryModel(item: item)
        XCTAssertEqual(MenuBarPresentation.modelName(item.path, models: [model]), "Qwen3-8B")
        XCTAssertEqual(ServedModelsSelection.candidates(models: [model], slots: [], query: "QWEN").count, 1)
        XCTAssertTrue(ServedModelsSelection.candidates(models: [model], slots: [slot(item.path)], query: "").isEmpty)
        XCTAssertTrue(ServedModelsSelection.candidates(models: [model], slots: [], query: "llama").isEmpty)
        XCTAssertEqual(ServedModelsSelection.nextPort(slots: [slot("a", port: 8766)], servers: []), 8767)
    }

    func testConnectionDetailsRequireTheSelectedRunningModel() throws {
        let endpoint = slot("/models/qwen", port: 8766)
        let running = ServerInfo(repo: endpoint.modelPath, runtime: "mlx", port: endpoint.port, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "r")
        let state = EndpointState.running(modelPath: endpoint.modelPath, port: endpoint.port)
        XCTAssertEqual(ServedModelsSelection.connection(slot: endpoint, state: state, servers: [running])?.modelName, endpoint.modelPath)
        XCTAssertNil(ServedModelsSelection.connection(slot: endpoint, state: .disabled, servers: [running]))
        XCTAssertNil(ServedModelsSelection.connection(slot: endpoint, state: .modelMismatch(servedModel: "other", port: endpoint.port), servers: [running]))
        XCTAssertNil(ServedModelsSelection.connection(slot: endpoint, state: state, servers: []))
        XCTAssertEqual(MenuBarPresentation.availability(endpoint, state: .starting, residency: nil), "Starting…")
    }

    @MainActor
    func testServedModelsAndFamilyReviewsRenderWithoutStartingLiveServices() async throws {
        let stateRoot = WorkbenchStatePaths.hostedTestRoot
        let world = FakeServeWorld()
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/Qwen3-8B-4bit", loadOnRequest: true, memoryPolicy: .automatic)
        world.preload(repo: slot.modelPath, port: slot.port, jit: true, modelState: "unloaded", memoryPolicy: .automatic)
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: stateRoot.appendingPathComponent("render-fleet.json"))
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false)])
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore(fileURL: stateRoot.appendingPathComponent("render-endpoint.json")), fleetStore: fleet)
        let app = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", agentHealth: .notConfigured, runtimeReport: .checking, endpoint: supervisor)
        await supervisor.reconcile()
        let models = ["Qwen3-8B-4bit", "Qwen3-8B-abliterated-8bit", "Qwen3-8B-coding-4bit"].map { name in
            LibraryModel(item: ModelItem(path: "/models/" + name, name: name, bytes: 5_000_000_000, modifiedAt: nil,
                shard: nil, modelKey: name, architecture: "qwen3", quantization: "4-bit", parameters: "8B", structure: nil,
                signature: "weights-" + name, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil))
        }
        app.librarySnapshot = LibrarySnapshot(models: models, groups: [], hardware: app.hardwareProfile, generatedAt: Date())
        await app.comparison.waitForHistory(); await app.modelPurposes.waitForHistory()
        _ = await app.modelPurposes.save(path: models[1].item.path, signature: models[1].item.signature, note: "Abliterated creative writing")
        for width in [560, 800] {
            for dark in [false, true] {
                for family in [false, true] {
                    let view = family
                        ? AnyView(ModelFamilyReviewView(appHost: app, onCompare: {}, onReviewRemoval: { _ in }))
                        : AnyView(ServedModelsView(appHost: app))
                    let hosting = NSHostingView(rootView: view.padding().frame(width: CGFloat(width), height: 700)
                        .background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = hosting
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.orderFront(nil)
                    hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "\(family ? "family" : "served")-\(width)-\(dark ? "dark" : "light")"
                    let capture = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    capture.name = name; capture.lifetime = .keepAlways; add(capture)
                    if let folder = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDER_OUTPUT"] {
                        let url = URL(fileURLWithPath: folder)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        try data.write(to: url.appendingPathComponent(name + ".png"))
                    }
                    window.close()
                }
            }
        }
        XCTAssertEqual(app.endpoint.fleet.slots, [slot])
        XCTAssertEqual(try world.status().count, 1)
        XCTAssertNil(app.comparison.activeRunID)
        XCTAssertNil(app.handoffs[.compareFamily])
    }

    func testFleetIconIgnoresDisabledSlotsLeftInAStaleState() {
        let off = slot("/m/a", port: 1, enabled: false)
        let on = slot("/m/b", port: 2)
        let states: [UUID: EndpointState] = [off.id: .degraded(reason: "x"), on.id: .running(modelPath: "/m/b", port: 2)]
        XCTAssertEqual(MenuBarPresentation.fleetIcon(slots: [off, on], states: states), "bolt.fill")
        XCTAssertEqual(MenuBarPresentation.fleetIcon(slots: [off], states: states), "bolt.slash")
        XCTAssertEqual(MenuBarPresentation.fleetIcon(slots: [on], states: [:]), "bolt.slash")
    }

    func testSlotTitleNamesTheActionTheItemPerforms() {
        XCTAssertEqual(MenuBarPresentation.slotTitle(slot("/nonexistent/qwen", port: 8081, enabled: true)), "Stop qwen · :8081")
        XCTAssertEqual(MenuBarPresentation.slotTitle(slot("/nonexistent/qwen", port: 8081, enabled: false)), "Start qwen · :8081")
    }

    func testFleetSummaryCountsRunningAmongEnabledSlots() {
        let running = slot("/m/a", port: 1)
        let starting = slot("/m/b", port: 2)
        let off = slot("/m/c", port: 3, enabled: false)
        let states: [UUID: EndpointState] = [
            running.id: .running(modelPath: "/m/a", port: 1),
            starting.id: .starting,
            off.id: .disabled,
        ]
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [running, starting, off], states: states), "1 of 2 endpoints running")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [running], states: states), "1 of 1 endpoint running")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [off], states: states), "No always-on endpoints")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [], states: [:]), "No always-on endpoints")
        XCTAssertEqual(MenuBarPresentation.fleetSummary(slots: [slot("", port: 4)], states: [:]), "No always-on endpoints")
    }

    func testIconsFollowTheSlotState() {
        XCTAssertEqual(EndpointIcon.name(for: .running(modelPath: "/m", port: 1)), "bolt.fill")
        XCTAssertEqual(EndpointIcon.name(for: .disabled), "bolt.slash")
        XCTAssertEqual(EndpointIcon.name(forStates: [.disabled, .starting]), "bolt.horizontal")
        XCTAssertEqual(EndpointIcon.name(forStates: [.running(modelPath: "/m", port: 1), .degraded(reason: "x")]), "exclamationmark.triangle")
    }

    func testMenuBodyBuildsNoFileURLsAndKeepsQuitShortcut() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/MenuBarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("URL(fileURLWithPath:"))
        XCTAssertFalse(source.contains("HStack"))
        XCTAssertFalse(source.contains("(spec 09"))
        XCTAssertTrue(source.contains("Button(\"Open MLX Workbench\")"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"q\")"))
    }
}
