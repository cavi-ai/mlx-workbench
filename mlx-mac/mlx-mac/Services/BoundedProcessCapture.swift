import Foundation

/// Structured command output. Call only from a blocking I/O worker.
/// Both pipes drain independently; ownership lasts through process exit and EOF.
enum BoundedProcessCapture {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    enum Failure: LocalizedError {
        case timedOut, outputTooLarge, shutdownIncomplete
        var errorDescription: String? {
            switch self {
            case .timedOut: return "The command exceeded its time limit."
            case .outputTooLarge: return "The command returned too much output."
            case .shutdownIncomplete: return "Command shutdown did not finish."
            }
        }
    }

    static func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval, outputLimit: Int = 8 * 1024 * 1024,
                    cancellation: CLIInvocationCancellation = CLIInvocationCancellation(),
                    registry: CLIProcessRegistry = .shared) throws -> Output {
        if cancellation.isRequested { throw CancellationError() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let exited = DispatchSemaphore(value: 0), drained = DispatchGroup()
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let group = AgentProcessGroup(pid: process.processIdentifier)
        if !registry.register(group) { cancellation.cancel() }
        defer { if !group.isAlive { registry.unregister(group) } }
        let captured = Capture(limit: max(0, outputLimit))
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            drained.enter()
            Thread.detachNewThread {
                defer { try? pipe.fileHandleForReading.close(); drained.leave() }
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    guard !data.isEmpty else { return }
                    captured.append(data, isError: isError)
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var didExit = false
        while true {
            let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            if cancellation.isRequested || timedOut || captured.overflow {
                AgentProcessGroup.stop([group], grace: 0.2)
                let shutdown = ProcessInfo.processInfo.systemUptime + 5
                repeat {
                    if !didExit { didExit = exited.wait(timeout: .now() + 0.02) == .success }
                    if didExit && drained.wait(timeout: .now()) == .success && !group.isAlive {
                        if cancellation.isRequested { throw CancellationError() }
                        throw captured.overflow ? Failure.outputTooLarge : Failure.timedOut
                    }
                    usleep(20_000)
                } while ProcessInfo.processInfo.systemUptime < shutdown
                throw Failure.shutdownIncomplete
            }
            if !didExit { didExit = exited.wait(timeout: .now() + 0.02) == .success }
            if didExit && drained.wait(timeout: .now()) == .success && !group.isAlive { break }
            usleep(20_000)
        }
        if cancellation.isRequested { throw CancellationError() }
        if captured.overflow { throw Failure.outputTooLarge }
        return captured.output(status: process.terminationStatus)
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var stdout = Data(), stderr = Data()
        private var exceeded = false
        init(limit: Int) { self.limit = limit }
        var overflow: Bool { lock.withLock { exceeded } }
        func append(_ data: Data, isError: Bool) {
            lock.withLock {
                if isError {
                    stderr.append(data)
                    if stderr.count > 64 * 1024 { stderr.removeFirst(stderr.count - 64 * 1024) }
                } else {
                    let remaining = limit - stdout.count
                    if data.count > remaining { exceeded = true }
                    stdout.append(data.prefix(remaining))
                }
            }
        }
        func output(status: Int32) -> Output {
            lock.withLock { Output(stdout: String(decoding: stdout, as: UTF8.self),
                                   stderr: String(decoding: stderr, as: UTF8.self), status: status) }
        }
    }
}
