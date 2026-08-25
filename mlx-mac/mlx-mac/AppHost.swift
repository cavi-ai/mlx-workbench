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
    @Published var librarySnapshot: LibrarySnapshot?
    @Published var catalog: CatalogState
    @Published var isRefreshingCatalog = false
    @Published var selectedModelPath: String?
    @Published var benchmarkResults: [RecommendationBenchmarkResult] = []
    @Published var recommendationPreferences: RecommendationPreferences = .defaults
    @Published var hardwareProfile: HardwareProfile
    @Published var lastError: String?
    @Published var modelWorkflow: ModelWorkflowCoordinator

    let api: WorkbenchAPI

    private let configModule: ConfigModule
    private let cli: CLIProcess
    private let catalogStore: CatalogStore
    private let catalogClient: any CatalogRefreshing
    private let catalogTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let scanOperation: @Sendable ([String], [String], Bool, Int?) async throws -> ScanResult

    init(
        configModule: ConfigModule = ConfigModule(),
        cli: CLIProcess = CLIProcess(),
        catalogStore: CatalogStore = CatalogStore(),
        catalogClient: any CatalogRefreshing = CatalogClient(),
        catalogTTL: TimeInterval = CatalogFreshness.metadataTTL,
        config: Config? = nil,
        discoveredRoots: [String]? = nil,
        vendorAgentPath: String? = nil,
        configPath: String? = nil,
        agentHealth: AgentHealth? = nil,
        runtimeReport: RuntimeReport? = nil,
        hardwareProfile: HardwareProfile = HardwareProfile.current(),
        now: @escaping @Sendable () -> Date = { Date() },
        scanOperation: (@Sendable ([String], [String], Bool, Int?) async throws -> ScanResult)? = nil,
        modelWorkflowAPI: ModelWorkflowAPI? = nil,
        modelWorkflowPersistence: ModelWorkflowPersistence? = nil
    ) {
        self.configModule = configModule
        self.cli = cli
        self.catalogStore = catalogStore
        self.catalogClient = catalogClient
        self.catalogTTL = catalogTTL
        let loadedConfig = config ?? configModule.load()
        self.config = loadedConfig
        let api = WorkbenchAPI(cli: cli, agentPath: loadedConfig.mlxAgentPath)
        self.api = api
        self.modelWorkflow = ModelWorkflowCoordinator(
            api: modelWorkflowAPI ?? .live(api: api),
            persistence: modelWorkflowPersistence ?? .live(store: ModelWorkflowStore(fileURL: ModelWorkflowStore.defaultFileURL()))
        )
        self.discoveredRoots = discoveredRoots ?? Config.discoverGgufRoots()
        self.configPath = configPath ?? configModule.configPath()
        self.vendorAgentPath = vendorAgentPath ?? configModule.vendorAgentPath()
        self.agentHealth = agentHealth ?? Self.checkAgentHealth(path: loadedConfig.mlxAgentPath, cli: cli)
        self.runtimeReport = runtimeReport ?? RuntimeChecker.report()
        self.hardwareProfile = hardwareProfile
        let initialNow = now()
        self.now = now
        self.catalog = Self.catalogState(
            from: catalogStore.load(),
            client: catalogClient,
            now: initialNow,
            ttl: catalogTTL
        )
        self.scanOperation = scanOperation ?? { ggufRoots, mlxRoots, signatures, limit in
            try await api.scan(
                ggufRoots: ggufRoots,
                mlxRoots: mlxRoots,
                signatures: signatures,
                limit: limit
            )
        }
    }

    func requestRescan() {
        Task { await self.rescan() }
    }

    func rescan(limit: Int? = nil) async {
        _ = await rescan(limit: limit, reconcileWorkflow: true)
    }

    func refreshWorkflowStatus(jobs: [Job]? = nil) async {
        if let jobs {
            await modelWorkflow.reconcile(snapshot: librarySnapshot, jobs: jobs)
        } else {
            await modelWorkflow.refreshOperationalStatus()
        }
        await finishCompletionReconciliationIfNeeded()
    }

    private func rescan(limit: Int?, reconcileWorkflow: Bool) async -> LibrarySnapshot? {
        guard !isScanning else { return nil }
        isScanning = true

        do {
            let roots = config.ggufRoots.isEmpty ? Config.discoverGgufRoots() : config.ggufRoots
            let scan = try await scanOperation(
                roots,
                config.mlxRoots,
                config.signatures,
                limit
            )
            let snapshot = ModelLibraryBuilder.build(scan: scan, hardware: hardwareProfile, now: now())
            scanResult = scan
            librarySnapshot = snapshot
            lastError = nil
            if reconcileWorkflow {
                await modelWorkflow.refreshOperationalStatus()
                isScanning = false
                await finishCompletionReconciliationIfNeeded()
                return snapshot
            }
            isScanning = false
            return snapshot
        } catch {
            lastError = Self.render(error)
            isScanning = false
            return nil
        }
    }

    private func finishCompletionReconciliationIfNeeded() async {
        guard modelWorkflow.consumeCompletionRescanRequest() else { return }
        let freshSnapshot = await rescan(limit: nil, reconcileWorkflow: false)
        modelWorkflow.resolveCompletionAfterFreshScan(snapshot: freshSnapshot)
    }

    func saveConfig(_ newConfig: Config) -> Config {
        do {
            let normalized = try Self.normalizeAndValidateForSave(newConfig)
            let saved = try configModule.save(normalized)
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

    func refreshCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }

        do {
            let snapshot = try await catalogClient.refresh()
            do {
                try catalogStore.save(snapshot)
                catalog = Self.catalogState(for: snapshot, now: now(), ttl: catalogTTL)
            } catch {
                catalog = Self.catalogFailureState(
                    current: catalog,
                    snapshot: snapshot,
                    message: "Metadata was fetched, but the catalog cache could not be saved: \(Self.render(error))",
                    now: now(),
                    ttl: catalogTTL
                )
            }
        } catch {
            catalog = Self.catalogFailureState(
                current: catalog,
                client: catalogClient,
                error: error,
                now: now(),
                ttl: catalogTTL
            )
        }
    }

    /// Recreate the API when the agent path changes, so subcommands run from
    /// the newly selected checkout.
    func setAgentPath(_ path: String) async -> Config {
        var updated = config
        updated.mlxAgentPath = Self.normalizeAgentPath(path)
        do {
            let saved = try configModule.save(updated)
            config = saved
            await api.setAgentPath(saved.mlxAgentPath)
            agentHealth = Self.checkAgentHealth(path: saved.mlxAgentPath, cli: cli)
            lastError = nil
            return saved
        } catch {
            lastError = Self.render(error)
            return config
        }
    }

    static func checkAgentHealth(path: String, cli: CLIProcess) -> AgentHealth {
        let normalizedPath = normalizeAgentPath(path)
        guard !normalizedPath.isEmpty else { return .notConfigured }
        let root = Path.expandedURL(normalizedPath)
        let script = root.appendingPathComponent("scripts/mlx-agent")
        var isDirectory = ObjCBool(false)
        if !FileManager.default.fileExists(atPath: script.path, isDirectory: &isDirectory) || isDirectory.boolValue {
            return .notFound(path: root.path, cli: script.path)
        }
        if !FileManager.default.isReadableFile(atPath: script.path) {
            return .notUsable(path: root.path, cli: script.path, reason: "scripts/mlx-agent is not readable.")
        }
        return .ready(path: root.path, cli: script.path)
    }

    static func normalizeAgentPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return Path.expandedURL(trimmed).path
    }

    private static func catalogState(
        from loadResult: CatalogStore.LoadResult,
        client: any CatalogRefreshing,
        now: Date,
        ttl: TimeInterval
    ) -> CatalogState {
        switch loadResult {
        case .missing:
            return client.isConfigured ? .missing : .unavailable(message: client.unavailableMessage)
        case .corrupt(let message):
            return .corrupt(message: message)
        case .snapshot(let snapshot):
            if client.isConfigured {
                return catalogState(for: snapshot, now: now, ttl: ttl)
            }
            return catalogFailureState(
                current: catalogState(for: snapshot, now: now, ttl: ttl),
                snapshot: snapshot,
                message: "Metadata provider unavailable: \(client.unavailableMessage)",
                now: now,
                ttl: ttl
            )
        }
    }

    private static func catalogState(
        for snapshot: CatalogSnapshot,
        now: Date,
        ttl: TimeInterval
    ) -> CatalogState {
        switch CatalogFreshness.classify(fetchedAt: snapshot.fetchedAt, now: now, ttl: ttl) {
        case .current:
            return .current(snapshot)
        case .stale:
            return .stale(snapshot)
        }
    }

    private static func catalogFailureState(
        current: CatalogState,
        client: any CatalogRefreshing,
        error: Error,
        now: Date,
        ttl: TimeInterval
    ) -> CatalogState {
        let message: String
        switch error {
        case CatalogClientError.unavailable(let detail):
            message = "Metadata provider unavailable: \(detail)"
        case CatalogClientError.invalidPayload(let detail):
            message = "Metadata validation failed: \(detail)"
        default:
            message = "Metadata refresh failed: \(render(error))"
        }
        return catalogFailureState(current: current, snapshot: current.snapshot, message: message, now: now, ttl: ttl)
    }

    private static func catalogFailureState(
        current: CatalogState,
        snapshot: CatalogSnapshot?,
        message: String,
        now: Date,
        ttl: TimeInterval
    ) -> CatalogState {
        guard let snapshot else {
            if case .corrupt(let existing) = current {
                return .corrupt(message: "\(existing) \(message)")
            }
            if case .unavailable(let existing) = current {
                return .unavailable(message: existing)
            }
            return .refreshFailed(snapshot: nil, message: message)
        }

        switch CatalogFreshness.classify(fetchedAt: snapshot.fetchedAt, now: now, ttl: ttl) {
        case .current:
            return .currentFailure(snapshot: snapshot, message: message)
        case .stale:
            return .staleFailure(snapshot: snapshot, message: message)
        }
    }

    private static func normalizeAndValidateForSave(_ config: Config) throws -> Config {
        let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Config.LOOPBACK_HOSTS.contains(host.isEmpty ? "127.0.0.1" : host) else {
            throw ConfigError.invalidHost(host)
        }
        guard (1...65535).contains(config.port) else {
            throw ConfigError.invalidPort(config.port)
        }
        var normalized = config
        normalized.host = host.isEmpty ? "127.0.0.1" : host
        return normalized
    }

    static func render(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "Unknown bridge error."
        }
        return error.localizedDescription
    }

    var recommendations: [UseCase: [Recommendation]] {
        guard case .ready = agentHealth, runtimeReport.ok else { return [:] }
        guard let snapshot = librarySnapshot else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: UseCase.allCases.map { useCase in
                (
                    useCase,
                    RecommendationEngine.recommend(
                        useCase: useCase,
                        snapshot: snapshot,
                        catalog: catalog,
                        benchmarkResults: benchmarkResults,
                        preferences: recommendationPreferences
                    )
                )
            }
        )
    }

    func recommendations(for useCase: UseCase) -> [Recommendation] {
        recommendations[useCase] ?? []
    }

    func model(for recommendation: Recommendation) -> LibraryModel? {
        librarySnapshot?.models.first(where: { $0.item.path == recommendation.modelID })
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
    static let LOOPBACK_HOSTS: Set<String> = ["127.0.0.1", "localhost", "::1"]

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
    case notUsable(path: String, cli: String, reason: String)
    case ready(path: String, cli: String)
}
