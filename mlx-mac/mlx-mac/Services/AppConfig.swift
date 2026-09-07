import Foundation

// MARK: - AppConfig
//
// Persistent app configuration: the Config record, its load/save module,
// tolerant coercion of on-disk JSON, and agent health. Split out of
// AppHost.swift; behavior is unchanged.
//
// Path math note: this file lives one level deeper than AppHost.swift
// (Services/), so repo-root derivation climbs four directories, not three.

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
    // Premium feature toggles (specs 01–08). All have defaults, so configs
    // written before these keys existed keep working.
    var verificationEnabled: Bool
    var watchEnabled: Bool
    var fitReserveGB: Double
    var reclaimStaleDays: Int
    var comparisonMaxTokens: Int

    static let SCHEMA_VERSION = "1.0"
    static let Q_BITS_CHOICES: Set<Int> = [4, 8]
    static let MAX_ROOTS = 32
    static let LOOPBACK_HOSTS: Set<String> = ["127.0.0.1", "localhost", "::1"]
    static let FIT_RESERVE_RANGE: ClosedRange<Double> = 0...16
    // 2…365: 1 collides with JSON bool coercion (true → 1).
    static let STALE_DAYS_RANGE: ClosedRange<Int> = 2...365
    static let COMPARISON_MAX_TOKENS_RANGE: ClosedRange<Int> = 64...4096

    // Snake-case on disk, matching the coerce()/encode() contract.
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ggufRoots = "gguf_roots"
        case mlxRoots = "mlx_roots"
        case outputDir = "output_dir"
        case mlxAgentPath = "mlx_agent_path"
        case quarantineDir = "quarantine_dir"
        case qBits = "q_bits"
        case signatures, host, port
        case verificationEnabled = "verification_enabled"
        case watchEnabled = "watch_enabled"
        case fitReserveGB = "fit_reserve_gb"
        case reclaimStaleDays = "reclaim_stale_days"
        case comparisonMaxTokens = "comparison_max_tokens"
    }

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
            port: 8765,
            verificationEnabled: true,
            watchEnabled: true,
            fitReserveGB: 4,
            reclaimStaleDays: ReclaimAdvisor.defaultStaleDays,
            comparisonMaxTokens: 512
        )
    }

    static func discoverGgufRoots(home: URL = Path.home()) -> [String] {
        let candidates = [
            home.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent(".cache/lm-studio/models"),
            home.appendingPathComponent(".lmstudio/models"),
            home.appendingPathComponent(".models"),
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

        let here = repoRootFromThisFile()
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

    /// <repo>/mlx-mac/mlx-mac/Services/AppConfig.swift → repo root.
    fileprivate static func repoRootFromThisFile() -> URL {
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

enum ConfigError: LocalizedError {
    case invalidHost(String)
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            let displayHost = host.isEmpty ? "127.0.0.1" : host
            return "Invalid host \"\(displayHost)\"; use 127.0.0.1, localhost, or ::1."
        case .invalidPort(let port):
            return "Invalid port \"\(port)\"; valid ports are 1-65535."
        }
    }
}

// MARK: - ConfigModule

struct ConfigModule {
    private let configEnv = "MLX_WORKBENCH_CONFIG"
    private let agentEnv = "MLX_AGENT_HOME"
    /// Test seam: ProcessInfo caches the environment at process start, so
    /// setenv-based overrides are invisible. Tests inject the path directly.
    private let pathOverride: String?

    init(pathOverride: String? = nil) {
        self.pathOverride = pathOverride
    }

    func configPath() -> String {
        if let pathOverride { return pathOverride }
        if let override = ProcessInfo.processInfo.environment[configEnv] {
            return Path.expandedURL(override).path
        }
        if let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: base).appendingPathComponent("mlx-workbench/config.json").path
        }
        return Path.home().appendingPathComponent(".config/mlx-workbench/config.json").path
    }

    func vendorAgentPath() -> String {
        let candidate = Config.repoRootFromThisFile().appendingPathComponent("vendor/mlx-agent")
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

    if let host = dict["host"] as? String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            merged.host = normalized
        }
    }
    if !Config.LOOPBACK_HOSTS.contains(merged.host) {
        merged.host = "127.0.0.1"
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

    if let verificationEnabled = dict["verification_enabled"] as? Bool {
        merged.verificationEnabled = verificationEnabled
    }
    if let watchEnabled = dict["watch_enabled"] as? Bool {
        merged.watchEnabled = watchEnabled
    }
    if let reserve = dict["fit_reserve_gb"] as? Double, Config.FIT_RESERVE_RANGE.contains(reserve) {
        merged.fitReserveGB = reserve
    }
    if let days = dict["reclaim_stale_days"] as? Int, !days.isBool, Config.STALE_DAYS_RANGE.contains(days) {
        merged.reclaimStaleDays = days
    }
    if let maxTokens = dict["comparison_max_tokens"] as? Int, !maxTokens.isBool, Config.COMPARISON_MAX_TOKENS_RANGE.contains(maxTokens) {
        merged.comparisonMaxTokens = maxTokens
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
        "verification_enabled": config.verificationEnabled,
        "watch_enabled": config.watchEnabled,
        "fit_reserve_gb": config.fitReserveGB,
        "reclaim_stale_days": config.reclaimStaleDays,
        "comparison_max_tokens": config.comparisonMaxTokens,
    ]
}

private extension Int {
    var isBool: Bool {
        return self == 0 || self == 1
    }
}

// MARK: - Path Helpers

enum Path {
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
    case notUsable(path: String, cli: String, reason: String)
    case ready(path: String, cli: String)
}
