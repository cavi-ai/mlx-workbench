import Foundation

// MARK: - GenerationResult

/// One image rendered by `mlx-agent convert generate`.
struct GenerationResult: Codable, Equatable, Sendable {
    let path: String
    let width: Int
    let height: Int
    let steps: Int
    let seed: Int
    let seconds: Double?
    let loadSeconds: Double?
    let pixelStd: Double?

    enum CodingKeys: String, CodingKey {
        case path, width, height, steps, seed, seconds
        case loadSeconds = "load_seconds"
        case pixelStd = "pixel_std"
    }
}

/// What to render: prompt, square size, sampling steps, seed.
struct ImageRequest: Equatable, Sendable {
    var prompt: String
    var size: Int = 1024
    var steps: Int = 40
    var seed: Int = 42

    static let sizes = [512, 768, 1024]
}

// MARK: - ImageGenerationCoordinator
//
// Renders prompts with converted image-generation models through the agent,
// one at a time, into ~/Pictures/MLX Workbench (new files only).

@MainActor
final class ImageGenerationCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case generating(modelPath: String, startedAt: Date)
        case finished(modelPath: String, GenerationResult)
        case failed(modelPath: String, String)
        case cancelled(modelPath: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isCancelling = false
    private var renderTask: Task<GenerationResult, Error>?

    private let render: @Sendable (String, URL, ImageRequest) async throws -> GenerationResult
    private let outputDirectory: () -> URL
    private let now: () -> Date

    init(
        render: @escaping @Sendable (String, URL, ImageRequest) async throws -> GenerationResult,
        outputDirectory: @escaping () -> URL = ImageGenerationCoordinator.defaultOutputDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.render = render
        self.outputDirectory = outputDirectory
        self.now = now
    }

    var isGenerating: Bool {
        if case .generating = state { return true }
        return false
    }

    nonisolated static func defaultOutputDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("MLX Workbench", isDirectory: true)
    }

    /// Each attempt gets an independent destination, including retries in the same second.
    nonisolated static func outputURL(directory: URL, modelPath: String, seed: Int, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = URL(fileURLWithPath: modelPath).lastPathComponent
        return directory.appendingPathComponent("\(name)-\(formatter.string(from: date))-\(UUID().uuidString)-s\(seed).png")
    }

    func cancel(modelPath: String) {
        guard case .generating(let path, _) = state, path == modelPath,
              let renderTask, !isCancelling else { return }
        isCancelling = true
        renderTask.cancel()
    }

    func generate(modelPath: String, request: ImageRequest) async {
        guard !isGenerating else { return }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            state = .failed(modelPath: modelPath, "Describe the image to generate.")
            return
        }
        var trimmed = request
        trimmed.prompt = prompt
        do {
            try Task.checkCancellation()
            let directory = outputDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let started = now()
            let out = Self.outputURL(directory: directory, modelPath: modelPath, seed: request.seed, date: started)
            state = .generating(modelPath: modelPath, startedAt: started)
            let render = self.render
            let request = trimmed
            let task = Task {
                try Task.checkCancellation()
                return try await render(modelPath, out, request)
            }
            renderTask = task
            defer { renderTask = nil; isCancelling = false }
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard !task.isCancelled else { throw CancellationError() }
                state = .finished(modelPath: modelPath, result)
            } catch {
                state = error is CancellationError || task.isCancelled || Task.isCancelled
                    ? .cancelled(modelPath: modelPath) : .failed(modelPath: modelPath, AppHost.render(error))
            }
        } catch {
            state = error is CancellationError ? .cancelled(modelPath: modelPath) : .failed(modelPath: modelPath, AppHost.render(error))
        }
    }
}
