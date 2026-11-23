import Foundation

@MainActor
final class MediaReuseCapabilities: ObservableObject {
    private static let maxConcurrentQueries = 4

    @Published private(set) var values: [String: TaskCapabilities] = [:]
    @Published private(set) var pathErrors: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let api: any InferenceTaskAPI
    private var requestID = UUID()
    init(api: any InferenceTaskAPI) { self.api = api }

    func record(_ capabilities: TaskCapabilities, path: String) {
        requestID = UUID(); isLoading = false; error = nil
        pathErrors.removeValue(forKey: path)
        values[path] = capabilities
    }

    func refresh(paths: [String]) async {
        let id = UUID(); requestID = id
        isLoading = true; error = nil
        defer { if requestID == id { isLoading = false } }

        let uniquePaths = Set(paths).sorted()
        guard !uniquePaths.isEmpty else { return }

        let api = self.api
        var successes: [String: TaskCapabilities] = [:]
        var failures: [(String, Error)] = []

        await withTaskGroup(of: (String, Result<TaskCapabilities, Error>).self) { group in
            var iterator = uniquePaths.makeIterator()
            for _ in 0..<min(Self.maxConcurrentQueries, uniquePaths.count) {
                guard let path = iterator.next() else { break }
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let capabilities = try await api.taskMediaCapabilities(modelPath: path)
                        return (path, .success(capabilities))
                    } catch {
                        return (path, .failure(error))
                    }
                }
            }

            while let (path, outcome) = await group.next() {
                switch outcome {
                case .success(let capabilities):
                    successes[path] = capabilities
                case .failure(let err):
                    failures.append((path, err))
                }
                if !Task.isCancelled, let nextPath = iterator.next() {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let capabilities = try await api.taskMediaCapabilities(modelPath: nextPath)
                            return (nextPath, .success(capabilities))
                        } catch {
                            return (nextPath, .failure(error))
                        }
                    }
                }
            }
        }

        guard requestID == id, !Task.isCancelled else { return }
        for (path, capabilities) in successes {
            values[path] = capabilities
            pathErrors.removeValue(forKey: path)
        }

        let nonCancellationFailures = failures
            .filter { !($0.1 is CancellationError) }
            .sorted { $0.0 < $1.0 }
        for (path, err) in nonCancellationFailures {
            values.removeValue(forKey: path)
            pathErrors[path] = AppHost.render(err)
        }
        if !nonCancellationFailures.isEmpty {
            if nonCancellationFailures.count == 1, let only = nonCancellationFailures.first {
                self.error = AppHost.render(only.1)
            } else {
                self.error = nonCancellationFailures.map { path, err in
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return "\(name): \(AppHost.render(err))"
                }.joined(separator: " ")
            }
        }
    }

    func allowsAdaptive(kind: TaskKind, paths: [String]) -> Bool {
        !isLoading && !paths.isEmpty && paths.allSatisfy { values[$0]?.reuseCapability(for: kind, modelPath: $0)?.supportsAdaptive == true }
    }
    func reason(kind: TaskKind, paths: [String]) -> String? {
        if isLoading { return "Checking model settings…" }
        if paths.isEmpty {
            if let error { return error }
            return "Select models to check reuse support."
        }
        for path in paths {
            if let pathError = pathErrors[path] { return pathError }
        }
        if let error, pathErrors.isEmpty { return error }
        for path in paths {
            guard let capability = values[path]?.reuseCapability(for: kind, modelPath: path) else {
                return "The engine did not advertise reuse settings for this model. Standard generation remains available."
            }
            if !capability.supportsAdaptive { return capability.unavailableReason ?? "This model does not support adaptive reuse." }
        }
        return nil
    }
}
