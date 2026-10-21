import Foundation

/// Blocking filesystem and process work does not occupy the UI or Swift's cooperative pool.
enum WorkbenchIO {
    static func perform<Value>(on queue: DispatchQueue = .global(qos: .utility), _ operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
