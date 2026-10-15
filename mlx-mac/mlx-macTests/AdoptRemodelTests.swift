import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum AdoptFixtures {
    static let totalBytes: Int64 = 137_438_953_472
    static let hardware = HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: totalBytes, macOSVersion: nil)
    static let repo = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    static let cachePath = "/render/.cache/huggingface/hub/models--mlx-community--Qwen3-Coder-30B-A3B-Instruct-4bit/snapshots/abc123"

    static func model(_ path: String, task: ModelTask? = nil, readiness: ModelReadiness = .ready) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 17_200_000_000,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "4bit", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil, task: task
        )
        return LibraryModel(item: item, readiness: readiness)
    }

    static func snapshot(_ models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: hardware, generatedAt: Date(timeIntervalSinceReferenceDate: 1_000_000_000))
    }

    static func response(model: String? = repo, status: String? = "complete", phase: String? = "recommended",
                         evidence: String? = "strong", message: String? = nil) -> AdoptResult {
        AdoptResult(
            state: "state.json", role: "coding", model: model, status: status, message: message, manager: nil,
            workflowID: nil, phase: phase, evidenceStrength: evidence
        )
    }
}

// MARK: - Presentation

final class AdoptPresentationTests: XCTestCase {
    private typealias F = AdoptFixtures

