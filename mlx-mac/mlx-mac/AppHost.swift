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
    /// Conversion Quality Gate. Attached to the workflow by the app entry
    /// point via `verification.attach(to: modelWorkflow)`.
    let verification: VerificationCoordinator
    /// Measured Comparisons (prompt-set replay across variants).
    let comparison: ComparisonCoordinator
    /// Cross-client wiring transactions (premium spec 02).
    let wiring: WiringCoordinator
    /// Always-on endpoint supervisor (premium spec 06).
    let endpoint: EndpointSupervisor
    /// Usage evidence per model path (premium spec 04).
    let usage: UsageTracker
    let workflowEvidence: WorkflowEvidenceStore
    /// Disk Pressure Advisor apply surface (premium spec 04).
    let reclaim: ReclaimCoordinator
    /// Watch & regression alerts (premium spec 08).
    let watch: WatchCoordinator
    /// Guided runtime setup (make install runner). Only actionable when the
    /// app runs from a checkout; see WorkbenchPython.repoRoot().
    let runtimeInstaller: RuntimeInstaller
    /// Hugging Face intake sheet state (verdict, backend install, downloads).
    let intake: IntakeCoordinator
    /// Prompt → PNG for converted image-generation models.
    let imageGeneration: ImageGenerationCoordinator
    /// First-launch setup assistant state (persisted once completed).
    let setup: SetupCoordinator
    /// In-app updates (official tags or beta/main) for checkout-run installs.
    let updater: UpdateCoordinator

    let api: WorkbenchAPI

    private let configModule: ConfigModule
    private let cli: CLIProcess
    private let catalogStore: CatalogStore
    private let catalogClient: any CatalogRefreshing
    private let catalogTTL: TimeInterval
    private let preferencesStore: JSONStore<RecommendationPreferences>
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
        modelWorkflowPersistence: ModelWorkflowPersistence? = nil,
        verification: VerificationCoordinator? = nil,
        comparison: ComparisonCoordinator? = nil,
        wiring: WiringCoordinator? = nil,
        endpoint: EndpointSupervisor? = nil,
        usage: UsageTracker? = nil,
        workflowEvidence: WorkflowEvidenceStore? = nil,
        reclaim: ReclaimCoordinator? = nil,
        watch: WatchCoordinator? = nil,
        runtimeInstaller: RuntimeInstaller? = nil,
        setup: SetupCoordinator? = nil,
        updater: UpdateCoordinator? = nil,
        preferencesStore: JSONStore<RecommendationPreferences>? = nil,
        intakeAPI: IntakeAPI? = nil
    ) {
        self.configModule = configModule
        self.cli = cli
        self.catalogStore = catalogStore
        self.catalogClient = catalogClient
        self.catalogTTL = catalogTTL
        self.preferencesStore = preferencesStore ?? JSONStore<RecommendationPreferences>(
            fileURL: JSONStore<RecommendationPreferences>.defaultFileURL("recommendation-preferences.json")
        )
        if let stored = try? self.preferencesStore.load().first {
            recommendationPreferences = stored
        }
        let loadedConfig = config ?? configModule.load()
        self.config = loadedConfig
        let api = WorkbenchAPI(cli: cli, agentPath: loadedConfig.mlxAgentPath)
        self.api = api
        self.modelWorkflow = ModelWorkflowCoordinator(
            api: modelWorkflowAPI ?? .live(api: api),
            persistence: modelWorkflowPersistence ?? .live(store: ModelWorkflowStore(fileURL: ModelWorkflowStore.defaultFileURL()))
        )
        self.verification = verification ?? VerificationCoordinator(
            probe: ServeProbe(
                lifecycle: .live(api: api),
                prober: OpenAIEndpointProber()
            ),
            store: VerificationStore(fileURL: VerificationStore.defaultFileURL())
        )
        self.comparison = comparison ?? ComparisonCoordinator(
            probe: ServeProbe(
                lifecycle: .live(api: api),
                prober: OpenAIEndpointProber()
            ),
            runStore: JSONStore<ComparisonRun>(fileURL: JSONStore<ComparisonRun>.defaultFileURL("comparison-runs.json")),
            promptSetStore: JSONStore<PromptSet>(fileURL: JSONStore<PromptSet>.defaultFileURL("prompt-sets.json")),
            mediaRunner: LiveComparisonMediaRunner(api: api),
            outputStore: ComparisonOutputStore()
        )
        self.wiring = wiring ?? WiringCoordinator(
            store: JSONStore<WiringTransaction>(fileURL: JSONStore<WiringTransaction>.defaultFileURL("wiring-transactions.json"))
        )
        self.endpoint = endpoint ?? EndpointSupervisor(
            lifecycle: .live(api: api),
            statusProvider: { try await api.serveStatus() },
            store: JSONStore<EndpointConfig>(fileURL: JSONStore<EndpointConfig>.defaultFileURL("endpoint-config.json"))
        )
        self.usage = usage ?? UsageTracker(
            store: JSONStore<UsageStamp>(fileURL: JSONStore<UsageStamp>.defaultFileURL("usage-stamps.json"))
        )
        self.workflowEvidence = workflowEvidence ?? WorkflowEvidenceStore(store: JSONStore<WorkflowEvidence>(fileURL: JSONStore<WorkflowEvidence>.defaultFileURL("workflow-evidence.json")))
        self.reclaim = reclaim ?? ReclaimCoordinator()
        self.runtimeInstaller = runtimeInstaller ?? RuntimeInstaller()
        self.intake = IntakeCoordinator(api: intakeAPI ?? .live(api: api))
        self.imageGeneration = ImageGenerationCoordinator(render: { path, out, request in
            try await api.generate(path: path, out: out.path, request: request)
        })
        self.setup = setup ?? SetupCoordinator()
        self.updater = updater ?? UpdateCoordinator()
        let verificationCoordinator = self.verification
        let watchStateDir = JSONStore<WatchState>.defaultFileURL("placeholder")
            .deletingLastPathComponent()
            .appendingPathComponent("watch-state", isDirectory: true)
            .path
        self.watch = watch ?? WatchCoordinator(
            watchDiff: {
                let data = try await api.raw(["watch", "diff", "--state-dir", watchStateDir], isScout: true)
                return (data["findings"] as? [[String: Any]]) ?? []
            },
            watchSnapshot: {
                _ = try await api.raw(["watch", "snapshot", "--state-dir", watchStateDir], isScout: true)
            },
            fingerprint: {
                EnvironmentFingerprint.current(
                    hardware: hardwareProfile,
                    mlxLMVersion: WatchCoordinator.probeMLXLVersion
                )
            },
            verifiedReports: {
                verificationCoordinator.reports.filter { $0.outcome == .passed }
            },
            alertStore: JSONStore<WatchAlert>(fileURL: JSONStore<WatchAlert>.defaultFileURL("watch-alerts.json")),
            stateStore: JSONStore<WatchState>(fileURL: JSONStore<WatchState>.defaultFileURL("watch-state.json")),
            notify: AlertNotifier.post
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
        // Measured comparisons feed the RecommendationEngine: rehydrate
        // aggregates from completed runs, then append as new runs finish.
        benchmarkResults.append(contentsOf: self.comparison.aggregateBenchmarks())
        self.comparison.onBenchmarks = { [weak self] newBenchmarks in
            self?.benchmarkResults.append(contentsOf: newBenchmarks)
        }
        // Benchmarks carry the environment fingerprint so drifted evidence
        // is down-weighted instead of silently trusted.
        self.comparison.environmentFingerprint = { [weak self] in
            self?.watch.currentFingerprintDescription
        }
        // The always-on endpoint only serves verified models by default;
        // the quality gate's per-signature status is the verdict source.
        self.endpoint.isVerified = { [weak self] path in
            self?.isModelVerified(path) ?? false
        }
        // Usage evidence: serve, verify, and measure all count as "used" for
        // the Disk Pressure Advisor's staleness detector.
        self.modelWorkflow.onServeStarted = { [weak self] path in self?.usage.recordServed(path) }
        self.endpoint.onUserServeStarted = { [weak self] path in self?.usage.recordServed(path) }
        self.modelWorkflow.onTerminalState = { [weak self] record in
            AlertNotifier.post(workflowOutcome: record)
            guard record.state == .verified, record.reclaimSourceAfterVerification == true else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.reclaim.previewSource(record)
                guard let current = self.modelWorkflow.history.first(where: { $0.id == record.id }), current == record else { return }
                await self.reclaim.confirmSource(current)
                await self.rescan()
            }
        }
        self.verification.onReport = { [weak self] report in self?.usage.record(report.modelPath) }
        self.comparison.onVariantMeasured = { [weak self] path in self?.usage.record(path) }
        self.reclaim.quarantineDir = { [weak self] in self?.config.quarantineDir ?? "" }
        self.reclaim.ggufRoots = { [weak self] in self?.config.ggufRoots ?? [] }
        self.reclaim.mlxRoots = { [weak self] in
            guard let self else { return [] }
            let roots = self.config.ggufRoots.isEmpty ? Config.discoverGgufRoots() : self.config.ggufRoots
            return Self.scanMLXRoots(self.config, ggufRoots: roots)
        }
        self.reclaim.protectedPaths = { [weak self] in Array(self?.occupiedModelPaths ?? []) }
        self.comparison.maxTokensCap = { [weak self] in self?.config.comparisonMaxTokens ?? 512 }
        // HF-cache reclaim rides the authoritative doctor prune flow.
        self.reclaim.doctorScan = { try await api.doctor(wiredRoots: [], hfCache: nil) }
        self.reclaim.doctorPrunePreview = { try await api.doctorPrunePreview(hfCache: nil) }
        self.reclaim.doctorPruneConfirm = { hash in try await api.doctorPruneConfirm(previewHash: hash, hfCache: nil) }
        // Watch drift action: re-verify stale models one at a time (the gate
        // already serializes verification runs).
        self.watch.reverify = { [weak self] paths in
            Task { [weak self] in
                guard let self else { return }
                for path in paths {
                    await MainActor.run { self.verification.verifyNow(modelPath: path, signature: nil) }
                    while await MainActor.run(body: { self.verification.activeModelPath != nil }) {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
        }
        // Speech-to-text and classification models take their own canary.
        self.verification.taskType = { [weak self] path in
            self?.librarySnapshot?.models.first { $0.item.path == path || $0.outputPaths.contains(path) }?.item.task?.type
        }
        self.verification.speech = SpeechCanaryRunner(
            synthesize: { try await SpeechClipSynthesizer.make(phrase: $0) },
            transcribe: { path, clip, language in try await api.transcribe(path: path, audio: clip.path, language: language) }
        )
        self.verification.decide = { path, request in try await api.decide(path: path, request: request.path) }
        self.verification.render = { path, out, request in try await api.generate(path: path, out: out.path, request: request) }
        // Record the environment fingerprint on every verification report.
        self.verification.environmentFingerprint = { [weak self] in
            self?.watch.currentFingerprintDescription
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

    /// Where intake downloads land: already-MLX repos into the (scanned)
    /// output directory, GGUF files into the first GGUF root; convertible
    /// repos go to the HF cache (nil).
    func intakeDownloadDirectory(for resolution: IntakeResolution) -> String? {
        switch resolution.verdict {
        case .alreadyMLX:
            return URL(fileURLWithPath: config.outputDir).appendingPathComponent(resolution.repoName).path
        case .gguf:
            let roots = config.ggufRoots.isEmpty ? Config.discoverGgufRoots() : config.ggufRoots
            let root = roots.first ?? config.outputDir
            return URL(fileURLWithPath: root).appendingPathComponent(resolution.repoName).path
        default:
            return nil
        }
    }

    /// Hands a finished download to the existing flows; returns the route to show.
    func reuseIntake(_ resolution: IntakeResolution) async -> AppRoute? {
        await rescan()
        let ready = Set((librarySnapshot?.models ?? []).filter { $0.readiness == .ready }.map { $0.item.path })
        guard let path = IntakeCoordinator.existingModelPath(resolution, qBits: config.qBits, history: modelWorkflow.history, readyPaths: ready) else { return nil }
        selectedModelPath = path
        if resolution.verdict == .convertible {
            modelWorkflow.inspect(intake: resolution, outputDirectory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                  qBits: config.qBits, snapshot: librarySnapshot)
            return .prepare
        }
        return .library
    }

    func finishIntake(_ resolution: IntakeResolution, downloadedPath: String?, selectedFile: String?) async -> AppRoute? {
        switch resolution.verdict {
        case .convertible:
            let source = downloadedPath.map { path in resolution.source.subfolder.map { URL(fileURLWithPath: path).appendingPathComponent($0).path } ?? path }
            modelWorkflow.inspect(intake: resolution, outputDirectory: config.outputDir, qBits: config.qBits, snapshot: librarySnapshot, downloadedPath: source)
            return .prepare
        case .alreadyMLX:
            await rescan()
            selectedModelPath = downloadedPath
            return .library
        case .gguf:
            await rescan()
            guard let downloadedPath, let selectedFile else { return .library }
            let path = URL(fileURLWithPath: downloadedPath).appendingPathComponent(selectedFile).path
            selectedModelPath = path
            if let model = librarySnapshot?.models.first(where: { $0.item.path == path }) {
                modelWorkflow.inspect(source: model.item, snapshot: librarySnapshot)
                return .prepare
            }
            return .library
        default:
            return nil
        }
    }

    /// MLX roots the scan reads: configured roots plus the intake output dir,
    /// unless a root already contains it (scanning both lists every converted
    /// model twice). With no MLX roots configured the agent falls back to
    /// scanning the GGUF roots, so that fallback is spelled out first.
    static func scanMLXRoots(_ config: Config, ggufRoots: [String], fileIdentity: (String) -> NSObject? = AppHost.fileIdentity) -> [String] {
        let output = config.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return config.mlxRoots }
        var roots = config.mlxRoots.isEmpty ? ggufRoots : config.mlxRoots
        if !roots.contains(where: { isPath(output, within: $0, fileIdentity: fileIdentity) }) {
            roots.append(output)
        }
        return roots
    }

    /// True when `path` is `root` or lies under it: by file identity where the
    /// directories exist (a case-variant or symlinked spelling of a root is that
    /// root), by standardized path otherwise.
    static func isPath(_ path: String, within root: String, fileIdentity: (String) -> NSObject?) -> Bool {
        let standardized = { (value: String) in URL(fileURLWithPath: NSString(string: value).expandingTildeInPath).standardizedFileURL }
        let rootURL = standardized(root)
        let rootIdentity = fileIdentity(rootURL.path)
        var candidate = standardized(path)
        while true {
            if candidate.path == rootURL.path { return true }
            if let rootIdentity, let identity = fileIdentity(candidate.path), identity.isEqual(rootIdentity) { return true }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return false }
            candidate = parent
        }
    }

    static func fileIdentity(_ path: String) -> NSObject? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    private func rescan(limit: Int?, reconcileWorkflow: Bool) async -> LibrarySnapshot? {
        guard !isScanning else { return nil }
        isScanning = true

        do {
            let roots = config.ggufRoots.isEmpty ? Config.discoverGgufRoots() : config.ggufRoots
            let scan = try await scanOperation(
                roots,
                Self.scanMLXRoots(config, ggufRoots: roots),
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
        guard let freshSnapshot = await rescan(limit: nil, reconcileWorkflow: false) else {
            modelWorkflow.deferCompletionRescan()
            return
        }
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
            applyFeatureToggles()
            return saved
        } catch {
            lastError = Self.render(error)
            return config
        }
    }

    /// Re-probe the convert/serve runtime (e.g. after a guided install).
    func refreshRuntimeReport() {
        runtimeReport = RuntimeChecker.report()
        // The installed mlx-lm version may have changed; the watch
        // fingerprint must reflect the new runtime.
        WatchCoordinator.invalidateEnvironmentProbe()
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
                        preferences: recommendationPreferences,
                        currentEnvironment: watch.currentFingerprintDescription
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

    /// Whether the quality gate has verified this exact model file
    /// (path + signature).
    func isModelVerified(_ path: String) -> Bool {
        let signature = librarySnapshot?.models
            .first(where: { $0.item.path == path || $0.outputPaths.contains(path) })?
            .item.signature
        if case .verified = verification.status(for: path, signature: signature) {
            return true
        }
        return false
    }

    /// Mark a model as the preferred choice for a use case ("promote winner"
    /// and the per-variant affordance share this one write path). Persisted
    /// so a promoted winner survives relaunch.
    func setPreferredModel(_ path: String, for useCase: UseCase) {
        do { try savePreferredModel(path, for: useCase) }
        catch { lastError = Self.render(error) }
    }

    func savePreferredModel(_ path: String, for useCase: UseCase) throws {
        var preferred = recommendationPreferences.preferredModelIDs
        preferred[useCase] = path
        let updated = RecommendationPreferences(
            speedWeight: recommendationPreferences.speedWeight,
            qualityWeight: recommendationPreferences.qualityWeight,
            hiddenModelIDs: recommendationPreferences.hiddenModelIDs,
            preferredModelIDs: preferred
        )
        try preferencesStore.replaceAll([updated])
        recommendationPreferences = updated
    }

    /// Explicit actions refresh inventory and resource probes outside view evaluation.
    func reviewModelGuidance(evidence: AgentEvidenceExport, taskID: String, path: String) async throws -> ModelGuidanceReview {
        await WatchCoordinator.refreshEnvironmentProbe()
        guard let snapshot = await rescan(limit: nil, reconcileWorkflow: false) else {
            throw WorkflowEvidenceError.invalid(lastError ?? "Library scan is already running; try again when it finishes.")
        }
        let capture = await Task.detached(priority: .utility) { (MemorySnapshot.probe(), Date()) }.value
        let fresh = ComparisonInsights.agentEvidence(models: snapshot.models, runs: comparison.runs,
            workflow: workflowEvidence.records, environment: watch.currentFingerprintDescription,
            hardware: hardwareProfile, memory: capture.0, capturedAt: capture.1, contextTokens: evidence.contextTokens,
            reserveGB: config.fitReserveGB, protected: occupiedModelPaths)
        let candidate = try ModelGuidanceAction.validate(original: evidence, fresh: fresh, taskID: taskID, path: path)
        guard let model = snapshot.models.first(where: { $0.item.path == path }),
              ModelTaskPresentation.isServable(model), !model.capabilities.isEmpty else {
            throw WorkflowEvidenceError.invalid("This model has no supported serving role. Use its task-specific panel instead.")
        }
        return ModelGuidanceReview(evidence: fresh, taskID: taskID, candidate: candidate,
            roles: UseCase.allCases.filter { model.capabilities.contains($0) },
            endpoint: endpoint.config, verified: isModelVerified(path))
    }

    func applyModelGuidance(_ review: ModelGuidanceReview, role: UseCase, enableEndpoint: Bool) async throws -> String {
        let fresh = try await reviewModelGuidance(evidence: review.evidence, taskID: review.taskID, path: review.candidate.modelPath)
        try ModelGuidanceAction.validateApplication(review: review, fresh: fresh, role: role,
            enableEndpoint: enableEndpoint, comparisonActive: comparison.activeRunID != nil)
        try savePreferredModel(fresh.candidate.modelPath, for: role)
        let saved = "Saved \(fresh.candidate.name) as preferred for \(role.title)."
        guard enableEndpoint else { return saved }
        if fresh.endpoint.enabled && fresh.endpoint.modelPath == fresh.candidate.modelPath {
            return "\(saved) Endpoint already configured for this model; check Run for its current status."
        }
        if fresh.endpoint.enabled { await endpoint.swap(to: fresh.candidate.modelPath) }
        else { await endpoint.enable(modelPath: fresh.candidate.modelPath, port: fresh.endpoint.port) }
        if let problem = endpoint.persistenceError ?? endpoint.lastError {
            throw WorkflowEvidenceError.invalid("\(saved) Endpoint needs attention: \(problem)")
        }
        if case .degraded(let reason) = endpoint.state {
            throw WorkflowEvidenceError.invalid("\(saved) Endpoint needs attention: \(reason)")
        }
        if case .running(let path, let port) = endpoint.state, path == fresh.candidate.modelPath {
            return "\(saved) Endpoint running on port \(port)."
        }
        return "\(saved) Endpoint requested; check Run for its current status."
    }

    /// Paths that must never be reclaimed: running servers and the active
    /// conversion's source/output.
    var occupiedModelPaths: Set<String> {
        var occupied = Set(modelWorkflow.servers.filter { $0.state?.lowercased() == "running" }.flatMap { [$0.repo, $0.path].compactMap { $0 } })
        occupied.formUnion(endpoint.fleet.slots.filter(\.enabled).map(\.modelPath))
        occupied.formUnion(recommendationPreferences.preferredModelIDs.values)
        if let path = verification.activeModelPath { occupied.insert(path) }
        if case .generating(let path, _) = imageGeneration.state { occupied.insert(path) }
        if let id = comparison.activeRunID, let run = comparison.runs.first(where: { $0.id == id }) {
            occupied.formUnion(run.variants)
        }
        if modelWorkflow.workflow.state == .queued || modelWorkflow.workflow.state == .running {
            occupied.insert(modelWorkflow.workflow.outputPath)
            occupied.insert(modelWorkflow.workflow.sourcePath)
        }
        // Canonicalize local paths and protect every cache snapshot sharing an active repo identity.
        let canonical = Set(occupied.filter { $0.hasPrefix("/") }.map { Quarantine.resolve($0) })
        for model in librarySnapshot?.models ?? [] {
            if canonical.contains(Quarantine.resolve(model.item.path)) || HFRepoID.forPath(model.item.path).map({ occupied.contains($0) }) == true {
                occupied.insert(model.item.path)
            }
        }
        return occupied
    }

    /// Apply the premium feature toggles from the current config: attach or
    /// detach the quality gate, start or stop watch monitoring. Idempotent;
    /// called at app launch and after every config save.
    func applyFeatureToggles() {
        // Prewarm the environment fingerprint probe off the main thread;
        // the render path (recommendations) must never spawn a process.
        WatchCoordinator.prewarmEnvironmentProbe()
        if config.verificationEnabled {
            verification.attach(to: modelWorkflow)
        } else {
            verification.detach(from: modelWorkflow)
        }
        if config.watchEnabled {
            watch.startMonitoring()
        } else {
            watch.stopMonitoring()
        }
    }

    /// Recompute Disk Pressure Advisor opportunities from the latest
    /// snapshot, duplicate groups, usage evidence, and verification status.
    func analyzeReclaim() {
        reclaim.analyze(
            snapshot: librarySnapshot,
            duplicates: scanResult?.duplicates ?? [],
            lastUsedByPath: usage.lastUsedByPath,
            isVerified: { [weak self] path in self?.isModelVerified(path) ?? false },
            occupiedPaths: occupiedModelPaths,
            staleDays: config.reclaimStaleDays,
            measuredSuperseded: ComparisonInsights.superseded(models: librarySnapshot?.models ?? [], runs: comparison.runs, workflow: workflowEvidence.records, environment: watch.currentFingerprintDescription, protected: occupiedModelPaths)
        )
    }

    /// Provenance timeline for one model, assembled read-only from the
    /// stores the app already keeps (premium spec 07).
    func lineage(for path: String) -> ModelLineage {
        let canonicalPath = Quarantine.resolve(path)
        let item = librarySnapshot?.models.first(where: {
            Quarantine.resolve($0.item.path) == canonicalPath
                || $0.outputPaths.contains(where: { Quarantine.resolve($0) == canonicalPath })
        })?.item
        return LineageIndexer.assemble(
            modelPath: path,
            item: item,
            workflows: modelWorkflow.history,
            reports: verification.reports,
            runs: comparison.runs,
            lastUsedByPath: usage.lastUsedByPath,
            transactions: wiring.transactions,
            quarantineRecords: Quarantine.ledger(quarantineDir: config.quarantineDir)
        )
    }
}
