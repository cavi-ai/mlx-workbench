import Foundation
import XCTest
import Combine
import Network
@testable import mlx_workbench

@MainActor
final class HostedIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFailedRefreshKeepsPreviousInventoryAndReportsFailure() async throws {
        let store = JSONStore<ModelHost>(fileURL: try directory().appendingPathComponent("hosts.json"))
        let host = ModelHost(name: "Ollama", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        let calls = InventorySequence()
        let coordinator = ModelHostsCoordinator(store: store, readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { host, _ in
            try await calls.fetch(host)
        })
        try coordinator.save(host, token: nil, replaceToken: false)
        await coordinator.refresh(host.id)
        XCTAssertEqual(coordinator.inventories[host.id]?.models.map(\.modelID), ["model:latest"])
        let captured = coordinator.inventories[host.id]?.capturedAt
        await coordinator.refresh(host.id)
        XCTAssertEqual(coordinator.inventories[host.id]?.capturedAt, captured)
        XCTAssertNotNil(coordinator.errors[host.id])
        XCTAssertFalse(coordinator.refreshing.contains(host.id))
    }

    func testInvalidHostDoesNotPersistOrWriteCredentials() throws {
        let store = JSONStore<ModelHost>(fileURL: try directory().appendingPathComponent("hosts.json"))
        let coordinator = ModelHostsCoordinator(store: store, readToken: { _ in nil }, writeToken: { _, _ in XCTFail("Invalid host wrote a secret") })
        XCTAssertThrowsError(try coordinator.save(ModelHost(name: "Remote", provider: .ollama, baseURL: "http://example.com"), token: "secret", replaceToken: true))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(coordinator.hosts.isEmpty)
    }

    func testFailedHostSavePreservesPublishedConfiguration() throws {
        let root = try directory()
        let file = root.appendingPathComponent("hosts.json")
        let store = JSONStore<ModelHost>(fileURL: file)
        let host = ModelHost(name: "Ollama", provider: .ollama, baseURL: "http://localhost:11434")
        let coordinator = ModelHostsCoordinator(store: store, readToken: { _ in nil }, writeToken: { _, _ in })
        try coordinator.save(host, token: nil, replaceToken: false)
        try Data("broken".utf8).write(to: file)
        var changed = host; changed.name = "Changed"
        XCTAssertThrowsError(try coordinator.save(changed, token: nil, replaceToken: false))
        XCTAssertEqual(coordinator.hosts, [host])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }

    func testTargetIdentityIncludesHostAndRejectsMismatchedModel() throws {
        let first = ModelHost(name: "First", provider: .ollama, baseURL: "http://localhost:11434")
        let second = ModelHost(name: "Second", provider: .lmStudio, baseURL: "http://localhost:1234")
        let model = HostedModel(hostID: first.id, modelID: "same", name: "Same")
        let a = HostedComparisonTarget(host: first, model: model, capturedAt: Date())
        let b = HostedComparisonTarget(host: second, model: HostedModel(hostID: second.id, modelID: "same", name: "Same"), capturedAt: Date())
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNoThrow(try a.validate(mode: .chat))
        XCTAssertThrowsError(try HostedComparisonTarget(host: second, model: model, capturedAt: Date()).validate(mode: .chat))
        XCTAssertThrowsError(try a.validate(mode: .imageGeneration))
    }

