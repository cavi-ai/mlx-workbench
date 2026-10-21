import Foundation
import Observation

// MARK: - AppHost

@MainActor
@Observable
class AppHost {
    var config: Config = Config.defaults(ggufRoots: [])
    var agentHealth: AgentHealth = .notConfigured
    var runtimeReport: RuntimeReport
    private(set) var isCheckingRuntime = false
    var discoveredRoots: [String] = []
    var vendorAgentPath: String = ""
    var configPath: String = ""
    var isScanning = false
    var scanResult: ScanResult?
    private(set) var scanError: String?
    var librarySnapshot: LibrarySnapshot? {
        didSet {
            HFRepoID.forgetResolvedPaths()
            occupancyLibrary = (librarySnapshot?.models.map(\.item.path) ?? []).map {
                ModelOccupancy.LibraryPath(path: $0, key: HFRepoID.Identity($0))
            }
        }
    }
    private var occupancyLibrary: [ModelOccupancy.LibraryPath] = []
    /// The effective roots `librarySnapshot` was scanned from; nil until a scan succeeds.
    var scannedRoots: ScanRoots?
    var catalog: CatalogState
    var isRefreshingCatalog = false
    var selectedModelPath: String?
    /// Cross-tab requests, applied by their destination route while it is active.
    var handoffs = RouteHandoffs()
    var benchmarkResults: [RecommendationBenchmarkResult] = []
    var recommendationPreferences: RecommendationPreferences = .defaults
    var hardwareProfile: HardwareProfile
    var lastError: String?
    var modelWorkflow: ModelWorkflowCoordinator
    /// Conversion Quality Gate. Attached to the workflow by the app entry
    /// point via `verification.attach(to: modelWorkflow)`.
    let verification: VerificationCoordinator
    /// Measured Comparisons (prompt-set replay across variants).
    let comparison: ComparisonCoordinator
    let modelHosts: ModelHostsCoordinator
    let hostedComparison: HostedComparisonCoordinator
    var compareHostedModels = false
    var hostedComparisonTargets: [HostedComparisonTarget] = []
    let servingProfiles: ServingProfileCoordinator
    let lab: LabCoordinator
    /// Cross-client wiring transactions (premium spec 02).
    let wiring: WiringCoordinator
    /// Always-on endpoint supervisor (premium spec 06).
    let endpoint: EndpointSupervisor
    let resources: SystemResourceMonitor
    /// Usage evidence per model path (premium spec 04).
    let usage: UsageTracker
    let workflowEvidence: WorkflowEvidenceStore
    /// Disk Pressure Advisor apply surface (premium spec 04).
    let reclaim: ReclaimCoordinator
    /// Watch & regression alerts (premium spec 08).
    let watch: WatchCoordinator
    /// Guided runtime setup (make install runner). Only actionable when a
    /// checkout is known; see WorkbenchPython.repoRoot().
    let runtimeInstaller: RuntimeInstaller
    /// Hugging Face intake sheet state (verdict, backend install, downloads).
    let intake: IntakeCoordinator
    let trainedAdapters: TrainedAdapterServingCoordinator
    /// First-launch setup assistant state (persisted once completed).
    let setup: SetupCoordinator
    /// In-app updates (official tags or beta/main) for checkout-run installs.
    let updater: UpdateCoordinator

    let api: WorkbenchAPI
    let inferenceTasks: InferenceTaskCoordinator

