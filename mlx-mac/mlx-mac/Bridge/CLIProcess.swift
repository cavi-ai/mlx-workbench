import Foundation

// MARK: - CLIProcess
//
// Runs the vendored (or configured) mlx-agent CLI with --json and returns the
// unwrapped `data` payload. Throws a classified BridgeError on any failure,
// mirroring mlx_workbench/bridge.py.

struct CLIProcess {
    private let cliRelative = "scripts/mlx-agent"
    private let defaultTimeout: TimeInterval = 300
    private let scoutTimeout: TimeInterval = 600
    static let maxOutputBytes = 8 * 1024 * 1024

    private var python: String {
        ProcessInfo.processInfo.environment["MLX_WORKBENCH_PYTHON"]
            ?? ProcessInfo.processInfo.environment["PYTHON"]
            ?? "python3"
    }

    /// Absolute path to `python` (resolves via PATH). Process.executableURL
    /// requires an absolute path; a bare "python3" would throw at launch.
    private func pythonExecutable() throws -> URL {
        let candidate = Self.normalizePath(python)
        if candidate.isEmpty {
            throw BridgeError.skillUnavailable
        }
        if candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in envPath.split(separator: ":") {
            let full = URL(fileURLWithPath: String(dir)).appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: full.path) {
                return full
            }
        }
        throw BridgeError.skillUnavailable
    }

    private static func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("~") {
            return NSString(string: trimmed).expandingTildeInPath
        }
        return trimmed
    }

    private func expandedURL(_ path: String) -> URL {
        if path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: path)
    }

    func cliScript(agentPath: String) throws -> URL {
        let normalizedPath = Self.normalizePath(agentPath)
        guard !normalizedPath.isEmpty else {
            throw BridgeError.agentNotConfigured
        }
        let root = expandedURL(normalizedPath)
        let script = root.appendingPathComponent("scripts/mlx-agent")
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: script.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: script.path) else {
            throw BridgeError.agentNotFound
        }
        return script
    }

    func agentHealth(agentPath: String) -> (ok: Bool, path: String, cli: String, message: String) {
        let normalizedPath = Self.normalizePath(agentPath)
        guard !normalizedPath.isEmpty else {
            return (false, "", "", "No mlx-agent checkout configured.")
        }
        let root = expandedURL(normalizedPath)
        let script = root.appendingPathComponent("scripts/mlx-agent")
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: script.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return (false, root.path, script.path, "scripts/mlx-agent is missing (init the vendor submodule?).")
        }
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            return (false, root.path, script.path, "scripts/mlx-agent is not readable.")
        }
        return (true, root.path, script.path, "mlx-agent CLI ready.")
    }

    // MARK: - Execution

    /// Run one mlx-agent subcommand and return its unwrapped `data` payload.
    func run(agentPath: String, argv: [String], isScout: Bool = false,
             timeout: TimeInterval? = nil) throws -> [String: Any] {
        let script = try cliScript(agentPath: agentPath)
        let time = timeout ?? (isScout ? scoutTimeout : defaultTimeout)
        let pythonURL = try pythonExecutable()

        var command = [pythonURL.path, script.path]
        command.append(contentsOf: argv.map { String($0) })
        if !command.contains("--json") {
            command.append("--json")
        }

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = Array(command[1...])
        // The agent resolves sibling executables (e.g. mlx_lm.convert) via
        // PATH; put the running interpreter's directory first so a uv-tool
        // or Homebrew install of a different version cannot shadow it.
        var environment = ProcessInfo.processInfo.environment
        let pythonDirectory = pythonURL.deletingLastPathComponent().path
        environment["PATH"] = pythonDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchGroup()
        var launchError: Error?
        var stdoutCapture: (data: Data, tooLarge: Bool)?
        var stderrCapture: (data: Data, tooLarge: Bool)?

        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCapture = Self.collect(handle: stdout.fileHandleForReading, cap: Self.maxOutputBytes)
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrCapture = Self.collect(handle: stderr.fileHandleForReading, cap: Self.maxOutputBytes)
            drained.leave()
        }

        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            // No child was spawned; the pipes never reach EOF, so close the
            // read handles to unblock the drain threads before waiting.
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            launchError = error
            exited.signal()
        }

        let result = exited.wait(timeout: .now() + time)
        if result == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            _ = drained.wait(timeout: .now() + 5)
            throw BridgeError.skillTimeout
        }

        drained.wait()

        guard let stdoutCapture else { throw BridgeError.skillOutputTooLarge }
        guard let stderrCapture else { throw BridgeError.skillOutputTooLarge }
        let stdoutData = stdoutCapture.data
        let outputTooLarge = stdoutCapture.tooLarge
        let stderrData = stderrCapture.data

        if launchError != nil {
            throw BridgeError.skillUnavailable
        }

        if outputTooLarge {
            throw BridgeError.skillOutputTooLarge
        }

        let stderrText = String(decoding: stderrData, as: UTF8.self)
        let envelope = parseEnvelope(stdoutData, stderr: stderrText)
        return try unwrap(envelope)
    }

    /// Drain a pipe until EOF with a hard byte cap so oversized output cannot
    /// balloon memory or hang the drain.
    private static func collect(handle: FileHandle, cap: Int) -> (Data, Bool) {
        var data = Data()
        while data.count < cap {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        let tooLarge = data.count >= cap
        if tooLarge {
            data = data.prefix(cap)
        }
        return (data, tooLarge)
    }

    private func parseEnvelope(_ data: Data, stderr: String) -> [String: Any] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["status": "error", "error": [
                "code": "skill_output_unreadable",
                "message": detail.isEmpty ? "The agent did not return JSON." : String(detail.prefix(400)),
                "remediation": "Run the same command by hand in the mlx-agent checkout to see the failure.",
            ]]
        }
        return object
    }

    private func unwrap(_ envelope: [String: Any]) throws -> [String: Any] {
        guard let status = envelope["status"] as? String else {
            throw BridgeError.skillOutputUnreadable
        }
        if status == "ok" {
            return (envelope["data"] as? [String: Any]) ?? [:]
        }
        if let error = envelope["error"] as? [String: Any] {
            throw BridgeError.remote(
                code: error["code"] as? String ?? "skill_failed",
                message: error["message"] as? String ?? "The agent reported an error.",
                remediation: error["remediation"] as? String ?? "Inspect the agent output and retry."
            )
        }
        throw BridgeError.skillFailed
    }
}
