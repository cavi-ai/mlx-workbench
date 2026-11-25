import Combine
import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class ServingInventoryCoordinatorTests: XCTestCase {
    func testHostPublicationKeepsTheActualEngineCaptureTime() async throws {
        var instant = Date(timeIntervalSince1970: 100)
        let gate = InventoryTestGate()
        let entered = expectation(description: "host refresh waiting")
        let engine = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, now: { instant },
            fetchEngine: { ServingEngineSnapshot(servers: [engine]) }, fetchHosts: { _ in
                entered.fulfill(); await gate.wait(); return ServingHostSnapshot()
            }, readMemory: { _ in [:] })
        let published = expectation(description: "engine published")
        let observation = coordinator.$snapshot.dropFirst().filter { !$0.services.isEmpty }.first().sink { _ in published.fulfill() }
        defer { observation.cancel(); gate.open() }
        let refresh = Task { await coordinator.refresh(refreshHosts: true) }
        await fulfillment(of: [entered, published], timeout: 2)
        instant = Date(timeIntervalSince1970: 200)
        gate.open()
        await refresh.value
        XCTAssertEqual(coordinator.snapshot.services.first?.capturedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(coordinator.snapshot.capturedAt, instant)
    }

    private let capturedAt = Date(timeIntervalSince1970: 1_000)
    private let managedReceipts = "/receipts/workbench"

    private func server(path: String = "/models/model", pid: Int = 10, port: Int = 8766,
                        root: String = "/receipts/workbench", residency: String = "loaded") -> ServerInfo {
        ServerInfo(path: path, runtime: "mlx_lm", port: port, pid: pid, state: "running", jit: true,
            modelState: residency, workerPid: pid + 100, activeRequests: 0,
            receiptsDirectory: root, processStartedAt: "process-\(pid)")
    }

    private func hostInventory() -> HostInventory {
        let host = ModelHost(name: "Local host", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        return HostInventory(host: host,
            models: [HostedModel(hostID: host.id, modelID: "org/model", name: "Model", digest: "digest", isLoaded: true)],
            capturedAt: capturedAt)
    }

    func testRemovalUsesFreshEngineAndLocalHostOwnership() async throws {
        let host = hostInventory()
        var engineReads = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            engineReads += 1
            return ServingEngineSnapshot(servers: [self.server()])
        }, fetchHosts: { _ in ServingHostSnapshot(inventories: [host]) }, readMemory: { _ in [:] })
        let paths = try await coordinator.pathsForRemoval()
        XCTAssertEqual(engineReads, 1)
        XCTAssertTrue(paths.contains("/models/model"))
        XCTAssertTrue(paths.contains("org/model"))
    }

    func testBackgroundPollingSlowsWhenEmptyAndResumesWhenServing() async {
        let live = server()
        var engineReads = 0
        var hostProbes: [Bool] = []
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            engineReads += 1
            return ServingEngineSnapshot(servers: engineReads <= 2 ? [] : [live])
        }, fetchHosts: { refresh in
            hostProbes.append(refresh)
            return ServingHostSnapshot()
        }, readMemory: { _ in [:] })
        for _ in 0..<8 { await coordinator.refreshForTick(elapsed: .seconds(10)) }
        coordinator.stopMonitoring()

        XCTAssertEqual(hostProbes, [true, false, false, false, false, true, false, false])
    }

    func testRemovedListenerDoesNotBlockRemovalAfterSuccessfulDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = hostInventory()
        var listeners = [LocalModelHost(host: inventory.host, processID: 42)]
        var failDiscovery = false
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            discoverLocal: {
                if failDiscovery { throw CocoaError(.fileReadUnknown) }
                return listeners
            }, fetch: { _, _ in inventory })
        let managedServer = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [managedServer]) },
            fetchHosts: { await hosts.servingSnapshot(refreshLocal: $0) }, readMemory: { _ in [:] })

        let initial = try await coordinator.pathsForRemoval()
        XCTAssertTrue(initial.contains("org/model"))
        listeners = []
        failDiscovery = true
        do {
            _ = try await coordinator.pathsForRemoval()
            XCTFail("A failed probe must still block model removal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Local server discovery"))
        }
        failDiscovery = false
        let current = try await coordinator.pathsForRemoval()
        XCTAssertTrue(current.contains("/models/model"))
        XCTAssertFalse(current.contains("org/model"))
        XCTAssertNil(hosts.discoveredProcessIDs[inventory.host.id])
    }

    func testSavedHostWithNoServerDoesNotBlockRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        close(listener)
        XCTAssertTrue(bound)
        let store = JSONStore<ModelHost>(fileURL: root.appendingPathComponent("hosts.json"))
        let saved = ModelHost(name: "Stopped server", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(port)")
        try store.replaceAll([saved])
        let hosts = ModelHostsCoordinator(store: store, discoverLocal: { [] }, readToken: { _ in nil })
        let managedServer = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [managedServer]) },
            fetchHosts: { await hosts.servingSnapshot(refreshLocal: $0) }, readMemory: { _ in [:] })

        let paths = try await coordinator.pathsForRemoval()
        XCTAssertTrue(paths.contains("/models/model"))
        XCTAssertEqual(hosts.offline, [saved.id])
        XCTAssertNil(hosts.errors[saved.id])
    }

    func testRemovalNamesUnavailableSourcesAndFailsClosed() throws {
        let host = hostInventory()
        let key = "host:" + host.host.id.uuidString
        let hosts = ServingHostSnapshot(inventories: [host], errors: [key: "Connection failed"])
        XCTAssertThrowsError(try ServingInventoryCoordinator.pathsForRemoval(
            engine: ServingEngineSnapshot(servers: []), engineError: nil, hosts: hosts, managedReceipts: managedReceipts)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Local host"))
            XCTAssertTrue(error.localizedDescription.contains("Connection failed"))
            XCTAssertTrue(error.localizedDescription.contains("Serving"))
        }
        XCTAssertThrowsError(try ServingInventoryCoordinator.pathsForRemoval(
            engine: ServingEngineSnapshot(servers: [], errors: ["engine:receipts": "Unreadable"]),
            engineError: nil, hosts: ServingHostSnapshot(), managedReceipts: managedReceipts))
        XCTAssertThrowsError(try ServingInventoryCoordinator.pathsForRemoval(
            engine: ServingEngineSnapshot(servers: [], supportsDiscovery: false),
            engineError: nil, hosts: ServingHostSnapshot(), managedReceipts: managedReceipts))
    }

    func testCancelledRefreshCannotReusePriorOwnership() async throws {
        let gate = InventoryTestGate()
        let entered = expectation(description: "second engine read")
        var reads = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            reads += 1
            if reads == 2 { entered.fulfill(); await gate.wait() }
            return ServingEngineSnapshot(servers: [self.server()])
        }, readMemory: { _ in [:] })
        _ = try await coordinator.pathsForRemoval()
        let retry = Task { try await coordinator.pathsForRemoval() }
        await fulfillment(of: [entered], timeout: 2)
        coordinator.stopMonitoring()
        gate.open()
        do { _ = try await retry.value; XCTFail("Interrupted ownership refresh must refuse removal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("interrupted")) }
    }

    func testRemovalUsesTheHostResultItAwaited() async throws {
        let gate = InventoryTestGate()
        let strictRead = expectation(description: "strict host read")
        let cachedRead = expectation(description: "cached host read")
        let host = hostInventory()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            await gate.wait()
            return ServingEngineSnapshot(servers: [])
        }, fetchHosts: { refresh in
            if refresh { strictRead.fulfill(); return ServingHostSnapshot(inventories: [host]) }
            cachedRead.fulfill()
            return ServingHostSnapshot(errors: ["local-listeners": "Cached read unavailable"])
        }, readMemory: { _ in [:] })
        let removal = Task { try await coordinator.pathsForRemoval() }
        await fulfillment(of: [strictRead], timeout: 2)
        let displayRefresh = Task { await coordinator.refresh() }
        await fulfillment(of: [cachedRead], timeout: 2)
        gate.open()
        let paths = try await removal.value
        await displayRefresh.value
        XCTAssertTrue(paths.contains("org/model"))
    }

    func testConcurrentEngineRefreshesShareOneInFlightRead() async {
        let entered = expectation(description: "engine read entered")
        let secondCachedRead = expectation(description: "second refresh reads cached hosts")
        let gate = InventoryTestGate()
        var engineCalls = 0, cachedHostReads = 0
        let observed = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            engineCalls += 1; entered.fulfill()
            await gate.wait()
            return ServingEngineSnapshot(servers: [observed])
        }, fetchHosts: { _ in
            cachedHostReads += 1
            if cachedHostReads == 2 { secondCachedRead.fulfill() }
            return ServingHostSnapshot()
        }, readMemory: { _ in [:] })
        let first = Task { await coordinator.refresh() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { await coordinator.refresh() }
        await fulfillment(of: [secondCachedRead], timeout: 2)
        await Task.yield()
        gate.open()
        await first.value; await second.value
        XCTAssertEqual(engineCalls, 1)
        XCTAssertEqual(coordinator.snapshot.services.count, 1)
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testConcurrentHostRefreshesShareOneInFlightRead() async {
        let entered = expectation(description: "host read entered")
        let secondStarted = expectation(description: "second host refresh started")
        let gate = InventoryTestGate()
        var hostCalls = 0
        let inventory = hostInventory()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: []) }, fetchHosts: { refresh in
                XCTAssertTrue(refresh)
                hostCalls += 1; entered.fulfill()
                await gate.wait()
                return ServingHostSnapshot(inventories: [inventory])
            }, readMemory: { _ in [:] })
        let first = Task { await coordinator.refresh(refreshHosts: true) }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { secondStarted.fulfill(); await coordinator.refresh(refreshHosts: true) }
        await fulfillment(of: [secondStarted], timeout: 2)
        await Task.yield()
        gate.open()
        await first.value; await second.value
        XCTAssertEqual(hostCalls, 1)
        XCTAssertEqual(coordinator.snapshot.services.first?.host?.id, inventory.host.id)
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testEngineFailureKeepsLastObservationAndDisablesItsActions() async throws {
        var failing = false
        let observed = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            if failing { throw InventoryTestError.unavailable }
            return ServingEngineSnapshot(servers: [observed])
        }, readMemory: { _ in [:] })
        await coordinator.refresh()
        let original = try XCTUnwrap(coordinator.snapshot.services.first)
        XCTAssertTrue(original.canUnload)
        failing = true
        await coordinator.refresh()
        let retained = try XCTUnwrap(coordinator.snapshot.services.first)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.capturedAt, original.capturedAt)
        XCTAssertTrue(retained.stale)
        XCTAssertFalse(retained.canUnload)
        XCTAssertFalse(retained.canStop)
        XCTAssertEqual(coordinator.snapshot.loadedCount, 0)
        XCTAssertEqual(coordinator.snapshot.unknownCount, 1)
        XCTAssertNotNil(coordinator.snapshot.sourceErrors["engine"])
    }

    func testHostFailureKeepsLastHostRowsWithTheirSourceError() async throws {
        let inventory = hostInventory()
        let sourceID = "host:" + inventory.host.id.uuidString
        var failing = false
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: []) }, fetchHosts: { _ in
                failing ? ServingHostSnapshot(errors: [sourceID: "Host unavailable"])
                    : ServingHostSnapshot(inventories: [inventory])
            }, readMemory: { _ in [:] })
        await coordinator.refresh()
        let original = try XCTUnwrap(coordinator.snapshot.services.first)
        failing = true
        await coordinator.refresh()
        let retained = try XCTUnwrap(coordinator.snapshot.services.first)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertTrue(retained.stale)
        XCTAssertEqual(coordinator.snapshot.sourceErrors[sourceID], "Host unavailable")
        XCTAssertFalse(retained.canUnload)
    }

    func testPartialEngineFailureKeepsMissingSourceStaleAndSuccessfulSourceFresh() async throws {
        let first = server(path: "/models/first", pid: 10, root: "/receipts/first")
        let second = server(path: "/models/second", pid: 20, port: 8767, root: "/receipts/second")
        var partial = false
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            ServingEngineSnapshot(servers: partial ? [first] : [first, second],
                errors: partial ? ["engine:/receipts/second": "Unreadable receipts"] : [:])
        }, readMemory: { _ in [:] })
        await coordinator.refresh()
        partial = true
        await coordinator.refresh()
        XCTAssertEqual(coordinator.snapshot.services.count, 2)
        let current = try XCTUnwrap(coordinator.snapshot.services.first { $0.modelID == first.modelIdentity })
        let retained = try XCTUnwrap(coordinator.snapshot.services.first { $0.modelID == second.modelIdentity })
        XCTAssertFalse(current.stale)
        XCTAssertTrue(retained.stale)
        XCTAssertEqual(coordinator.snapshot.sourceErrors[retained.sourceID], "Unreadable receipts")
        XCTAssertEqual(coordinator.snapshot.loadedCount, 1)
    }

    func testSuccessfulRefreshClearsFailureAndReplacesStaleObservation() async throws {
        var failing = false
        let observed = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            if failing { throw InventoryTestError.unavailable }
            return ServingEngineSnapshot(servers: [observed])
        }, readMemory: { _ in [:] })
        await coordinator.refresh()
        failing = true; await coordinator.refresh()
        XCTAssertTrue(try XCTUnwrap(coordinator.snapshot.services.first).stale)
        failing = false; await coordinator.refresh()
        let refreshed = try XCTUnwrap(coordinator.snapshot.services.first)
        XCTAssertFalse(refreshed.stale)
        XCTAssertTrue(refreshed.canUnload)
        XCTAssertTrue(coordinator.snapshot.sourceErrors.isEmpty)
    }

    func testPreparationUsesFreshResidencyAndRefusesAnAlreadyUnloadedModel() async throws {
        var observed = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, readMemory: { _ in [:] })
        await coordinator.refresh()
        let selected = try XCTUnwrap(coordinator.snapshot.services.first)
        observed = server(residency: "unloaded")
        await coordinator.prepare(.unload, service: selected)
        XCTAssertNil(coordinator.actionReview)
        XCTAssertNotNil(coordinator.actionError)
        XCTAssertEqual(coordinator.snapshot.services.first?.residency, .unloaded)
    }

    func testMenuReviewCannotCancelOrConfirmWindowReview() async throws {
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [self.server()]) }, readMemory: { _ in [:] })
        var mutations = 0
        coordinator.mutate = { _, _ in mutations += 1 }
        await coordinator.refresh()
        await coordinator.prepare(.unload, service: try XCTUnwrap(coordinator.snapshot.services.first))
        coordinator.cancelReview(surface: .menuBar)
        await coordinator.confirm(surface: .menuBar)
        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(coordinator.actionReview?.surface, .window)
    }

    func testDismissedMenuPreparationDoesNotPublishReview() async throws {
        let gate = InventoryTestGate()
        var reads = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, fetchEngine: {
            reads += 1
            if reads > 1 { await gate.wait() }
            return ServingEngineSnapshot(servers: [self.server()])
        }, readMemory: { _ in [:] })
        await coordinator.refresh()
        let selected = try XCTUnwrap(coordinator.snapshot.services.first)
        let task = Task { await coordinator.prepare(.unload, service: selected, surface: .menuBar) }
        while reads < 2 { await Task.yield() }
        coordinator.cancelReview(surface: .menuBar)
        gate.open()
        await task.value
        XCTAssertNil(coordinator.actionReview)
    }

    func testChangedProcessRefusesPreparationAndClearsAnOlderReview() async throws {
        var observed = server()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, readMemory: { _ in [:] })
        await coordinator.refresh()
        let selected = try XCTUnwrap(coordinator.snapshot.services.first)
        await coordinator.prepare(.unload, service: selected)
        XCTAssertNotNil(coordinator.actionReview)
        observed = server(pid: 20)
        await coordinator.prepare(.stop, service: selected)
        XCTAssertNotNil(coordinator.actionError)
        XCTAssertNil(coordinator.actionReview, "Failed preparation must not leave an older confirmation target exposed")
    }

    func testOccupancyChangeBeforeConfirmationPreventsMutation() async throws {
        let observed = server()
        var allowed = true, mutations = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, readMemory: { _ in [:] })
        coordinator.mayChange = { _ in allowed }
        coordinator.mutate = { _, _ in mutations += 1 }
        await coordinator.refresh()
        await coordinator.prepare(.unload, service: try XCTUnwrap(coordinator.snapshot.services.first))
        allowed = false
        await coordinator.confirm()
        XCTAssertEqual(mutations, 0)
        XCTAssertNotNil(coordinator.actionError)
        XCTAssertNotNil(coordinator.actionReview)
        XCTAssertFalse(coordinator.isChanging)
    }

    func testMutationIdentityRefusalIsReportedWithoutAutomaticRetry() async throws {
        var observed = server()
        var mutations = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, readMemory: { _ in [:] })
        coordinator.mutate = { selected, action in
            mutations += 1
            XCTAssertEqual(action, .stop)
            guard selected.server?.pid == observed.pid else { throw InventoryTestError.changed }
        }
        await coordinator.refresh()
        await coordinator.prepare(.stop, service: try XCTUnwrap(coordinator.snapshot.services.first))
        observed = server(pid: 20)
        await coordinator.confirm()
        await coordinator.refresh()
        XCTAssertEqual(mutations, 1)
        XCTAssertTrue(coordinator.actionError?.contains("identity changed") == true)
        XCTAssertNotNil(coordinator.actionReview)
        XCTAssertEqual(coordinator.snapshot.services.first?.server?.pid, 20)
        XCTAssertFalse(coordinator.isChanging)
    }

    func testSuccessfulMutationClearsReviewAndReadsBackResidency() async throws {
        var observed = server()
        var mutations = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, readMemory: { _ in [:] })
        coordinator.mutate = { selected, action in
            mutations += 1
            XCTAssertEqual(action, .unload)
            XCTAssertEqual(selected.server?.pid, observed.pid)
            observed = self.server(residency: "unloaded")
        }
        await coordinator.refresh()
        await coordinator.prepare(.unload, service: try XCTUnwrap(coordinator.snapshot.services.first))
        await coordinator.confirm()
        XCTAssertEqual(mutations, 1)
        XCTAssertNil(coordinator.actionReview)
        XCTAssertNil(coordinator.actionError)
        XCTAssertEqual(coordinator.snapshot.services.first?.residency, .unloaded)
        XCTAssertFalse(coordinator.isChanging)
    }

    func testSlowHostReadDoesNotDelayEnginePublication() async {
        let hostEntered = expectation(description: "slow host read entered")
        let enginePublished = expectation(description: "engine inventory published before host completes")
        let gate = InventoryTestGate()
        let observed = server()
        let inventory = hostInventory()
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, fetchHosts: { refresh in
                XCTAssertTrue(refresh)
                hostEntered.fulfill()
                await gate.wait()
                return ServingHostSnapshot(inventories: [inventory])
            }, readMemory: { _ in [:] })
        var published = false
        let subscription = coordinator.$snapshot.sink { snapshot in
            if !published, snapshot.services.contains(where: { $0.server?.pid == observed.pid }) {
                published = true; enginePublished.fulfill()
            }
        }
        let refresh = Task { await coordinator.refresh(refreshHosts: true) }
        await fulfillment(of: [hostEntered, enginePublished], timeout: 2)
        XCTAssertTrue(coordinator.isRefreshing)
        XCTAssertEqual(coordinator.snapshot.services.compactMap(\.server).count, 1)
        XCTAssertTrue(coordinator.snapshot.services.compactMap(\.host).isEmpty)
        gate.open()
        await refresh.value
        subscription.cancel()
        XCTAssertEqual(coordinator.snapshot.services.count, 2)
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testMemoryReadsUseOnlyInjectedKnownProcessIDs() async {
        let observed = server(pid: 10)
        let inventory = hostInventory()
        var requestedPIDs: [Int] = []
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts, now: { self.capturedAt },
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) },
            fetchHosts: { _ in ServingHostSnapshot(inventories: [inventory], processIDs: [inventory.host.id: 99]) },
            readMemory: { pids in requestedPIDs = pids.sorted(); return [10: 100, 110: 200, 99: 300] })
        await coordinator.refresh()
        await coordinator.refresh()
        XCTAssertEqual(requestedPIDs, [10, 99, 110])
        XCTAssertEqual(coordinator.processMemory, [10: 100, 110: 200, 99: 300])
        XCTAssertEqual(coordinator.processMemoryCapturedAt, capturedAt)
    }

    func testConcurrentConfirmationDoesNotSendAMutationTwice() async throws {
        let entered = expectation(description: "mutation entered")
        let gate = InventoryTestGate()
        let observed = server()
        var mutations = 0
        let coordinator = ServingInventoryCoordinator(managedReceipts: managedReceipts,
            fetchEngine: { ServingEngineSnapshot(servers: [observed]) }, readMemory: { _ in [:] })
        coordinator.mutate = { _, _ in mutations += 1; entered.fulfill(); await gate.wait() }
        await coordinator.refresh()
        await coordinator.prepare(.unload, service: try XCTUnwrap(coordinator.snapshot.services.first))
        let first = Task { await coordinator.confirm() }
        await fulfillment(of: [entered], timeout: 2)
        await coordinator.confirm()
        coordinator.cancelReview()
        XCTAssertNotNil(coordinator.actionReview)
        XCTAssertTrue(coordinator.isChanging)
        gate.open()
        await first.value
        XCTAssertEqual(mutations, 1)
        XCTAssertNil(coordinator.actionReview)
        XCTAssertFalse(coordinator.isChanging)
    }
}

@MainActor
private final class InventoryTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private enum InventoryTestError: LocalizedError {
    case unavailable, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Inventory source unavailable"
        case .changed: "Serving process identity changed"
        }
    }
}