    private let configModule: ConfigModule
    private let cli: CLIProcess
    private let catalogStore: CatalogStore
    private let catalogClient: any CatalogRefreshing
    private let catalogTTL: TimeInterval
    private let preferencesStore: JSONStore<RecommendationPreferences>
    private let now: @Sendable () -> Date
    private let scanOperation: @Sendable ([String], [String], Bool, Int?) async throws -> ScanResult
    private let libraryBuildOperation: @Sendable (ScanResult, HardwareProfile, Date) -> LibrarySnapshot
    private let runtimeProbe: @Sendable () -> RuntimeReport
    private var runtimeCheckGeneration = UUID()
    private var runtimeCheckTask: Task<Void, Never>?
    private let runtimeCheckQueue = DispatchQueue(label: "runtime-checks", qos: .utility)

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
        libraryBuildOperation: @escaping @Sendable (ScanResult, HardwareProfile, Date) -> LibrarySnapshot = {
            ModelLibraryBuilder.build(scan: $0, hardware: $1, now: $2)
        },
        modelWorkflowAPI: ModelWorkflowAPI? = nil,
        modelWorkflowPersistence: ModelWorkflowPersistence? = nil,
        verification: VerificationCoordinator? = nil,
        comparison: ComparisonCoordinator? = nil,
        modelHosts: ModelHostsCoordinator? = nil,
        hostedComparison: HostedComparisonCoordinator? = nil,
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
        intakeAPI: IntakeAPI? = nil,
        inferenceTasks: InferenceTaskCoordinator? = nil,
        runtimeProbe: @escaping @Sendable () -> RuntimeReport = { RuntimeChecker.report() }
    ) {
        self.configModule = configModule
        self.runtimeProbe = runtimeProbe
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
        self.inferenceTasks = inferenceTasks ?? InferenceTaskCoordinator(api: api, artifactRoot: api.taskArtifactsRoot)
        self.lab = LabCoordinator(api: api)
        self.resources = SystemResourceMonitor(statusProvider: { try await api.serveStatus() })
        let profiles = ServingProfileCoordinator(store: JSONStore(fileURL: JSONStore<ServingProfile>.defaultFileURL("serving-profiles.json")),
            probe: { options in ServeProbe(lifecycle: .live(api: api, runtime: "strata", strataOptions: options),
                prober: OpenAIEndpointProber(requestTimeout: 900), readyTimeout: 900) })
        self.servingProfiles = profiles
        profiles.memoryPreview = { profile in
            try await api.servePreview(repo: profile.modelPath, runtime: "strata", port: nil,
                strataOptions: profile.options, timeout: 30)
        }
        self.modelWorkflow = ModelWorkflowCoordinator(
            api: modelWorkflowAPI ?? .live(api: api, resolveProfile: { try profiles.resolve($0) }),
            persistence: modelWorkflowPersistence ?? .live(store: ModelWorkflowStore(fileURL: ModelWorkflowStore.defaultFileURL()))
        )
        self.verification = verification ?? VerificationCoordinator(
            probe: ServeProbe(
                // Canaries judge the answer path; reasoning is switched off where the template allows.
                lifecycle: .live(api: api, thinkingOff: true),
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
            loadHistoryInBackground: true,
            indexedHistory: true,
            mediaRunner: LiveComparisonMediaRunner(api: api),
            outputStore: ComparisonOutputStore(),
            recoverCleanup: { try await api.recoverComparisonServer($0) },
            strataProbe: { options in ServeProbe(lifecycle: .live(api: api, runtime: "strata", strataOptions: options),
                prober: OpenAIEndpointProber(requestTimeout: 900)) }
        )
        let hosts = modelHosts ?? ModelHostsCoordinator()
        self.modelHosts = hosts
        self.hostedComparison = hostedComparison ?? HostedComparisonCoordinator(
            nativeProbe: ServeProbe(lifecycle: .live(api: api), prober: OpenAIEndpointProber()),
            readToken: { try hosts.token(for: $0) },
            recoverCleanup: { try await api.recoverComparisonServer($0) },
            loadHistoryInBackground: true, indexedHistory: true)
        self.wiring = wiring ?? WiringCoordinator(
            home: WorkbenchStatePaths.userHome(),
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
        self.runtimeInstaller = runtimeInstaller ?? RuntimeInstaller(checkRuntime: {
            await Task.detached(priority: .utility) { RuntimeChecker.report() }.value
        }, checkPrerequisites: { root in await RuntimeInstaller.inspectPrerequisites(root: root) })
        self.intake = IntakeCoordinator(api: intakeAPI ?? .live(api: api))
        self.trainedAdapters = TrainedAdapterServingCoordinator(api: .live(api))
        self.setup = setup ?? SetupCoordinator()
        self.updater = updater ?? UpdateCoordinator(installed: .running())
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
        self.discoveredRoots = discoveredRoots ?? []
        self.configPath = configPath ?? configModule.configPath()
        self.vendorAgentPath = vendorAgentPath ?? configModule.vendorAgentPath()
        self.agentHealth = agentHealth ?? Self.checkAgentHealth(path: loadedConfig.mlxAgentPath, cli: cli)
        self.runtimeReport = runtimeReport ?? .checking
        self.isCheckingRuntime = runtimeReport == nil
        self.hardwareProfile = hardwareProfile
        let initialNow = now()
        self.now = now
        self.libraryBuildOperation = libraryBuildOperation
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
        hosts.resourceUseBlocked = { [weak self] in
            guard let self else { return true }
            return self.hostedComparison.activeRunID != nil || self.comparison.activeRunID != nil
        }
        self.hostedComparison.validateTarget = { [weak self] target in
            guard let self, self.comparison.activeRunID == nil, !self.modelHosts.resourceBusy else {
                throw HostedIntegrationError.invalid("Finish the active comparison or host memory operation before starting hosted lanes.")
            }
            if let host = target.host {
                guard self.modelHosts.hosts.contains(host) else {
                    throw HostedIntegrationError.invalid("The host configuration changed. Refresh and select the model again.")
                }
            } else if let path = target.localPath {
                guard let model = self.librarySnapshot?.models.first(where: { $0.item.path == path }),
                      model.item.signature == target.localSignature,
                      ComparePresentation.candidates(from: [model]).count == 1 else {
                    throw HostedIntegrationError.invalid("The local model changed or is no longer ready. Scan and select it again.")
                }
            }
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
        self.endpoint.profileLifecycle = { profile in .verifiedProfile(try profiles.resolve(profile), api: api) }
        profiles.suggestionSource = { [weak self] run in
            guard let comparison = self?.comparison else { throw WorkflowEvidenceError.invalid("Comparison results are unavailable.") }
            return try comparison.requireCurrentSuggestion(run)
        }
        profiles.comparisonSource = { [weak self] id in
            guard let comparison = self?.comparison else { throw WorkflowEvidenceError.invalid("Comparison results are unavailable.") }
            return try comparison.recordedRun(id: id)
        }
        profiles.measuredSource = { [weak self] run, laneID in
            guard let comparison = self?.comparison else { throw WorkflowEvidenceError.invalid("Comparison results are unavailable.") }
            return try comparison.requireCurrentProfileLane(run, laneID: laneID)
        }
        profiles.removalGuard = { [weak self] id in
            guard let endpoint = self?.endpoint else { throw WorkflowEvidenceError.invalid("Endpoint configuration is unavailable.") }
            try endpoint.requireUnreferencedProfile(id)
        }
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
                // A source outside the configured roots stays where it is; cleanup would only be refused.
                let isRepoSource = PrepareWorkflowPresentation(workflow: record).isRepoSource
                guard PrepareWorkflowPresentation.sourceCleanupIsPossible(
                    sourceLocation: record.localSourcePath ?? (isRepoSource ? nil : record.sourcePath),
                    roots: self.config.ggufRoots + self.config.mlxRoots
                ) else { return }
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
        self.reclaim.protectedPaths = { [weak self] in
            guard let self else { return [] }
            if !self.comparison.hasLoadedHistory {
                return Array(self.occupancy.protectedPaths) + self.reclaim.ggufRoots() + self.reclaim.mlxRoots()
            }
            return Array(self.occupancy.protectedPaths)
        }
        self.reclaim.servingModelPaths = { [weak self] in
            guard self?.comparison.hasLoadedHistory == true else {
                throw WorkflowEvidenceError.invalid("Saved comparison ownership is unavailable. Wait for history to load before reclaiming models.")
            }
            return try await api.servingPathsForRemoval()
        }
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

    /// Takes the pending Hosted models request once; a removed or edited connection must not select another host.
    func takeHostedModelsHost() throws -> ModelHost? {
        guard handoffs[.openHostedModels] != nil, let requested = handoffs.take(.openHostedModels)?.host else { return nil }
        guard modelHosts.hosts.contains(requested) else {
            throw HostedIntegrationError.invalid("The requested host connection changed or was removed. Select a host to continue.")
        }
        return requested
    }

    func requestRescan() {
        Task { await self.rescan() }
    }

    func modelRuntimeRecoveryIsCurrent(_ request: ModelRuntimeRecoveryRequest, source: String) -> Bool {
        handoffs[.recoverModelRuntime]?.id == request.id && config.mlxAgentPath == source
            && librarySnapshot?.models.contains(where: request.matches) == true
    }

    /// Return only after an authoritative scan; never substitute another model or start it.
    func returnFromRuntimeRecovery(_ request: ModelRuntimeRecoveryRequest, source: String) async throws {
        func failure(_ message: String) -> NSError {
            NSError(domain: "ModelRuntimeRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard modelRuntimeRecoveryIsCurrent(request, source: source) else {
            throw failure("The model or engine changed. Select the model again in Library.")
        }
        guard !isScanning else { throw failure("A library scan is already running. Wait for it to finish, then return to the model.") }
        guard let snapshot = await rescan(limit: nil, reconcileWorkflow: false) else {
            throw failure(lastError ?? "The model inventory could not be refreshed. Retry Return to model.")
        }
        guard config.mlxAgentPath == source, handoffs[.recoverModelRuntime]?.id == request.id,
              snapshot.models.contains(where: request.matches) else {
            throw failure("The original model is missing or changed in the refreshed library. Select it again in Library.")
        }
        selectedModelPath = request.modelPath
        handoffs.send(LibraryRevealRequest(modelPath: request.modelPath), as: .revealModel)
        handoffs.finish(request, as: .recoverModelRuntime)
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
        let ready = IntakeLibraryMatch.readyPaths(in: librarySnapshot)
        guard let path = IntakeCoordinator.existingModelPath(resolution, qBits: config.qBits, history: modelWorkflow.history, readyPaths: ready) else { return nil }
        selectedModelPath = path
        if resolution.verdict == .convertible {
            let conversion = IntakeCoordinator.existingConversion(resolution, qBits: config.qBits, history: modelWorkflow.history, readyPaths: ready)
            modelWorkflow.inspect(intake: resolution, outputDirectory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                  qBits: config.qBits, snapshot: librarySnapshot,
                                  downloadedPath: IntakeCoordinator.reusableSource(conversion?.localSourcePath, for: resolution))
            return .prepare
        }
        handoffs.send(LibraryRevealRequest(modelPath: path), as: .revealModel)
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
            if let downloadedPath { handoffs.send(LibraryRevealRequest(modelPath: downloadedPath), as: .revealModel) }
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
            handoffs.send(LibraryRevealRequest(modelPath: path), as: .revealModel)
            return .library
        default:
            return nil
        }
    }

    /// MLX roots the scan reads: configured roots plus the intake output dir,
    /// unless a root already contains it (scanning both lists every converted
    /// model twice). With no MLX roots configured the agent falls back to
    /// scanning the GGUF roots, so that fallback is spelled out first.
    nonisolated static func scanMLXRoots(_ config: Config, ggufRoots: [String], fileIdentity: (String) -> NSObject? = AppHost.fileIdentity) -> [String] {
        let output = config.outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return config.mlxRoots }
        var roots = config.mlxRoots.isEmpty ? ggufRoots : config.mlxRoots
        if !roots.contains(where: { isPath(output, within: $0, fileIdentity: fileIdentity) }) {
            roots.append(output)
        }
        return roots
    }

    /// True when the agent's walk of `root` reaches `path`: it lies at or under `root`
    /// (see `components(of:within:fileIdentity:)`) below no hidden or skipped folder.
    nonisolated static func isPath(_ path: String, within root: String, fileIdentity: (String) -> NSObject?) -> Bool {
        components(of: path, within: root, fileIdentity: fileIdentity).map { !LMStudioShelfResolver.isSkipped($0) } ?? false
    }

    /// Names from `root` down to where `path` resolves, or nil when that is not `root` or under it.
    /// Symlinks in `path` are followed, as the agent's walk never descends a symlinked folder;
    /// the root matches by file identity where it exists (a case-variant or symlinked spelling
    /// is that folder), by standardized path otherwise.
    nonisolated static func components(of path: String, within root: String, fileIdentity: (String) -> NSObject?) -> [String]? {
        let standardized = { (value: String) in URL(fileURLWithPath: NSString(string: value).expandingTildeInPath).standardizedFileURL }
        let rootURL = standardized(root)
        let rootPaths: Set<String> = [rootURL.path, resolvingSymlinks(rootURL).path]
        let rootIdentity = fileIdentity(rootURL.path)
        var names: [String] = []
        var candidate = resolvingSymlinks(standardized(path))
        while true {
            if rootPaths.contains(candidate.path) { return names }
            if let rootIdentity, let identity = fileIdentity(candidate.path), identity.isEqual(rootIdentity) { return names }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            names.insert(candidate.lastPathComponent, at: 0)
            candidate = parent
        }
    }

    /// `url` with symlinks resolved through its deepest existing folder, keeping the missing names below it.
    private nonisolated static func resolvingSymlinks(_ url: URL) -> URL {
        var existing = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { return url }
            missing.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// Identity of the file `path` names after following symlinks; nil when there is none.
    nonisolated static func fileIdentity(_ path: String) -> NSObject? {
        (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    private func rescan(limit: Int?, reconcileWorkflow: Bool) async -> LibrarySnapshot? {
        guard !isScanning else { return nil }
        if let scanError, lastError == scanError { lastError = nil }
        scanError = nil
        isScanning = true
        let scanConfig = config

        do {
            let (roots, mlxRoots) = await WorkbenchIO.perform {
                let roots = scanConfig.ggufRoots.isEmpty ? Config.discoverGgufRoots() : scanConfig.ggufRoots
                return (roots, Self.scanMLXRoots(scanConfig, ggufRoots: roots))
            }
            let scan = try await scanOperation(
                roots,
                mlxRoots,
                scanConfig.signatures,
                limit
            )
            guard !Task.isCancelled else { isScanning = false; return nil }
            let builder = libraryBuildOperation, hardware = hardwareProfile, capturedAt = now()
            let snapshot = await WorkbenchIO.perform { builder(scan, hardware, capturedAt) }
            guard !Task.isCancelled else { isScanning = false; return nil }
            guard config == scanConfig else {
                isScanning = false
                return await rescan(limit: limit, reconcileWorkflow: reconcileWorkflow)
            }
            scanResult = scan
            scanError = nil
            scannedRoots = ScanRoots(gguf: roots, mlx: mlxRoots)
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
            scanError = Self.render(error)
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
            let runtimeChanged = saved.mlxAgentPath != config.mlxAgentPath
            config = saved
            agentHealth = Self.checkAgentHealth(path: saved.mlxAgentPath, cli: cli)
            if runtimeChanged { refreshRuntimeReport() }
            lastError = nil
            applyFeatureToggles()
            return saved
        } catch {
            lastError = Self.render(error)
            return config
        }
    }

    /// Persist settings before changing the execution checkout or publishing the new configuration.
    func saveSettingsConfig(_ newConfig: Config) async -> Bool {
        do {
            let normalized = try Self.normalizeAndValidateForSave(newConfig)
            let saved = try configModule.saveSettings(normalized)
            await api.setAgentPath(saved.mlxAgentPath)
            config = saved
            agentHealth = Self.checkAgentHealth(path: saved.mlxAgentPath, cli: cli)
            await refreshRuntimeReport()?.value
            lastError = nil
            applyFeatureToggles()
            return true
        } catch {
            lastError = Self.render(error)
            return false
        }
    }

    /// Re-probe the convert/serve runtime (e.g. after a guided install).
    @discardableResult
    func refreshRuntimeReport(_ checkedReport: RuntimeReport? = nil) -> Task<Void, Never>? {
        runtimeCheckTask?.cancel()
        let generation = UUID()
        runtimeCheckGeneration = generation
        WatchCoordinator.invalidateEnvironmentProbe()
        if let checkedReport {
            runtimeReport = checkedReport
            isCheckingRuntime = false
            runtimeCheckTask = nil
            return nil
        }
        isCheckingRuntime = true
        runtimeReport = .checking
        let probe = runtimeProbe
        let queue = runtimeCheckQueue, cancellation = CLIInvocationCancellation()
        let task = Task { [weak self] in
            let checked: RuntimeReport? = await withTaskCancellationHandler {
                await WorkbenchIO.perform(on: queue) {
                    guard !cancellation.isRequested else { return nil }
                    return probe()
                }
            } onCancel: { cancellation.cancel() }
            guard let self, let checked, !Task.isCancelled, runtimeCheckGeneration == generation else { return }
            runtimeReport = checked
            isCheckingRuntime = false
            runtimeCheckTask = nil
        }
        runtimeCheckTask = task
        return task
    }

    var catalogRefreshUnavailableReason: String? {
        if !catalogClient.isConfigured { return catalogClient.unavailableMessage }
        return isRefreshingCatalog ? "Catalog metadata is being refreshed." : nil
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
            reserveGB: config.fitReserveGB, protected: occupancy.protectedPaths)
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

    /// The one stop/unload path for the toolbar and Run; models a run serves are refused.
    func unloadServing(_ server: ServerInfo) async -> Bool {
        guard comparison.hasLoadedHistory, !occupancy.blocksStop(server) else { return false }
        return await endpoint.unloadServer(server)
    }

    /// Run's stop for the selected model's server; a model a run serves is refused before any workflow call.
    func stopSelectedServer(modelPath: String) async -> Bool {
        guard comparison.hasLoadedHistory, !occupancy.blocksStop(modelIdentity: modelPath) else { return false }
        await modelWorkflow.stopServer(modelPath: modelPath)
        return true
    }

    /// Every model active work holds: running and endpoint servers, preferences,
    /// verification, comparisons, Library tasks and the active conversion.
    var occupancy: ModelOccupancy {
        var occupancy = ModelOccupancy(library: occupancyLibrary)
        occupancy.add(modelWorkflow.servers.filter { $0.state?.lowercased() == "running" }
            .flatMap { [$0.repo, $0.path].compactMap { $0 } }, for: .runningServer)
        occupancy.add(endpoint.fleet.slots.filter(\.enabled).map(\.modelPath), for: .endpoint)
        occupancy.add(recommendationPreferences.preferredModelIDs.values, for: .preference)
        occupancy.add([verification.activeModelPath].compactMap { $0 }, for: .verification)
        occupancy.add(inferenceTasks.activeModelPaths, for: .inferenceTask)
        if let id = hostedComparison.activeRunID, let record = hostedComparison.records.first(where: { $0.id == id }) {
            occupancy.add(record.targets.compactMap(\.localPath), for: .hostedComparison)
        }
        if let id = comparison.activeRunID, let run = comparison.runs.first(where: { $0.id == id }) {
            occupancy.add(run.variants, for: .comparison)
        }
        if modelWorkflow.workflow.state == .queued || modelWorkflow.workflow.state == .running {
            occupancy.add([modelWorkflow.workflow.outputPath, modelWorkflow.workflow.sourcePath], for: .conversion)
        }
        return occupancy
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

    /// Launch-time live work against the user's real config and state: the
    /// quality gate, watch and endpoint supervision, resource sampling, GGUF
    /// folder discovery, and the first scan with workflow reconciliation. Skipped
    /// in a hosted unit-test process so the suite never starts or stops real servers.
    @discardableResult
    func startLiveServices(environment: [String: String] = ProcessInfo.processInfo.environment) -> Task<Void, Never>? {
        guard !WorkbenchStatePaths.isHostedUnitTest(environment) else { return nil }
        if isCheckingRuntime { refreshRuntimeReport() }
        applyFeatureToggles()
        let startup = Task {
            await comparison.waitForHistory()
            if comparison.hasLoadedHistory { endpoint.startMonitoring() }
        }
        resources.startMonitoring()
        Task { await self.refreshDiscoveredRoots() }
        requestRescan()
        return startup
    }

    /// Default GGUF folders that Settings and Setup suggest, discovered off the main actor.
    func refreshDiscoveredRoots() async {
        discoveredRoots = await Task.detached(priority: .utility) { Config.discoverGgufRoots() }.value
    }

    /// Recompute Disk Pressure Advisor opportunities from the latest
    /// snapshot, duplicate groups, usage evidence, and verification status.
    func analyzeReclaim() {
        let protected = occupancy.protectedPaths
        reclaim.analyze(
            snapshot: librarySnapshot,
            duplicates: scanResult?.duplicates ?? [],
            lastUsedByPath: usage.lastUsedByPath,
            isVerified: { [weak self] path in self?.isModelVerified(path) ?? false },
            occupiedPaths: protected,
            staleDays: config.reclaimStaleDays,
            measuredSuperseded: ComparisonInsights.superseded(models: librarySnapshot?.models ?? [], runs: comparison.runs, workflow: workflowEvidence.records, environment: watch.currentFingerprintDescription, protected: protected)
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
