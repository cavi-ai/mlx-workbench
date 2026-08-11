import Foundation

// MARK: - AppHost

@MainActor
class AppHost: ObservableObject {
    @Published var config: Config = Config.defaults()
    @Published var agentHealth: AgentHealth = .notConfigured
    @Published var runtimeReport: RuntimeReport = RuntimeChecker.report()
    @Published var discoveredRoots: [String] = []
    @Published var vendorAgentPath: String = ""
    @Published var configPath: String = ""
    @Published var isScanning = false
    @Published var scanResult: ScanResult?
    @Published var lastError: String?

    let api: WorkbenchAPI

    private let configModule: ConfigModule
    private let cli: CLIProcess

    init() {
        let module = ConfigModule()
        self.configModule = module
        let cli = CLIProcess()
        self.cli = cli
        let config = module.load()
        self.config = config
        self.api = WorkbenchAPI(cli: cli, agentPath: config.mlxAgentPath)
        self.discoveredRoots = Config.discoverGgufRoots()
        self.configPath = module.configPath()
        self.vendorAgentPath = module.vendorAgentPath()
        self.agentHealth = Self.checkAgentHealth(path: config.mlxAgentPath, cli: cli)
        self.runtimeReport = RuntimeChecker.report()
    }

    func requestRescan() {
        Task { await self.rescan() }
    }

    func rescan(limit: Int? = nil) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        do {
            let roots = config.ggufRoots.isEmpty ? Config.discoverGgufRoots() : config.ggufRoots
            scanResult = try await api.scan(
                ggufRoots: roots,
                mlxRoots: config.mlxRoots,
                signatures: config.signatures,
                limit: limit
            )
            lastError = nil
        } catch {
            scanResult = nil
            lastError = Self.render(error)
        }
    }

    func saveConfig(_ newConfig: Config) -> Config {
        do {
            let saved = try configModule.save(newConfig)
            config = saved
            agentHealth = Self.checkAgentHealth(path: saved.mlxAgentPath, cli: cli)
            runtimeReport = RuntimeChecker.report()
            lastError = nil
            return saved
        } catch {
            lastError = Self.render(error)
            return config
        }
    }

    /// Recreate the API when the agent path changes, so subcommands run from
    /// the newly selected checkout.
    func setAgentPath(_ path: String) -> Config {
        var updated = config
        updated.mlxAgentPath = path
        do {
            let saved = try configModule.save(updated)
            config = saved
            Task { await api.setAgentPath(saved.mlxAgentPath) }
            agentHealth = Self.checkAgentHealth(path: saved.mlxAgentPath, cli: cli)
            lastError = nil
            return saved
        } catch {
            lastError = Self.render(error)
            return config
        }
    }

    static func checkAgentHealth(path: String, cli: CLIProcess) -> AgentHealth {
        guard !path.isEmpty else { return .notConfigured }
        let root = Path.expandedURL(path)
        let script = root.appendingPathComponent("scripts/mlx-agent")
        if !FileManager.default.fileExists(atPath: script.path) {
            return .notFound(path: root.path, cli: script.path)
        }
        if !FileManager.default.isExecutableFile(atPath: script.path) {
            return .notFound(path: root.path, cli: script.path)
        }
        return .ready(path: root.path, cli: script.path)
    }

    static func render(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "Unknown bridge error."
        }
        return error.localizedDescription
    }
}

// MARK: - Config

struct Config: Codable, Equatable {
    var schemaVersion: String
    var ggufRoots: [String]
    var mlxRoots: [String]
    var outputDir: String
    var mlxAgentPath: String
    var quarantineDir: String
    var qBits: Int
    var signatures: Bool
    var host: String
    var port: Int

    static let SCHEMA_VERSION = "1.0"
    static let Q_BITS_CHOICES: Set<Int> = [4, 8]
    static let MAX_ROOTS = 32

    static func defaults() -> Config {
        return Config(
            schemaVersion: SCHEMA_VERSION,
            ggufRoots: discoverGgufRoots(),
            mlxRoots: [],
            outputDir: Path.home().appendingPathComponent("models/mlx").path,
            mlxAgentPath: discoverAgentPath(),
            quarantineDir: defaultQuarantineDir(),
            qBits: 4,
            signatures: true,
            host: "127.0.0.1",
            port: 8765
        )
    }

    static func discoverGgufRoots() -> [String] {
        let home = Path.home()
        let candidates = [
            home.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent(".cache/lm-studio/models"),
            home.appendingPathComponent(".lmstudio/models"),
            home.appendingPathComponent("models"),
            home.appendingPathComponent("Models"),
        ]
        let fm = FileManager.default
        return candidates
            .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
            .map { $0.path }
    }

