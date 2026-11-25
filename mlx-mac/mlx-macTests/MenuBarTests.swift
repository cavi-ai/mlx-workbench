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

    // MARK: - Serving rows on the quick surfaces

    private let managedReceipts = "/receipts/workbench"

    private func engineServer(_ path: String, port: Int, pid: Int, managed: Bool, residency: String) -> ServerInfo {
        ServerInfo(path: path, runtime: "mlx_lm", port: port, pid: pid, state: "running", jit: true,
                   modelState: residency, workerPid: pid + 100, activeRequests: 0,
                   receiptsDirectory: managed ? managedReceipts : "/receipts/other", processStartedAt: "process-\(pid)")
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
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: ServingTally(loaded: 2), compact: false), "2 loaded · 12.0 GB available")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: ServingTally(loaded: 2), compact: true), "12.0 GB available")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: nil, compact: false), "12.0 GB available")
    }

    func testToolbarLinesPutAttentionInABadgeAndShortenInOrder() {
        let twelve: Int64 = 12_000_000_000
        let lines = ResourceHeaderPresentation.lines(availableBytes: twelve, tally: ServingTally(attention: 1, loaded: 2, onRequest: 2))
        XCTAssertEqual(lines, [ResourceHeaderLine(badge: "A model failed to load", text: "2 loaded · 2 on request · 12.0 GB free"),
                               ResourceHeaderLine(badge: "A model failed to load", text: "12.0 GB free"),
                               ResourceHeaderLine(badge: nil, text: "Load failed")])
        XCTAssertEqual(ResourceHeaderPresentation.attentionPhrase(2), "2 models failed to load")
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
                       "1 loaded · 12.0 GB available, endpoint: " + degraded.summary)
        XCTAssertEqual(ResourceHeaderPresentation.accessibilityLabel(availableBytes: nil, tally: nil, attention: nil), "RAM unavailable")
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
}
