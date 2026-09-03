import Foundation
import XCTest

@testable import mlx_workbench

final class AppHostHealthTests: XCTestCase {
    func testNormalizeAgentPathTrimsWhitespace() async {
        let result = await MainActor.run { AppHost.normalizeAgentPath("  /tmp/mlx ") }
        XCTAssertEqual(result, "/tmp/mlx")
    }

    func testCheckAgentHealthReturnsNotConfiguredForBlankPath() async {
        let result = await MainActor.run { AppHost.checkAgentHealth(path: " \n\t ", cli: CLIProcess()) }
        XCTAssertEqual(result, .notConfigured)
    }

    func testCheckAgentHealthAcceptsLeadingAndTrailingWhitespace() async throws {
        let tmp = try makeTempDirectory()
        defer { cleanup(tmp) }

        let scriptsPath = tmp.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsPath, withIntermediateDirectories: true)
        let scriptPath = scriptsPath.appendingPathComponent("mlx-agent", isDirectory: false)
        FileManager.default.createFile(atPath: scriptPath.path, contents: Data("print('ok')".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath.path)
        }

        let result = await MainActor.run { AppHost.checkAgentHealth(path: "  \(tmp.path)  ", cli: CLIProcess()) }
        XCTAssertEqual(result, .ready(path: tmp.path, cli: scriptPath.path))
    }

    func testCheckAgentHealthRejectsDirectoryWhereScriptPathShouldBeFile() async throws {
        let tmp = try makeTempDirectory()
        defer { cleanup(tmp) }

        let scriptDir = tmp.appendingPathComponent("scripts/mlx-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let result = await MainActor.run { AppHost.checkAgentHealth(path: tmp.path, cli: CLIProcess()) }
        switch result {
        case .notFound(let path, let cliPath):
            XCTAssertEqual(path, tmp.path)
            XCTAssertEqual(cliPath, scriptDir.path)
        default:
            XCTFail("expected notFound when mlx-agent is a directory, got \(result)")
        }
    }

    func testCLIProcessNormalizesPathBeforeHealthCheck() async throws {
        let tmp = try makeTempDirectory()
        defer { cleanup(tmp) }

        let scriptsPath = tmp.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsPath, withIntermediateDirectories: true)
        let scriptPath = scriptsPath.appendingPathComponent("mlx-agent", isDirectory: false)
        FileManager.default.createFile(atPath: scriptPath.path, contents: Data("print('ok')".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath.path)
        }

        let health = await MainActor.run { CLIProcess().agentHealth(agentPath: "  \(tmp.path)  ") }
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.path, tmp.path)
        XCTAssertEqual(health.cli, scriptPath.path)
    }

    func testCatalogRefreshFailurePreservesCorruptStateAndActualDetail() async throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }

        let store = CatalogStore(appSupportDirectory: { root })
        let cacheDirectory = store.cacheURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.cacheURL())

        let client = CatalogClient(
            provider: ThrowingCatalogProvider(error: .invalidPayload("fixture payload rejected"))
        )
        let host = await MainActor.run {
            AppHost(
                catalogStore: store,
                catalogClient: client,
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }

        await host.refreshCatalog()

        let state = await MainActor.run { host.catalog }
        switch state {
        case .corrupt(let message):
            XCTAssertTrue(message.contains("Metadata validation failed: fixture payload rejected"))
            XCTAssertFalse(message.contains("(message)"))
        default:
            XCTFail("expected corrupt state with refresh detail, got \(state)")
        }
    }

    func testCatalogMissingCacheReflectsProviderConfiguration() async throws {
        let configuredRoot = try makeTempDirectory()
        let unconfiguredRoot = try makeTempDirectory()
        defer {
            cleanup(configuredRoot)
            cleanup(unconfiguredRoot)
        }

        let configuredHost = await MainActor.run {
            AppHost(
                catalogStore: CatalogStore(appSupportDirectory: { configuredRoot }),
                catalogClient: CatalogClient(provider: StaticCatalogProvider()),
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }
        let unconfiguredHost = await MainActor.run {
            AppHost(
                catalogStore: CatalogStore(appSupportDirectory: { unconfiguredRoot }),
                catalogClient: CatalogClient(),
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }

        let configuredState = await MainActor.run { configuredHost.catalog }
        let unconfiguredState = await MainActor.run { unconfiguredHost.catalog }

        XCTAssertEqual(configuredState, .missing)
        switch unconfiguredState {
        case .unavailable(let message):
            XCTAssertFalse(message.isEmpty)
        default:
            XCTFail("expected unavailable state without a provider, got \(unconfiguredState)")
        }
    }

    func testRefreshWithoutProviderAndCacheRemainsUnavailable() async throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }

        let host = await MainActor.run {
            AppHost(
                catalogStore: CatalogStore(appSupportDirectory: { root }),
                catalogClient: CatalogClient(),
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }

        await host.refreshCatalog()

        let state = await MainActor.run { host.catalog }
        switch state {
        case .unavailable(let message):
            XCTAssertFalse(message.isEmpty)
        default:
            XCTFail("expected unavailable state after no-provider refresh, got \(state)")
        }
    }

    func testRefreshFailurePreservesCurrentAndStaleFreshness() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let currentRoot = try makeTempDirectory()
        let staleRoot = try makeTempDirectory()
        defer {
            cleanup(currentRoot)
            cleanup(staleRoot)
        }

        let currentStore = CatalogStore(appSupportDirectory: { currentRoot })
        try currentStore.save(makeSnapshot(fetchedAt: now.addingTimeInterval(-1)))
        let staleStore = CatalogStore(appSupportDirectory: { staleRoot })
        try staleStore.save(makeSnapshot(fetchedAt: now.addingTimeInterval(-CatalogFreshness.metadataTTL - 1)))

        let failingClient = CatalogClient(
            provider: ThrowingCatalogProvider(error: .unavailable("fixture provider offline"))
        )
        let currentHost = await MainActor.run {
            AppHost(
                catalogStore: currentStore,
                catalogClient: failingClient,
                config: Config.defaults(),
                now: { now }
            )
        }
        let staleHost = await MainActor.run {
            AppHost(
                catalogStore: staleStore,
                catalogClient: failingClient,
                config: Config.defaults(),
                now: { now }
            )
        }

        await currentHost.refreshCatalog()
        await staleHost.refreshCatalog()

        let currentState = await MainActor.run { currentHost.catalog }
        let staleState = await MainActor.run { staleHost.catalog }
        switch currentState {
        case .currentFailure(_, let message):
            XCTAssertTrue(message.contains("fixture provider offline"))
        default:
            XCTFail("expected current freshness after refresh failure, got \(currentState)")
        }
        switch staleState {
        case .staleFailure(_, let message):
            XCTAssertTrue(message.contains("fixture provider offline"))
        default:
            XCTFail("expected stale freshness after refresh failure, got \(staleState)")
        }
    }

    func testActivityPresentationRendersQueuedRunningCompletedAndFailedCards() {
        XCTAssertEqual(ActivityWorkflowCardPresentation(workflow: makeOperationalWorkflow(state: .queued), job: nil, snapshot: nil).stateTitle, "Queued")
        XCTAssertEqual(ActivityWorkflowCardPresentation(workflow: makeOperationalWorkflow(state: .running), job: nil, snapshot: nil).stateTitle, "Running")
        XCTAssertEqual(ActivityWorkflowCardPresentation(workflow: makeOperationalWorkflow(state: .completed), job: nil, snapshot: nil).stateTitle, "Completed")
        XCTAssertEqual(ActivityWorkflowCardPresentation(workflow: makeOperationalWorkflow(state: .failed, errorMessage: "converter exited 9"), job: nil, snapshot: nil).workflow.errorMessage, "converter exited 9")
    }

    func testActivityCompletedOutputRoutesToLibraryAndRun() {
        let model = makeOperationalModel(path: "/models/atlas-mlx", status: "ready")
        let workflow = makeOperationalWorkflow(state: .completed, completedModelPath: model.item.path)
        let card = ActivityWorkflowCardPresentation(workflow: workflow, job: nil, snapshot: makeOperationalSnapshot(models: [model]))
        XCTAssertEqual(card.actions, [.openInLibrary(model.item.path), .runModel(workflow)])
    }

    func testActivityFailureOffersRetryPreview() {
        let workflow = makeOperationalWorkflow(state: .failed, errorMessage: "failed exactly")
        let source = makeOperationalModel(path: workflow.sourcePath, status: "pending").item
        let card = ActivityWorkflowCardPresentation(
            workflow: workflow,
            job: nil,
            snapshot: nil,
            sourceEvidence: source,
            agentReady: true,
            convertRuntimeReady: true
        )
        XCTAssertEqual(card.actions, [.retryPreview(workflow)])
    }

    func testActivityRetryRequiresCurrentUsableSourceAndPrerequisites() {
        let workflow = makeOperationalWorkflow(state: .failed, errorMessage: "historic failure")
        let source = makeOperationalModel(path: workflow.sourcePath, status: "pending").item

        XCTAssertFalse(ActivityWorkflowCardPresentation(workflow: workflow, job: nil, snapshot: nil).actions.contains(.retryPreview(workflow)))
        XCTAssertFalse(ActivityWorkflowCardPresentation(workflow: workflow, job: nil, snapshot: nil, sourceEvidence: source, agentReady: false, convertRuntimeReady: true).actions.contains(.retryPreview(workflow)))
        XCTAssertFalse(ActivityWorkflowCardPresentation(workflow: workflow, job: nil, snapshot: nil, sourceEvidence: source, agentReady: true, convertRuntimeReady: false).actions.contains(.retryPreview(workflow)))
    }

    func testRunPresentationShowsAuthoritativeActiveServer() {
        let model = makeOperationalModel(path: "/models/atlas-mlx", status: "ready")
        let server = ServerInfo(repo: model.item.path, runtime: "mlx_lm", port: 8766, pid: 412, state: "running", logPath: "/logs/serve.log", startedAt: "2026-08-25T12:00:00Z", receipt: "serve-receipt")
        let presentation = RunPresentation(workflow: makeOperationalWorkflow(state: .completed, serveState: .running, completedModelPath: model.item.path), model: model, servers: [server], runtimeAvailable: true, runtimeMessage: "ready")
        XCTAssertEqual(presentation.modelPath, model.item.path)
        XCTAssertEqual(presentation.activeServer?.port, 8766)
        XCTAssertEqual(presentation.activeServer?.pid, 412)
        XCTAssertEqual(presentation.activeServer?.receipt, "serve-receipt")
        XCTAssertEqual(presentation.activeServer?.logPath, "/logs/serve.log")
    }

    func testRunPresentationExplainsMissingRuntime() {
        let presentation = RunPresentation(workflow: makeOperationalWorkflow(state: .completed, completedModelPath: "/models/atlas-mlx"), model: makeOperationalModel(path: "/models/atlas-mlx", status: "ready"), servers: [], runtimeAvailable: false, runtimeMessage: "mlx_lm.server is missing")
        XCTAssertEqual(presentation.remediation, "mlx_lm.server is missing")
        XCTAssertFalse(presentation.canPreview)
        XCTAssertFalse(presentation.canConfirm)
    }

    func testRunPresentationRejectsArbitraryReadyLibrarySelection() {
        let selected = makeOperationalModel(path: "/models/arbitrary-mlx", status: "ready")
        let workflow = makeOperationalWorkflow(
            state: .completed,
            serveState: .readyToConfirm,
            completedModelPath: "/models/atlas-mlx"
        )
        let presentation = RunPresentation(
            workflow: workflow,
            model: selected,
            servers: [],
            runtimeAvailable: true,
            runtimeMessage: "ready"
        )

        XCTAssertNil(presentation.modelPath)
        XCTAssertFalse(presentation.canPreview)
        XCTAssertFalse(presentation.canConfirm)
        XCTAssertNotNil(presentation.selectionError)
    }

    func testRunPresentationMatchesOnlySelectedModelsServer() {
        let model = makeOperationalModel(path: "/models/atlas-mlx", status: "ready")
        let unrelated = ServerInfo(repo: "/models/other-mlx", runtime: "mlx_lm", port: 9001, pid: 1, state: "running", logPath: "/logs/other.log", startedAt: nil, receipt: "other")
        let selected = ServerInfo(repo: model.item.path, runtime: "mlx_lm", port: 9002, pid: 2, state: "running", logPath: "/logs/selected.log", startedAt: nil, receipt: "selected")
        let workflow = makeOperationalWorkflow(state: .completed, completedModelPath: model.item.path)

        let multiple = RunPresentation(workflow: workflow, model: model, servers: [unrelated, selected], runtimeAvailable: true, runtimeMessage: "ready")
        XCTAssertEqual(multiple.activeServer, selected)
        XCTAssertFalse(multiple.canPreview)

        let unrelatedOnly = RunPresentation(workflow: workflow, model: model, servers: [unrelated], runtimeAvailable: true, runtimeMessage: "ready")
        XCTAssertNil(unrelatedOnly.activeServer)
        XCTAssertTrue(unrelatedOnly.canPreview)
    }

    @MainActor
    func testCoordinatorStopsOnlySelectedModelsServer() async {
        let unrelated = ServerInfo(repo: "/models/other-mlx", runtime: "mlx_lm", port: 9001, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "other")
        let selected = ServerInfo(repo: "/models/atlas-mlx", runtime: "mlx_lm", port: 9002, pid: 2, state: "running", logPath: nil, startedAt: nil, receipt: "selected")
        var stoppedPorts: [Int] = []
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [unrelated, selected] },
            serveStop: { port in
                stoppedPorts.append(port)
                return [:]
            }
        )
        let coordinator = ModelWorkflowCoordinator(
            api: api,
            persistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
        )

        await coordinator.refreshOperationalStatus()
        await coordinator.stopServer(modelPath: "/models/atlas-mlx")

        XCTAssertEqual(stoppedPorts, [9002])
    }

    func testHomeNextActionForNoRootsIsConfiguration() {
        let action = makeHomeAction(rootsConfigured: false)
        XCTAssertEqual(action.kind, .configure)
        XCTAssertEqual(action.route, "settings")
    }

    func testHomeNextActionForNoScanIsLibraryScan() {
        let action = makeHomeAction(snapshot: nil)
        XCTAssertEqual(action.kind, .scan)
        XCTAssertEqual(action.route, "models")
    }

    func testHomeNextActionForActiveJobIsActivity() {
        let action = makeHomeAction(workflow: makeOperationalWorkflow(state: .running, receipt: "receipt"))
        XCTAssertEqual(action.kind, .activity)
        XCTAssertEqual(action.route, "jobs")
        XCTAssertEqual(action.reason, "A conversion is running; Activity has the authoritative receipt and live status.")
    }

    func testHomeNextActionForCompletedOutputIsRun() {
        let model = makeOperationalModel(path: "/models/atlas-mlx", status: "ready")
        let action = makeHomeAction(
            workflow: makeOperationalWorkflow(state: .completed, completedModelPath: model.item.path),
            snapshot: makeOperationalSnapshot(models: [model])
        )
        XCTAssertEqual(action.kind, .run("/models/atlas-mlx"))
        XCTAssertEqual(action.route, "serve")
    }

    func testHomeDoesNotRunArbitraryReadyLibraryModel() {
        let model = makeOperationalModel(path: "/models/arbitrary-mlx", status: "ready")
        let action = makeHomeAction(snapshot: makeOperationalSnapshot(models: [model]))
        XCTAssertEqual(action.kind, .library)
        XCTAssertEqual(action.route, "models")
    }

    func testHomeNextActionForFailureIsActivityWithExactReason() {
        let action = makeHomeAction(workflow: makeOperationalWorkflow(state: .failed, errorMessage: "receipt reported conversion failure"))
        XCTAssertEqual(action.kind, .activity)
        XCTAssertEqual(action.reason, "receipt reported conversion failure")
        XCTAssertEqual(action.route, "jobs")
    }

    func testDiscoverGgufRootsIncludesHiddenModelsDirectory() throws {
        let home = try makeTempDirectory()
        defer { cleanup(home) }
        let hiddenModels = home.appendingPathComponent(".models", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenModels, withIntermediateDirectories: true)

        XCTAssertEqual(Config.discoverGgufRoots(home: home), [hiddenModels.path])
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeOperationalWorkflow(
        state: ConversionWorkflowState = .idle,
        serveState: ServeWorkflowState = .idle,
        receipt: String? = nil,
        completedModelPath: String? = nil,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        let timestamp = Date(timeIntervalSince1970: 1_756_120_000)
        return ConversionWorkflow(
            id: UUID(), sourcePath: "/models/atlas.gguf", sourceModelKey: "atlas", sourceSignature: "signature",
            outputPath: "/models/atlas-mlx", previewHash: nil, jobReceipt: receipt, completedModelPath: completedModelPath,
            state: state, serveState: serveState, message: nil, errorMessage: errorMessage,
            createdAt: timestamp, updatedAt: timestamp, lastKnownAgentState: state.rawValue
        )
    }

    private func makeOperationalModel(path: String, status: String) -> LibraryModel {
        LibraryModel(
            item: ModelItem(
                path: path, name: "Atlas", bytes: 4_096, modifiedAt: 1_756_120_000, shard: nil,
                modelKey: "atlas", architecture: "llama", quantization: "4-bit", parameters: "7B",
                structure: nil, signature: "signature", companion: nil, readable: true, status: status,
                outputs: [], tensorCount: 32, error: nil
            ),
            normalizedFamilyKey: "atlas",
            displayName: "Atlas"
        )
    }

    private func makeOperationalSnapshot(models: [LibraryModel] = []) -> LibrarySnapshot {
        LibrarySnapshot(
            models: models,
            groups: [],
            hardware: HardwareProfile(chip: "M4", model: "Mac16,1", memoryBytes: 32_000_000_000, macOSVersion: "15.0"),
            generatedAt: Date(timeIntervalSince1970: 1_756_120_000)
        )
    }

    private func makeHomeAction(
        workflow: ConversionWorkflow? = nil,
        snapshot: LibrarySnapshot? = LibrarySnapshot(
            models: [], groups: [],
            hardware: HardwareProfile(chip: "M4", model: "Mac16,1", memoryBytes: 32_000_000_000, macOSVersion: "15.0"),
            generatedAt: Date(timeIntervalSince1970: 1_756_120_000)
        ),
        rootsConfigured: Bool = true
    ) -> HomeNextAction {
        HomeNextAction.derive(
            workflow: workflow ?? makeOperationalWorkflow(), snapshot: snapshot,
            rootsConfigured: rootsConfigured, isScanning: false, lastError: nil,
            agentReady: true, convertRuntimeReady: true, serveRuntimeReady: true
        )
    }

    private func makeSnapshot(fetchedAt: Date) -> CatalogSnapshot {
        CatalogSnapshot(
            provider: "fixture-provider",
            source: "fixtures/catalog.json",
            revision: "fixture-revision",
            fetchedAt: fetchedAt,
            metadataOnly: true,
            records: []
        )
    }

    private struct StaticCatalogProvider: CatalogMetadataProviding {
        func fetchCatalogMetadata() async throws -> CatalogSnapshot {
            CatalogSnapshot(
                provider: "fixture-provider",
                source: "fixtures/catalog.json",
                revision: "fixture-revision",
                fetchedAt: Date(timeIntervalSinceReferenceDate: 100),
                metadataOnly: true,
                records: []
            )
        }
    }

    private struct ThrowingCatalogProvider: CatalogMetadataProviding {
        let error: CatalogClientError

        func fetchCatalogMetadata() async throws -> CatalogSnapshot {
            throw error
        }
    }
}
