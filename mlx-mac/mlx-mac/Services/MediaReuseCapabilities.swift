import Foundation

@MainActor
final class MediaReuseCapabilities: ObservableObject {
    @Published private(set) var values: [String: TaskCapabilities] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let api: any InferenceTaskAPI
    private var requestID = UUID()
    init(api: any InferenceTaskAPI) { self.api = api }

    func record(_ capabilities: TaskCapabilities, path: String) {
        requestID = UUID(); isLoading = false; error = nil
        values[path] = capabilities
    }

    func refresh(paths: [String]) async {
        let id = UUID(); requestID = id
        isLoading = true; error = nil
        defer { if requestID == id { isLoading = false } }
        do {
            var results: [String: TaskCapabilities] = [:]
            for path in Set(paths).sorted() {
                try Task.checkCancellation()
                results[path] = try await api.taskMediaCapabilities(modelPath: path)
            }
            guard requestID == id else { return }
            values = results
        } catch {
            guard requestID == id else { return }
            values = [:]
            if !(error is CancellationError) { self.error = AppHost.render(error) }
        }
    }

    func allowsAdaptive(kind: TaskKind, paths: [String]) -> Bool {
        !isLoading && !paths.isEmpty && paths.allSatisfy { values[$0]?.reuseCapability(for: kind, modelPath: $0)?.supportsAdaptive == true }
    }
    func reason(kind: TaskKind, paths: [String]) -> String? {
        if isLoading { return "Checking model settings…" }
        if let error { return error }
        if paths.isEmpty { return "Select models to check reuse support." }
        for path in paths {
            guard let capability = values[path]?.reuseCapability(for: kind, modelPath: path) else {
                return "The engine did not advertise reuse settings for this model. Standard generation remains available."
            }
            if !capability.supportsAdaptive { return capability.unavailableReason ?? "This model does not support adaptive reuse." }
        }
        return nil
    }
}