    func testHostedRunPersistsCapturedIdentityAndFullOutputOutsideNativeStore() async throws {
        let root = try directory(), store = JSONStore<HostedComparisonRecord>(fileURL: root.appendingPathComponent("hosted.json"))
        let host = ModelHost(name: "Ollama", provider: .ollama, baseURL: "http://localhost:11434")
        let model = HostedModel(hostID: host.id, modelID: "model:latest", name: "Model", digest: "original")
        let inventory = HostInventory(host: host, models: [model], capturedAt: Date(), runtimeVersion: "1.0")
        let coordinator = HostedComparisonCoordinator(store: store, readToken: { _ in nil },
            freshInventory: { _, _ in inventory }, hostedChat: { _, _, id, entry in
                XCTAssertEqual(id, "model:latest")
                XCTAssertEqual(entry.text, "Say hello")
                return ProbeSample(text: "Hello", completionTokens: 1, timeToFirstTokenSeconds: 0.1,
                    durationSeconds: 1, metricsEstimated: false, finishReason: "stop")
            })
        let done = expectation(description: "Run terminal")
        var subscription: AnyCancellable? = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        try coordinator.start(targets: [HostedComparisonTarget(host: host, model: model, capturedAt: inventory.capturedAt, runtimeVersion: "1.0")],
            promptSet: PromptSet(id: "host-test", name: "Host test", useCase: nil, prompts: [PromptEntry(id: "p", text: "Say hello", maxTokens: 32)], origin: .userCreated))
        await fulfillment(of: [done], timeout: 5)
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.run.state, .completed)
        XCTAssertEqual(saved.run.results.first?.samples.first?.fullOutput, "Hello")
        XCTAssertEqual(saved.targets.first?.model?.digest, "original")
        XCTAssertEqual(saved.targets.first?.runtimeVersion, "1.0")
        XCTAssertEqual(saved.temperature, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("comparison-runs.json").path))
        subscription?.cancel(); subscription = nil
    }

    func testChangedHostedDigestFailsBeforeInference() async throws {
        let store = JSONStore<HostedComparisonRecord>(fileURL: try directory().appendingPathComponent("hosted.json"))
        let host = ModelHost(name: "Ollama", provider: .ollama, baseURL: "http://localhost:11434")
        let before = HostedModel(hostID: host.id, modelID: "model", name: "Model", digest: "before")
        var after = before; after.digest = "after"
        let inventory = HostInventory(host: host, models: [after], capturedAt: Date())
        let coordinator = HostedComparisonCoordinator(store: store, readToken: { _ in nil }, freshInventory: { _, _ in inventory },
            hostedChat: { _, _, _, _ in XCTFail("Changed weights reached inference"); throw CancellationError() })
        let done = expectation(description: "Run terminal")
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        try coordinator.start(targets: [HostedComparisonTarget(host: host, model: before, capturedAt: Date())],
            promptSet: PromptSet(id: "p", name: "Test", useCase: nil, prompts: [PromptEntry(id: "p", text: "Hi", maxTokens: 32)], origin: .userCreated))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(try store.load().first?.run.state, .failed)
        XCTAssertNotNil(try store.load().first?.run.results.first?.error)
        subscription.cancel()
    }

    func testCancellationStopsObservationAndRetainsCancelledRun() async throws {
        let store = JSONStore<HostedComparisonRecord>(fileURL: try directory().appendingPathComponent("hosted.json"))
        let host = ModelHost(name: "Host", provider: .openAICompatible, baseURL: "http://localhost:9999")
        let model = HostedModel(hostID: host.id, modelID: "model", name: "Model")
        let inventory = HostInventory(host: host, models: [model], capturedAt: Date())
        let started = expectation(description: "Inference started"), done = expectation(description: "Cancellation recorded")
        let coordinator = HostedComparisonCoordinator(store: store, readToken: { _ in nil }, freshInventory: { _, _ in inventory },
            hostedChat: { _, _, _, _ in
                started.fulfill(); try await Task.sleep(nanoseconds: 10_000_000_000); throw CancellationError()
            })
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        try coordinator.start(targets: [HostedComparisonTarget(host: host, model: model, capturedAt: Date())], promptSet: testPrompts())
        await fulfillment(of: [started], timeout: 5)
        coordinator.cancel()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(try store.load().first?.run.state, .cancelled)
        XCTAssertFalse(coordinator.cancelling)
        XCTAssertNil(coordinator.activeRunID)
        subscription.cancel()
    }

    func testMixedLanesRecordNativeOwnershipAndStopOnlyNativeServer() async throws {
        let root = try directory(), store = JSONStore<HostedComparisonRecord>(fileURL: root.appendingPathComponent("hosted.json"))
        let events = NativeLifecycleEvents()
        let receipt = ComparisonServerReceipt(port: 9998, pid: 123, modelIdentity: "/Models/native", previewHash: "reviewed", startedAt: "stamp")
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "reviewed" }, start: { _, _, _ in },
            stop: { port in await events.stopped(port) }, startWithReceipt: { _, _, _ in receipt }),
            prober: HostedNativeProber(check: {
                XCTAssertEqual(try store.load().first?.run.pendingServerCleanup?.server, receipt)
            }), pickPort: { 9998 })
        let host = ModelHost(name: "Host", provider: .ollama, baseURL: "http://localhost:11434")
        let model = HostedModel(hostID: host.id, modelID: "model", name: "Model", digest: "sha")
        let inventory = HostInventory(host: host, models: [model], capturedAt: Date())
        let coordinator = HostedComparisonCoordinator(store: store, nativeProbe: probe, readToken: { _ in nil },
            freshInventory: { _, _ in inventory }, hostedChat: { _, _, _, _ in
                ProbeSample(text: "Hosted answer", completionTokens: 2, timeToFirstTokenSeconds: 0.2, durationSeconds: 2, metricsEstimated: false, finishReason: "stop")
            })
        let done = expectation(description: "Mixed run completed")
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        let local = nativeModel()
        try coordinator.start(targets: [HostedComparisonTarget(local: local, capturedAt: Date()),
            HostedComparisonTarget(host: host, model: model, capturedAt: Date())], promptSet: testPrompts())
        await fulfillment(of: [done], timeout: 5)
        let result = try XCTUnwrap(store.load().first)
        XCTAssertEqual(result.run.state, .completed)
        XCTAssertEqual(result.run.results.map { $0.samples.first?.fullOutput }, ["Native answer", "Hosted answer"])
        XCTAssertNil(result.run.pendingServerCleanup)
        let stopped = await events.ports
        XCTAssertEqual(stopped, [9998])
        XCTAssertEqual(result.observedTargets?.first?.host, host)
        subscription.cancel()
    }

    func testCleanupRecoveryRequiresRecordedReceiptBeforeAnotherRun() async throws {
        let store = JSONStore<HostedComparisonRecord>(fileURL: try directory().appendingPathComponent("hosted.json"))
        let receipt = ComparisonServerReceipt(port: 9998, pid: 123, modelIdentity: "/Models/native", previewHash: "reviewed", startedAt: "stamp")
        var run = ComparisonRun(id: UUID(), promptSetID: "p", promptSetName: "Test", useCase: nil, variants: ["local:/Models/native"],
            results: [], startedAt: Date(), finishedAt: nil, state: .running)
        run.pendingServerCleanup = ComparisonCleanup(server: receipt, completionState: .cancelled)
        try store.upsert(HostedComparisonRecord(run: run, targets: [HostedComparisonTarget(local: nativeModel(), capturedAt: Date())],
            temperature: 0, workflow: nil, submissions: []), id: \.id)
        let recovered = expectation(description: "Owned server recovered")
        let coordinator = HostedComparisonCoordinator(store: store, recoverCleanup: { saved in XCTAssertEqual(saved, receipt); recovered.fulfill() })
        XCTAssertTrue(coordinator.cleanupPending)
        XCTAssertThrowsError(try coordinator.start(targets: [], promptSet: testPrompts()))
        let done = expectation(description: "Cleanup cleared")
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        coordinator.retryCleanup()
        await fulfillment(of: [recovered, done], timeout: 5)
        XCTAssertNil(try store.load().first?.run.pendingServerCleanup)
        XCTAssertEqual(try store.load().first?.run.state, .cancelled)
        XCTAssertFalse(coordinator.cleanupPending)
        subscription.cancel()
    }

    func testDefaultHostedRunnerUsesAuthenticatedHTTPInventoryAndStreamingChat() async throws {
        let server = try await HostedFixtureServer.start()
        defer { server.stop() }
        let store = JSONStore<HostedComparisonRecord>(fileURL: try directory().appendingPathComponent("hosted.json"))
        let host = ModelHost(name: "Fixture host", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port)")
        let model = HostedModel(hostID: host.id, modelID: "fixture-model", name: "Fixture model")
        let coordinator = HostedComparisonCoordinator(store: store, readToken: { _ in "fixture-token" })
        let done = expectation(description: "HTTP comparison completed")
        let subscription = coordinator.$activeRunID.dropFirst().filter { $0 == nil }.sink { _ in done.fulfill() }
        try coordinator.start(targets: [HostedComparisonTarget(host: host, model: model, capturedAt: Date())], promptSet: testPrompts())
        await fulfillment(of: [done], timeout: 5)
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.run.state, .completed)
        XCTAssertEqual(saved.run.results.first?.samples.first?.fullOutput, "Hello")
        XCTAssertEqual(saved.run.results.first?.samples.first?.completionTokens, 1)
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].hasPrefix("GET /v1/models "))
        XCTAssertTrue(requests[1].hasPrefix("POST /v1/chat/completions "))
        XCTAssertTrue(requests.allSatisfy { $0.lowercased().contains("authorization: bearer fixture-token") })
        let body = try XCTUnwrap(requests[1].components(separatedBy: "\r\n\r\n").last?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "fixture-model")
        XCTAssertEqual(json["max_tokens"] as? Int, 32)
        XCTAssertEqual(json["temperature"] as? Int, 0)
        subscription.cancel()
    }

    func testOwnershipSaveAndStopFailureRetainBlockingCleanup() async throws {
        let root = try directory(), file = root.appendingPathComponent("hosted.json")
        let store = JSONStore<HostedComparisonRecord>(fileURL: file)
        let receipt = ComparisonServerReceipt(port: 9998, pid: 123, modelIdentity: "/Models/native", previewHash: "reviewed", startedAt: "stamp")
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "reviewed" }, start: { _, _, _ in },
            stop: { _ in throw URLError(.cannotConnectToHost) }, startWithReceipt: { _, _, _ in
                try Data("corrupt".utf8).write(to: file); return receipt
            }), prober: HostedNativeProber(check: { XCTFail("Unrecorded ownership reached inference") }), pickPort: { 9998 })
        let coordinator = HostedComparisonCoordinator(store: store, nativeProbe: probe)
        let finished = expectation(description: "Failure handling finished")
        let subscription = coordinator.$progress.dropFirst().filter { $0 == nil || $0?.lowercased().contains("cleanup") == true }.prefix(1).sink { _ in finished.fulfill() }
        try coordinator.start(targets: [HostedComparisonTarget(local: nativeModel(), capturedAt: Date())], promptSet: testPrompts())
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(coordinator.cleanupPending)
        XCTAssertNotNil(coordinator.activeRunID)
        XCTAssertThrowsError(try coordinator.start(targets: [], promptSet: testPrompts()))
        subscription.cancel()
    }

    func testStreamingResponseRejectsOversizedLineAndAggregateBytes() async throws {
        for body in ["data: " + String(repeating: "x", count: 2048), String(repeating: "data: {}\n", count: 200)] {
            let server = try await HostedFixtureServer.start(streamBody: body)
            defer { server.stop() }
            let prober = OpenAIEndpointProber(session: HostHTTPClient.sharedSession, maximumResponseBytes: 1024, maximumLineBytes: 256)
            do {
                _ = try await prober.chat(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, model: "fixture-model", prompt: "Hello", maxTokens: 32)
                XCTFail("Oversized streaming data must fail")
            } catch { XCTAssertEqual(error as? ProbeHTTPError, .responseTooLarge) }
        }
    }

    private func testPrompts() -> PromptSet {
        PromptSet(id: "p", name: "Test", useCase: nil, prompts: [PromptEntry(id: "p", text: "Hello", maxTokens: 32)], origin: .userCreated)
    }

    func testResourcePreviewAndCancelNeverReleaseModels() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        XCTAssertNotNil(coordinator.resourcePreview)
        XCTAssertEqual(coordinator.resourcePreview?.activity.state, .unknown)
        coordinator.cancelResourcePreview()
        XCTAssertNil(coordinator.resourcePreview)
        let count = await peer.releases
        XCTAssertEqual(count, 0)
    }

    func testChangedActivityRequiresAnotherConfirmationBeforeRelease() async throws {
        let (coordinator, peer, host) = try resourceFixture(provider: .comfyUI)
        await peer.setState(.idle)
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection())
        await peer.setState(.busy)
        await coordinator.confirmResource()
        var count = await peer.releases
        XCTAssertEqual(count, 0)
        XCTAssertEqual(coordinator.resourcePreview?.activity.state, .busy)
        await coordinator.confirmResource()
        count = await peer.releases
        XCTAssertEqual(count, 1)
        XCTAssertNil(coordinator.resourcePreview)
        XCTAssertTrue(coordinator.resourceMessage?.contains("accepted") == true)
        await coordinator.confirmResource()
        count = await peer.releases
        XCTAssertEqual(count, 1, "A consumed confirmation cannot be replayed")
    }

    func testChangedInstanceMetadataRequiresRenewedConfirmation() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        await peer.setDigest("changed")
        await coordinator.confirmResource()
        let count = await peer.releases
        XCTAssertEqual(count, 0)
        XCTAssertEqual(coordinator.resourcePreview?.model?.digest, "changed")
    }

    func testConcurrentResourceConfirmationsIssueOneRelease() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        async let first: Void = coordinator.confirmResource()
        async let second: Void = coordinator.confirmResource()
        _ = await (first, second)
        let count = await peer.releases
        XCTAssertEqual(count, 1)
        XCTAssertFalse(coordinator.resourceBusy)
    }

    func testHostEditInvalidatesResourcePreviewAndActiveWorkBlocksMutation() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        var changed = host; changed.baseURL = "http://127.0.0.1:12345"
        try coordinator.save(changed, token: nil, replaceToken: false)
        await coordinator.confirmResource()
        XCTAssertNil(coordinator.resourcePreview)
        await coordinator.prepareResource(hostID: changed.id, selection: HostResourceSelection(modelID: "model"))
        coordinator.resourceUseBlocked = { true }
        await coordinator.confirmResource()
        let count = await peer.releases
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(coordinator.resourceMessage)
    }

    func testUnloadReadbackMustShowModelAbsentBeforeReportingUnloaded() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        await coordinator.confirmResource()
        XCTAssertTrue(coordinator.resourceMessage?.contains("still reported loaded") == true)
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        await peer.setLoaded(false)
        await coordinator.confirmResource()
        XCTAssertTrue(coordinator.resourceMessage?.contains("no longer loaded") == true)
    }

    func testUncertainReleaseIsNotRetriedAndFailedRefreshRetainsInventory() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.refresh(host.id)
        let captured = coordinator.inventories[host.id]
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        await peer.failReleaseAndRefresh()
        await coordinator.confirmResource()
        let count = await peer.releases
        XCTAssertEqual(count, 1)
        XCTAssertEqual(coordinator.inventories[host.id], captured)
        XCTAssertNotNil(coordinator.errors[host.id])
        XCTAssertNil(coordinator.resourcePreview)
        XCTAssertTrue(coordinator.resourceMessage?.contains("unknown") == true)
    }

    func testOllamaReadbackWithChangedDigestCannotEstablishUnloadedState() async throws {
        let (coordinator, peer, host) = try resourceFixture()
        await coordinator.prepareResource(hostID: host.id, selection: HostResourceSelection(modelID: "model"))
        await peer.setLoaded(false)
        await peer.setReadbackDigest("different-weights")
        await coordinator.confirmResource()
        XCTAssertFalse(coordinator.resourceMessage?.contains("no longer loaded") == true)
        XCTAssertTrue(coordinator.resourceMessage?.contains("identity changed") == true)
    }

    private func resourceFixture(provider: ModelHostProvider = .ollama) throws -> (ModelHostsCoordinator, ResourceTestPeer, ModelHost) {
        let peer = ResourceTestPeer()
        let host = ModelHost(name: "Fixture", provider: provider, baseURL: "http://127.0.0.1:11434")
        let coordinator = ModelHostsCoordinator(store: JSONStore(fileURL: try directory().appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { host, _ in try await peer.inventory(host) },
            inspectResource: { host, selection, _ in await peer.preview(host, selection) },
            releaseResource: { preview, _ in try await peer.release(preview) })
        try coordinator.save(host, token: nil, replaceToken: false)
        return (coordinator, peer, host)
    }
    private func nativeModel() -> LibraryModel {
        LibraryModel(item: ModelItem(path: "/Models/native", name: "Native", bytes: 100, modifiedAt: nil, shard: nil,
            modelKey: "native", architecture: nil, quantization: "q4", parameters: nil, structure: nil, signature: "native-sha",
            companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: nil), readiness: .ready)
    }
}

