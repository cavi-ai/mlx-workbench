import Foundation

/// The editor's transient check. Generation identity fences late responses after
/// edits or dismissal, including adapters that do not promptly observe cancellation.
@MainActor
final class ModelHostConnectionCheck: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var inventory: HostInventory?
    @Published private(set) var errorMessage: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    @discardableResult
    func check(_ operation: @escaping () async throws -> HostInventory) -> Task<Void, Never>? {
        guard !isChecking else { return nil }
        invalidate()
        let generation = generation
        isChecking = true
        let task = Task {
            defer {
                if self.generation == generation { self.isChecking = false; self.task = nil }
            }
            do {
                let result = try await operation()
                guard !Task.isCancelled, self.generation == generation else { return }
                inventory = result
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                errorMessage = Self.guidance(for: error)
            }
        }
        self.task = task
        return task
    }

    func invalidate() {
        generation = UUID()
        task?.cancel(); task = nil
        isChecking = false
        inventory = nil
        errorMessage = nil
    }

    /// Never display arbitrary server bodies, credentials or underlying errors.
    static func guidance(for error: Error) -> String {
        switch error {
        case HostHTTPError.httpStatus(401), HostHTTPError.httpStatus(403):
            return "Authentication was refused. Check the API token and the server's access settings."
        case HostHTTPError.httpStatus(404):
            return "The model-list API was not found. Check the provider, server URL and API path."
        case let error as HostHTTPError:
            return error.localizedDescription
        case is CancellationError:
            return "Connection check cancelled. Test again when ready."
        default:
            return "Connection could not be checked. Check the running server and its saved credential, then try again."
        }
    }
}
