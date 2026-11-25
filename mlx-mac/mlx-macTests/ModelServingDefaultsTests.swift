import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class ModelServingDefaultsTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = WorkbenchStatePaths.hostedTestRoot.appendingPathComponent("model-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSupervisor(root: URL, slots: [EndpointSlot], world: FakeServeWorld = FakeServeWorld()) throws -> (EndpointSupervisor, ModelDefaultsStore) {
        var lifecycle = world.lifecycle
        lifecycle.stopObservedIfIdle = { server in world.kill(port: server.port ?? -1) }
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: root.appendingPathComponent("fleet.json"))
        try fleet.replaceAll([EndpointFleetConfig(slots: slots, installedAtLogin: false)])
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore(fileURL: root.appendingPathComponent("legacy.json")), fleetStore: fleet)
        supervisor.inferenceLifecycle = { _ in lifecycle }
        let defaults = ModelDefaultsStore(store: JSONStore(fileURL: root.appendingPathComponent("model-defaults.json")))
        supervisor.modelDefaultsStore = defaults
        return (supervisor, defaults)
    }

    func testLegacySlotJSONDecodesWithoutOverridesAndKeepsItsOwnValues() throws {
        let json = """
        {"id":"\(UUID().uuidString)","enabled":true,"port":8925,"modelPath":"/Models/a","loadOnRequest":true,
         "acceleration":{"temperature":0.7,"systemPrompt":"Be brief"}}
        """
        let slot = try JSONDecoder().decode(EndpointSlot.self, from: Data(json.utf8))
        XCTAssertNil(slot.overrides)
        let defaults = ModelServingDefaults(inference: LocalInferenceOptions(systemPrompt: "Other", temperature: 0.1))
        let resolved = ServingSettings.effective(slot: slot, defaults: defaults)
        XCTAssertEqual(resolved.inferenceOptions.temperature, 0.7)
        XCTAssertEqual(resolved.inferenceOptions.systemPrompt, "Be brief")
        let encoded = try JSONEncoder().encode(EndpointFleetConfig(slots: [slot], installedAtLogin: false))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("overrides"))
    }

    func testNewSlotFollowsModelDefaults() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (supervisor, defaults) = try makeSupervisor(root: root, slots: [])
        try defaults.save(ModelServingDefaults(inference: LocalInferenceOptions(systemPrompt: "Be terse", temperature: 0.2),
            loadOnRequest: true), for: "/Models/a")
        let id = await supervisor.addSlot(modelPath: "/Models/a", port: 8930)
        let slot = try XCTUnwrap(supervisor.fleet.slots.first { $0.id == id })
        XCTAssertEqual(slot.overrides, [])
        let resolved = supervisor.effectiveSlot(slot)
        XCTAssertEqual(resolved.inferenceOptions.temperature, 0.2)
        XCTAssertEqual(resolved.inferenceOptions.systemPrompt, "Be terse")
    }

    func testOverridingTemperatureKeepsDefaultSystemPrompt() {
        var slot = EndpointSlot(enabled: true, port: 8925, modelPath: "/Models/a", loadOnRequest: true)
        slot.acceleration = LocalInferenceOptions(temperature: 0.9)
        slot.overrides = [.temperature]
        let defaults = ModelServingDefaults(inference: LocalInferenceOptions(systemPrompt: "Be terse", temperature: 0.1))
        let resolved = ServingSettings.effective(slot: slot, defaults: defaults)
        XCTAssertEqual(resolved.inferenceOptions.temperature, 0.9)
        XCTAssertEqual(resolved.inferenceOptions.systemPrompt, "Be terse")
        XCTAssertEqual(ServingSettings.source(of: .temperature, slot: slot), .endpoint)
        XCTAssertEqual(ServingSettings.source(of: .systemPrompt, slot: slot), .modelDefault)
    }

    func testStoreRoundTripUnderHostedTestRoot() throws {
        let url = WorkbenchStatePaths.modelDefaults()
        XCTAssertTrue(url.path.hasPrefix(WorkbenchStatePaths.hostedTestRoot.path))
        XCTAssertEqual(url.lastPathComponent, "model-defaults.json")
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model-defaults.json")
        let value = ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 2048, systemPrompt: "Be terse", temperature: 0.3),
            memoryPolicy: .automatic, loadOnRequest: true, splashPresetName: "editing", servingProfileID: UUID())
        try ModelDefaultsStore(store: JSONStore(fileURL: file)).save(value, for: "/Models/a")
        let reopened = ModelDefaultsStore(store: JSONStore(fileURL: file))
        XCTAssertEqual(reopened.defaults(for: "/Models/a"), value)
        XCTAssertNil(reopened.defaults(for: "/Models/b"))
    }

    private func runningFleet() async throws -> (EndpointSupervisor, ModelDefaultsStore, FakeServeWorld, EndpointSlot, EndpointSlot, URL) {
        let root = try makeRoot()
        let world = FakeServeWorld()
        var following = EndpointSlot(enabled: true, port: 8925, modelPath: "/Models/a", loadOnRequest: false)
        following.overrides = []
        var stopped = EndpointSlot(enabled: false, port: 8926, modelPath: "/Models/a", loadOnRequest: false)
        stopped.overrides = []
        let legacy = EndpointSlot(enabled: true, port: 8927, modelPath: "/Models/a", loadOnRequest: false)
        let (supervisor, defaults) = try makeSupervisor(root: root, slots: [following, stopped, legacy], world: world)
        await supervisor.reconcile()
        await supervisor.reconcile()
        return (supervisor, defaults, world, following, stopped, root)
    }

    func testRunningFollowingSlotIsListedWithItsPlanAndConfirmRestartsIt() async throws {
        let (supervisor, defaults, world, following, stopped, root) = try await runningFleet()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .some(.running) = supervisor.slotStates[following.id] else { return XCTFail("slot not running") }
        let change = ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 1024))
        let preview = try await supervisor.previewModelDefaultsChange(modelPath: "/Models/a", to: change)
        XCTAssertEqual(preview.restarting.map(\.id), [following.id])
        XCTAssertEqual(Set(preview.following.map(\.id)), [following.id, stopped.id])
        XCTAssertFalse(try XCTUnwrap(preview.plans[following.id]).isEmpty)
        let confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertTrue(confirmed, supervisor.lastError ?? "")
        XCTAssertEqual(defaults.defaults(for: "/Models/a"), change)
        XCTAssertTrue(try world.status().contains { $0.port == 8925 })
        let slot = try XCTUnwrap(supervisor.fleet.slots.first { $0.id == following.id })
        XCTAssertEqual(supervisor.effectiveSlot(slot).inferenceOptions.maximumTokens, 1024)
    }

    func testConfirmRefusesWhenTheListedSlotDriftedAndSavesNothing() async throws {
        let (supervisor, defaults, world, _, _, root) = try await runningFleet()
        defer { try? FileManager.default.removeItem(at: root) }
        let change = ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 1024))
        let preview = try await supervisor.previewModelDefaultsChange(modelPath: "/Models/a", to: change)
        world.kill(port: 8925)
        await supervisor.reconcile()
        let confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertFalse(confirmed)
        XCTAssertNil(defaults.defaults(for: "/Models/a"))
    }

    func testPreviewRefusesDefaultsThatMakeAFollowingSlotIllegal() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var slot = EndpointSlot(enabled: false, port: 8925, modelPath: "/Models/a", loadOnRequest: true)
        slot.apiKeySHA256 = String(repeating: "a", count: 64)
        slot.overrides = []
        let (supervisor, _) = try makeSupervisor(root: root, slots: [slot])
        do {
            _ = try await supervisor.previewModelDefaultsChange(modelPath: "/Models/a", to: ModelServingDefaults(loadOnRequest: false))
            XCTFail("loadOnRequest false with an API key must be refused")
        } catch { XCTAssertEqual(error as? EndpointFleetValidation, .invalidAuthentication(slot.id)) }
    }
}
