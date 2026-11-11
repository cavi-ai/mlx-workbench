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

    func testToolbarNamesServingModelsThatAreNotLoaded() {
        let servers = [
            ServerInfo(path: "/models/loaded", port: 1, pid: 10, state: "running", modelState: "loaded"),
            ServerInfo(path: "/models/idle", port: 2, pid: 20, state: "running", modelState: "unloaded"),
            ServerInfo(path: "/models/unknown", port: 3, pid: 30, state: "running")
        ]
        let snapshot = ServingInventorySnapshot.make(engine: servers, hosts: [], managedReceipts: "/receipts", capturedAt: capturedAt)
        let text = ResourceHeaderPresentation.memoryText(availableBytes: 12_000_000_000, loaded: snapshot.loadedCount,
                                                         serving: snapshot.servingCount, compact: false)
        XCTAssertEqual(text, "3 serving · 1 loaded · ~12.0 GB available")
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
