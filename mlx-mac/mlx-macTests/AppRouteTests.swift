import AppKit
import SwiftUI
import XCTest
@testable import mlx_workbench

final class AppRouteTests: XCTestCase {
    func testRouteRegistryPreservesLegacyIDsAndIncludesStudies() {
        let routes = AppRoute.allCases
        let expectedIDs = [
            "quickstart", "models", "use",
            "convert", "quant", "serve",
            "jobs", "duplicates", "wire", "doctor",
            "scout", "lmstudio", "studies", "training-studio", "adopt",
            "settings", "monitor", "sources", "terminal"
        ]

        XCTAssertEqual(routes.count, 19)
        XCTAssertEqual(routes.map(\.rawValue), expectedIDs)
        XCTAssertEqual(Set(routes.map(\.rawValue)).count, routes.count)
        XCTAssertEqual(routes.map(\.order), Array(0..<routes.count))
    }

    func testNoSidebarGroupHoldsASinglePage() {
        for entry in AppRoute.grouped {
            XCTAssertGreaterThan(entry.routes.count, 1, "\(entry.group.rawValue) holds one page")
        }
    }

    func testEveryCurrentRouteAppearsOnceInItsOwnGroup() {
        let listed = AppRoute.grouped.flatMap(\.routes)
        let current = AppRoute.allCases.filter { $0.navigationDestination == $0 }
        XCTAssertEqual(listed.count, current.count)
        XCTAssertEqual(Set(listed), Set(current))
    }

    func testCollapsedSidebarSectionShowsItsPagesCount() {
        let badges: [AppRoute: String] = [.activity: "3", .health: "2", .reclaim: "12 GB"]
        XCTAssertEqual(AppSidebar.headerBadge(for: .system, expanded: false, badges: badges), "5")
        XCTAssertNil(AppSidebar.headerBadge(for: .system, expanded: true, badges: badges))
        XCTAssertNil(AppSidebar.headerBadge(for: .studio, expanded: false, badges: badges))
    }


    func testUnknownOrMissingSelectionOpensLibraryAndValidIDsWin() {
        XCTAssertEqual(AppRoute(rawID: nil), .library)
        XCTAssertEqual(AppRoute(rawID: "not-a-route"), .library)
        XCTAssertEqual(AppRoute(rawID: "quickstart"), .overview)
        XCTAssertEqual(AppRoute(rawID: "models"), .library)
    }

    @MainActor
    func testFreshInstallWindowOpensOnLibrary() async throws {
        let app = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", agentHealth: .notConfigured, runtimeReport: .checking)
        app.librarySnapshot = LibrarySnapshot(models: [], groups: [], hardware: app.hardwareProfile, generatedAt: Date())

        let fresh = try XCTUnwrap(UserDefaults(suiteName: "app-route-\(UUID().uuidString)"))
        XCTAssertNil(fresh.string(forKey: AppRoute.selectionStorageKey))
        let freshTitle = try await windowTitle(app: app, defaults: fresh)
        XCTAssertEqual(freshTitle, "Library")

        let stored = try XCTUnwrap(UserDefaults(suiteName: "app-route-\(UUID().uuidString)"))
        stored.set(AppRoute.overview.rawValue, forKey: AppRoute.selectionStorageKey)
        let storedTitle = try await windowTitle(app: app, defaults: stored)
        XCTAssertEqual(storedTitle, "Overview")
    }

