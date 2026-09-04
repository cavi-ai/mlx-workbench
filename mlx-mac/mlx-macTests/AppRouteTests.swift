import XCTest
@testable import mlx_workbench

final class AppRouteTests: XCTestCase {
    func testRouteRegistryContainsTheFourteenUniqueLegacyIDsInCanonicalOrder() {
        let routes = AppRoute.allCases
        let expectedIDs = [
            "quickstart", "models",
            "convert", "quant", "serve",
            "jobs", "duplicates", "wire", "doctor",
            "scout", "lmstudio", "training-studio", "adopt",
            "settings"
        ]

        XCTAssertEqual(routes.count, 14)
        XCTAssertEqual(routes.map(\.rawValue), expectedIDs)
        XCTAssertEqual(Set(routes.map(\.rawValue)).count, routes.count)
        XCTAssertEqual(routes.map(\.order), Array(0..<routes.count))

        XCTAssertEqual(AppRoute.grouped.map(\.group), [.workbench, .lifecycle, .operations, .lab, .settings])
        XCTAssertEqual(AppRoute.grouped.map { $0.routes.count }, [2, 3, 4, 4, 1])
    }

    func testRouteMetadataMatchesTheSiliconInstrumentBenchInformationArchitecture() {
        let expected: [(AppRoute, String, String, String)] = [
            (.overview, "Workbench", "Overview", "house"),
            (.library, "Workbench", "Library", "books.vertical"),
            (.prepare, "Lifecycle", "Prepare", "shippingbox"),
            (.compare, "Lifecycle", "Compare", "chart.bar"),
            (.run, "Lifecycle", "Run", "play.circle"),
            (.activity, "Operations", "Activity", "clock.arrow.circlepath"),
            (.reclaim, "Operations", "Reclaim", "square.3.layers.3d"),
            (.clientSetup, "Operations", "Client Setup", "arrow.triangle.branch"),
            (.health, "Operations", "Health", "stethoscope"),
            (.discover, "Lab", "Discover", "magnifyingglass"),
            (.lmStudio, "Lab", "LM Studio", "square.and.arrow.down"),
            (.training, "Lab", "Training", "sparkles"),
            (.adopt, "Lab", "Adopt", "hand.tap"),
            (.settings, "Settings", "Settings", "gearshape")
        ]

        for (route, group, label, symbol) in expected {
            XCTAssertEqual(route.group.rawValue, group)
            XCTAssertEqual(route.label, label)
            XCTAssertEqual(route.symbolName, symbol)
            XCTAssertFalse(route.pageDescription.isEmpty)
        }
    }

    func testLegacyIDInitializerFallsBackToOverviewForUnknownValues() {
        XCTAssertEqual(AppRoute(legacyID: "quickstart"), .overview)
        XCTAssertEqual(AppRoute(rawID: "models"), .library)
        XCTAssertEqual(AppRoute(rawID: "not-a-route"), .overview)
        XCTAssertEqual(AppRoute(rawID: nil), .overview)
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
    }

    func testExternalStateIsHumanizedInsteadOfRelabeledUnknown() {
        let status = WorkbenchStatus(rawValue: "fresh_external_state")

        XCTAssertEqual(status.label, "Fresh External State")
        XCTAssertEqual(status.tone, .neutral)
    }
}
