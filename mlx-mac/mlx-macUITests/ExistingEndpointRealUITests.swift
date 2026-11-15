import AppKit
import XCTest

final class ExistingEndpointRealUITests: XCTestCase {
    private var app: XCUIApplication?
    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
    }
    override func tearDownWithError() throws { app?.terminate() }

    func testOpenDiscoveredExistingEndpoint() throws {
        let env = ProcessInfo.processInfo.environment
        let application = XCUIApplication(); app = application
        application.launchEnvironment["MLX_WORKBENCH_CONFIG"] = try XCTUnwrap(env["MLX_UX_CONFIG_PATH"])
        application.launchEnvironment["MLX_WORKBENCH_PYTHON"] = try XCTUnwrap(env["MLX_WORKBENCH_PYTHON"])
        application.launchEnvironment["CFFIXED_USER_HOME"] = try XCTUnwrap(env["MLX_UX_APP_HOME"])
        application.launchEnvironment["XDG_STATE_HOME"] = try XCTUnwrap(env["MLX_UX_APP_STATE"])
        application.launchEnvironment["XDG_CACHE_HOME"] = try XCTUnwrap(env["MLX_UX_APP_CACHE"])
        application.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES"]
        application.launch(); XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))
        let window = application.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 998, dy: 718))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertLessThan(window.frame.width, 1100)
        let serving = application.buttons["Serving"].firstMatch
        XCTAssertTrue(serving.waitForExistence(timeout: 20)); serving.click()
        let add = application.buttons["serving-add-model"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 30)); add.click()
        let picker = application.popUpButtons["serving-model-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30)); picker.click()
        let model = application.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Qwen3-4B")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 20)); model.click()
        let start = application.radioButtons["Start now"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.click()
        let preview = application.buttons["Preview serve"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15)); XCTAssertTrue(preview.isHittable); preview.click()
        let open = application.buttons["open-existing-endpoint"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30)); XCTAssertTrue(open.isHittable)
        capture("Existing endpoint notice")
        open.click()
        let tabs = application.radioGroups["serving-workspace-tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20)); XCTAssertTrue(tabs.isHittable)
        let address = application.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", ":19081/v1", ":19081/v1")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 20)); XCTAssertTrue(address.isHittable)
        capture("Existing endpoint settings")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
