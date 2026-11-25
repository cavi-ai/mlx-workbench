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

    func testSplashFilesFollowModelDefaultsAndCanBeOverriddenIndependently() {
        var slot = EndpointSlot(enabled: false, port: 8925, modelPath: "/Models/a", loadOnRequest: true)
        slot.overrides = []
        let defaults = ModelServingDefaults(inference: LocalInferenceOptions(
            splashDraftModel: "/Models/default-draft", splashChatTemplate: "/Models/default.jinja"))
        let inherited = ServingSettings.effective(slot: slot, defaults: defaults)
        XCTAssertEqual(inherited.inferenceOptions, defaults.inference)

        let selected = ModelServingDefaults(inference: LocalInferenceOptions(splashChatTemplate: "/Models/custom.jinja"))
        let applied = ServingSettings.applying(selected, to: slot, servingProfile: nil,
            modelDefaults: defaults, defaultsServingProfile: nil)
        XCTAssertEqual(ServingSettings.effective(slot: applied, defaults: defaults).inferenceOptions, selected.inference)

        let otherDefaults = ModelServingDefaults(inference: LocalInferenceOptions(
            splashDraftModel: "/Models/new-draft", splashChatTemplate: "/Models/new.jinja"))
        XCTAssertEqual(ServingSettings.effective(slot: applied, defaults: otherDefaults).inferenceOptions, selected.inference)
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

    func testProfileSurvivesReloadAndLegacyFileHasNone() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model-defaults.json")
        let legacy = ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 512))
        let encoded = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        try Data("[{\"modelPath\":\"/Models/a\",\"defaults\":\(encoded)}]".utf8).write(to: file)
        let store = ModelDefaultsStore(store: JSONStore(fileURL: file))
        XCTAssertEqual(store.defaults(for: "/Models/a"), legacy)
        XCTAssertEqual(store.profiles(for: "/Models/a"), [])
        let profile = ServingSettingsProfile(name: "Terse", settings: ModelServingDefaults(inference: LocalInferenceOptions(systemPrompt: "Be terse", temperature: 0.2)))
        try store.saveProfile(profile, for: "/Models/a")
        let reopened = ModelDefaultsStore(store: JSONStore(fileURL: file))
        XCTAssertEqual(reopened.profiles(for: "/Models/a"), [profile])
        XCTAssertEqual(reopened.defaults(for: "/Models/a"), legacy)
        try reopened.save(nil, for: "/Models/a")
        XCTAssertEqual(reopened.profiles(for: "/Models/a"), [profile])
    }

    func testApplyingAProfilePreviewsTheRunningSlotAndConfirmRewritesIt() async throws {
        let (supervisor, defaults, _, following, _, root) = try await runningFleet()
        defer { try? FileManager.default.removeItem(at: root) }
        try defaults.save(ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 256)), for: "/Models/a")
        let profile = ServingSettingsProfile(name: "Long", settings: ModelServingDefaults(inference: LocalInferenceOptions(thinkingOff: true, maximumTokens: 4096)))
        let preview = try await supervisor.previewApplyingProfile(slotID: following.id, profile: profile)
        XCTAssertEqual(preview.restarting.map(\.id), [following.id])
        XCTAssertEqual(preview.following.map(\.id), [following.id])
        let confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertTrue(confirmed, supervisor.lastError ?? "")
        let slot = try XCTUnwrap(supervisor.fleet.slots.first { $0.id == following.id })
        XCTAssertEqual(supervisor.effectiveSlot(slot).inferenceOptions, profile.settings.inference)
        XCTAssertEqual(defaults.defaults(for: "/Models/a")?.inference.maximumTokens, 256)
    }

    func testApplyingRefusesDriftAndInUseEndpointsLeavingFleetUnchanged() async throws {
        let (supervisor, defaults, world, following, _, root) = try await runningFleet()
        defer { try? FileManager.default.removeItem(at: root) }
        try defaults.save(ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 256)), for: "/Models/a")
        let profile = ServingSettingsProfile(name: "Long", settings: ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 4096)))
        let before = supervisor.fleet
        supervisor.mayStopSlot = { _ in false }
        var preview = try await supervisor.previewApplyingProfile(slotID: following.id, profile: profile)
        var confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertFalse(confirmed)
        XCTAssertTrue(try XCTUnwrap(supervisor.lastError).contains("Finish the operation using :8925"))
        XCTAssertEqual(supervisor.fleet, before)
        supervisor.mayStopSlot = nil
        // The model default changes after the preview while the server keeps running: the recheck must refuse.
        preview = try await supervisor.previewApplyingProfile(slotID: following.id, profile: profile)
        let changedDefaults = ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 4096))
        try defaults.save(changedDefaults, for: "/Models/a")
        confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertFalse(confirmed)
        XCTAssertTrue(try XCTUnwrap(supervisor.lastError).contains("Review the profile again"))
        XCTAssertEqual(supervisor.fleet, before)
        XCTAssertEqual(defaults.defaults(for: "/Models/a"), changedDefaults)
        XCTAssertTrue(try world.status().contains { $0.port == 8925 })
    }

    func testApplyingAProfileWithoutTheDefaultServingProfileDropsItButKeepsMatchingFieldsFollowing() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let options = StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192)
        var strata = ServingProfile(id: UUID(), name: "Paged", modelPath: "/Models/a", options: options)
        strata.verification = ServingProfileVerification(options: options, modelFingerprint: "model", runtimeFingerprint: "runtime",
            suiteVersion: CanarySuite.version, canaries: CanarySuite.cases.map {
                CanaryResult(id: $0.id, title: $0.title, passed: true, failureReason: nil, responseExcerpt: "fixture",
                             tokensPerSecond: nil, timeToFirstTokenSeconds: nil)
            }, verifiedAt: Date())
        var slot = EndpointSlot(enabled: false, port: 8092, modelPath: "/Models/a", loadOnRequest: false)
        slot.overrides = [.servingProfile]
        let (supervisor, defaults) = try makeSupervisor(root: root, slots: [slot])
        supervisor.profileResolver = { $0 == strata.id ? strata : nil }
        try defaults.save(ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 256), servingProfileID: strata.id), for: "/Models/a")
        XCTAssertNil(supervisor.effectiveSlot(slot).servingProfile)
        let plain = ServingSettingsProfile(name: "Plain", settings: ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 256), loadOnRequest: false))
        let preview = try await supervisor.previewApplyingProfile(slotID: slot.id, profile: plain)
        let confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertTrue(confirmed, supervisor.lastError ?? "")
        let saved = try XCTUnwrap(supervisor.fleet.slots.first { $0.id == slot.id })
        XCTAssertNil(supervisor.effectiveSlot(saved).servingProfile)
        XCTAssertEqual(saved.overrides, [.servingProfile])
    }

    func testConfigurationJSONCarriesEffectiveValuesAndNoKeyMaterial() throws {
        var slot = EndpointSlot(enabled: true, port: 8925, modelPath: "/Models/a", loadOnRequest: true)
        slot.apiKeySHA256 = String(repeating: "a", count: 64)
        slot.acceleration = LocalInferenceOptions(maximumTokens: 777, temperature: 0.3)
        let json = try ServingConfiguration.json(effective: slot)
        XCTAssertTrue(json.contains("777"))
        XCTAssertTrue(json.contains("\"protected\" : true"))
        XCTAssertFalse(json.contains(String(repeating: "a", count: 64)))
        XCTAssertFalse(json.lowercased().contains("sha256"))
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
        let recorder = LifecycleRecorder()
        world.recorder = recorder
        let confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertTrue(confirmed, supervisor.lastError ?? "")
        XCTAssertEqual(defaults.defaults(for: "/Models/a"), change)
        let starts = recorder.events.filter { $0.hasPrefix("start:") }
        XCTAssertEqual(starts.count, 1, "\(recorder.events)")
        XCTAssertTrue(starts.first?.hasPrefix("start:/Models/a:8925:") == true, "\(recorder.events)")
        XCTAssertTrue(try world.status().contains { $0.port == 8925 })
        let slot = try XCTUnwrap(supervisor.fleet.slots.first { $0.id == following.id })
        XCTAssertEqual(supervisor.effectiveSlot(slot).inferenceOptions.maximumTokens, 1024)
    }

    func testChangingSplashDefaultsReplacesReviewedPlansForRunningAndStoppedEndpoints() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let world = FakeServeWorld()
        var running = EndpointSlot(enabled: true, port: 8925, modelPath: "/Models/a", loadOnRequest: true)
        running.splashPresetName = "editing"
        running.overrides = []
        running.profilePreviewHash = "old-plan"
        var stopped = EndpointSlot(enabled: false, port: 8926, modelPath: running.modelPath, loadOnRequest: true)
        stopped.splashPresetName = running.splashPresetName
        stopped.overrides = []
        stopped.profilePreviewHash = "old-plan"
        let receipt = root.appendingPathComponent("existing.json")
        try JSONSerialization.data(withJSONObject: ["pid": 1, "port": running.port, "path": running.modelPath,
            "preview_hash": "old-plan"]).write(to: receipt)
        world.preload(repo: running.modelPath, port: running.port, jit: true, activeRequests: 0, receipt: receipt.path)
        let (supervisor, _) = try makeSupervisor(root: root, slots: [running, stopped], world: world)
        supervisor.splashLifecycle = { _ in
            var base = world.lifecycle
            base.configured = { options in
                var lifecycle = world.lifecycle
                lifecycle.jitPreview = { _, port, _ in "\(options.splashDraftModel ?? "engine-default"):\(port)" }
                lifecycle.jitStart = { path, port, hash, _ in
                    let receipt = root.appendingPathComponent("new-\(port).json")
                    try JSONSerialization.data(withJSONObject: ["pid": 1, "port": port, "path": path,
                        "preview_hash": hash]).write(to: receipt)
                    world.preload(repo: path, port: port, jit: true, activeRequests: 0, receipt: receipt.path)
                }
                return lifecycle
            }
            return base
        }
        await supervisor.reconcile()
        XCTAssertEqual(supervisor.slotStates[running.id], .running(modelPath: running.modelPath, port: running.port))
        let defaults = ModelServingDefaults(inference: LocalInferenceOptions(splashDraftModel: "/Models/new-draft"))
        let preview = try await supervisor.previewModelDefaultsChange(modelPath: running.modelPath, to: defaults)
        XCTAssertEqual(preview.restarting.map(\.id), [running.id])
        let confirmed = await supervisor.confirmModelDefaultsChange(preview)
        XCTAssertTrue(confirmed, supervisor.lastError ?? "")
        XCTAssertEqual(supervisor.fleet.slots.map(\.profilePreviewHash), ["/Models/new-draft:8925", "/Models/new-draft:8926"])
        let enabled = await supervisor.setSlotEnabled(id: stopped.id, true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(try world.status().compactMap(\.port).sorted(), [8925, 8926])
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
