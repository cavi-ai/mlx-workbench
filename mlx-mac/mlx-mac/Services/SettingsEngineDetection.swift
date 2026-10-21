import Combine
import Foundation

/// Read-only discovery for the Settings draft. Only Save changes the configured engine.
@MainActor
final class SettingsEngineDetection: ObservableObject {
    enum State: Equatable {
        case idle, searching
        case found(path: String)
        case notFound(path: String)
        case failed(path: String, message: String)

        var path: String? {
            switch self {
            case .found(let path), .notFound(let path), .failed(let path, _): return path
            case .idle, .searching: return nil
            }
        }
    }

    @Published private(set) var state: State = .idle
    private let discover: @Sendable () async throws -> String
    private var generation: UUID?
    var isDetecting: Bool { state == .searching }

    init(discover: @escaping @Sendable () async throws -> String = {
        try await Task.detached(priority: .userInitiated) {
            let checkout = Config.discoverAgentPath()
            if !checkout.isEmpty { return checkout }
            return try BundledRuntime.included()?.existingAgentPath() ?? ""
        }.value
    }) {
        self.discover = discover
    }

    func detect(currentPath: String) async -> String? {
        guard !isDetecting else { return nil }
        let token = UUID()
        generation = token
        state = .searching
        do {
            let found = try await discover().trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == token else { return nil }
            guard !Task.isCancelled else { cancel(); return nil }
            generation = nil
            state = found.isEmpty ? .notFound(path: currentPath) : .found(path: found)
            return found.isEmpty ? currentPath : found
        } catch {
            guard generation == token else { return nil }
            guard !Task.isCancelled else { cancel(); return nil }
            generation = nil
            state = .failed(path: currentPath, message: error.localizedDescription)
            return currentPath
        }
    }

    func cancel() {
        generation = nil
        state = .idle
    }
}
