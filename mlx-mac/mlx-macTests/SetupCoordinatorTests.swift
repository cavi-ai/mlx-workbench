import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class SetupCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "mlx-workbench-setup-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPresentsOnFirstLaunch() {
        XCTAssertTrue(SetupCoordinator(defaults: defaults).isPresented)
    }

    func testDoesNotPresentOnceCompleted() {
        defaults.set(true, forKey: SetupCoordinator.completionKey)
        XCTAssertFalse(SetupCoordinator(defaults: defaults).isPresented)
    }

    func testFinishPersistsCompletionAndCloses() {
        let coordinator = SetupCoordinator(defaults: defaults)
        coordinator.finish()

        XCTAssertFalse(coordinator.isPresented)
        XCTAssertFalse(SetupCoordinator(defaults: defaults).isPresented)
    }

    func testDismissWithoutFinishReturnsNextLaunch() {
        let coordinator = SetupCoordinator(defaults: defaults)
        coordinator.dismiss()

        XCTAssertFalse(coordinator.isPresented)
        XCTAssertTrue(SetupCoordinator(defaults: defaults).isPresented)
    }

    func testPresentAgainResetsToFirstStep() {
        let coordinator = SetupCoordinator(defaults: defaults)
        coordinator.advance()
        coordinator.advance()
        coordinator.dismiss()

        coordinator.presentAgain()

        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.step, .agent)
    }

    func testStepNavigationBounds() {
        let coordinator = SetupCoordinator(defaults: defaults)
        coordinator.retreat()
        XCTAssertEqual(coordinator.step, .agent)

        for _ in 0..<10 { coordinator.advance() }
        XCTAssertEqual(coordinator.step, .done)

        coordinator.advance()
        XCTAssertEqual(coordinator.step, .done)
    }

    func testStepTitlesExistForEveryStep() {
        for step in SetupCoordinator.Step.allCases {
            XCTAssertFalse(step.title.isEmpty)
        }
    }

    func testProgressLabelCountsFromOne() {
        XCTAssertEqual(SetupCoordinator.Step.agent.progressLabel, "Step 1 of 4")
        XCTAssertEqual(SetupCoordinator.Step.done.progressLabel, "Step 4 of 4")
    }

    func testHeaderKeepsTheStepTitleAsItsOwnHeaderElement() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/SetupAssistantView.swift"), encoding: .utf8)
        let header = try XCTUnwrap(source.range(of: "private var header: some View"))
        let end = try XCTUnwrap(source.range(of: "private var stepContent", range: header.upperBound..<source.endIndex))
        let body = source[header.lowerBound..<end.lowerBound]
        XCTAssertFalse(body.contains("children: .combine"))
        let title = try XCTUnwrap(body.range(of: "Text(coordinator.step.title)"))
        XCTAssertTrue(body[title.upperBound...].prefix(120).contains(".accessibilityAddTraits(.isHeader)"))
    }

    func testHeaderHasNoUppercaseLabelOrMonospacedProgress() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/SetupAssistantView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Text(\"SETUP\")"))
        XCTAssertFalse(source.contains("Text(\"Step \\("))
        let progress = try XCTUnwrap(source.range(of: "Text(coordinator.step.progressLabel)"))
        let styling = source[progress.upperBound...].prefix(120)
        XCTAssertTrue(styling.contains("WorkbenchTypography.secondary"))
        XCTAssertFalse(styling.contains("WorkbenchTypography.value"))
    }
}
