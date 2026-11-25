import AppKit
import Foundation

enum LiveStateClockError: LocalizedError {
    case partialInventory(String)

    var errorDescription: String? {
        switch self {
        case .partialInventory(let detail): "Serving discovery was incomplete: \(detail)"
        }
    }
}

/// One serving-discovery fetch per tick, shared by every live-state consumer.
/// Ticks every 10 s while a window is visible and every 60 s otherwise.
@MainActor
final class LiveStateClock {
    typealias Consumer = @MainActor () async -> Void
    private typealias Outcome = Result<ServingEngineSnapshot, Error>

    static let visibleInterval = Duration.seconds(10)
    static let hiddenInterval = Duration.seconds(60)

    private let fetch: @Sendable () async throws -> ServingEngineSnapshot
    private let sleep: (Duration) async throws -> Void
    private let isVisible: () -> Bool
    private let now: () -> Date
    private var consumers: [Consumer] = []
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var visibilityWake: Bool?
    private var inFlight: (id: Int, task: Task<Outcome, Never>)?
    private var started = 0
    private var last: (result: Outcome, at: Date)?

    init(fetch: @escaping @Sendable () async throws -> ServingEngineSnapshot,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         isVisible: @escaping () -> Bool = { NSApp.occlusionState.contains(.visible) },
         now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.sleep = sleep
        self.isVisible = isVisible
        self.now = now
    }

    var interval: Duration { isVisible() ? Self.visibleInterval : Self.hiddenInterval }
    var isRunning: Bool { loop != nil }

    /// Runs after every tick's fetch, concurrently; consumers read `snapshot()`.
    func addConsumer(_ consumer: @escaping Consumer) { consumers.append(consumer) }

    /// The latest discovery, reused while younger than one tick.
    func snapshot() async throws -> ServingEngineSnapshot {
        if let last, isFresh(last.at) { return try last.result.get() }
        return try await fetchNow(force: false).get()
    }

    /// The latest discovery's servers; throws when any discovery source reported an error.
    func servers() async throws -> [ServerInfo] {
        let current = try await snapshot()
        if !current.errors.isEmpty {
            throw LiveStateClockError.partialInventory(current.errors.keys.sorted().joined(separator: ", "))
        }
        return current.servers
    }

    /// A fetch that starts after this call, never one already in flight.
    func fresh() async throws -> ServingEngineSnapshot { try await fetchNow(force: true).get() }

    /// Forces a fetch and runs the consumers, after a serving mutation or a route activation.
    func tickNow() async {
        _ = await fetchNow(force: true)
        await notify()
    }

    /// Fetches only when the latest snapshot is older than one tick.
    func activate() async {
        if let last, isFresh(last.at) { return }
        await tickNow()
    }

    /// Interrupts the current sleep: becoming visible ticks now, then both states sleep their own interval.
    func visibilityChanged() {
        visibilityWake = isVisible()
        sleeper?.cancel()
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        if let loop { return loop }
        let task = Task { [weak self] in
            var skipTick = false
            while !Task.isCancelled {
                guard let self else { return }
                if !skipTick { await tickNow() }
                skipTick = false
                visibilityWake = nil
                let delay = interval
                let sleeping = Task { try await self.sleep(delay) }
                sleeper = sleeping
                let outcome = await withTaskCancellationHandler { await sleeping.result } onCancel: { sleeping.cancel() }
                sleeper = nil
                if Task.isCancelled { return }
                if case .failure = outcome {
                    guard let visible = visibilityWake else { return }
                    visibilityWake = nil
                    skipTick = !visible
                }
            }
        }
        loop = task
        return task
    }

    func stop() { loop?.cancel(); loop = nil }

    private func isFresh(_ at: Date) -> Bool {
        now().timeIntervalSince(at) < Double(interval.components.seconds)
    }

    private func fetchNow(force: Bool) async -> Outcome {
        let requested = started
        if let running = inFlight {
            let shared = await running.task.value
            if !force { return shared }
        }
        if let newer = inFlight, newer.id > requested { return await newer.task.value }
        started += 1
        let id = started
        let fetch = self.fetch
        let task = Task<Outcome, Never> { @MainActor [weak self] in
            let outcome: Outcome
            do { outcome = .success(try await fetch()) } catch { outcome = .failure(error) }
            self?.finish(id: id, outcome)
            return outcome
        }
        inFlight = (id, task)
        return await task.value
    }

    private func finish(id: Int, _ outcome: Outcome) {
        last = (outcome, now())
        if inFlight?.id == id { inFlight = nil }
    }

    private func notify() async {
        let current = consumers
        await withTaskGroup(of: Void.self) { group in
            for consumer in current { group.addTask { await consumer() } }
        }
    }
}
