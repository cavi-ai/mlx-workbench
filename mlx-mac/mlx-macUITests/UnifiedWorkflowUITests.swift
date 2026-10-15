import XCTest

/// Opt-in native acceptance against explicitly selected local engine artifacts.
final class UnifiedWorkflowUITests: XCTestCase {
    func testControlledReviewAndTrainingEvaluation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let agent = environment["MLX_LAB_UI_AGENT"],
              let python = environment["MLX_LAB_UI_PYTHON"],
              let store = environment["MLX_LAB_UI_STORE"],
              let trainingReceipt = environment["MLX_LAB_UI_TRAINING_RECEIPT"] else {
            throw XCTSkip("Provide local engine, workspace, and completed training receipt paths.")
        }
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-native-acceptance-" + UUID().uuidString)
        let config = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings: [String: Any] = ["mlx_agent_path": agent, "gguf_roots": [], "mlx_roots": [],
            "output_dir": root.appendingPathComponent("output").path, "verification_enabled": false, "watch_enabled": false]
        try JSONSerialization.data(withJSONObject: settings).write(to: config)
        let receipts = root.appendingPathComponent("Library/Application Support/mlx-workbench/.mlx-agent-receipts/lora")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: trainingReceipt),
                                         to: receipts.appendingPathComponent("acceptance-lora.json"))
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launchEnvironment = ["MLX_WORKBENCH_CONFIG": config.path, "MLX_WORKBENCH_PYTHON": python,
                                 "CFFIXED_USER_HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path]
        func launch(_ route: String) {
            app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES", "-mlx-workbench.selectedRoute", route,
                                   "-mlx-workbench.lab-store", store, "-mlx-workbench.lab-reviewer", "acceptance-reviewer"]
            app.launch(); app.activate()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        launch("quant")
        let studies = app.buttons["open-studies"]
        XCTAssertTrue(studies.waitForExistence(timeout: 10))
        studies.click()
        XCTAssertTrue(app.buttons["New experiment…"].waitForExistence(timeout: 30))
        app.buttons["New experiment…"].click()
        XCTAssertTrue(app.staticTexts["New controlled experiment"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Create experiment"].isEnabled)
        capture("native-authoring")
        app.sheets.buttons["Cancel"].click()
        let review = app.buttons.matching(identifier: "Blind review…").matching(NSPredicate(format: "enabled == true")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 30))
        review.click()
        XCTAssertTrue(app.staticTexts["Blind video review"].waitForExistence(timeout: 30))
        let play = app.buttons["Play together"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        let playable = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
        wait(for: [playable], timeout: 30)
        play.click()
        app.buttons["Pause"].click()
        XCTAssertTrue(app.buttons["Next frame"].isEnabled)
        app.buttons["Next frame"].click()
        app.buttons["Previous frame"].click()
        XCTAssertFalse(app.buttons["Submit immutable review"].isEnabled)
        capture("native-blind-playback")
        app.sheets.buttons["Close"].click()
        app.terminate()
        launch("training-studio")
        let compare = app.buttons["Compare with base"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        capture("native-training-receipt")
        compare.click()
        let prompt = app.textFields["Evaluation prompt"].exists ? app.textFields["Evaluation prompt"] : app.textViews["Evaluation prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        prompt.click(); prompt.typeText("Explain what a LoRA adapter changes.")
        app.buttons["Preview"].click()
        let run = app.buttons["Run comparison"]
        XCTAssertTrue(run.waitForExistence(timeout: 30))
        let reviewed = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: run)
        wait(for: [reviewed], timeout: 30)
        run.click()
        let evidence = app.staticTexts["training-evaluation-evidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 60))
        capture("native-linked-training-evaluation")
    }
}
