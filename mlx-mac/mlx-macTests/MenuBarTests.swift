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
                        : AnyView(ServeView(appHost: app))
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
        XCTAssertTrue(source.contains("Button(\"Open Serving\")"))
        XCTAssertFalse(source.contains("Manage served models"))
    }

    // MARK: - Serving rows on the quick surfaces

    private let managedReceipts = "/receipts/workbench"

    private func engineServer(_ path: String, port: Int, pid: Int, managed: Bool, residency: String) -> ServerInfo {
        ServerInfo(path: path, runtime: "mlx_lm", port: port, pid: pid, state: "running", jit: true,
                   modelState: residency, workerPid: pid + 100, activeRequests: 0,
                   receiptsDirectory: managed ? managedReceipts : "/receipts/other", processStartedAt: "process-\(pid)")
    }

    /// One endpoint with its server, one third-party service and one running server no slot owns.
    @MainActor
    private func servingFixture(readInventory: Bool, residency: String = "loaded") async throws -> (header: SystemResourceHeader, rows: [ServingRow]) {
        let stateRoot = WorkbenchStatePaths.hostedTestRoot
        let world = FakeServeWorld()
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/Qwen3-8B-4bit", loadOnRequest: true, memoryPolicy: .automatic)
        world.preload(repo: slot.modelPath, port: slot.port, jit: true, modelState: "loaded", memoryPolicy: .automatic)
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: stateRoot.appendingPathComponent("popover-fleet.json"))
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false)])
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore(fileURL: stateRoot.appendingPathComponent("popover-endpoint.json")), fleetStore: fleet)
        await supervisor.reconcile()
        let owned = engineServer(slot.modelPath, port: slot.port, pid: 10, managed: true, residency: residency)
        let thirdParty = engineServer("/models/ollama-model", port: 11434, pid: 30, managed: false, residency: "unloaded")
        let bare = ServerInfo(path: "/models/bare", port: 9001, pid: 40, state: "running")
        let inventory = ServingInventoryCoordinator(managedReceipts: managedReceipts, now: { Date(timeIntervalSince1970: 1_000) },
            fetchEngine: { ServingEngineSnapshot(servers: [owned, thirdParty]) }, readMemory: { _ in [:] })
        if readInventory { await inventory.refresh() }
        let resources = SystemResourceMonitor(probe: { MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 12_000_000_000) })
        await resources.refreshMemory()
        let servers = [owned, bare]
        let header = SystemResourceHeader(resources: resources, endpoint: supervisor, servingInventory: inventory, servers: servers,
                                          onUnload: { _ in false })
        return (header, ServingRows.build(slots: supervisor.fleet.slots, servers: servers, snapshot: inventory.snapshot))
    }

    @MainActor
    private func host<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, dark: Bool = false) -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: AnyView(view.background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return (window, hosting)
    }

    func testMenuBarTitlesFollowTheServingRowOrder() {
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/Qwen3-8B-4bit")
        let owned = engineServer(slot.modelPath, port: slot.port, pid: 10, managed: true, residency: "loaded")
        let thirdParty = engineServer("/models/ollama-model", port: 11434, pid: 30, managed: false, residency: "unloaded")
        let bare = ServerInfo(path: "/models/bare", port: 9001, pid: 40, state: "running")
        let snapshot = ServingInventorySnapshot.make(engine: [owned, thirdParty], hosts: [], managedReceipts: managedReceipts,
                                                      capturedAt: Date(timeIntervalSince1970: 1_000))
        let rows = ServingRows.build(slots: [slot], servers: [owned, bare], snapshot: snapshot)
        let titles = rows.map { MenuBarPresentation.rowTitle($0) }
        XCTAssertEqual(titles.count, 3)
        XCTAssertEqual(titles[0], "Qwen3-8B-4bit · :8766")
        XCTAssertEqual(titles[1], "bare · :9001")
        XCTAssertEqual(titles[2], "ollama-model · MLX Agent · Available · unloaded")
    }

    func testToolbarLabelNamesLoadedCountOnlyWhenWideAndRead() {
        let twelve: Int64 = 12_000_000_000
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: ServingTally(loaded: 2), compact: false), "2 loaded · ~12.0 GB available")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: ServingTally(loaded: 2), compact: true), "~12.0 GB available")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: nil, compact: false), "~12.0 GB available")
    }

    func testToolbarLinesPutAttentionInABadgeAndShortenInOrder() {
        let twelve: Int64 = 12_000_000_000
        let lines = ResourceHeaderPresentation.lines(availableBytes: twelve, tally: ServingTally(attention: 1, loaded: 2, onRequest: 2))
        XCTAssertEqual(lines, [ResourceHeaderLine(badge: "1 needs attention", text: "2 loaded · 2 on request · ~12.0 GB free"),
                               ResourceHeaderLine(badge: "1 needs attention", text: "~12.0 GB free"),
                               ResourceHeaderLine(badge: "1", text: "12.0 GB")])
        XCTAssertEqual(ResourceHeaderPresentation.lines(availableBytes: twelve, tally: nil).map(\.badge), [nil, nil, nil])
    }

    func testToolbarSurfacesEndpointTroubleOnlyForANonEmptyFleet() {
        let fleet = [slot("/models/a")]
        for state in [EndpointState.starting, .waitingForServer, .modelMismatch(servedModel: "x", port: 8080), .degraded(reason: "down")] {
            XCTAssertEqual(ResourceHeaderPresentation.attentionState(slots: fleet, state: state), state)
            XCTAssertNil(ResourceHeaderPresentation.attentionState(slots: [], state: state))
        }
        XCTAssertNil(ResourceHeaderPresentation.attentionState(slots: fleet, state: .running(modelPath: "/models/a", port: 8080)))
        XCTAssertNil(ResourceHeaderPresentation.attentionState(slots: fleet, state: .disabled))
        let degraded = EndpointState.degraded(reason: "down")
        XCTAssertEqual(EndpointIcon.name(for: degraded), "exclamationmark.triangle")
        XCTAssertEqual(ResourceHeaderPresentation.accessibilityLabel(availableBytes: 12_000_000_000, tally: ServingTally(loaded: 1), attention: degraded),
                       "1 loaded · ~12.0 GB available, endpoint: " + degraded.summary)
        XCTAssertEqual(ResourceHeaderPresentation.accessibilityLabel(availableBytes: nil, tally: nil, attention: nil), "RAM unavailable")
    }

    @MainActor
    func testHostedToolbarLabelNeverAsksForMoreWidthThanOffered() async throws {
        let read = try await servingFixture(readInventory: true, residency: "failed")
        XCTAssertEqual(ServingWorkspacePresentation.tally(read.rows).attention, 1, "the fixture has a model that needs attention")
        /// The width the rendered label takes when the toolbar offers `offered` points.
        func width(offered: CGFloat) -> CGFloat {
            let hosting = NSHostingController(rootView: read.header)
            return hosting.sizeThatFits(in: CGSize(width: offered, height: 40)).width
        }
        let roomy = width(offered: 900)
        XCTAssertGreaterThan(roomy, 200, "with room, the label names the serving counts")
        for offered: CGFloat in [260, 160, 110] {
            XCTAssertLessThanOrEqual(width(offered: offered), offered, "offered \(offered) points")
        }
    }

    func testServerRowsOfferOnlyReviewedStopsAndUnloads() {
        let launched = engineServer("/models/launched", port: 9002, pid: 50, managed: true, residency: "loaded")
        let snapshot = ServingInventorySnapshot.make(engine: [launched], hosts: [], managedReceipts: managedReceipts,
                                                      capturedAt: Date(timeIntervalSince1970: 1_000))
        let service = snapshot.services.first
        XCTAssertEqual(ResourceHeaderPresentation.serverActions(service: service).map(\.title), ["Unload model…", "Stop server…"])
        XCTAssertEqual(ResourceHeaderPresentation.serverActions(service: nil).map(\.title), ["Open Serving"])
        let stale = ServingInventorySnapshot.make(engine: [engineServer("/models/launched", port: 9002, pid: 50, managed: true, residency: "unloaded")],
                                                  hosts: [], managedReceipts: managedReceipts, capturedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(ResourceHeaderPresentation.serverActions(service: stale.services.first).map(\.title), ["Stop server…"])
    }

    @MainActor
    func testPopoverRendersEachServingRowInOrderWithinTheFixedSize() async throws {
        let fixture = try await servingFixture(readInventory: true)
        XCTAssertEqual(fixture.rows.count, 3)
        guard case .endpoint = fixture.rows[0], case .server = fixture.rows[1], case .service = fixture.rows[2] else {
            return XCTFail("rows must read endpoint, server, service")
        }
        let width = WorkbenchSize.ResourceHeader.popoverWidth
        let (window, hosting) = host(fixture.header.panel, width: width, height: WorkbenchSize.ResourceHeader.popoverMaxHeight)
        defer { window.close() }
        XCTAssertEqual(hosting.fittingSize.width, width, accuracy: 0.5)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, WorkbenchSize.ResourceHeader.popoverMaxHeight)

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let capture = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        capture.name = "popover-light"; capture.lifetime = .keepAlways; add(capture)
        if let folder = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDER_OUTPUT"] {
            let url = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("popover-light.png"))
        }
    }
}
