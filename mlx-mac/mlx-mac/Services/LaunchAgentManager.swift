import Foundation

// MARK: - LaunchAgentManager
//
// Boot persistence for the always-on endpoint (premium spec 06, phase 2).
// The LaunchAgent runs `mlx-agent serve start` once at login
// (RunAtLoad, no KeepAlive): launchd provides boot persistence, the in-app
// EndpointSupervisor provides runtime reconciliation, and mlx-agent receipts
// stay the process authority. `serve start` supervises its own detached
// server, so a KeepAlive loop would fight it — deliberately avoided.
//
// The plist is generated, shown to the user, and only installed after
// confirmation — the same preview/confirm grammar as everything else.

enum LaunchAgentError: LocalizedError {
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let detail): return "launchctl failed: \(detail)"
        }
    }
}

struct LaunchAgentManager: Sendable {
    static let label = "ai.cavi.mlxworkbench.endpoint"

    let home: URL
    /// Injected process runner (executable, argv) → stdout. Throws on
    /// non-zero exit. Production default runs `/bin/launchctl` — argv tokens,
    /// never a shell string.
    let run: @Sendable (_ executable: String, _ argv: [String]) throws -> String
    let uid: UInt32

    init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        run: @escaping @Sendable (String, [String]) throws -> String = LaunchAgentManager.launchctl,
        uid: UInt32 = getuid()
    ) {
        self.home = home
        self.run = run
        self.uid = uid
    }

    var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - Preview

    /// The exact plist that would be installed. Shown to the user before
    /// confirmation.
    func plistPreview(config: EndpointConfig, agentPath: String) throws -> String {
        let script = URL(fileURLWithPath: agentPath)
            .appendingPathComponent("scripts/mlx-agent").path
        let logPath = home.appendingPathComponent("Library/Logs/mlx-workbench-endpoint.log").path
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [
                pythonExecutable(),
                script,
                "serve", "start",
                "--repo", config.modelPath,
                "--runtime", "mlx",
                "--port", String(config.port),
            ],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw LaunchAgentError.launchctlFailed("plist serialization produced non-UTF-8 output")
        }
        return text
    }

    // MARK: - Install / remove

    func install(config: EndpointConfig, agentPath: String) throws {
        let plist = try plistPreview(config: config, agentPath: agentPath)
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        // Already bootstrapped agents must be booted out before re-bootstrap.
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        _ = try run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
    }

    func uninstall() throws {
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    // MARK: - Process runner

    private static func launchctl(_ executable: String, _ argv: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw LaunchAgentError.launchctlFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw LaunchAgentError.launchctlFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    private func pythonExecutable() -> String {
        if let python = ProcessInfo.processInfo.environment["MLX_WORKBENCH_PYTHON"]
            ?? ProcessInfo.processInfo.environment["PYTHON"], python.hasPrefix("/") {
            return python
        }
        return "/usr/bin/python3"
    }
}
