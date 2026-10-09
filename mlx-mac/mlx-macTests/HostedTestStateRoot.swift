import Foundation
import XCTest

@testable import mlx_workbench

/// Test bundle principal class: every test runs against a fresh, empty
/// state root that is removed when the test finishes.
final class HostedTestStateRoot: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        WorkbenchStatePaths.hostedTestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        try? FileManager.default.removeItem(at: WorkbenchStatePaths.hostedTestRoot)
    }
}
