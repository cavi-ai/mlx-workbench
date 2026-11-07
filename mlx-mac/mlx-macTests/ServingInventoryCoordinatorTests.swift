import Combine
import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class ServingInventoryCoordinatorTests: XCTestCase {
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
