import XCTest

final class GGUFToRunRealDataUITests: XCTestCase {
    private var app: XCUIApplication!
    private var evidenceDirectory: URL!
    private var observations: [String] = []
    private var runtimeValues: [String: String] = [:]
    private var runtimeManifest: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        runtimeManifest = loadRuntimeManifest()

        let required = [
            "TASK6_EVIDENCE_DIR",
            "TASK6_SOURCE_PATH",
            "TASK6_MODEL_QUERY",
            "TASK6_AGENT_HOME",
            "TASK6_CONFIG_PATH",
        ]
        for key in required {
            guard let value = configuredValue(key) else {
                throw XCTSkip("Missing required real-data runtime value: \(key)")
            }
            runtimeValues[key] = value
        }

        evidenceDirectory = URL(fileURLWithPath: runtimeValues["TASK6_EVIDENCE_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchEnvironment["MLX_AGENT_HOME"] = runtimeValues["TASK6_AGENT_HOME"]
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = runtimeValues["TASK6_CONFIG_PATH"]
        app.launch()

        addTeardownBlock { [weak self] in
            self?.stopServerIfNeeded()
        }
    }

    func testRealGGUFToRunningMLXGoldenPath() throws {
        let sourcePath = try XCTUnwrap(runtimeValues["TASK6_SOURCE_PATH"])
        let modelQuery = try XCTUnwrap(runtimeValues["TASK6_MODEL_QUERY"])
        let sourceDirectory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().standardizedFileURL.path

        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 30), "Library navigation was not exposed by the launched native app.")
        app.buttons["Library"].click()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20))

        let search = app.textFields["Search family, variant, path, key, or evidence"]
        XCTAssertTrue(search.waitForExistence(timeout: 180), "The real local inventory did not finish scanning into Library.")
        search.click()
        search.typeText(modelQuery)

        let sourceName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let sourceRow = app.staticTexts[sourceName].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 30), "Configured real GGUF was not visible after Library search: \(sourceName)")
        sourceRow.click()
        XCTAssertTrue(app.buttons["Prepare to run"].waitForExistence(timeout: 20))
        capture("01-library-real-gguf-selected", note: "Library displayed the configured real GGUF and its evidence.")

        XCTAssertTrue(app.staticTexts["Prepare destination"].exists, "Library did not expose the Prepare destination label.")

        app.buttons["Prepare to run"].click()
        XCTAssertTrue(app.staticTexts["Prepare"].waitForExistence(timeout: 20))
        capture("02-prepare-workflow", note: "Prepare rendered the workflow state reached from the selected real GGUF.")
        let hasPrepareAction = app.buttons["Run existing"].waitForExistence(timeout: 10)
            || app.buttons["Preview conversion"].exists
        XCTAssertTrue(
            hasPrepareAction,
            "Prepare rendered neither Run existing nor conversion controls."
        )
        XCTAssertTrue(waitForVisibleTextContaining(sourceName, timeout: 20), "Prepare did not visibly preserve the selected source name.")

        let prepareLabels = visibleLabels()
        let sourceOccurrences = prepareLabels.filter { compacted($0).contains(compacted(sourcePath)) }.count
        if app.staticTexts["Equivalent MLX model found"].exists, sourceOccurrences >= 2 {
            capture("02-invalid-gguf-self-reuse", note: "Prepare displayed the GGUF source itself as the equivalent MLX destination.")
            XCTFail("Prepare incorrectly reused the selected GGUF source itself as an equivalent MLX model instead of offering conversion.")
            return
        }
        guard let destinationPath = displayedDestination(in: prepareLabels, sourcePath: sourcePath, sourceDirectory: sourceDirectory),
              destinationPath != sourcePath else {
            XCTFail("Prepare did not visibly display a distinct same-directory destination.")
            return
        }
        record("source=\(sourcePath)")
        record("destination=\(destinationPath)")
        capture("02-prepare-same-directory-destination", note: "Prepare displayed source and coordinator-approved same-directory destination.")

        if app.buttons["Run existing"].exists {
            capture("03-existing-mlx-reuse", note: "Prepare selected an existing equivalent MLX model without conversion.")
            app.buttons["Run existing"].click()
        } else {
            let preview = app.buttons["Preview conversion"]
            XCTAssertTrue(preview.waitForExistence(timeout: 20))
            XCTAssertTrue(preview.isEnabled, "Conversion preview was unavailable for the selected real GGUF.")
            preview.click()
            XCTAssertTrue(app.staticTexts["Preview ready"].waitForExistence(timeout: 300), "Conversion preview did not reach Preview ready.")
            XCTAssertTrue(app.buttons["Confirm conversion"].isEnabled, "Preview hash did not enable confirmation.")
            capture("03-conversion-preview-ready", note: "Conversion preview completed and hash-gated confirmation became enabled.")

            let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
            if let sourceBytes = (sourceAttributes?[.size] as? NSNumber)?.int64Value,
               sourceBytes >= 29_000_000_000 {
                capture(
                    "04-large-conversion-safety-gate",
                    note: "The visible preview was safe, but the selected 29 GB source exceeded the unattended conversion gate."
                )
                XCTFail(
                    "Conversion confirmation withheld by Task 6 operational safety gate: selected source is \(sourceBytes) bytes (29 GB), so this unattended evidence run will not start conversion or serving."
                )
                return
            }

            app.buttons["Confirm conversion"].click()
            XCTAssertNotNil(
                waitForAnyText(["Conversion queued", "Conversion running", "Conversion completed"], timeout: 120),
                "Confirmed conversion did not enter an authoritative operational state."
            )
            capture("04-conversion-confirmed", note: "Hash-confirmed conversion entered queued or running state.")

            app.buttons["Activity"].click()
            XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts[sourcePath].waitForExistence(timeout: 30), "Activity did not display the selected conversion source.")
            capture("05-activity-receipt", note: "Activity displayed the confirmed real-data conversion record and receipt state.")

            waitForConversionCompletion(timeout: 2_400)
            capture("06-authoritative-conversion-completed", note: "Activity exposed completion after authoritative status and fresh Library discovery.")
            app.buttons["Run model"].click()
        }

        XCTAssertTrue(app.staticTexts["Run"].waitForExistence(timeout: 30), "Completed/reused model did not route into Run.")
        XCTAssertTrue(app.buttons["Preview serve"].waitForExistence(timeout: 30))
        capture("07-run-model-selected", note: "Run displayed the exact workflow-selected MLX model.")

        let servePreview = app.buttons["Preview serve"]
        XCTAssertTrue(servePreview.isEnabled, "Serve preview was unavailable for the selected completed MLX model.")
        servePreview.click()
        XCTAssertTrue(waitForButtonEnabled("Confirm and run", timeout: 300), "Serve preview did not produce a hash-gated confirmation.")
        capture("08-serve-preview-ready", note: "Serve preview enabled confirmation for the selected MLX model.")

        app.buttons["Confirm and run"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 180), "Confirmed serve did not route to Activity.")
        app.buttons["Run"].click()
        XCTAssertTrue(app.buttons["Stop server"].waitForExistence(timeout: 180), "Authoritative running server state was not visible in Run.")
        capture("09-server-running", note: "Run displayed the authoritative running server and stop control.")

        app.buttons["Stop server"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 180), "Server stop did not return to Activity.")
        capture("10-server-stopped", note: "Stop completed and returned to Activity without deleting model data.")
    }

    private func waitForConversionCompletion(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.buttons["Run model"].exists && app.staticTexts["Completed"].exists {
                return
            }
            if app.staticTexts["Failed"].exists {
                capture("conversion-failed", note: "Activity reported a failed real-data conversion.")
                XCTFail("Activity reported that the real-data conversion failed.")
                return
            }
            if app.buttons["Refresh"].exists && app.buttons["Refresh"].isEnabled {
                app.buttons["Refresh"].click()
            }
            Thread.sleep(forTimeInterval: 5)
        }
        capture("conversion-timeout", note: "Conversion did not reach authoritative completion before timeout.")
        XCTFail("Conversion did not reach receipt-backed completion and fresh Library discovery within \(Int(timeout)) seconds.")
    }

    private func configuredValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
            ?? Bundle(for: Self.self).object(forInfoDictionaryKey: key) as? String
            ?? runtimeManifest[key]
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func loadRuntimeManifest() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let defaultURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".run/task-6-native-e2e/runtime.json")
        let url = environment["TASK6_RUNTIME_MANIFEST"].map(URL.init(fileURLWithPath:)) ?? defaultURL
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }

    private func waitForAnyText(_ labels: [String], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let label = labels.first(where: { app.staticTexts[$0].exists }) {
                return label
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    private func waitForButtonEnabled(_ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let button = app.buttons[label]
            if button.exists && button.isEnabled { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func waitForVisibleTextContaining(_ text: String, timeout: TimeInterval) -> Bool {
        let expected = compacted(text)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if visibleLabels().contains(where: { compacted($0).contains(expected) }) { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func displayedDestination(in labels: [String], sourcePath: String, sourceDirectory: String) -> String? {
        let directoryPrefix = compacted(sourceDirectory) + "/"
        let reusePrefix = "ExistingequivalentMLXmodel:"
        for rawLabel in labels {
            let label = compacted(rawLabel)
            if label.hasPrefix(reusePrefix) {
                return String(label.dropFirst(reusePrefix.count))
            }
        }
        for rawLabel in labels {
            let label = compacted(rawLabel)
            if label != compacted(sourcePath), label.hasPrefix(directoryPrefix) {
                return label
            }
        }
        return nil
    }

    private func compacted(_ value: String) -> String {
        value.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }

    private func visibleLabels() -> [String] {
        app.staticTexts.allElementsBoundByIndex.compactMap { element in
            let parts = [element.label, element.value as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    private func capture(_ name: String, note: String) {
        let screenshot = app.windows.firstMatch.exists ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let visibleText = XCTAttachment(string: visibleLabels().joined(separator: "\n"))
        visibleText.name = "\(name)-visible-text"
        visibleText.lifetime = .keepAlways
        add(visibleText)

        do {
            try screenshot.pngRepresentation.write(to: evidenceDirectory.appendingPathComponent("\(name).png"), options: .atomic)
            record("\(name): \(note)")
        } catch {
            observations.append("\(ISO8601DateFormatter().string(from: Date())) \(name): \(note) [xcresult attachment; direct write unavailable: \(error.localizedDescription)]")
        }
    }

    private func record(_ line: String) {
        observations.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        let text = observations.joined(separator: "\n") + "\n"
        try? text.write(to: evidenceDirectory.appendingPathComponent("ui-observations.log"), atomically: true, encoding: .utf8)
    }

    private func stopServerIfNeeded() {
        guard app != nil, app.state == .runningForeground || app.state == .runningBackground else { return }
        if !app.buttons["Stop server"].exists, app.buttons["Run"].exists {
            app.buttons["Run"].click()
            _ = app.buttons["Stop server"].waitForExistence(timeout: 10)
        }
        if app.buttons["Stop server"].exists {
            app.buttons["Stop server"].click()
            record("teardown: stopped server after incomplete test path")
        }
    }
}
