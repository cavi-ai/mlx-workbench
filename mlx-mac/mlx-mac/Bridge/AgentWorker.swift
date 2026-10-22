import Darwin
import Foundation
import os

final class AgentWorker: Sendable {
    static let shared = AgentWorker()

    struct Reply: Sendable {
        let stdout: Data
        let stderr: Data
    }

    static func handles(_ argv: [String]) -> Bool { Array(argv.prefix(2)) == ["serve", "status"] }

    private struct Running: Sendable {
        let key: String
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let group: AgentProcessGroup
        let registry: CLIProcessRegistry
        var buffer = Data()
    }

    private struct State: Sendable {
        var running: Running?
        var unavailable: Set<String> = []
    }

    private static let replyTimeout: TimeInterval = 30
    private static let readyTimeout: TimeInterval = 15

    private let script: URL?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let invocation = DispatchSemaphore(value: 1)

    init(script: URL? = Bundle.main.url(forResource: "agent-worker", withExtension: "py")) {
        self.script = script
    }

    var processIdentifier: pid_t? {
        state.withLock { $0.running?.process.processIdentifier }
    }

    func run(python: URL, agentRoot: URL, argv: [String], environment: [String: String],
             deadline: TimeInterval, cancellation: CLIInvocationCancellation?, registry: CLIProcessRegistry) throws -> Reply? {
        guard let script else { return nil }
        let key = python.path + "\n" + agentRoot.standardizedFileURL.path
        try acquire(deadline: deadline, cancellation: cancellation)
        defer { invocation.signal() }
        guard !state.withLock({ $0.unavailable.contains(key) }) else { return nil }
        if state.withLock({ $0.running?.key }) != key { stopRunning() }
        if state.withLock({ $0.running == nil }) {
            guard let started = try Self.start(script: script, python: python, agentRoot: agentRoot, key: key,
                environment: environment, deadline: deadline, cancellation: cancellation, registry: registry) else {
                state.withLock { _ = $0.unavailable.insert(key) }
                return nil
            }
            state.withLock { $0.running = started }
        }
        do {
            guard var current = state.withLock({ $0.running }),
                  let request = try? JSONSerialization.data(withJSONObject: ["argv": argv]),
                  try Self.write(request + Data([0x0A]), to: current.input, deadline: deadline, cancellation: cancellation),
                  let line = try Self.readLine(current.output, buffer: &current.buffer,
                      deadline: min(deadline, ProcessInfo.processInfo.systemUptime + Self.replyTimeout), cancellation: cancellation),
                  let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let stdout = reply["stdout"] as? String, let stderr = reply["stderr"] as? String else {
                stopRunning()
                return nil
            }
            try Self.check(deadline: deadline, cancellation: cancellation)
            state.withLock { $0.running = current }
            return Reply(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        } catch {
            stopRunning()
            throw error
        }
    }

    func stop() {
        invocation.wait()
        defer { invocation.signal() }
        stopRunning()
    }

    private func acquire(deadline: TimeInterval, cancellation: CLIInvocationCancellation?) throws {
        while true {
            try Self.check(deadline: deadline, cancellation: cancellation)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if invocation.wait(timeout: .now() + min(remaining, 0.05)) == .success {
                do { try Self.check(deadline: deadline, cancellation: cancellation) }
                catch { invocation.signal(); throw error }
                return
            }
        }
    }

    private static func check(deadline: TimeInterval, cancellation: CLIInvocationCancellation?) throws {
        if cancellation?.isRequested == true { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeError.skillTimeout }
    }

    /// The invocation lease owns pipe I/O; the state lock only protects short snapshots.
    private func stopRunning() {
        let current = state.withLock { state -> Running? in
            defer { state.running = nil }
            return state.running
        }
        guard let current else { return }
        try? current.input.close()
        AgentProcessGroup.stop([current.group], grace: CLIProcess.terminationGrace)
        current.registry.unregister(current.group)
        try? current.output.close()
    }

    private static func start(script: URL, python: URL, agentRoot: URL, key: String,
                              environment: [String: String], deadline: TimeInterval,
                              cancellation: CLIInvocationCancellation?, registry: CLIProcessRegistry) throws -> Running? {
        try check(deadline: deadline, cancellation: cancellation)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, agentRoot.path]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let group = AgentProcessGroup(pid: process.processIdentifier)
        guard registry.register(group) else {
            AgentProcessGroup.stop([group], grace: CLIProcess.terminationGrace)
            return nil
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let flags = fcntl(input.fileHandleForWriting.fileDescriptor, F_GETFL)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        var started = Running(key: key, process: process, input: input.fileHandleForWriting,
                              output: output.fileHandleForReading, group: group, registry: registry)
        var accepted = false
        defer {
            if !accepted {
                try? started.input.close()
                AgentProcessGroup.stop([group], grace: CLIProcess.terminationGrace)
                registry.unregister(group)
                try? started.output.close()
            }
        }
        guard let line = try readLine(started.output, buffer: &started.buffer,
            deadline: min(deadline, ProcessInfo.processInfo.systemUptime + readyTimeout), cancellation: cancellation),
            (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["ready"] as? Bool == true else { return nil }
        accepted = true
        return started
    }

    private static func write(_ data: Data, to handle: FileHandle, deadline: TimeInterval,
                              cancellation: CLIInvocationCancellation?) throws -> Bool {
        let descriptor = handle.fileDescriptor
        return try data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                try check(deadline: deadline, cancellation: cancellation)
                var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&request, 1, 50)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                if written == 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private static func readLine(_ handle: FileHandle, buffer: inout Data, deadline: TimeInterval,
                                 cancellation: CLIInvocationCancellation?) throws -> Data? {
        let descriptor = handle.fileDescriptor
        let limit = CLIProcess.maxOutputBytes * 4
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try check(deadline: deadline, cancellation: cancellation)
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard buffer.count < limit else { return nil }
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, Int32(max(0, min(remaining, 0.05)) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