    @MainActor
    private func windowTitle(app: AppHost, defaults: UserDefaults) async throws -> String {
        let size = CGSize(width: WorkbenchSize.windowMinimumWidth, height: WorkbenchSize.windowMinimumHeight)
        let hosting = NSHostingView(rootView: AnyView(ContentView(appHost: app).defaultAppStorage(defaults).frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<40 where window.title.isEmpty {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return window.title
    }

    func testOnlyPrepareAndRunCarryAToolbarSubtitle() {
        let timestamp = Date(timeIntervalSince1970: 1_726_500_000)
        let workflow = ConversionWorkflow(
            id: UUID(), sourcePath: "/models/atlas.gguf", sourceModelKey: "atlas", sourceSignature: "signature",
            outputPath: "/models/atlas-mlx", previewHash: nil, jobReceipt: nil, completedModelPath: nil,
            state: .inspectingSource, serveState: .idle, message: nil, errorMessage: nil,
            createdAt: timestamp, updatedAt: timestamp, lastKnownAgentState: nil
        )
        for route in AppRoute.allCases {
            let subtitle = ContentView.subtitle(route: route, workflow: workflow, selectedModelPath: "/models/other-model")
            if route == .prepare || route == .run {
                XCTAssertFalse(subtitle.isEmpty, "\(route.label) names its model")
            } else {
                XCTAssertEqual(subtitle, "", "\(route.label) has no subtitle")
            }
        }
    }

    func testLegacyAdoptUsesTheDiscoverDestinationWithoutADuplicatePage() {
        XCTAssertEqual(AppRoute(rawID: "adopt"), .adopt)
        XCTAssertEqual(AppRoute.adopt.navigationDestination, .discover)
        XCTAssertEqual(AppRoute.discover.navigationDestination, .discover)
        XCTAssertFalse(AppRoute.grouped.flatMap(\.routes).contains(.adopt))
        XCTAssertEqual(ContentView.mountedRoutes(for: [.adopt, .discover, .library]), [.library, .discover])
        for route in AppRoute.allCases where route != .adopt && route != .lmStudio {
            XCTAssertEqual(route.navigationDestination, route)
        }
    }

    func testLegacyLMStudioUsesTheLibraryDestinationWithoutADuplicatePage() {
        XCTAssertEqual(AppRoute(rawID: "lmstudio"), .lmStudio)
        XCTAssertEqual(AppRoute.lmStudio.navigationDestination, .library)
        XCTAssertFalse(AppRoute.grouped.flatMap(\.routes).contains(.lmStudio))
        XCTAssertEqual(ContentView.mountedRoutes(for: [.lmStudio, .library, .discover]), [.library, .discover])
    }

    func testLegacyIDInitializerFallsBackToLibraryForUnknownValues() {
        XCTAssertEqual(AppRoute(legacyID: "quickstart"), .overview)
        XCTAssertEqual(AppRoute(rawID: "models"), .library)
        XCTAssertEqual(AppRoute(rawID: "studies"), .studies)
        XCTAssertEqual(AppRoute(rawID: "not-a-route"), .library)
        XCTAssertEqual(AppRoute(rawID: nil), .library)
    }
}

final class WorkbenchStatusTests: XCTestCase {
    func testEveryConversionWorkflowStateKeepsATruthfulVisibleLabel() {
        let expected: [ConversionWorkflowState: String] = [
            .idle: "Idle",
            .inspectingSource: "Inspecting Source",
            .existingModelFound: "Existing Model Found",
            .previewingConversion: "Previewing Conversion",
            .readyToConfirm: "Ready to Confirm",
            .queued: "Queued",
            .running: "Running",
            .completed: "Completed",
            .verifying: "Verifying",
            .verified: "Verified",
            .verificationFailed: "Verification Failed",
            .failed: "Failed"
        ]

        for (state, label) in expected {
            XCTAssertEqual(WorkbenchStatus(rawValue: state.rawValue).label, label)
        }
    }

    func testEveryLibraryReadinessAndRecommendationConfidenceKeepsItsDomainLabel() {
        for readiness in ModelReadiness.allCases {
            XCTAssertEqual(
                WorkbenchStatus(rawValue: readiness.rawValue).label,
                readiness.title
            )
        }

        for confidence in [RecommendationConfidence.low, .medium, .high] {
            XCTAssertEqual(
                WorkbenchStatus(rawValue: confidence.title).label,
                confidence.title
            )
        }

        XCTAssertEqual(WorkbenchStatus(rawValue: RecommendationConfidence.low.title).tone, .warning)
        XCTAssertEqual(WorkbenchStatus(rawValue: RecommendationConfidence.medium.title).tone, .information)
        XCTAssertEqual(WorkbenchStatus(rawValue: RecommendationConfidence.high.title).tone, .information)
        XCTAssertEqual(WorkbenchStatus(rawValue: ConversionWorkflowState.running.rawValue).tone, .information)
        XCTAssertEqual(WorkbenchStatus(rawValue: ConversionWorkflowState.queued.rawValue).tone, .information)
        XCTAssertEqual(WorkbenchStatus(rawValue: ConversionWorkflowState.verifying.rawValue).tone, .information)
        XCTAssertEqual(WorkbenchStatus(rawValue: ConversionWorkflowState.verificationFailed.rawValue).tone, .failure)
        // mlx-agent `convert status` reports finished jobs as "done".
        XCTAssertEqual(WorkbenchStatus(rawValue: "done"), .completed)
    }

    func testExternalStateIsHumanizedInsteadOfRelabeledUnknown() {
        let status = WorkbenchStatus(rawValue: "fresh_external_state")

        XCTAssertEqual(status.label, "Fresh External State")
        XCTAssertEqual(status.tone, .neutral)
    }
}