    func testAdoptStartAcceptsTheDiscoveryRoles() throws {
        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/mlx-agent/providers/codex/src/mlx_agent/cli.py")
        let source = try String(contentsOf: cli, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: #"start = actions.add_parser\("start""#, options: .regularExpression))
        let role = try XCTUnwrap(source[start.upperBound...].prefix(400).range(of: #"start.add_argument\("--role"[^\n]*choices=DISCOVERY_ROLES"#, options: .regularExpression))
        XCTAssertFalse(role.isEmpty)
    }

    func testIdleSentenceNamesTheDraftRole() {
        XCTAssertEqual(AdoptRecommendationState.idleSentence(role: "general"), "Verify and recommend to find a General model for this Mac.")
        XCTAssertEqual(AdoptRecommendationState.idleSentence(role: "tool-use"), "Verify and recommend to find a Tool use model for this Mac.")
    }

    func testLibraryMatchIsSharedWithDiscover() {
        let owned = F.model(F.cachePath), local = F.model("/models/local")
        let snapshot = F.snapshot([local, owned])
        let index = DiscoverPresentation.libraryModels(in: snapshot)
        XCTAssertEqual(Set(index.keys), [F.repo])
        XCTAssertEqual(DiscoverPresentation.libraryRepos(in: snapshot), [F.repo])
        XCTAssertEqual(DiscoverPresentation.libraryModel(for: F.repo, in: index)?.item.path, F.cachePath)
        XCTAssertNil(DiscoverPresentation.libraryModel(for: "other/repo", in: index))
        XCTAssertEqual(
            AdoptRecommendationState.make(response: F.response(), libraryModels: index, intakeIsBusy: false),
            AdoptRecommendationState.make(response: F.response(), library: snapshot, intakeIsBusy: false)
        )
    }

    func testRoleListExcludesAnyAndTitlesComeFromDiscover() {
        XCTAssertFalse(AdoptRole.choices.contains(""))
        XCTAssertTrue(AdoptRole.choices.contains(AdoptRole.initial))
        for role in AdoptRole.choices {
            XCTAssertEqual(AdoptRole.title(role), DiscoverRole.title(role))
        }
        XCTAssertEqual(AdoptRole.title("coding"), "Coding")
        XCTAssertEqual(AdoptRole.title("tool-use"), "Tool use")
    }

    func testOutcomeItemsAreVerbatimAndOmitAbsentFields() {
        XCTAssertEqual(AdoptOutcome.items(F.response()), [
            AdoptOutcomeItem(figure: "complete", label: "Status"),
            AdoptOutcomeItem(figure: "recommended", label: "Phase"),
            AdoptOutcomeItem(figure: "strong", label: "Evidence strength"),
        ])
        XCTAssertEqual(AdoptOutcome.items(F.response(status: "running", phase: nil, evidence: "")), [
            AdoptOutcomeItem(figure: "running", label: "Status"),
        ])
        XCTAssertEqual(AdoptOutcome.items(F.response(status: nil, phase: nil, evidence: nil)), [])
        XCTAssertEqual(AdoptOutcome.items(nil), [])
    }

    func testNoResponseIsIdle() {
        XCTAssertEqual(AdoptRecommendationState.make(response: nil, library: nil, intakeIsBusy: false), .idle)
    }

    func testResponseWithoutModelIsNoRecommendation() {
        for model in [nil, ""] as [String?] {
            XCTAssertEqual(
                AdoptRecommendationState.make(response: F.response(model: model), library: nil, intakeIsBusy: false),
                .noRecommendation
            )
        }
    }

    func testReadyServableLibraryModelOffersRun() {
        let model = F.model(F.cachePath)
        let state = AdoptRecommendationState.make(response: F.response(), library: F.snapshot([model]), intakeIsBusy: false)
        XCTAssertEqual(state, .recommended(repo: F.repo, step: .inLibrary(model: model, canRun: true)))
    }

    func testNonServableLibraryModelOffersNoRun() {
        let task = ModelTask(type: .speechToText, useCases: [], source: "registry", confidence: "confirmed")
        let model = F.model(F.cachePath, task: task)
        let state = AdoptRecommendationState.make(response: F.response(), library: F.snapshot([model]), intakeIsBusy: false)
        XCTAssertEqual(state, .recommended(repo: F.repo, step: .inLibrary(model: model, canRun: false)))
    }

    func testModelThatIsNotReadyOffersNoRun() {
        let model = F.model(F.cachePath, readiness: .needsConversion)
        let state = AdoptRecommendationState.make(response: F.response(), library: F.snapshot([model]), intakeIsBusy: false)
        XCTAssertEqual(state, .recommended(repo: F.repo, step: .inLibrary(model: model, canRun: false)))
    }

    func testRepoMissingFromLibraryOffersAddFromHuggingFace() {
        let other = F.model("/render/.cache/huggingface/hub/models--mlx-community--Other-4bit/snapshots/abc")
        for library in [nil, F.snapshot([other])] as [LibrarySnapshot?] {
            XCTAssertEqual(
                AdoptRecommendationState.make(response: F.response(), library: library, intakeIsBusy: false),
                .recommended(repo: F.repo, step: .addFromHuggingFace(
                    enabled: true, help: DiscoverIntakeAction.readyHelp
                ))
            )
        }
    }

    func testBusyIntakeDisablesAdd() {
        XCTAssertEqual(
            AdoptRecommendationState.make(response: F.response(), library: nil, intakeIsBusy: true),
            .recommended(repo: F.repo, step: .addFromHuggingFace(enabled: false, help: DiscoverIntakeAction.busyHelp))
        )
    }
}

// MARK: - Source

final class AdoptSourceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testAdoptViewPaintsNoSurfaceBackgroundAndKeepsTheLabelAsALabel() throws {
        let text = try source("AdoptView.swift")
        XCTAssertFalse(text.contains(".background(WorkbenchColor.surface)"))
        XCTAssertNil(text.range(of: #"Text\("Adopt a role"\)\s*\.font\(WorkbenchTypography\.title\)"#, options: .regularExpression))
        XCTAssertTrue(text.contains("WorkbenchSurface"))
    }

    func testOnlyTheFitViewObservesTheMemoryMonitor() throws {
        let text = try source("AdoptView.swift")
        XCTAssertEqual(text.components(separatedBy: "@ObservedObject var resources").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: ".borderedProminent").count - 1, 1)
    }
}

// MARK: - Renders

@MainActor
final class AdoptRenderTests: XCTestCase {
    private typealias F = AdoptFixtures

    func testDiscoverModesSwitchThroughTheNativeControl() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_DISCOVERY_CAPTURE"] else {
            throw XCTSkip("Set MLX_WORKBENCH_DISCOVERY_CAPTURE for native Discover mode checks.")
        }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = host(library: [])
        let page = DiscoveryWorkspace(appHost: app).environment(\.isRouteActive, true)
        let hosting = NSHostingView(rootView: page.frame(width: 814, height: 900)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 814, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func capture(_ name: String) throws {
            hosting.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(250))
        let browseRole = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Any") })
        let browseMenu = try XCTUnwrap(browseRole.menu)
        let codingIndex = browseRole.indexOfItem(withTitle: "Coding")
        XCTAssertGreaterThanOrEqual(codingIndex, 0)
        browseMenu.performActionForItem(at: codingIndex)
        try await Task.sleep(for: .milliseconds(100))
        try capture("browse")
        let picker = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "Browse candidates" })
        XCTAssertEqual(picker.selectedSegment, 0)
        let action = try XCTUnwrap(picker.action)
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(action, to: picker.target))
        try await Task.sleep(for: .milliseconds(250))
        let recommendRole = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("General") && !$0.itemTitles.contains("Any") })
        let recommendMenu = try XCTUnwrap(recommendRole.menu)
        let toolUseIndex = recommendRole.indexOfItem(withTitle: "Tool use")
        XCTAssertGreaterThanOrEqual(toolUseIndex, 0)
        recommendMenu.performActionForItem(at: toolUseIndex)
        try await Task.sleep(for: .milliseconds(100))
        try capture("recommend")
        XCTAssertEqual(picker.selectedSegment, 1)
        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(action, to: picker.target))
        try await Task.sleep(for: .milliseconds(250))
        try capture("browse-return")
        XCTAssertEqual(picker.selectedSegment, 0)
        XCTAssertEqual(descendants(hosting).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Any") }?.titleOfSelectedItem, "Coding")
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(action, to: picker.target))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(descendants(hosting).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("General") && !$0.itemTitles.contains("Any") }?.titleOfSelectedItem, "Tool use")
        try capture("recommend-return")
        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(action, to: picker.target))
        hosting.rootView = DiscoveryWorkspace(appHost: app, recommendationRequested: true)
            .environment(\.isRouteActive, true).frame(width: 814, height: 900)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(picker.selectedSegment, 1, "A legacy Adopt request opens the retained recommendation mode.")
        try capture("legacy-adopt-request")
    }

    private func config() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: ["/m"], mlxRoots: [], outputDir: "/out/mlx",
            mlxAgentPath: "/agent", quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: 4, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    private func host(library: [LibraryModel]) -> AppHost {
        let host = AppHost(
            config: config(), discoveredRoots: [], configPath: "/state/config.json", agentHealth: .notConfigured,
            runtimeReport: RuntimeReport(
                convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready."),
                serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready."),
                install: "make install", ok: true
            ), hardwareProfile: F.hardware,
            modelWorkflowAPI: ModelWorkflowAPI(
                convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
                servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] }
            ),
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
        )
        host.librarySnapshot = F.snapshot(library)
        return host
    }

    private func monitor() async -> SystemResourceMonitor {
        let reading = MemorySnapshot(totalBytes: F.totalBytes, availableBytes: 60_000_000_000)
        let monitor = SystemResourceMonitor(probe: { reading })
        await monitor.refreshMemory()
        return monitor
    }

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 900) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: viewport, height: height).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "adopt-\(name)-\(dark ? "dark" : "light")-\(Int(viewport))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        struct Scenario {
            let name: String
            let library: [LibraryModel]
            var workflow: AdoptView.WorkflowContext?
            var operation: AdoptView.Operation?
            var error: String?
            var lastKnown = false
        }
        let statePath = "/state/adoptions/0F2A9C1E-7B34-4D8E-9A51-3C6E0B7D2F14.json"
        let owned = [F.model(F.cachePath)]
        let scenarios = [
            Scenario(name: "idle", library: owned),
            Scenario(
                name: "running", library: owned,
                workflow: .init(requestedRole: "coding", statePath: statePath), operation: .start
            ),
            Scenario(
                name: "recommended-in-library", library: owned,
                workflow: .init(requestedRole: "coding", statePath: statePath, response: F.response(message: "Qwen3-Coder leads the coding shortlist for this Mac."))
            ),
            Scenario(
                name: "recommended-not-in-library", library: [],
                workflow: .init(requestedRole: "coding", statePath: statePath, response: F.response())
            ),
            Scenario(
                name: "no-recommendation", library: owned,
                workflow: .init(requestedRole: "reasoning", statePath: statePath, response: F.response(model: nil, evidence: nil))
            ),
            Scenario(
                name: "error", library: owned,
                workflow: .init(requestedRole: "coding", statePath: statePath, response: F.response()),
                error: "Status refresh failed. The agent exited with status 2. Refresh to try again.", lastKnown: true
            ),
        ]
        let resources = await monitor()
        for scenario in scenarios {
            for dark in [true, false] {
                for width in [CGFloat(1220), 824, 514] {
                    let page = AdoptView(
                        appHost: host(library: scenario.library), resources: resources,
                        seedWorkflow: scenario.workflow, seedOperation: scenario.operation,
                        seedError: scenario.error, seedLastKnown: scenario.lastKnown
                    )
                    try await attach(page.environment(\.isRouteActive, false), name: scenario.name, viewport: width, dark: dark)
                }
            }
        }
    }
}
