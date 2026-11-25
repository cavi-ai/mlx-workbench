import XCTest
@testable import mlx_workbench

@MainActor
final class LiveStateClockTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Time {
        var elapsed: TimeInterval = 0
        let origin = Date(timeIntervalSince1970: 1_000)
        var date: Date { origin.addingTimeInterval(elapsed) }
    }

    private struct Harness {
        let clock: LiveStateClock
        let fetches: Counter
        let consumerReads: Counter
    }

    /// Virtual time: each sleep advances the clock and stops the loop once `limit` seconds have passed.
    private func harness(visible: Bool, limit: TimeInterval, consumers: Int = 4) -> Harness {
        let fetches = Counter()
        let reads = Counter()
        let time = Time()
        let clock = LiveStateClock(
            fetch: { fetches.bump(); return ServingEngineSnapshot(servers: []) },
            sleep: { delay in
                time.elapsed += Double(delay.components.seconds)
                if time.elapsed >= limit { throw CancellationError() }
            },
            isVisible: { visible },
            now: { time.date })
        for _ in 0..<consumers {
            clock.addConsumer { [clock] in _ = try? await clock.snapshot(); reads.bump() }
        }
        return Harness(clock: clock, fetches: fetches, consumerReads: reads)
    }

    private func runLoop(_ clock: LiveStateClock) async {
        await clock.start().value
    }

    func testVisibleMinuteSendsSixFetchesForFourConsumers() async {
        let h = harness(visible: true, limit: 60)
        await runLoop(h.clock)
        XCTAssertEqual(h.fetches.count, 6)
        XCTAssertEqual(h.consumerReads.count, 24)
    }

    func testOccludedMinuteSendsOneFetch() async {
        let h = harness(visible: false, limit: 60)
        await runLoop(h.clock)
        XCTAssertEqual(h.fetches.count, 1)
    }

    func testSecondOnAppearRefreshWithinOneTickSendsNoFetch() async throws {
        let h = harness(visible: true, limit: 0)
        _ = try await h.clock.snapshot()
        _ = try await h.clock.snapshot()
        await h.clock.activate()
        XCTAssertEqual(h.fetches.count, 1)
    }

    private actor Gate {
        private var open = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    func testForcedTickDuringFetchDeliversANewerFetchToConsumers() async throws {
        let fetches = Counter()
        let gate = Gate()
        let seen = Seen()
        let clock = LiveStateClock(
            fetch: {
                fetches.bump()
                let number = fetches.count
                if number == 1 { await gate.wait() }
                return ServingEngineSnapshot(servers: [], errors: ["fetch": "\(number)"])
            },
            sleep: { _ in throw CancellationError() },
            isVisible: { true })
        clock.addConsumer { [clock] in seen.add((try? await clock.snapshot())?.errors["fetch"] ?? "none") }
        let first = Task { try await clock.snapshot() }
        await waitUntil("the first fetch to start") { fetches.count >= 1 }
        let forced = Task { await clock.tickNow() }
        for _ in 0..<200 { await Task.yield() }
        await gate.release()
        _ = try await first.value
        await forced.value
        XCTAssertEqual(fetches.count, 2)
        XCTAssertEqual(seen.values, ["2"])
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testHiddenToVisibleTicksWithinTheVisibleCadence() async throws {
        let fetches = Counter()
        let visible = VisibilityBox()
        let sleeps = Seen()
        let clock = LiveStateClock(
            fetch: { fetches.bump(); return ServingEngineSnapshot(servers: []) },
            sleep: { delay in
                sleeps.add("\(delay.components.seconds)")
                try await Task.sleep(for: .seconds(3600))
            },
            isVisible: { visible.value })
        let loop = clock.start()
        await waitUntil("the first sleep") { sleeps.values.count >= 1 }
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(sleeps.values, ["60"])
        visible.value = true
        clock.visibilityChanged()
        await waitUntil("the second sleep") { sleeps.values.count >= 2 }
        XCTAssertEqual(fetches.count, 2)
        XCTAssertEqual(sleeps.values, ["60", "10"])
        visible.value = false
        clock.visibilityChanged()
        await waitUntil("the third sleep") { sleeps.values.count >= 3 }
        XCTAssertEqual(fetches.count, 2)
        XCTAssertEqual(sleeps.values, ["60", "10", "60"])
        clock.stop()
        await loop.value
    }

    func testFreshRefetchesWhileTheSnapshotIsYoung() async throws {
        let fetches = Counter()
        let clock = LiveStateClock(fetch: { fetches.bump(); return ServingEngineSnapshot(servers: []) },
            sleep: { _ in throw CancellationError() }, isVisible: { true })
        _ = try await clock.snapshot()
        _ = try await clock.snapshot()
        _ = try await clock.fresh()
        XCTAssertEqual(fetches.count, 2)
    }

    func testServersRefuseAPartialInventory() async {
        let clock = LiveStateClock(
            fetch: { ServingEngineSnapshot(servers: [], errors: ["engine:lmstudio": "unreachable"]) },
            sleep: { _ in throw CancellationError() }, isVisible: { true })
        do {
            _ = try await clock.servers()
            XCTFail("a partial inventory must not be used for reconcile")
        } catch {
            XCTAssertTrue(error is LiveStateClockError)
        }
    }

    private final class VisibilityBox: @unchecked Sendable { var value = false }

    /// Yields until `condition` holds; fails with `message` after `timeout` seconds instead of hanging.
    private func waitUntil(_ message: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for \(message)")
                return
            }
            await Task.yield()
        }
    }
}
