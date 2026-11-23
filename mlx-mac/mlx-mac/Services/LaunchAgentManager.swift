import Foundation

// MARK: - LaunchAgentManager
//
// Boot persistence for the always-on endpoint (premium spec 06, phase 2).
// One LaunchAgent per enabled endpoint runs `mlx-agent serve start` once at
// login (RunAtLoad, no KeepAlive). launchd provides boot persistence, the
// in-app EndpointSupervisor provides runtime reconciliation, and mlx-agent
// receipts stay the process authority. `serve start` supervises its own
// detached server, so a KeepAlive loop would fight it — deliberately avoided.
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
    case invalidPlan(String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let detail): return "launchctl failed: \(detail)"
        case .invalidPlan(let detail): return detail
        }
    }
}

/// Login install uses the same won't-fit rule as enabling an endpoint:
/// the install does not proceed until the user explicitly overrides.
enum LoginFleetInstall {
    static func refusal(verdict: FitVerdict?, overridden: Bool) -> String? {
        guard !overridden, let verdict, case .wontFit = verdict else { return nil }
        return verdict.summary
    }
}

struct LaunchAgentManager: Sendable {
    /// The single-slot agent from earlier releases. Install and remove boot it out.
    static let legacyLabel = "ai.cavi.mlxworkbench.endpoint"

    static func label(for slotID: UUID) -> String { "\(legacyLabel).\(slotID.uuidString)" }

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

    private var agentsDirectory: URL {
        home.appendingPathComponent("Library/LaunchAgents")
    }

    private var legacyPlistURL: URL {
        agentsDirectory.appendingPathComponent("\(Self.legacyLabel).plist")
    }

    func plistURL(for slotID: UUID) -> URL {
        agentsDirectory.appendingPathComponent("\(Self.label(for: slotID)).plist")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyPlistURL.path) || !slotPlistURLs().isEmpty
    }

    // MARK: - Preview

    /// The exact plist that would be installed. Shown to the user before
    /// confirmation.
    func plistPreview(plan: LoginItemPlan) throws -> String {
        let script = URL(fileURLWithPath: plan.agentPath)
            .appendingPathComponent("scripts/mlx-agent").path
        let expected = String(decoding: try JSONEncoder().encode(plan.slot), as: UTF8.self)
        let python = pythonExecutable(agentPath: plan.agentPath)
        let logPath = home.appendingPathComponent("Library/Logs/mlx-workbench-endpoint-\(plan.slot.port).log").path
        let plist: [String: Any] = [
            "Label": Self.label(for: plan.slot.id),
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
        try install(plans: [plan])
    }

    /// Writes and bootstraps one plist per plan. A failed bootstrap removes
    /// the agents this call started so a partial fleet is not left running.
    func install(plans: [LoginItemPlan]) throws {
        guard !plans.isEmpty, plans.allSatisfy({ $0.slot.enabled && !$0.slot.modelPath.isEmpty }) else {
            throw LaunchAgentError.invalidPlan("Enable an endpoint before installing its login item.")
        }
        guard plans.count <= EndpointFleetConfig.maxSlots, Set(plans.map(\.slot.id)).count == plans.count else {
            throw LaunchAgentError.invalidPlan("A login item can start at most \(EndpointFleetConfig.maxSlots) different endpoints.")
        }
        let rendered = try plans.map { (plan: $0, text: try plistPreview(plan: $0)) }
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        for item in rendered {
            try item.text.write(to: plistURL(for: item.plan.slot.id), atomically: true, encoding: .utf8)
        }
        try removeAgents(keeping: Set(plans.map(\.slot.id)))
        var started: [UUID] = []
        do {
            for plan in plans {
                let label = Self.label(for: plan.slot.id)
                _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
                _ = try run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL(for: plan.slot.id).path])
                started.append(plan.slot.id)
            }
        } catch {
            for id in started {
                _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label(for: id))"])
            }
            for plan in plans {
                try? FileManager.default.removeItem(at: plistURL(for: plan.slot.id))
            }
            throw error
        }
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
        try removeAgents(keeping: [])
    }

    /// Boots out the legacy single-slot agent and any slot agent not in `keeping`.
    private func removeAgents(keeping: Set<UUID>) throws {
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.legacyLabel)"])
        if FileManager.default.fileExists(atPath: legacyPlistURL.path) {
            try FileManager.default.removeItem(at: legacyPlistURL)
        }
        for url in slotPlistURLs() {
            let label = url.deletingPathExtension().lastPathComponent
            let idText = label.dropFirst(Self.legacyLabel.count + 1)
            if let id = UUID(uuidString: String(idText)), keeping.contains(id) { continue }
            _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            try FileManager.default.removeItem(at: url)
        }
    }

    private func slotPlistURLs() -> [URL] {
        let prefix = "\(Self.legacyLabel)."
        guard let urls = try? FileManager.default.contentsOfDirectory(at: agentsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { url in
            let name = url.lastPathComponent
            let id = name.dropFirst(prefix.count).dropLast(".plist".count)
            return name.hasPrefix(prefix) && name.hasSuffix(".plist") && UUID(uuidString: String(id)) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
