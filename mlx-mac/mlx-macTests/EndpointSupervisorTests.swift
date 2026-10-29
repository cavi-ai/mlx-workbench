import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class EndpointSupervisorTests: XCTestCase {
    func testFreshConfirmedLoginReceiptIsAdoptedAndPersisted() async throws {
        let hash = String(repeating: "b", count: 64)
        var slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a")
        slot.acceleration = .init(promptLookup: true)
        slot.accelerationPreviewHash = String(repeating: "a", count: 64)
        let receipt = temporaryURL("new-login-receipt.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["pid": 1, "port": slot.port, "path": slot.modelPath,
            "preview_hash": hash]).write(to: receipt)
        let world = FakeServeWorld()
        world.preload(repo: slot.modelPath, port: slot.port, receipt: receipt.path,
            decodeProfile: .object(["name": .string("prompt-lookup-v1"), "fingerprint": .string(hash)]))
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: temporaryURL("login-fleet.json"))
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: true)])
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: fleet)
        supervisor.accelerationLifecycle = { _ in
            var selected = world.lifecycle
            selected.preview = { _, _ in hash }
            return selected
        }
        await supervisor.reconcile()
        XCTAssertEqual(supervisor.state, .running(modelPath: slot.modelPath, port: slot.port))
        XCTAssertEqual(try fleet.load().first?.slots.first?.accelerationPreviewHash, hash)
        await supervisor.disable()
        XCTAssertNil(supervisor.lastError)
        XCTAssertTrue(try world.status().isEmpty)
    }

    func testLocalAcceleratedEndpointLifecycleWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_ENDPOINT_ACCELERATION_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_ENDPOINT_ACCELERATION_MANIFEST for local accelerated endpoint acceptance.")
        }
        struct Manifest: Decodable {
            let agentPath: String; let model: String; let evidenceRoot: String
            let port: Int; let prompt: String; let expectedText: String
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let evidenceRoot = URL(fileURLWithPath: manifest.evidenceRoot)
        let root = evidenceRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: manifest.agentPath, receiptDirectory: root.path)
        let legacy = JSONStore<EndpointConfig>(fileURL: root.appendingPathComponent("legacy.json"))
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: root.appendingPathComponent("fleet.json"))
        func supervisor() -> EndpointSupervisor {
            let owner = EndpointSupervisor(lifecycle: .live(api: api), statusProvider: { try await api.serveStatus() },
                store: legacy, fleetStore: fleet)
            owner.accelerationLifecycle = { .live(api: api, acceleration: $0) }
            return owner
        }
        func current() async throws -> ServerInfo {
            for _ in 0..<20 {
                if let server = try await api.serveStatus().first(where: { $0.port == manifest.port && $0.state == "running" }),
                   (server.activeRequests ?? 0) == 0 { return server }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw WorkflowEvidenceError.invalid("Endpoint did not become idle.")
        }
        func clientRequest() async throws -> String {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(manifest.port)/v1/chat/completions")!, timeoutInterval: 180)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "default_model", "temperature": 0,
                "max_tokens": 768, "messages": [["role": "system", "content": "You are a precise Python code editor."],
                                                ["role": "user", "content": manifest.prompt]]])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
            let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
            return try XCTUnwrap(message["content"] as? String)
        }
        let owner = supervisor()
        var owned: ServerInfo?
        func readOwnedReceipt(expectedHash: String? = nil) throws -> ServerInfo {
            let url = root.appendingPathComponent(".mlx-agent-receipts/serve/\(manifest.port).json")
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            receipt["receipt"] = url.path
            receipt["state"] = "running"
            let server = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [receipt]])?.first)
            guard server.matchesUnadaptedModel(manifest.model), let pid = server.pid, pid > 0,
                  expectedHash == nil || receipt["preview_hash"] as? String == expectedHash else {
                throw WorkflowEvidenceError.invalid("Acceptance receipt does not identify its own launch.")
            }
            return server
        }
        func stopOwned() async throws {
            guard let expected = owned else { return }
            let live = try await api.serveStatus().first { $0.port == expected.port }
            guard let live, live.sameProcess(as: expected) else {
                throw WorkflowEvidenceError.invalid("Acceptance endpoint ownership changed; no process was stopped.")
            }
            _ = try await api.serveStop(port: manifest.port)
            owned = nil
        }
        do {
            await owner.enable(modelPath: manifest.model, port: manifest.port, allowUnverified: true, loadOnRequest: true)
            let id = try XCTUnwrap(owner.fleet.slots.first?.id)
            owned = try readOwnedReceipt()
            await owner.disable()
            let stopped = try await api.serveStatus()
            guard stopped.isEmpty else { throw WorkflowEvidenceError.invalid("Acceptance endpoint did not stop.") }
            owned = nil
            let options = LocalAccelerationOptions(m5Prefill: true, promptLookup: true)
            let preview = try await owner.previewSlotAcceleration(id: id, options: options)
            let saved = await owner.confirmSlotAcceleration(preview)
            XCTAssertTrue(saved, owner.lastError ?? "Acceleration settings were not saved")
            await owner.setSlotEnabled(id: id, true)
            owned = try readOwnedReceipt(expectedHash: owner.fleet.slots.first?.accelerationPreviewHash)
            let first = try await clientRequest()
            XCTAssertEqual(first, manifest.expectedText)
            let loaded = try await current()
            XCTAssertTrue(loaded.matchesAcceleration(options))
            XCTAssertEqual(loaded.prefillKernel?.object?["adapter_enabled"], .boolean(true))
            XCTAssertEqual(loaded.decodeProfile?.object?["adapter_enabled"], .boolean(true))
            let unloaded = await owner.unloadServer(loaded)
            XCTAssertTrue(unloaded, owner.lastError ?? "JIT unload failed")
            let idle = try await current()
            XCTAssertEqual(idle.modelState, "unloaded")
            let reloaded = try await clientRequest()
            XCTAssertEqual(reloaded, first)
            let restored = supervisor()
            await restored.reconcile()
            XCTAssertEqual(restored.state, .running(modelPath: manifest.model, port: manifest.port))
            let policy = EndpointMemoryPolicy(idleTimeoutSeconds: 300, keepLoaded: false, minimumHeadroomGB: 2)
            await restored.setSlotMemoryPolicy(id: id, policy)
            XCTAssertNil(restored.lastError)
            let slot = try XCTUnwrap(restored.fleet.slots.first)
            let plan = try await api.loginItemPlan(slot: slot, fleetURL: fleet.url)
            let manager = LaunchAgentManager(home: root, run: { _, _ in throw WorkflowEvidenceError.invalid("Acceptance never installs launchd items.") })
            let plist = try manager.plistPreview(plan: plan)
            let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
            let arguments = try XCTUnwrap(fields["ProgramArguments"] as? [String])
            try await stopOwned()
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            let launchEnvironment = environment
            let startup = try await WorkbenchIO.perform {
                Result { try BoundedProcessCapture.run(executable: URL(fileURLWithPath: arguments[0]),
                    arguments: Array(arguments.dropFirst()), environment: launchEnvironment, timeout: 90) }
            }.get()
            try Data(startup.stdout.utf8).write(to: root.appendingPathComponent("startup.json"))
            let hashIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--preview-hash")) + 1
            owned = try? readOwnedReceipt(expectedHash: plan.arguments[hashIndex])
            guard startup.status == 0 else {
                throw WorkflowEvidenceError.invalid("Reviewed login command failed: " + startup.stdout + startup.stderr)
            }
            owned = try readOwnedReceipt(expectedHash: plan.arguments[hashIndex])
            let startupReply = try await clientRequest()
            XCTAssertEqual(startupReply, first)
            let server = try await current()
            XCTAssertTrue(server.matchesAcceleration(options))
            let loginOwner = supervisor()
            await loginOwner.reconcile()
            XCTAssertEqual(loginOwner.state, .running(modelPath: manifest.model, port: manifest.port))
            XCTAssertNotEqual(loginOwner.fleet.slots.first?.accelerationPreviewHash, slot.accelerationPreviewHash)
            try JSONSerialization.data(withJSONObject: ["jit_reload_matches_native": reloaded == manifest.expectedText,
                "login_command_matches_native": startupReply == manifest.expectedText,
                "prefill_kernel": server.prefillKernel?.jsonText ?? "", "decode_profile": server.decodeProfile?.jsonText ?? ""],
                options: [.prettyPrinted, .sortedKeys]).write(to: evidenceRoot.appendingPathComponent("acceptance.json"))
            await loginOwner.disable()
            XCTAssertNil(loginOwner.lastError)
            let final = try await api.serveStatus()
            guard final.isEmpty else { throw WorkflowEvidenceError.invalid("Acceptance endpoint did not stop.") }
            owned = nil
        } catch {
            try? await stopOwned()
            throw error
        }
    }

    func testAccelerationAdoptionRequiresBothRequestedOptionsAndConfirmedReceipt() async throws {
        for matchingReceipt in [false, true] {
            let world = FakeServeWorld()
            let hash = String(repeating: "a", count: 64)
            var slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a")
            slot.acceleration = .init(m5Prefill: true, promptLookup: true)
            slot.accelerationPreviewHash = hash
            let receipt = temporaryURL("receipt-\(matchingReceipt).json")
            try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["pid": 1, "port": 8766, "path": "/Models/a",
                "preview_hash": matchingReceipt ? hash : "changed"]).write(to: receipt)
            func metadata(_ name: String) -> LabValue { .object(["name": .string(name), "fingerprint": .string(hash)]) }
            world.preload(repo: "/Models/a", port: 8766, receipt: receipt.path,
                prefillKernel: metadata("m5-q4-prefill-v1"), decodeProfile: metadata("prompt-lookup-v1"))
            let fleet = JSONStore<EndpointFleetConfig>(fileURL: temporaryURL("accelerated-\(matchingReceipt).json"))
            try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false)])
            let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
                store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: fleet)
            await supervisor.reconcile()
            if matchingReceipt {
                XCTAssertEqual(supervisor.slotStates[slot.id], .running(modelPath: slot.modelPath, port: slot.port))
            } else {
                guard case .degraded? = supervisor.slotStates[slot.id] else { return XCTFail("Changed receipt must be refused") }
            }
            world.kill(port: slot.port)
            world.preload(repo: slot.modelPath, port: slot.port)
            await supervisor.reconcile()
            guard case .degraded? = supervisor.slotStates[slot.id] else { return XCTFail("Native server cannot replace accelerated endpoint") }
        }
    }

    func testAccelerationSaveFailureKeepsPersistedSettings() async throws {
        let world = FakeServeWorld()
        let slot = EndpointSlot(enabled: false, port: 8766, modelPath: "/Models/a")
        let url = temporaryURL("acceleration-save.json")
        let original = EndpointFleetConfig(slots: [slot], installedAtLogin: false)
        try JSONStore<EndpointFleetConfig>(fileURL: url).replaceAll([original])
        let store = JSONStore<EndpointFleetConfig>(fileURL: url, replaceItem: { _, _ in throw StubError.offline })
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: store)
        supervisor.accelerationLifecycle = { _ in world.lifecycle }
        let preview = try await supervisor.previewSlotAcceleration(id: slot.id, options: .init(promptLookup: true))
        let saved = await supervisor.confirmSlotAcceleration(preview)
        XCTAssertFalse(saved)
        XCTAssertEqual(supervisor.fleet, original)
        XCTAssertEqual(try JSONStore<EndpointFleetConfig>(fileURL: url).load(), [original])
        XCTAssertTrue(try world.status().isEmpty)
    }

    func testAccelerationRequiresDisabledEndpointAndReviewedUnchangedOptions() async throws {
        let world = FakeServeWorld()
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        supervisor.accelerationLifecycle = { _ in world.lifecycle }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        let options = LocalAccelerationOptions(m5Prefill: true, promptLookup: true)
        do {
            _ = try await supervisor.previewSlotAcceleration(id: id, options: options)
            XCTFail("Running endpoint must be disabled first")
        } catch {}
        await supervisor.disable()
        let preview = try await supervisor.previewSlotAcceleration(id: id, options: options)
        let saved = await supervisor.confirmSlotAcceleration(preview)
        XCTAssertTrue(saved)
        XCTAssertEqual(supervisor.fleet.slots.first?.acceleration, options)
        let persisted = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        XCTAssertEqual(persisted.fleet.slots.first?.acceleration, options)
        await supervisor.updateSlot(id: id, modelPath: "/Models/b", port: 8766, role: nil)
        let rejected = await supervisor.confirmSlotAcceleration(preview)
        XCTAssertFalse(rejected)
        XCTAssertNil(supervisor.fleet.slots.first?.acceleration)
    }

    func testAccelerationPreviewDriftOrOccupiedPortDoesNotSaveSettings() async throws {
        let world = FakeServeWorld()
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        supervisor.accelerationLifecycle = { _ in world.lifecycle }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.disable()
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        let preview = try await supervisor.previewSlotAcceleration(id: id,
            options: LocalAccelerationOptions(promptLookup: true))
        var changed = world.lifecycle
        changed.preview = { _, _ in "different-runtime-hash" }
        supervisor.accelerationLifecycle = { _ in changed }
        let driftRejected = await supervisor.confirmSlotAcceleration(preview)
        XCTAssertFalse(driftRejected)
        XCTAssertNil(supervisor.fleet.slots.first?.acceleration)
        supervisor.accelerationLifecycle = { _ in world.lifecycle }
        world.preload(repo: "/Models/other", port: 8766)
        let occupiedRejected = await supervisor.confirmSlotAcceleration(preview)
        XCTAssertFalse(occupiedRejected)
        XCTAssertNil(supervisor.fleet.slots.first?.acceleration)
    }

    func testLegacyEndpointsDefaultToNativeAccelerationAndMalformedMetadataIsRefused() throws {
        let slot = EndpointSlot(enabled: false, port: 8766, modelPath: "/Models/a")
        let restored = try JSONDecoder().decode(EndpointSlot.self, from: JSONEncoder().encode(slot))
        XCTAssertFalse(restored.accelerationOptions.requested)
        let native = ServerInfo(repo: "/Models/a")
        XCTAssertTrue(native.matchesAcceleration(.init()))
        let malformed = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [["repo": "/Models/a", "decode_profile": "invalid"]]])?.first)
        XCTAssertFalse(malformed.matchesAcceleration(.init()))
        XCTAssertFalse(malformed.matchesAcceleration(.init(promptLookup: true)))
    }

    func testRetriedModelSwapRecordsTheSelectedModelAsUsed() async throws {
        let world = FakeServeWorld()
        let operations = world.lifecycle
        let gate = RetryableEndpointStop(stop: operations.stop)
        let supervisor = EndpointSupervisor(lifecycle: ServeLifecycle(preview: operations.preview, start: operations.start,
            stop: { try await gate.stop($0) }), statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        var observed: [String] = []
        supervisor.onUserServeStarted = { observed.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        observed = []
        await supervisor.swap(to: "/Models/b")
        XCTAssertEqual(try world.status().first?.modelIdentity, "/Models/a")
        await gate.allowStop()
        await supervisor.retryPendingStops()
        await supervisor.reconcile()
        XCTAssertEqual(try world.status().first?.modelIdentity, "/Models/b")
        XCTAssertEqual(observed, ["/Models/b"])
    }

    func testFailedDisableToggleAndRemovalRemainRetryable() async throws {
        for action in ["disable", "toggle", "remove"] {
            let world = FakeServeWorld()
            let live = world.lifecycle
            let gate = RetryableEndpointStop(stop: live.stop)
            let supervisor = EndpointSupervisor(lifecycle: ServeLifecycle(preview: live.preview, start: live.start,
                stop: { try await gate.stop($0) }), statusProvider: { try world.status() },
                store: JSONStore<EndpointConfig>(fileURL: temporaryURL("\(action).json")))
            await supervisor.enable(modelPath: "/Models/a", port: 8766)
            let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
            switch action {
            case "disable": await supervisor.disable()
            case "toggle": await supervisor.setSlotEnabled(id: id, false)
            default: await supervisor.removeSlot(id: id)
            }
            XCTAssertEqual(try world.status().count, 1, action)
            XCTAssertEqual(supervisor.pendingStops[id]?.port, 8766, action)
            XCTAssertNotNil(supervisor.lastError, action)
            await supervisor.reconcile()
            XCTAssertNotEqual(supervisor.state, .disabled, action)
            await gate.allowStop()
            await supervisor.retryPendingStops()
            XCTAssertTrue(try world.status().isEmpty, action)
            XCTAssertTrue(supervisor.pendingStops.isEmpty, action)
            XCTAssertNil(supervisor.lastError, action)
            XCTAssertEqual(supervisor.state, .disabled, action)
        }
    }

    func testStopReadbackMustConfirmThatTheServerExited() async throws {
        let world = FakeServeWorld()
        let lifecycle = world.lifecycle
        let supervisor = EndpointSupervisor(lifecycle: ServeLifecycle(preview: lifecycle.preview, start: lifecycle.start,
            stop: { _ in }), statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.disable()
        XCTAssertEqual(supervisor.pendingStops.count, 1)
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertNotEqual(supervisor.state, .disabled)
    }

    func testDisableReportsStopFailureAndRetainsObservedServerState() async throws {
        let world = FakeServeWorld()
        let live = world.lifecycle
        let supervisor = EndpointSupervisor(lifecycle: ServeLifecycle(preview: live.preview, start: live.start,
            stop: { _ in throw StubError.offline }), statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.disable()
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(try world.status().count, 1)
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertNotEqual(supervisor.state, .disabled)
    }
    func testFailedFleetWritesPreserveDesiredStateAndRunningServers() async throws {
        for action in ["enable", "add", "disable", "toggle", "swap", "update", "remove"] {
            let fleetURL = temporaryURL("fleet.json")
            let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a")
            let original = EndpointFleetConfig(slots: [slot], installedAtLogin: false)
            try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).replaceAll([original])
            let world = FakeServeWorld()
            world.preload(repo: "/Models/a", port: 8766)
            let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
                store: JSONStore<EndpointConfig>(fileURL: storeURL),
                fleetStore: JSONStore(fileURL: fleetURL, replaceItem: { _, _ in throw StubError.offline }))
            switch action {
            case "enable": await supervisor.enable(modelPath: "/Models/b", port: 8766)
            case "add": await supervisor.addSlot(modelPath: "/Models/b", port: 8767)
            case "disable": await supervisor.disable()
            case "toggle": await supervisor.setSlotEnabled(id: slot.id, false)
            case "swap": await supervisor.swapSlot(id: slot.id, to: "/Models/b")
            case "update": await supervisor.updateSlot(id: slot.id, modelPath: "/Models/b", port: 8766, role: nil)
            default: await supervisor.removeSlot(id: slot.id)
            }
            XCTAssertEqual(supervisor.fleet, original, action)
            XCTAssertEqual(try world.status().map(\.modelIdentity), ["/Models/a"], action)
            XCTAssertEqual(try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).load(), [original], action)
            XCTAssertNotNil(supervisor.persistenceError, action)
        }
    }

    func testOverlappingFleetMutationIsRejectedWhileServerStopIsPending() async throws {
        let fleetURL = temporaryURL("fleet.json")
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a")
        try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).replaceAll([
            EndpointFleetConfig(slots: [slot], installedAtLogin: false)
        ])
        let entered = expectation(description: "Server stop entered")
        let gate = EndpointStopGate()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766)
        var lifecycle = world.lifecycle
        let stop = lifecycle.stop
        lifecycle.stop = { port in
            entered.fulfill()
            await gate.wait()
            try await stop(port)
        }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: JSONStore(fileURL: fleetURL))
        let removal = Task { await supervisor.removeSlot(id: slot.id) }
        await fulfillment(of: [entered], timeout: 5)
        await supervisor.updateSlot(id: slot.id, modelPath: "/Models/a", port: 8766, role: .coding)
        XCTAssertNotNil(supervisor.lastError, "A concurrent action must explain why it was refused")
        XCTAssertFalse(supervisor.fleet.slots.contains { $0.role == .coding })
        supervisor.markLoginItemInstalled(true)
        XCTAssertTrue(supervisor.fleet.installedAtLogin, "An installed login item must retain its durable flag during the pending stop")
        XCTAssertEqual(try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).load().first?.installedAtLogin, true)
        XCTAssertTrue(supervisor.isChanging)
        await gate.release()
        await removal.value
        XCTAssertFalse(supervisor.isChanging)
        XCTAssertTrue(supervisor.fleet.slots.isEmpty)
        XCTAssertTrue(supervisor.fleet.installedAtLogin)
        XCTAssertTrue(try world.status().isEmpty)
    }

    func testUnreadableFleetCannotBeReplacedByEnablingAnEndpoint() async throws {
        let fleetURL = temporaryURL("fleet.json")
        try FileManager.default.createDirectory(at: fleetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged fleet".utf8)
        try original.write(to: fleetURL)
        let world = FakeServeWorld()
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: JSONStore(fileURL: fleetURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(supervisor.fleet.slots.isEmpty)
        XCTAssertTrue(try world.status().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fleetURL), original)
        XCTAssertNotNil(supervisor.persistenceError)
    }

    func testAdapterStatusCannotMatchAnUnadaptedModelAndProcessIdentityRetainsItsContents() throws {
        let source: [String: Any] = ["repo": "org/base", "port": 8766, "pid": 42, "state": "running",
            "adapter_path": "/adapters/tuned", "adapter_identity": ["adapters.safetensors": ["sha256": "first", "bytes": 4]]]
        let server = try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: source))
        let bridged = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [source]])?.first)
        XCTAssertEqual(bridged.adapterPath, server.adapterPath)
        XCTAssertEqual(bridged.adapterIdentity, server.adapterIdentity)
        XCTAssertFalse(bridged.matchesUnadaptedModel("org/base"))
        XCTAssertEqual(server.adapterPath, "/adapters/tuned")
        XCTAssertFalse(server.matchesUnadaptedModel("org/base"))
        var changed = source
        changed["adapter_identity"] = ["adapters.safetensors": ["sha256": "second", "bytes": 4]]
        let replacement = try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertFalse(server.sameProcess(as: replacement))
        XCTAssertFalse(ClientWiringSelection.sameServer(server, replacement))
        XCTAssertTrue(ClientWiringSelection.matchingServers(request: .init(modelPath: "org/base", preferredPort: nil), servers: [server]).isEmpty)
        let unknown = ServerInfo(repo: "org/base", state: "running", adapterStatus: "unknown")
        XCTAssertFalse(unknown.matchesUnadaptedModel("org/base"))
        XCTAssertTrue(ServerInfo(repo: "org/base", state: "running").matchesUnadaptedModel("org/base"))
        let malformed = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [["repo": "org/base", "adapter_path": 42]]])?.first)
        XCTAssertFalse(malformed.matchesUnadaptedModel("org/base"))
    }

    func testBaseEndpointDoesNotAdoptOrConfigureAnAdapterServerOnItsPort() async throws {
        let world = FakeServeWorld(), recorder = LifecycleRecorder()
        world.recorder = recorder
        let adapter = ServerInfo(path: "/Models/a", port: 8766, pid: 42, state: "running", jit: true,
            modelState: "loaded", adapterPath: "/adapters/tuned")
        var lifecycle = world.lifecycle
        lifecycle.configureMemory = { _, _, _ in XCTFail("A base endpoint must not configure an adapter server") }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { [adapter] },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        guard case .modelMismatch(let name, _)? = supervisor.slotStates[id] else { return XCTFail("Adapter server must not be adopted as the base") }
        XCTAssertTrue(name.contains("Adapter: tuned"))
        XCTAssertTrue(recorder.events.isEmpty)
        await supervisor.setSlotMemoryPolicy(id: id, .init(idleTimeoutSeconds: 60, keepLoaded: true, minimumHeadroomGB: 4))
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testNewEndpointDefaultsToJITWithoutEagerStart() async throws {
        let world = FakeServeWorld()
        let recorder = LifecycleRecorder()
        world.recorder = recorder
        var lifecycle = world.lifecycle
        lifecycle.jitPreview = { _, _, policy in
            XCTAssertEqual(policy, .automatic)
            return "jit-hash"
        }
        lifecycle.jitStart = { model, port, hash, policy in
            XCTAssertEqual(hash, "jit-hash")
            XCTAssertEqual(policy, .automatic)
            world.preload(repo: model, port: port, jit: true, modelState: "unloaded", memoryPolicy: policy)
        }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        XCTAssertTrue(try XCTUnwrap(supervisor.fleet.slots.first).usesJIT)
        XCTAssertEqual(supervisor.fleet.slots.first?.memoryPolicy, .automatic)
        XCTAssertEqual(try world.status().first?.modelState, "unloaded")
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testPolicyChangesApplyToLoadedGatewayWithoutStoppingIt() async throws {
        let world = FakeServeWorld()
        let recorder = LifecycleRecorder()
        world.recorder = recorder
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded", activeRequests: 1)
        var lifecycle = world.lifecycle
        lifecycle.configureMemory = { port, pid, policy in
            XCTAssertEqual(pid, 1)
            world.configureMemory(port: port, policy: policy)
        }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        let policy = EndpointMemoryPolicy(idleTimeoutSeconds: 60, keepLoaded: true, minimumHeadroomGB: 4)
        await supervisor.setSlotMemoryPolicy(id: id, policy)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(try world.status().first?.memoryPolicy, policy)
        XCTAssertEqual(try world.status().first?.modelState, "loaded")
        XCTAssertEqual(try world.status().first?.activeRequests, 1)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testPolicySaveFailureDoesNotChangeGateway() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded")
        let recorder = LifecycleRecorder()
        var lifecycle = world.lifecycle
        lifecycle.configureMemory = { _, _, _ in recorder.record("configure") }
        let fleetURL = temporaryURL("fleet.json")
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a", loadOnRequest: true)
        try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false)])
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: fleetURL, replaceItem: { _, _ in throw StubError.offline }))
        await supervisor.setSlotMemoryPolicy(id: slot.id, .automatic)
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertNil(supervisor.fleet.slots.first?.memoryPolicy)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testJITUnloadKeepsDesiredEndpointAndDoesNotStartWorkerAgain() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded")
        var lifecycle = world.lifecycle
        lifecycle.unload = { port, _ in world.unloadModel(port: port) }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let before = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(before)
        XCTAssertTrue(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        await supervisor.reconcile()
        let after = try XCTUnwrap(try world.status().first)
        XCTAssertEqual(after.pid, before.pid)
        XCTAssertEqual(after.state, "running")
        XCTAssertEqual(after.modelState, "unloaded")
    }

    func testFailedJITUnloadKeepsDesiredStateAndReportsLoadedModel() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded")
        var lifecycle = world.lifecycle
        lifecycle.unload = { _, _ in throw StubError.offline }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertEqual(try world.status().first?.modelState, "loaded")
        XCTAssertNotNil(supervisor.lastError)
    }

    func testUnloadStandaloneServerAndPreservesOtherPorts() async throws {
        let world = FakeServeWorld()
        let fleetURL = temporaryURL("fleet.json")
        try FileManager.default.createDirectory(at: fleetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("damaged fleet".utf8)
        try damaged.write(to: fleetURL)
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: fleetURL))
        world.preload(repo: "/Models/a", port: 8766)
        world.preload(repo: "/Models/b", port: 8767)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertTrue(unloaded)
        XCTAssertEqual(try world.status().map(\.port), [8767])
        XCTAssertEqual(try Data(contentsOf: fleetURL), damaged)
        XCTAssertNotNil(supervisor.persistenceError)
    }

    func testUnloadSaveFailureDoesNotStopOrDisableServer() async throws {
        let world = FakeServeWorld()
        let fleetURL = temporaryURL("fleet.json")
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: fleetURL, replaceItem: { _, _ in throw StubError.offline }))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertEqual(try world.status(), [server])
        XCTAssertNotNil(supervisor.lastError)
    }

    func testUnloadStopFailureLeavesRestartDisabledAndReportsRunningServer() async throws {
        let world = FakeServeWorld()
        let live = world.lifecycle
        let supervisor = EndpointSupervisor(lifecycle: ServeLifecycle(preview: live.preview, start: live.start,
            stop: { _ in throw StubError.offline }), statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(try world.status(), [server])
        XCTAssertNotNil(supervisor.lastError)
    }

    func testUnloadRefusesChangedServerIdentityAndDoesNotDisableEndpoint() async throws {
        let (supervisor, world) = makeSupervisor()
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        world.kill(port: 8766)
        world.preload(repo: "/Models/b", port: 8766)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertEqual(try world.status().first?.modelIdentity, "/Models/b")
    }

    func testUnloadDisablesDesiredEndpointAndDoesNotRestartIt() async throws {
        let (supervisor, world) = makeSupervisor()
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertTrue(unloaded)
        XCTAssertFalse(supervisor.config.enabled)
        await supervisor.reconcile()
        XCTAssertFalse(try world.status().contains { $0.state == "running" })
    }

    func testIntentionalEnableSwapAndAddRecordServedButAutomaticRestartsDoNot() async throws {
        let (supervisor, world) = makeSupervisor()
        let tracker = UsageTracker(store: JSONStore<UsageStamp>(fileURL: temporaryURL("usage.json")))
        var served: [String] = []
        supervisor.onUserServeStarted = { path in served.append(path); tracker.recordServed(path) }

        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        await supervisor.swap(to: "/Models/b")
        await supervisor.reconcile()
        await supervisor.addSlot(modelPath: "/Models/c", port: 8767)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a", "/Models/b", "/Models/c"])
        await tracker.waitForPersistence()
        XCTAssertNotNil(tracker.lastServedByPath["/Models/c"])
        let stamps = tracker.lastServedByPath

        world.kill(port: 8766)
        await supervisor.reconcile()
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a", "/Models/b", "/Models/c"])
        XCTAssertEqual(tracker.lastServedByPath, stamps)
    }

    func testUserEnableExistingMatchingServerRecordsIntentionalSelection() async {
        let (supervisor, world) = makeSupervisor()
        world.preload(repo: "/Models/a", port: 8766)
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertEqual(served, ["/Models/a"])
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a"])
    }

    func testDisabledSlotEditsAndRoleOnlyChangesDoNotRecordServing() async throws {
        let (supervisor, _) = makeSupervisor()
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        served = []
        await supervisor.updateSlot(id: id, modelPath: "/Models/a", port: 8766, role: .coding)
        XCTAssertTrue(served.isEmpty)
        await supervisor.setSlotEnabled(id: id, false)
        await supervisor.swapSlot(id: id, to: "/Models/b")
        await supervisor.updateSlot(id: id, modelPath: "/Models/c", port: 8766, role: .coding)
        XCTAssertTrue(served.isEmpty)
        await supervisor.setSlotEnabled(id: id, true)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/c"])
        await supervisor.swapSlot(id: id, to: "/Models/d")
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/c", "/Models/d"])
        await supervisor.updateSlot(id: id, modelPath: "/Models/e", port: 8766, role: .coding)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/c", "/Models/d", "/Models/e"])
    }

    func testFailedStartAndRejectedUserOperationsDoNotRecordServing() async {
        let failing = EndpointSupervisor(lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in throw StubError.offline }, stop: { _ in }), statusProvider: { [] }, store: JSONStore<EndpointConfig>(fileURL: storeURL))
        var served: [String] = []
        failing.onUserServeStarted = { served.append($0) }
        await failing.enable(modelPath: "/Models/a", port: 8766)
        await failing.swap(to: "/Models/b")
        await failing.addSlot(modelPath: "/Models/c", port: 8767)
        XCTAssertTrue(served.isEmpty)

        let (supervisor, world) = makeSupervisor()
        supervisor.onUserServeStarted = { served.append($0) }
        supervisor.isVerified = { _ in false }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(served.isEmpty)
        supervisor.isVerified = nil
        world.statusError = StubError.offline
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(served.isEmpty)
        world.statusError = nil
        world.preload(repo: "/Models/other", port: 8766)
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(served.isEmpty)
    }

    func testUnrelatedAutomaticFleetRestartDuringUserAddDoesNotRecordOldModel() async {
        let (supervisor, world) = makeSupervisor()
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        served = []
        world.kill(port: 8766)
        await supervisor.addSlot(modelPath: "/Models/b", port: 8767)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/b"])
    }

    func testAcceptedStartWaitsForAuthoritativeRunningAndRecordsOnce() async {
        let (supervisor, world) = makeSupervisor()
        world.survives = false
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertEqual(supervisor.state, .waitingForServer)
        XCTAssertTrue(served.isEmpty)
        await supervisor.reconcile()
        XCTAssertTrue(served.isEmpty)
        world.preload(repo: "/Models/a", port: 8766)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a"])
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a"])
    }

    func testPendingIntentClearsAfterStatusFailureOrDisable() async {
        let (supervisor, world) = makeSupervisor()
        world.survives = false
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        world.statusError = StubError.offline
        await supervisor.reconcile()
        world.statusError = nil
        world.preload(repo: "/Models/a", port: 8766)
        await supervisor.reconcile()
        XCTAssertTrue(served.isEmpty)

        world.kill(port: 8766)
        await supervisor.enable(modelPath: "/Models/b", port: 8766)
        await supervisor.disable()
        world.preload(repo: "/Models/b", port: 8766)
        await supervisor.reconcile()
        XCTAssertTrue(served.isEmpty)
    }

    // MARK: - Reconcile matrix

    func testDisabledConfigStaysDisabledAndNeverStarts() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)

        await supervisor.reconcile()

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testEnabledWithRunningMatchingServerReportsRunning() async {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/q4", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .running(modelPath: "/Models/q4", port: 8766))
    }

    // MARK: - Port text validation (no silent coercion)

    func testNonNumericPortTextIsRefusedWithoutEnabling() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)

        await supervisor.enable(modelPath: "/Models/q4", portText: "8o80")

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(supervisor.lastError, "Port must be a number between 1 and 65535.")
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testOutOfRangePortTextIsRefused() async {
        let (supervisor, _) = makeSupervisor()

        await supervisor.enable(modelPath: "/Models/q4", portText: "99999")

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(supervisor.lastError, "Port must be a number between 1 and 65535.")
    }

    func testEmptyPortTextUsesTheDefaultPort() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)

        await supervisor.enable(modelPath: "/Models/q4", portText: "  ")

        XCTAssertEqual(supervisor.config.port, EndpointConfig.defaultPort)
        XCTAssertEqual(supervisor.state, .waitingForServer)
        XCTAssertNil(supervisor.lastError)
    }

    func testEnabledWithoutServerStartsViaPreviewHashFlow() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .waitingForServer)
        XCTAssertEqual(lifecycle.events, [
            "preview:/Models/q4:8766",
            "start:/Models/q4:8766:hash-1",
        ])

        // The next reconcile sees the authoritative running server.
        await supervisor.reconcile()
        XCTAssertEqual(supervisor.state, .running(modelPath: "/Models/q4", port: 8766))
    }

    func testRunningDifferentModelOnConfiguredPortIsMismatchNotRestart() async {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/other", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .modelMismatch(servedModel: "other", port: 8766))
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testCrashLoopGuardStopsRestartingAfterLimit() async {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.survives = false
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)
        await supervisor.reconcile()
        await supervisor.reconcile()

        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("start") }.count, 3)

        await supervisor.reconcile()

        if case .degraded = supervisor.state {} else {
            XCTFail("expected degraded, got \(supervisor.state)")
        }
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("start") }.count, 3)
    }

    func testStatusUnavailablePreservesLastKnownState() async {
        let world = FakeServeWorld()
        world.statusError = StubError.offline
        let (supervisor, _) = makeSupervisor(world: world)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .disabled)  // initial state preserved
        XCTAssertTrue(supervisor.lastError?.contains("unavailable") == true)
    }

    // MARK: - Verification gate

    func testEnableRefusesUnverifiedModelWithoutOverride() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)
        supervisor.isVerified = { _ in false }

        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertTrue(supervisor.lastError?.contains("not verified") == true)
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testEnableAllowsUnverifiedWithExplicitOverride() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)
        supervisor.isVerified = { _ in false }

        await supervisor.enable(modelPath: "/Models/q4", port: 8766, allowUnverified: true)

        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertFalse(lifecycle.events.isEmpty)
    }

    // MARK: - Swap and disable

    func testSwapStopsCurrentAndStartsNewModelOnSamePort() async {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/q4", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)
        XCTAssertEqual(supervisor.state, .running(modelPath: "/Models/q4", port: 8766))

        await supervisor.swap(to: "/Models/q8")

        XCTAssertEqual(supervisor.config.modelPath, "/Models/q8")
        XCTAssertEqual(lifecycle.events, [
            "stop:8766",
            "preview:/Models/q8:8766",
            "start:/Models/q8:8766:hash-1",
        ])
    }

    func testDisableStopsOurServerAndPersists() async throws {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/q4", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        await supervisor.disable()

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertEqual(lifecycle.events, ["stop:8766"])
        // Persistence moved to the fleet store in spec 09 P1; the legacy
        // endpoint-config.json is now a read-only migration source.
        let fleetURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("endpoint-fleet.json")
        let persisted = try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).load()
        XCTAssertEqual(persisted.first?.slots.first?.enabled, false)
    }

    // MARK: - LaunchAgentManager

    func testPlistPreviewContainsLabelArgumentsAndRunAtLoad() throws {
        let home = try makeHome()
        let manager = LaunchAgentManager(home: home, run: { _, _ in "" }, uid: 501)
        let plan = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/q4"), fleetURL: storeURL, agentPath: "/opt/mlx-agent", arguments: WorkbenchAPI.serveArguments(model: "/Models/q4", runtime: "auto", port: 8766, receipts: home.path, previewHash: "hash"))

        let plist = try manager.plistPreview(plan: plan)

        XCTAssertTrue(plist.contains("<string>ai.cavi.mlxworkbench.endpoint</string>"))
        XCTAssertTrue(plist.contains("<string>/opt/mlx-agent/scripts/mlx-agent</string>"))
        XCTAssertTrue(plist.contains("<string>--path</string>"))
        XCTAssertTrue(plist.contains("<string>/Models/q4</string>"))
        XCTAssertTrue(plist.contains("<string>8766</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
    }

    func testInstallWritesPlistAndBootstrapsViaLaunchctlArgv() throws {
        let home = try makeHome()
        let invocations = InvocationRecorder()
        let manager = LaunchAgentManager(home: home, run: { executable, argv in
            invocations.record(executable: executable, argv: argv)
            return ""
        }, uid: 501)
        let plan = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/q4"), fleetURL: storeURL, agentPath: "/opt/mlx-agent", arguments: WorkbenchAPI.serveArguments(model: "/Models/q4", runtime: "auto", port: 8766, receipts: home.path, previewHash: "hash"))

        try manager.install(plan: plan)

        XCTAssertTrue(manager.isInstalled)
        let calls = invocations.values
        XCTAssertEqual(calls.last?.executable, "/bin/launchctl")
        XCTAssertEqual(calls.last?.argv, [
            "bootstrap", "gui/501",
            home.appendingPathComponent("Library/LaunchAgents/ai.cavi.mlxworkbench.endpoint.plist").path,
        ])
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        let home = try makeHome()
        let invocations = InvocationRecorder()
        let manager = LaunchAgentManager(home: home, run: { executable, argv in
            invocations.record(executable: executable, argv: argv)
            return ""
        }, uid: 501)
        let plan = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/q4"), fleetURL: storeURL, agentPath: "/opt/mlx-agent", arguments: WorkbenchAPI.serveArguments(model: "/Models/q4", runtime: "auto", port: 8766, receipts: home.path, previewHash: "hash"))
        try manager.install(plan: plan)

        try manager.uninstall()

        XCTAssertFalse(manager.isInstalled)
        XCTAssertTrue(invocations.values.contains { $0.argv == ["bootout", "gui/501/ai.cavi.mlxworkbench.endpoint"] })
    }

    // MARK: - Helpers

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = temporaryURL("endpoint-config.json")
    }

    private func makeSupervisor(
        world: FakeServeWorld? = nil,
        lifecycle: LifecycleRecorder? = nil
    ) -> (EndpointSupervisor, FakeServeWorld) {
        let world = world ?? FakeServeWorld()
        let recorder = lifecycle ?? LifecycleRecorder()
        world.recorder = recorder
        let supervisor = EndpointSupervisor(
            lifecycle: world.lifecycle,
            statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            maxRestarts: 3,
            restartWindow: 300
        )
        return (supervisor, world)
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-endpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-endpoint-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private enum StubError: Error { case offline }
}

private actor EndpointStopGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(executable: String, argv: [String])] = []
    var values: [(executable: String, argv: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(executable: String, argv: [String]) {
        lock.lock()
        recorded.append((executable, argv))
        lock.unlock()
    }
}

private actor RetryableEndpointStop {
    private var allowed = false
    private let operation: @Sendable (Int) async throws -> Void
    init(stop: @escaping @Sendable (Int) async throws -> Void) { operation = stop }
    func allowStop() { allowed = true }
    func stop(_ port: Int) async throws {
        guard allowed else { throw CocoaError(.fileReadUnknown) }
        try await operation(port)
    }
}
