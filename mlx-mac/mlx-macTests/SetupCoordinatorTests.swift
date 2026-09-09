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
}
