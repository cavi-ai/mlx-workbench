import XCTest

final class GGUFToRunRealDataUITests: XCTestCase {
    private struct ActivityRecordEvidence {
        let state: String
        let receipt: String
    }

    private struct ServerReceiptEvidence: Equatable {
        let receipt: String
        let repo: String
        let runtime: String
        let port: Int
        let pid: Int
        let alive: Bool
        let argvMatch: Bool

        var isLive: Bool { alive && argvMatch }
    }

    private var app: XCUIApplication!
    private var evidenceDirectory: URL!
    private var observations: [String] = []
    private var runtimeValues: [String: String] = [:]
    private var runtimeManifest: [String: String] = [:]
    private var ownedServer: ServerReceiptEvidence?

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

        launchConfiguredApp()

        addTeardownBlock { [weak self] in
            self?.stopServerIfNeeded()
        }
    }

    func testRealGGUFToRunningMLXGoldenPath() throws {
        let sourcePath = try XCTUnwrap(runtimeValues["TASK6_SOURCE_PATH"])
        let modelQuery = try XCTUnwrap(runtimeValues["TASK6_MODEL_QUERY"])
        let sourceDirectory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().standardizedFileURL.path

        let libraryButton = app.buttons["Library"]
        guard libraryButton.waitForExistence(timeout: 30) else {
            capture("00-launch-navigation-missing", note: "The launched app did not expose Library navigation.")
            XCTFail("Library navigation was not exposed by the launched native app.")
            return
        }
        libraryButton.click()
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
            guard conversionSourceIsSafeToPreview(sourcePath) else { return }
            preview.click()
            XCTAssertTrue(app.staticTexts["Preview ready"].waitForExistence(timeout: 300), "Conversion preview did not reach Preview ready.")
            XCTAssertTrue(app.buttons["Confirm conversion"].isEnabled, "Preview hash did not enable confirmation.")
            capture("03-conversion-preview-ready", note: "Conversion preview completed and hash-gated confirmation became enabled.")

            app.buttons["Confirm conversion"].click()
            XCTAssertNotNil(
                waitForAnyText(["Conversion queued", "Conversion running", "Conversion completed"], timeout: 120),
                "Confirmed conversion did not enter an authoritative operational state."
            )
            capture("04-conversion-confirmed", note: "Hash-confirmed conversion entered queued or running state.")

            app.buttons["Activity"].click()
            XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 20))
            let initialRecord = try XCTUnwrap(
                waitForActivityRecord(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    acceptedStates: ["queued", "running", "completed"],
                    timeout: 120
                ),
                "Activity did not display one receipt-backed record containing the selected source and destination."
            )
            XCTAssertNotEqual(initialRecord.receipt, "Not reported", "The selected Activity record had no persisted job receipt.")
            capture("05-activity-receipt", note: "Activity displayed the confirmed real-data conversion record and receipt state.")

            restartAndReconcile(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                receipt: initialRecord.receipt
            )
            waitForConversionCompletion(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                receipt: initialRecord.receipt,
                timeout: 2_400
            )
            capture("06-authoritative-conversion-completed", note: "Activity exposed completion after authoritative status and fresh Library discovery.")
            rescanLibraryAndRouteExactOutput(destinationPath)
        }

        XCTAssertTrue(app.staticTexts["Run"].waitForExistence(timeout: 30), "Completed/reused model did not route into Run.")
        XCTAssertTrue(app.buttons["Preview serve"].waitForExistence(timeout: 30))
        capture("07-run-model-selected", note: "Run displayed the exact workflow-selected MLX model.")

        let servePreview = app.buttons["Preview serve"]
        XCTAssertTrue(servePreview.isEnabled, "Serve preview was unavailable for the selected completed MLX model.")
        servePreview.click()
        XCTAssertTrue(waitForButtonEnabled("Confirm and run", timeout: 300), "Serve preview did not produce a hash-gated confirmation.")
        capture("08-serve-preview-ready", note: "Serve preview enabled confirmation for the selected MLX model.")

        let preexistingServerReceipts = Set(try authoritativeServerReceipts().map(\.receipt))
        app.buttons["Confirm and run"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 180), "Confirmed serve did not route to Activity.")
        app.buttons["Run"].click()
        XCTAssertTrue(app.buttons["Stop server"].waitForExistence(timeout: 180), "Authoritative running server state was not visible in Run.")
        let visibleServerReceipt = app.staticTexts["active-server-receipt"].exists
            ? nonPlaceholderReceipt(app.staticTexts["active-server-receipt"].label)
            : nil
        let serverReceipt = try XCTUnwrap(visibleServerReceipt, "The running server did not expose a receipt that the test could own.")
        let observedServer = try XCTUnwrap(
            authoritativeServerReceipts().first(where: { $0.receipt == serverReceipt }),
            "The displayed server receipt was not returned by authoritative serve status."
        )
        XCTAssertFalse(preexistingServerReceipts.contains(observedServer.receipt), "The server receipt existed before this test confirmed serving, so cleanup cannot claim ownership.")
        XCTAssertEqual(observedServer.repo, destinationPath, "The new server receipt did not identify the workflow-selected MLX model.")
        XCTAssertEqual(observedServer.runtime, "mlx_lm", "The new server receipt did not identify the previewed runtime.")
        XCTAssertTrue(observedServer.isLive, "The new server receipt did not describe a live, argv-matched server.")
        XCTAssertTrue(receiptIsBoundToObservedServer(observedServer), "The new server receipt file did not match authoritative server status.")
        ownedServer = observedServer
        capture("09-server-running", note: "Run displayed the authoritative running server and stop control.")

        app.buttons["Stop server"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 180), "Server stop did not return to Activity.")
        capture("10-server-stopped", note: "Stop completed and returned to Activity without deleting model data.")
    }

    private func launchConfiguredApp() {
        app = XCUIApplication()
        app.launchEnvironment["MLX_AGENT_HOME"] = runtimeValues["TASK6_AGENT_HOME"]
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = runtimeValues["TASK6_CONFIG_PATH"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
            _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        }
    }

    private func restartAndReconcile(sourcePath: String, destinationPath: String, receipt: String) {
        app.terminate()
        launchConfiguredApp()

        XCTAssertTrue(app.buttons["Activity"].waitForExistence(timeout: 30), "Relaunched app did not expose Activity.")
        app.buttons["Activity"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 20))
        XCTAssertNotNil(
            waitForActivityRecord(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                receipt: receipt,
                acceptedStates: ["queued", "running", "completed"],
                timeout: 120
            ),
            "The receipt-backed selected conversion record did not survive app relaunch."
        )
        capture("05-relaunch-reconciled-receipt", note: "Relaunch restored the exact source, destination, and receipt-backed conversion record.")

        app.buttons["Library"].click()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20))
        requestFreshLibraryScan()
        searchLibrary(for: URL(fileURLWithPath: sourcePath).lastPathComponent)
        XCTAssertTrue(app.staticTexts[sourcePath].waitForExistence(timeout: 30), "Fresh post-relaunch Library scan did not preserve the exact selected source path.")
        capture("05-relaunch-fresh-library-scan", note: "Relaunch reconciliation included an explicit fresh Library scan with the selected source.")

        app.buttons["Activity"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 20))
    }

    private func rescanLibraryAndRouteExactOutput(_ destinationPath: String) {
        app.buttons["Library"].click()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20))
        requestFreshLibraryScan()
        searchLibrary(for: URL(fileURLWithPath: destinationPath).lastPathComponent)

        let outputName = URL(fileURLWithPath: destinationPath).lastPathComponent
        let outputRow = app.staticTexts[outputName].firstMatch
        XCTAssertTrue(outputRow.waitForExistence(timeout: 30), "Fresh Library scan did not display the completed output row: \(outputName)")
        outputRow.click()
        XCTAssertTrue(app.staticTexts[destinationPath].waitForExistence(timeout: 30), "Fresh Library evidence did not contain the exact completed output path.")
        capture("06-fresh-library-exact-output", note: "Fresh Library scan exposed the exact completed output before Run routing.")

        let selectForTry = app.buttons["Select for Try"]
        XCTAssertTrue(selectForTry.waitForExistence(timeout: 20), "Exact completed output did not expose the Run routing action.")
        selectForTry.click()
    }

    private func requestFreshLibraryScan() {
        let search = app.textFields["Search family, variant, path, key, or evidence"]
        XCTAssertTrue(search.waitForExistence(timeout: 180), "Library did not expose a completed scan.")
        XCTAssertTrue(waitForButtonEnabled("Refresh", timeout: 180), "Library refresh did not become available.")
        app.buttons["Refresh"].click()
        XCTAssertTrue(waitForButtonDisabled("Refresh", timeout: 10), "Explicit Library rescan did not enter its scanning state.")
        XCTAssertTrue(waitForButtonEnabled("Refresh", timeout: 180), "Explicit Library rescan did not complete.")
        XCTAssertTrue(app.staticTexts["Scanned"].exists, "Fresh Library scan timestamp evidence was absent.")
    }

    private func searchLibrary(for query: String) {
        let search = app.textFields["Search family, variant, path, key, or evidence"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        search.typeText(query)
    }

    private func waitForActivityRecord(
        sourcePath: String,
        destinationPath: String,
        receipt: String? = nil,
        acceptedStates: Set<String>,
        timeout: TimeInterval
    ) -> ActivityRecordEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = activityRecord(sourcePath: sourcePath, destinationPath: destinationPath, receipt: receipt),
               acceptedStates.contains(record.state) {
                return record
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    private func activityRecord(
        sourcePath: String,
        destinationPath: String,
        receipt expectedReceipt: String? = nil
    ) -> ActivityRecordEvidence? {
        let labels = visibleLabels()
        let source = compacted(sourcePath)
        let destination = compacted(destinationPath)
        let states = Set(["queued", "running", "completed", "failed"])

        for sourceIndex in labels.indices where compacted(labels[sourceIndex]) == source {
            let start = max(labels.startIndex, sourceIndex - 6)
            let end = min(labels.endIndex, sourceIndex + 16)
            let card = Array(labels[start..<end])
            let relativeSourceIndex = sourceIndex - start
            guard let destinationIndex = card.firstIndex(where: { compacted($0) == destination }),
                  destinationIndex > relativeSourceIndex,
                  let receiptTitleIndex = card[(destinationIndex + 1)...].firstIndex(where: { compacted($0) == "Receipt" }),
                  receiptTitleIndex + 1 < card.count else {
                continue
            }
            let receipt = card[receiptTitleIndex + 1]
            if let expectedReceipt, compacted(receipt) != compacted(expectedReceipt) { continue }
            guard let state = card.prefix(relativeSourceIndex).lazy
                .map({ self.compacted($0).lowercased() })
                .first(where: states.contains) else {
                continue
            }
            return ActivityRecordEvidence(state: state, receipt: receipt)
        }
        return nil
    }

    private func waitForConversionCompletion(
        sourcePath: String,
        destinationPath: String,
        receipt: String,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = activityRecord(sourcePath: sourcePath, destinationPath: destinationPath, receipt: receipt) {
                if record.state == "completed" { return }
                if record.state == "failed" {
                    capture("conversion-failed", note: "The selected receipt-backed Activity record reported a failed conversion.")
                    XCTFail("The selected receipt-backed real-data conversion failed.")
                    return
                }
            }
            if app.buttons["Refresh"].exists && app.buttons["Refresh"].isEnabled {
                app.buttons["Refresh"].click()
            }
            Thread.sleep(forTimeInterval: 5)
        }
        capture("conversion-timeout", note: "The selected receipt-backed conversion did not reach authoritative completion before timeout.")
        XCTFail("The selected conversion did not reach receipt-backed completion within \(Int(timeout)) seconds.")
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

    private func waitForButtonDisabled(_ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let button = app.buttons[label]
            if button.exists && !button.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
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

    private func conversionSourceIsSafeToPreview(_ sourcePath: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let sourceBytes = (attributes[.size] as? NSNumber)?.int64Value else {
            capture("03-conversion-safety-gate", note: "Source attributes were unavailable; preview was not attempted.")
            XCTFail("Conversion preview withheld because the source file type or size could not be established.")
            return false
        }
        guard sourceBytes < 29_000_000_000 else {
            capture("03-conversion-safety-gate", note: "The selected source exceeded the unattended conversion size gate; preview was not attempted.")
            XCTFail("Conversion preview withheld because the selected source is \(sourceBytes) bytes and exceeds the 29 GB unattended safety gate.")
            return false
        }
        return true
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

    private func nonPlaceholderReceipt(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Not reported") != .orderedSame else {
            return nil
        }
        return trimmed
    }

    private func authoritativeServerReceipts() throws -> [ServerReceiptEvidence] {
        guard let agentHome = runtimeValues["TASK6_AGENT_HOME"] else {
            throw HarnessError.missingAgentHome
        }
        let executable = URL(fileURLWithPath: agentHome)
            .appendingPathComponent("scripts/mlx-agent", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HarnessError.agentCLIUnavailable(executable.path)
        }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = ["serve", "status", "--json"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw HarnessError.serverStatusFailed(stderr)
        }
        guard let payload = try JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let data = payload["data"] as? [String: Any],
              let rawServers = data["servers"] as? [[String: Any]] else {
            throw HarnessError.serverStatusUnreadable
        }

        return rawServers.compactMap { raw in
            guard let receipt = raw["receipt"] as? String,
                  let repo = raw["repo"] as? String,
                  let runtime = raw["runtime"] as? String,
                  let port = raw["port"] as? Int,
                  let pid = raw["pid"] as? Int,
                  let alive = raw["alive"] as? Bool,
                  let argvMatch = raw["argv_match"] as? Bool else {
                return nil
            }
            return ServerReceiptEvidence(
                receipt: receipt,
                repo: repo,
                runtime: runtime,
                port: port,
                pid: pid,
                alive: alive,
                argvMatch: argvMatch
            )
        }
    }

    private func receiptIsBoundToObservedServer(_ server: ServerReceiptEvidence) -> Bool {
        let receiptURL = URL(fileURLWithPath: server.receipt).standardizedFileURL
        guard FileManager.default.fileExists(atPath: receiptURL.path),
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return receipt["repo"] as? String == server.repo
            && receipt["runtime"] as? String == server.runtime
            && receipt["port"] as? Int == server.port
            && receipt["pid"] as? Int == server.pid
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
        guard let ownedServer else {
            record("teardown: no server receipt owned by this test; no stop attempted")
            return
        }
        guard let currentServer = try? authoritativeServerReceipts().first(where: { $0.receipt == ownedServer.receipt }),
              currentServer == ownedServer,
              currentServer.isLive,
              receiptIsBoundToObservedServer(currentServer) else {
            record("teardown: authoritative server receipt did not match the test-owned live receipt; no stop attempted")
            return
        }
        if !app.buttons["Stop server"].exists, app.buttons["Run"].exists {
            app.buttons["Run"].click()
            _ = app.buttons["Stop server"].waitForExistence(timeout: 10)
        }
        guard app.buttons["Stop server"].exists,
              app.staticTexts["active-server-receipt"].exists,
              compacted(app.staticTexts["active-server-receipt"].label) == compacted(ownedServer.receipt) else {
            record("teardown: visible server receipt did not match the test-owned receipt; no stop attempted")
            return
        }
        app.buttons["Stop server"].click()
        record("teardown: stopped the test-owned server receipt")
    }

    private enum HarnessError: LocalizedError {
        case missingAgentHome
        case agentCLIUnavailable(String)
        case serverStatusFailed(String)
        case serverStatusUnreadable

        var errorDescription: String? {
            switch self {
            case .missingAgentHome:
                return "TASK6_AGENT_HOME is unavailable."
            case .agentCLIUnavailable(let path):
                return "mlx-agent CLI is unavailable at \(path)."
            case .serverStatusFailed(let stderr):
                return "mlx-agent serve status failed: \(stderr)"
            case .serverStatusUnreadable:
                return "mlx-agent serve status did not return a server list."
            }
        }
    }
}
