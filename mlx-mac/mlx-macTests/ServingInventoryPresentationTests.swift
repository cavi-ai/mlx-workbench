import Foundation
import XCTest

@testable import mlx_workbench

final class ServingInventoryPresentationTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_000)

    func testConfiguredFleetRowsDoNotHideExternalServersAtTheSamePort() {
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/owned")
        let owned = ServerInfo(path: slot.modelPath, port: slot.port, pid: 10, state: "running",
            modelState: "loaded", receiptsDirectory: "/receipts/workbench")
        let external = ServerInfo(path: "/models/external", port: slot.port, pid: 20, state: "running",
            modelState: "unloaded", receiptsDirectory: "/receipts/external")
        let snapshot = ServingInventorySnapshot.make(engine: [external, owned], hosts: [],
            managedReceipts: "/receipts/workbench", capturedAt: capturedAt)
        XCTAssertEqual(ServingInventoryPresentation.service(for: slot, in: snapshot)?.modelID, slot.modelPath)
        XCTAssertEqual(ServingInventoryPresentation.additionalServices(snapshot, slots: [slot]).map(\.modelID), ["/models/external"])
    }

    func testUnknownAndStaleObservationsDoNotCountAsLoaded() {
        let servers = [
            ServerInfo(path: "/models/loaded", port: 1, pid: 10, state: "running", modelState: "loaded"),
            ServerInfo(path: "/models/unloaded", port: 2, pid: 20, state: "running", modelState: "unloaded"),
            ServerInfo(path: "/models/unknown", port: 3, pid: 30, state: "running")
        ]
        var snapshot = ServingInventorySnapshot.make(engine: servers, hosts: [], managedReceipts: "/receipts", capturedAt: capturedAt)
        XCTAssertEqual(ServingInventoryPresentation.summary(snapshot), "1 loaded · 3 local models · 1 unknown")
        let loadedIndex = snapshot.services.firstIndex { $0.modelID == "/models/loaded" }!
        snapshot.services[loadedIndex].stale = true
        XCTAssertEqual(ServingInventoryPresentation.summary(snapshot), "0 loaded · 3 local models · 2 unknown")
        XCTAssertEqual(ServingInventoryPresentation.icon(snapshot, slots: [], states: [:]), "exclamationmark.triangle")
        XCTAssertEqual(ServingInventoryPresentation.summary(.empty), "Reading local serving models…")
    }

    func testToolbarCountsTheRunningRowsMonitorListsAndLeadsWithTheModelThatNeedsAttention() throws {
        let failed = ServerInfo(path: "/models/strata", runtime: "strata", port: 8766, pid: 40, state: "running", jit: true,
                                modelState: "failed", receiptsDirectory: "/receipts",
                                lastError: "Agent memory guard stopped the owned model worker.")
        let servers = [
            ServerInfo(path: "/models/loaded", port: 1, pid: 10, state: "running", modelState: "loaded", receiptsDirectory: "/receipts"),
            ServerInfo(path: "/models/idle", port: 2, pid: 20, state: "running", jit: true, modelState: "unloaded", receiptsDirectory: "/receipts"),
            ServerInfo(path: "/models/stopped", port: 3, pid: 30, state: "stopped", receiptsDirectory: "/receipts"),
            failed,
        ]
        let snapshot = ServingInventorySnapshot.make(engine: servers, hosts: [], managedReceipts: "/receipts", capturedAt: capturedAt)
        let rows = ServingRows.build(slots: [], servers: servers, snapshot: snapshot)
        let tally = ServingWorkspacePresentation.tally(rows)
        let twelve: Int64 = 12_000_000_000

        XCTAssertEqual(tally, ServingTally(attention: 1, loaded: 1, loading: 0, onRequest: 1))
        XCTAssertEqual(tally.attention + tally.loaded + tally.loading + tally.onRequest,
                       rows.filter(ServingWorkspacePresentation.isRunning).count, "the toolbar counts what Monitor lists")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: tally, compact: false),
                       "1 needs attention · 1 loaded · 1 ready on request · ~12.0 GB available")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: tally, compact: true), "1 needs attention")

        let attention = try XCTUnwrap(rows.first { ServingWorkspacePresentation.server($0)?.port == 8766 })
        XCTAssertEqual(ServingWorkspacePresentation.status(attention), "Needs attention")
        XCTAssertEqual(ServingWorkspacePresentation.attentionReason(attention), "Agent memory guard stopped the owned model worker.")
        XCTAssertEqual(ServingWorkspacePresentation.attentionFirst(rows).first?.id, attention.id)
        XCTAssertTrue(rows.filter { $0.id != attention.id }.allSatisfy { ServingWorkspacePresentation.attentionReason($0) == nil })

        let idleOnly = ServingWorkspacePresentation.tally(rows.filter { ServingWorkspacePresentation.server($0)?.port == 2 })
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: idleOnly, compact: false),
                       "1 ready on request · ~12.0 GB available")
        XCTAssertEqual(ResourceHeaderPresentation.memoryText(availableBytes: twelve, tally: ServingTally(), compact: false), "~12.0 GB available")
    }

    func testLibraryLinksRequireKnownPathsAndDoNotGuessByName() {
        let item = ModelItem(path: "/models/Qwen", name: "Qwen", bytes: 1, modifiedAt: nil,
            shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil,
            structure: nil, signature: "identity", companion: nil, readable: true, status: "ready",
            outputs: [], tensorCount: nil, error: nil)
        let snapshot = ServingInventorySnapshot.make(engine: [
            ServerInfo(path: "/models/./Qwen", pid: 10, state: "running"),
            ServerInfo(path: "/other/Qwen", pid: 20, state: "running")
        ], hosts: [], managedReceipts: "/receipts", capturedAt: capturedAt)
        XCTAssertEqual(ServingInventoryPresentation.linkedServices(for: LibraryModel(item: item), in: snapshot).map(\.modelID), ["/models/./Qwen"])
    }

    func testProviderReleaseSelectionKeepsHostAndInstanceScopes() {
        let host = ModelHost(name: "LM Studio", provider: .lmStudio, baseURL: "http://127.0.0.1:1234")
        var model = HostedModel(hostID: host.id, modelID: "model", name: "Model", isLoaded: true,
            loadedInstanceIDs: ["instance-one"])
        func observation(_ host: ModelHost, _ model: HostedModel) -> ServingServiceObservation {
            ServingInventorySnapshot.make(engine: [], hosts: [HostInventory(host: host, models: [model], capturedAt: capturedAt)],
                managedReceipts: "/receipts", capturedAt: capturedAt).services[0]
        }
        XCTAssertEqual(ServingInventoryPresentation.resourceSelection(for: observation(host, model)),
            HostResourceSelection(modelID: "model", instanceID: "instance-one"))
        model.loadedInstanceIDs = ["instance-one", "instance-two"]
        XCTAssertNil(ServingInventoryPresentation.resourceSelection(for: observation(host, model)))
        let images = ModelHost(name: "Images", provider: .comfyUI, baseURL: "http://127.0.0.1:8188")
        let imageModel = HostedModel(hostID: images.id, modelID: "checkpoint", name: "Checkpoint", isLoaded: true)
        XCTAssertEqual(ServingInventoryPresentation.resourceSelection(for: observation(images, imageModel)), HostResourceSelection())
        XCTAssertEqual(ServingInventoryPresentation.unloadTitle(for: observation(images, imageModel)), "Free host memory…")
    }
}