private actor ResourceTestPeer {
    var releases = 0
    private var state = HostActivityState.unknown
    private var digest = "original"
    private var loaded = true
    private var fail = false
    private var readbackDigest: String?
    func setState(_ value: HostActivityState) { state = value }
    func setDigest(_ value: String) { digest = value }
    func setLoaded(_ value: Bool) { loaded = value }
    func setReadbackDigest(_ value: String) { readbackDigest = value }
    func failReleaseAndRefresh() { fail = true }
    func preview(_ host: ModelHost, _ selection: HostResourceSelection) -> HostResourcePreview {
        HostResourcePreview(host: host, selection: selection,
            model: host.provider == .comfyUI ? nil : HostedModel(hostID: host.id, modelID: "model", name: "Model", digest: digest, isLoaded: true),
            activity: HostActivity(state: state, detail: "Fixture activity"))
    }
    func inventory(_ host: ModelHost) throws -> HostInventory {
        if fail { throw URLError(.cannotConnectToHost) }
        return HostInventory(host: host, models: [HostedModel(hostID: host.id, modelID: "model", name: "Model", digest: readbackDigest ?? digest, isLoaded: loaded)], capturedAt: Date())
    }
    func release(_ preview: HostResourcePreview) throws {
        releases += 1
        if fail { throw URLError(.timedOut) }
    }
}

