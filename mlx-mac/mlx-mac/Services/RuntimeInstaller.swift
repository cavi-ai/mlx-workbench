import Foundation

// MARK: - RuntimeInstaller
//
// Guided runtime setup ("click a button, it handles it"): runs the repo's
// `make install` — submodule check + .venv (Python 3.12) + convert/serve
// packages — with a live log tail. Only available when a checkout is known
// (WorkbenchPython.repoRoot(): the build checkout, or the checkout holding the
// configured agent path); otherwise the manual hint stays.

@MainActor
final class RuntimeInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case running, stopping, checking, cancelled
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Last lines of installer output, newest last. Capped so a long pip
    /// scroll can't grow memory unboundedly.
    @Published private(set) var logTail: [String] = []
    @Published private(set) var runtimeReport: RuntimeReport?
    @Published private(set) var stage = ""
    @Published private(set) var recoveryBlocked = false
    private let rootProvider: () -> URL?
    private let checkRuntime: (() async -> RuntimeReport)?
    private var cancellation: CLIInvocationCancellation?

    init(repoRoot: @escaping () -> URL? = { WorkbenchPython.repoRoot() },
         checkRuntime: (() async -> RuntimeReport)? = nil) {
        rootProvider = repoRoot
        self.checkRuntime = checkRuntime
    }

    private static let maxTailLines = 200

    /// The repo checkout the installer would operate on, if discoverable.
    var repoRoot: URL? { rootProvider() }

    var isBusy: Bool { state == .running || state == .stopping || state == .checking }
    var canCancel: Bool { state == .running }

    var canInstall: Bool {
        repoRoot != nil && checkRuntime != nil && !isBusy && !recoveryBlocked
    }

    var summary: String {
        switch state {
        case .idle: return "Not started"
        case .running: return stage
        case .stopping: return "Stopping installer…"
        case .checking: return "Checking base tools…"
        case .cancelled: return "Installation cancelled"
        case .succeeded: return "Install command finished"
        case .failed(let reason): return "Install failed: \(reason)"
        }
    }

    var readinessSummary: String? {
        runtimeReport.map {
            SetupReadiness(agentReady: true, convertReady: $0.convert.ok, serveReady: $0.serve.ok).runtimeMessage
        }
    }

    var recoveryMessage: String? {
        if recoveryBlocked {
            return "Installer shutdown could not be confirmed. Retry is disabled. Close Workbench and inspect the install log before repairing the environment."
        }
        switch state {
        case .cancelled, .failed:
            return "The environment may be partially installed. Review the tool checks and install log before retrying."
        case .succeeded where runtimeReport?.ok == false:
            return "The install command finished, but base tools still need setup. Review the tool checks and install log before retrying."
        default: return nil
        }
    }

    func cancel() {
        guard canCancel else { return }
        state = .stopping
        cancellation?.cancel()
    }

    func install(labAgentPath: String? = nil, inference: Bool = false) async {
        guard canInstall, let repoRoot, let checkRuntime else { return }
        let token = CLIInvocationCancellation()
        cancellation = token
        state = .running
        stage = "Preparing installation…"
        runtimeReport = nil
        logTail = []

        // Bound delivery and drain it before publishing the attempt's result.
        let (lines, delivery) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(Self.maxTailLines))
        let consumer = Task {
            for await line in lines {
                logTail.append(line)
                if logTail.count > Self.maxTailLines {
                    logTail.removeFirst(logTail.count - Self.maxTailLines)
                }
            }
        }
        let outcome: State
        do {
            let executable: URL
            let arguments: [String]
            if let labAgentPath {
                guard let python = WorkbenchPython.preferredExecutable(repoRoot: repoRoot) else {
                    throw BridgeError.skillUnavailable
                }
                let requirements = URL(fileURLWithPath: labAgentPath).appendingPathComponent(
                    inference ? "requirements-lab-inference.txt" : "requirements-lab.txt")
                guard FileManager.default.fileExists(atPath: requirements.path) else {
                    throw BridgeError.skillOutputUnreadable
                }
                executable = python
                arguments = ["-m", "pip", "install", "-r", requirements.path]
                stage = inference ? "Installing video runtime…" : "Installing study tools…"
            } else {
                executable = URL(fileURLWithPath: "/usr/bin/make")
                arguments = ["install"]
                stage = "Installing base tools…"
            }
            try await Self.runInstall(repoRoot: repoRoot, executable: executable, arguments: arguments,
                cancellation: token, onLine: { delivery.yield($0) })
            outcome = .succeeded
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            if case InstallError.shutdownIncomplete = error { recoveryBlocked = true }
            outcome = .failed(AppHost.render(error))
        }
        delivery.finish()
        await consumer.value
        cancellation = nil
        guard !recoveryBlocked else { state = outcome; return }
        state = .checking
        runtimeReport = await checkRuntime()
        state = outcome
    }

    /// Runs `make install` in the repo root, streaming combined output
    /// line-by-line. Throws on non-zero exit with the last lines as context.
    nonisolated static func runMakeInstall(
        repoRoot: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        try await runInstall(repoRoot: repoRoot, executable: URL(fileURLWithPath: "/usr/bin/make"),
                             arguments: ["install"], onLine: onLine)
    }

    nonisolated static func runInstall(
        repoRoot: URL, executable: URL, arguments: [String],
        cancellation: CLIInvocationCancellation? = nil,
        registry: CLIProcessRegistry = .shared,
        terminationGrace: TimeInterval = CLIProcess.terminationGrace,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let token = cancellation ?? CLIInvocationCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try runOwnedInstall(repoRoot: repoRoot, executable: executable, arguments: arguments,
                            cancellation: token, registry: registry, terminationGrace: terminationGrace, onLine: onLine)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// One worker owns launch, group shutdown, exit and EOF. The registry keeps
    /// ownership through app termination, including an incomplete shutdown.
    nonisolated private static func runOwnedInstall(
        repoRoot: URL, executable: URL, arguments: [String],
        cancellation: CLIInvocationCancellation, registry: CLIProcessRegistry,
        terminationGrace: TimeInterval, onLine: @escaping @Sendable (String) -> Void
    ) throws {
        if cancellation.isRequested { throw CancellationError() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw error
        }
        let group = AgentProcessGroup(pid: process.processIdentifier)
        if !registry.register(group) { cancellation.cancel() }
        defer { if !group.isAlive { registry.unregister(group) } }
        Thread.detachNewThread {
            let buffer = LineBuffer(onLine: onLine)
            while true {
                let data = pipe.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                buffer.append(data)
            }
            buffer.finish()
            drained.signal()
        }
        var didExit = false
        var didDrain = false
        while true {
            if cancellation.isRequested {
                AgentProcessGroup.stop([group], grace: terminationGrace)
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    if !didExit { didExit = exited.wait(timeout: .now() + 0.02) == .success }
                    if !didDrain { didDrain = drained.wait(timeout: .now() + 0.02) == .success }
                    if didExit && didDrain && !group.isAlive { throw CancellationError() }
                    usleep(20_000)
                } while Date() < deadline
                throw InstallError.shutdownIncomplete
            }
            if !didExit { didExit = exited.wait(timeout: .now() + 0.02) == .success }
            if !didDrain { didDrain = drained.wait(timeout: .now() + 0.02) == .success }
            if didExit && process.terminationReason == .uncaughtSignal { cancellation.cancel() }
            if didExit && didDrain && !group.isAlive { break }
            usleep(20_000)
        }
        if cancellation.isRequested { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw InstallError.exited(Int(process.terminationStatus)) }
    }

    enum InstallError: LocalizedError {
        case exited(Int), shutdownIncomplete

        var errorDescription: String? {
            switch self {
            case .exited(let code): return "Runtime installation exited with status \(code)."
            case .shutdownIncomplete: return "Installer shutdown did not finish."
            }
        }
    }

    /// Used only by the reader. Bound partial lines as well as the UI log.
    private final class LineBuffer {
        private var pending = Data()
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) {
            self.onLine = onLine
        }

        func append(_ data: Data) {
            pending.append(data)
            while !pending.isEmpty {
                if let newline = pending.prefix(16 * 1024).firstIndex(of: 0x0A) {
                    emit(pending[..<newline])
                    pending.removeSubrange(...newline)
                } else if pending.count >= 16 * 1024 {
                    emit(pending.prefix(16 * 1024))
                    pending.removeFirst(16 * 1024)
                } else { break }
            }
        }

        func finish() {
            if !pending.isEmpty {
                emit(pending)
            }
            pending.removeAll()
        }

        private func emit(_ data: Data.SubSequence) {
            let line = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            onLine(line)
        }
    }
}
