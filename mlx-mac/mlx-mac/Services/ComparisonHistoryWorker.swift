import Foundation

/// One serial owner for comparison-history I/O. Store mutations keep their existing lock.
/// Cancellation never abandons an atomic write or a server-ownership receipt.
final class ComparisonHistoryWorker: @unchecked Sendable {
    private let store: JSONStore<ComparisonRun>
    private let queue = DispatchQueue(label: "comparison-history", qos: .utility)
    init(store: JSONStore<ComparisonRun>) { self.store = store }

    func load() async throws -> [ComparisonRun] {
        try await perform { try $0.loadStreaming().sorted { $0.startedAt > $1.startedAt } }
    }
    func upsert(_ run: ComparisonRun) async throws {
        try await perform { try $0.upsertStreaming(run, id: \.id) }
    }
    func record(id: UUID) async throws -> ComparisonRun? {
        try await perform { try $0.findStreaming(id: id, keyPath: \.id) }
    }
    func update(id: UUID, transform: @escaping @Sendable (ComparisonRun) throws -> ComparisonRun?) async throws -> Bool {
        try await perform { try $0.updateStreaming(id: id, keyPath: \.id, transform: transform) }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable (JSONStore<ComparisonRun>) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try operation(store)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