private actor InventorySequence {
    var count = 0
    func fetch(_ host: ModelHost) throws -> HostInventory {
        count += 1
        if count > 1 { throw URLError(.cannotConnectToHost) }
        return HostInventory(host: host, models: [HostedModel(hostID: host.id, modelID: "model:latest", name: "Model")], capturedAt: Date())
    }
}

private actor NativeLifecycleEvents {
    var ports: [Int] = []
    func stopped(_ port: Int) { ports.append(port) }
}

private struct HostedNativeProber: EndpointProbing {
    let check: @Sendable () throws -> Void
    func isReady(baseURL: URL) async -> Bool { true }
    func listModels(baseURL: URL) async -> [String] { ["native"] }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        try check()
        return ProbeSample(text: "Native answer", completionTokens: 2, timeToFirstTokenSeconds: 0.1,
            durationSeconds: 1, metricsEstimated: false, finishReason: "stop")
    }
}

/// A controlled local HTTP peer exercises the production inventory and SSE client together.
private final class HostedFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hosted-comparison-http-fixture")
    private let lock = NSLock()
    private var recorded: [String] = []
    private let streamBody: String?
    var port: UInt16 { listener.port!.rawValue }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private init(streamBody: String?) throws {
        self.streamBody = streamBody
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    static func start(streamBody: String? = nil) async throws -> HostedFixtureServer {
        let server = try HostedFixtureServer(streamBody: streamBody)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state { case .ready: continuation.resume(); case .failed(let error): continuation.resume(throwing: error); default: break }
            }
            server.listener.newConnectionHandler = { connection in
                connection.start(queue: server.queue); server.receive(connection, data: Data())
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, complete, error in
            guard error == nil else { connection.cancel(); return }
            var data = data; data.append(chunk ?? Data())
            guard data.count < 1_048_576, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            guard let end = request.range(of: "\r\n\r\n") else {
                if complete { connection.cancel() } else { receive(connection, data: data) }; return
            }
            let header = String(request[..<end.lowerBound])
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request[end.upperBound...].utf8.count >= length else { receive(connection, data: data); return }
            lock.lock(); recorded.append(request); lock.unlock()
            let chat = request.hasPrefix("POST ")
            let body = chat
                ? (streamBody ?? "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":1,\"prompt_tokens\":3}}\n\ndata: [DONE]\n\n")
                : "{\"data\":[{\"id\":\"fixture-model\"}]}"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(chat ? "text/event-stream" : "application/json")\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { listener.cancel() }
}
