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

    init(script: URL? = Bundle.main.url(forResource: "agent-worker", withExtension: "py")) {
        self.script = script
    }

    var processIdentifier: pid_t? {
        state.withLock { $0.running?.process.processIdentifier }
    }

    func run(python: URL, agentRoot: URL, argv: [String], environment: [String: String],
             timeout: TimeInterval, registry: CLIProcessRegistry) -> Reply? {
        guard let script else { return nil }
        let key = python.path + "\n" + agentRoot.standardizedFileURL.path
        return state.withLock { state -> Reply? in
            guard !state.unavailable.contains(key) else { return nil }
            if state.running?.key != key { Self.stop(&state) }
            if state.running == nil {
                guard let started = Self.start(script: script, python: python, agentRoot: agentRoot, key: key,
                                               environment: environment, registry: registry) else {
                    state.unavailable.insert(key)
                    return nil
                }
                state.running = started
            }
            guard var current = state.running,
                  let request = try? JSONSerialization.data(withJSONObject: ["argv": argv]),
                  Self.write(request + Data([0x0A]), to: current.input),
                  let line = Self.readLine(current.output, buffer: &current.buffer,
                                           deadline: Date().addingTimeInterval(min(timeout, Self.replyTimeout))),
                  let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let stdout = reply["stdout"] as? String, let stderr = reply["stderr"] as? String else {
                Self.stop(&state)
                return nil
            }
            state.running = current
            return Reply(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }
    }

    func stop() {
        state.withLock { Self.stop(&$0) }
    }

    private static func stop(_ state: inout State) {
        guard let current = state.running else { return }
        state.running = nil
        try? current.input.close()
        AgentProcessGroup.stop([current.group], grace: CLIProcess.terminationGrace)
        current.registry.unregister(current.group)
        try? current.output.close()
    }

    private static func start(script: URL, python: URL, agentRoot: URL, key: String,
                              environment: [String: String], registry: CLIProcessRegistry) -> Running? {
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
        var started = Running(key: key, process: process, input: input.fileHandleForWriting,
                              output: output.fileHandleForReading, group: group, registry: registry)
        guard let line = readLine(started.output, buffer: &started.buffer, deadline: Date().addingTimeInterval(readyTimeout)),
              (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["ready"] as? Bool == true else {
            try? started.input.close()
            AgentProcessGroup.stop([group], grace: CLIProcess.terminationGrace)
            registry.unregister(group)
            try? started.output.close()
            return nil
        }
        return started
    }

    private static func write(_ data: Data, to handle: FileHandle) -> Bool {
        let descriptor = handle.fileDescriptor
        return data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private static func readLine(_ handle: FileHandle, buffer: inout Data, deadline: Date) -> Data? {
        let descriptor = handle.fileDescriptor
        let limit = CLIProcess.maxOutputBytes * 4
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, buffer.count < limit else { return nil }
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, Int32(min(remaining, 1) * 1000))
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
