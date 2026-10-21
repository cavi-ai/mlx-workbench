import Combine
import Foundation

enum DiscoveryState: Equatable {
    case notRun
    case running
    case completed([DiscoverCandidate])
    case failed(String)
    case stopped

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var candidates: [DiscoverCandidate] {
        if case .completed(let candidates) = self { return candidates }
        return []
    }
    var symbol: String {
        switch self {
        case .notRun, .running: return "magnifyingglass"
        case .completed: return "line.3.horizontal.decrease.circle"
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        }
    }
    var message: String {
        switch self {
        case .notRun: return "Discover models for this Mac. Choose a role, then select Discover."
        case .running: return "Discovering models…"
        case .completed: return "No candidates matched. Try another role or adjust the limit, then Discover again."
        case .failed(let message): return "Discovery failed. \(message) Try Discover again after resolving the issue."
        case .stopped: return "Discovery stopped. Select Discover to search again."
        }
    }
}

struct DiscoveryRequest: Equatable {
    let role: String?
    let limit: Int
    let fast: Bool

    init(role: String, limit: Int, fast: Bool) {
        self.role = role.isEmpty ? nil : role
        self.limit = DiscoverLimit.clamped(limit)
        self.fast = fast
    }
}

struct DiscoverySnapshot {
    let candidates: [DiscoverCandidate]
    let request: DiscoveryRequest?
}

/// Owns one discovery invocation. Stopping keeps the lane busy until its process exits.
@MainActor
final class DiscoverySession: ObservableObject {
    @Published private(set) var state: DiscoveryState
    @Published private(set) var result: DiscoverySnapshot?
    @Published private(set) var request: DiscoveryRequest?
    @Published private(set) var isStopping = false
    @Published private(set) var resultToken = 0
    private var task: Task<Void, Never>?
    private let fetch: (DiscoveryRequest) async throws -> [DiscoverCandidate]

    init(initialState: DiscoveryState = .notRun,
         fetch: @escaping (DiscoveryRequest) async throws -> [DiscoverCandidate]) {
        state = initialState
        if case .completed(let candidates) = initialState {
            result = DiscoverySnapshot(candidates: candidates, request: nil)
        }
        self.fetch = fetch
    }

    func start(_ request: DiscoveryRequest) {
        guard !state.isRunning else { return }
        self.request = request
        state = .running
        isStopping = false
        task = Task {
            defer { task = nil; isStopping = false }
            do {
                let candidates = try await fetch(request)
                try Task.checkCancellation()
                result = DiscoverySnapshot(candidates: candidates, request: request)
                resultToken += 1
                state = .completed(candidates)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    state = .stopped
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        guard state.isRunning, !isStopping, let task else { return }
        isStopping = true
        task.cancel()
    }

    func clear() {
        guard !state.isRunning else { return }
        result = nil
        request = nil
        state = .notRun
    }
}