    static func defaultQuarantineDir() -> String {
        if let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
            return URL(fileURLWithPath: xdgData).appendingPathComponent("mlx-workbench/quarantine").path
        }
        return Path.home().appendingPathComponent(".local/share/mlx-workbench/quarantine").path
    }

    static func discoverAgentPath() -> String {
        if let override = ProcessInfo.processInfo.environment["MLX_AGENT_HOME"] {
            let root = Path.expandedURL(override)
            let script = root.appendingPathComponent("scripts/mlx-agent")
            if FileManager.default.fileExists(atPath: script.path) {
                return root.path
            }
        }

        let here = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = here.appendingPathComponent("vendor/mlx-agent")
        let script = vendor.appendingPathComponent("scripts/mlx-agent")
        if FileManager.default.fileExists(atPath: script.path) {
            return vendor.path
        }

        for candidate in [
            here.deletingLastPathComponent().appendingPathComponent("mlx-agent"),
            here.appendingPathComponent("mlx-agent"),
        ] {
            let script = candidate.appendingPathComponent("scripts/mlx-agent")
            if FileManager.default.fileExists(atPath: script.path) {
                return candidate.path
            }
        }

        return ""
    }
}

// MARK: - ConfigModule

struct ConfigModule {
    private let configEnv = "MLX_WORKBENCH_CONFIG"
    private let agentEnv = "MLX_AGENT_HOME"

    func configPath() -> String {
        if let override = ProcessInfo.processInfo.environment[configEnv] {
            return Path.expandedURL(override).path
        }
        if let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: base).appendingPathComponent("mlx-workbench/config.json").path
        }
        return Path.home().appendingPathComponent(".config/mlx-workbench/config.json").path
    }

    func vendorAgentPath() -> String {
        let here = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = here.appendingPathComponent("vendor/mlx-agent")
        let script = candidate.appendingPathComponent("scripts/mlx-agent")
        if FileManager.default.fileExists(atPath: script.path) {
            return candidate.path
        }
        return ""
    }

    func load() -> Config {
        let location = URL(fileURLWithPath: configPath())
        do {
            let data = try Data(contentsOf: location)
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return coerce(dict)
        } catch {
            return Config.defaults()
        }
    }

    func save(_ value: Config) throws -> Config {
        let merged = coerce(encode(value))
        let location = URL(fileURLWithPath: configPath())
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(merged)
        let temp = location.appendingPathExtension(".tmp")
        try data.write(to: temp)
        try FileManager.default.moveItem(at: temp, to: location)
        return merged
    }

    func scanRoots(value: Config) -> [String] {
        return value.ggufRoots.isEmpty ? Config.discoverGgufRoots() : value.ggufRoots
    }

    func discoverGgufRoots() -> [String] {
        return Config.discoverGgufRoots()
    }
}

// MARK: - Coercion

private func coerce(_ dict: [String: Any]) -> Config {
    var merged = Config.defaults()

    func expand(_ value: String) -> String {
        return value.hasPrefix("~") ? NSString(string: value).expandingTildeInPath : value
    }

    if let ggufRoots = dict["gguf_roots"] as? [String] {
        let cleaned = ggufRoots
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { expand($0) }
        if cleaned.count <= Config.MAX_ROOTS {
            merged.ggufRoots = cleaned
        }
    }

    if let mlxRoots = dict["mlx_roots"] as? [String] {
        let cleaned = mlxRoots
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { expand($0) }
        if cleaned.count <= Config.MAX_ROOTS {
            merged.mlxRoots = cleaned
        }
    }

    if let outputDir = dict["output_dir"] as? String {
        merged.outputDir = outputDir.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : expand(outputDir)
    }

    if let mlxAgentPath = dict["mlx_agent_path"] as? String {
        merged.mlxAgentPath = mlxAgentPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : expand(mlxAgentPath)
    }

    if let quarantineDir = dict["quarantine_dir"] as? String {
        merged.quarantineDir = expand(quarantineDir)
    }

    if let qBits = dict["q_bits"] as? Int, !qBits.isBool, Config.Q_BITS_CHOICES.contains(qBits) {
        merged.qBits = qBits
    }

    if let signatures = dict["signatures"] as? Bool {
        merged.signatures = signatures
    }

    if let port = dict["port"] as? Int, !port.isBool, (1...65535).contains(port) {
        merged.port = port
    }

    if merged.mlxAgentPath.isEmpty {
        merged.mlxAgentPath = Config.discoverAgentPath()
    }

    return merged
}

private func encode(_ config: Config) -> [String: Any] {
    return [
        "schema_version": config.schemaVersion,
        "gguf_roots": config.ggufRoots,
        "mlx_roots": config.mlxRoots,
        "output_dir": config.outputDir,
        "mlx_agent_path": config.mlxAgentPath,
        "quarantine_dir": config.quarantineDir,
        "q_bits": config.qBits,
        "signatures": config.signatures,
        "host": config.host,
        "port": config.port,
    ]
}

private extension Int {
    var isBool: Bool {
        return self == 0 || self == 1
    }
}

// MARK: - Path Helpers

private enum Path {
    static func home() -> URL {
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func expandedURL(_ path: String) -> URL {
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Agent Health

enum AgentHealth: Equatable {
    case notConfigured
    case notFound(path: String, cli: String)
    case ready(path: String, cli: String)
}
