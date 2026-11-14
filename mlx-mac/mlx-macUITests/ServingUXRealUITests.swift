import AppKit
import CryptoKit
import Foundation
import XCTest

/// Inspects an archived comparison and real idle gateways in an isolated guest.
final class ServingUXRealUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws { app?.terminate() }

    func testRealIdleEndpointsAndArchivedFailure() throws {
        let env = ProcessInfo.processInfo.environment
        let archive = URL(fileURLWithPath: try XCTUnwrap(env["MLX_UX_ARCHIVE_PATH"]))
        let archiveHash = try XCTUnwrap(env["MLX_UX_ARCHIVE_SHA256"])
        let archiveID = try XCTUnwrap(env["MLX_UX_ARCHIVE_ID"])
        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), archiveHash)
        let archived = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(archived["id"] as? String, archiveID)

        let application = XCUIApplication(); app = application
        application.launchEnvironment["MLX_WORKBENCH_CONFIG"] = try XCTUnwrap(env["MLX_UX_CONFIG_PATH"])
        application.launchEnvironment["MLX_WORKBENCH_PYTHON"] = try XCTUnwrap(env["MLX_WORKBENCH_PYTHON"])
        application.launchEnvironment["CFFIXED_USER_HOME"] = try XCTUnwrap(env["MLX_UX_APP_HOME"])
        application.launchEnvironment["XDG_STATE_HOME"] = try XCTUnwrap(env["MLX_UX_APP_STATE"])
        application.launchEnvironment["XDG_CACHE_HOME"] = try XCTUnwrap(env["MLX_UX_APP_CACHE"])
        application.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES", "-sidebar.systemExpanded", "YES"]
        application.launch(); XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))
        let serving = application.buttons["Serving"].firstMatch
        XCTAssertTrue(serving.waitForExistence(timeout: 20)); serving.click()
        let first = text(":19081", in: application)
        XCTAssertTrue(first.waitForExistence(timeout: 30)); first.click()
        let sibling = application.links.matching(NSPredicate(format: "label CONTAINS %@", ":19082")).firstMatch
        XCTAssertTrue(sibling.waitForExistence(timeout: 15))
        resize(width: 1380, height: 850); XCTAssertGreaterThanOrEqual(application.windows.firstMatch.frame.width, 1300); capture("Serving real idle endpoints wide")
        resize(width: 1000, height: 720); XCTAssertLessThan(application.windows.firstMatch.frame.width, 1100); capture("Serving real idle endpoints ordinary")
        sibling.click()
        XCTAssertTrue(text("http://127.0.0.1:19082/v1", in: application).waitForExistence(timeout: 10))
        let monitor = application.buttons["Monitor"].firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 10)); monitor.click()
        XCTAssertTrue(text("live endpoint", in: application).waitForExistence(timeout: 20))
        resize(width: 1380, height: 850); capture("Monitor real idle endpoints standard")
        resize(width: 1000, height: 720); capture("Monitor real idle endpoints ordinary")
        let details = application.buttons["Endpoint details…"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10)); details.click()
        XCTAssertTrue(application.buttons["monitor-open-settings"].waitForExistence(timeout: 10))
        capture("Monitor endpoint details")
        application.buttons["Done"].firstMatch.click()
        let compare = application.buttons["Compare"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 10)); compare.click()
        XCTAssertTrue(text("No comparison output", in: application).waitForExistence(timeout: 30))
        let started = try XCTUnwrap(archived["startedAt"] as? Double)
        let date = Date(timeIntervalSinceReferenceDate: started).formatted(date: .abbreviated, time: .shortened)
        XCTAssertTrue(text(date, in: application).exists)
        let results = try XCTUnwrap(archived["results"] as? [[String: Any]])
        let firstError = try XCTUnwrap(results.compactMap { $0["error"] as? String }.first)
        let firstLine = try XCTUnwrap(firstError.split(separator: "\n").first).description
        XCTAssertTrue(text(firstLine, in: application).exists)
        resize(width: 1380, height: 850); capture("Archived comparison failure wide")
        resize(width: 1000, height: 720); capture("Archived comparison failure ordinary")
    }

    private func text(_ fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    private func resize(width: CGFloat, height: CGFloat) {
        guard let window = app?.windows.firstMatch else { return }
        let screen = NSScreen.main?.frame
        func moveHorizontally(_ delta: CGFloat) {
            let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20))
            titlebar.press(forDuration: 0.1, thenDragTo: titlebar.withOffset(CGVector(dx: delta, dy: 0)))
        }
        if let screen, window.frame.maxX > screen.maxX { moveHorizontally(screen.maxX - window.frame.maxX - 8) }
        let fittedWidth = min(width, screen?.width ?? width)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fittedWidth - 2, dy: height - 2))
        corner.press(forDuration: 0.1, thenDragTo: target)
        if let screen, window.frame.minX < screen.minX { moveHorizontally(screen.minX - window.frame.minX) }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
