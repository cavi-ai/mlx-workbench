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

struct LoginItemPlan: Sendable {
    let slot: EndpointSlot
    let fleetURL: URL
    let agentPath: String
    let arguments: [String]
}

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
    /// Interpreter for the login item, resolved for the agent path the same
    /// way CLI runs are (env override → repo .venv → PATH).
    let interpreter: @Sendable (_ agentPath: String) -> URL?

    static let defaultInterpreter: @Sendable (String) -> URL? = { agentPath in
        WorkbenchPython.preferredExecutable(repoRoot: WorkbenchPython.repoRoot(agentPath: agentPath))
    }

    init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        run: @escaping @Sendable (String, [String]) throws -> String = { try LaunchAgentManager.launchctl($0, $1) },
        uid: UInt32 = getuid(),
        interpreter: @escaping @Sendable (String) -> URL? = LaunchAgentManager.defaultInterpreter
    ) {
        self.home = home
        self.run = run
        self.uid = uid
        self.interpreter = interpreter
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
    func plistPreview(plan: LoginItemPlan) throws -> String {
        let script = URL(fileURLWithPath: plan.agentPath)
            .appendingPathComponent("scripts/mlx-agent").path
        let expected = String(decoding: try JSONEncoder().encode(plan.slot), as: UTF8.self)
        let python = pythonExecutable(agentPath: plan.agentPath)
        let logPath = home.appendingPathComponent("Library/Logs/mlx-workbench-endpoint.log").path
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [
                python, "-c", Self.bootstrap, plan.fleetURL.path, expected,
                python, script,
            ] + plan.arguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "EnvironmentVariables": ["PATH": URL(fileURLWithPath: python).deletingLastPathComponent().path
                + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")],
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

    func install(plan: LoginItemPlan) throws {
        let plist = try plistPreview(plan: plan)
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        // Already bootstrapped agents must be booted out before re-bootstrap.
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        _ = try run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
    }

    /// Read the current fleet before executing the captured, confirmed engine command.
    /// Model/runtime drift is also refused by the engine's reviewed preview hash.
    static let bootstrap = """
    import json, os, sys
    with open(sys.argv[1], encoding='utf-8') as source:
        fleets = json.load(source)
    expected = json.loads(sys.argv[2])
    slots = fleets[0]['slots'] if len(fleets) == 1 else []
    current = [slot for slot in slots if slot.get('id') == expected.get('id')]
    def settings(slot):
        return {key: value for key, value in slot.items() if key not in ('profilePreviewHash', 'accelerationPreviewHash')}
    if len(current) != 1 or not current[0].get('enabled') or settings(current[0]) != settings(expected):
        sys.exit('Endpoint settings changed. Review and reinstall the login item in Run.')
    os.environ['PATH'] = os.path.dirname(sys.argv[3]) + ':' + os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')
    os.execv(sys.argv[3], sys.argv[3:])
    """

    func uninstall() throws {
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    // MARK: - Process runner

    static func launchctl(_ executable: String, _ argv: [String], timeout: TimeInterval = 30,
                          cancellation: CLIInvocationCancellation = CLIInvocationCancellation()) throws -> String {
        let output = try BoundedProcessCapture.run(executable: URL(fileURLWithPath: executable), arguments: argv,
            timeout: timeout, cancellation: cancellation)
        guard output.status == 0 else {
            throw LaunchAgentError.launchctlFailed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.stdout
    }

    private func pythonExecutable(agentPath: String) -> String {
        interpreter(agentPath)?.path ?? "/usr/bin/python3"
    }
}
