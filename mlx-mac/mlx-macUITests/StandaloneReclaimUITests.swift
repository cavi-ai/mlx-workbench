import AppKit
import CryptoKit
import Foundation
import XCTest

/// Exercises Reclaim against the vendored engine and private temporary files.
final class StandaloneReclaimUITests: XCTestCase {
    private var app: XCUIApplication?
    private var temporaryDirectories: [URL] = []
    private var captureDirectory: URL?

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let directory = captureDirectory,
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in files {
                guard let data = try? Data(contentsOf: url) else { continue }
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = url.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
    }

    private func privateDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("mlx-workbench-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func text(_ fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    func testRealEngineComparisonQuarantineAndRestore() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = source.appendingPathComponent("vendor/mlx-agent", isDirectory: true)
        let script = engine.appendingPathComponent("scripts/mlx-agent")
        let scanner = engine.appendingPathComponent("src/mlx_agent/standalone_assets.py")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: script.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: scanner.path))
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["MLX_WORKBENCH_UI_PYTHON"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: python))
        let version = Process(), stdout = Pipe(), stderr = Pipe()
        version.executableURL = URL(fileURLWithPath: python)
        version.arguments = ["-c", "import sys; print('.'.join(map(str, sys.version_info[:3])))"]
        version.standardOutput = stdout; version.standardError = stderr
        try version.run(); version.waitUntilExit()
        let pythonVersion = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pythonError = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(version.terminationStatus, 0, pythonError)
        XCTAssertTrue(pythonVersion.hasPrefix("3.12."), pythonVersion)

        let privateHome = try privateDirectory("home"), modelRoot = try privateDirectory("models")
        let state = privateHome.appendingPathComponent("state"), cache = privateHome.appendingPathComponent("cache")
        let agentHome = privateHome.appendingPathComponent("agent"), quarantine = modelRoot.appendingPathComponent("saved-copies")
        let captures = privateHome.appendingPathComponent("scan-captures")
        captureDirectory = captures
        for path in [state, cache, agentHome, quarantine, captures] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: captures.path)
        let kept = modelRoot.appendingPathComponent("a.ckpt"), removed = modelRoot.appendingPathComponent("b.safetensors")
        let contents = Data(repeating: 0xA5, count: 2 * 1024 * 1024 + 17)
        try contents.write(to: kept); try contents.write(to: removed)
        let config: [String: Any] = ["mlx_agent_path": engine.path, "gguf_roots": [modelRoot.path], "mlx_roots": [modelRoot.path],
            "output_dir": modelRoot.path, "quarantine_dir": quarantine.path, "verification_enabled": false, "watch_enabled": false]
        let configURL = privateHome.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        let scriptHash = SHA256.hash(data: try Data(contentsOf: script)).map { String(format: "%02x", $0) }.joined()
        let scannerHash = SHA256.hash(data: try Data(contentsOf: scanner)).map { String(format: "%02x", $0) }.joined()
        let provenance = XCTAttachment(string: "engine=\(engine.path)\nscript_sha256=\(scriptHash)\nscanner_sha256=\(scannerHash)\npython=\(python)\npython_version=\(pythonVersion)python_status=\(version.terminationStatus)\nconfig=\(configURL.path)\nmodel_root=\(modelRoot.path)\nquarantine=\(quarantine.path)")
        provenance.name = "Real engine source and test inputs"; provenance.lifetime = .keepAlways
        add(provenance)

        let application = XCUIApplication(); app = application
        application.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configURL.path
        application.launchEnvironment["MLX_WORKBENCH_PYTHON"] = python
        application.launchEnvironment["MLX_WORKBENCH_SCAN_CAPTURE_DIR"] = captures.path
        application.launchEnvironment["XDG_STATE_HOME"] = state.path
        application.launchEnvironment["XDG_CACHE_HOME"] = cache.path
        application.launchEnvironment["MLX_AGENT_HOME"] = agentHome.path
        application.launchEnvironment["CFFIXED_USER_HOME"] = privateHome.path
        application.launchEnvironment["XDG_CONFIG_HOME"] = privateHome.path
        application.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES"]
        application.launch()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))
        let reclaim = application.buttons["Reclaim"].firstMatch
        XCTAssertTrue(reclaim.waitForExistence(timeout: 20)); reclaim.click()
        let compare = application.buttons["Compare model files"]
        XCTAssertTrue(compare.waitForExistence(timeout: 60))
        let initialScan = expectation(for: NSPredicate { _, _ in compare.isEnabled }, evaluatedWith: nil)
        wait(for: [initialScan], timeout: 60)
        compare.click()
        XCTAssertTrue(text("Found 1 group of identical model files", in: application).waitForExistence(timeout: 60))
        let scroll = application.scrollViews["reclaim-models-scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        scroll.scroll(byDeltaX: 0, deltaY: -450)
        let table = scroll.outlines.firstMatch
        let row = table.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "a.ckpt", "a.ckpt")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue(row.isHittable)
        let resultCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        resultCapture.name = "Compared model files"; resultCapture.lifetime = .keepAlways; add(resultCapture)
        let review = application.buttons["Review…"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        for _ in 0..<4 where !review.isHittable { scroll.scroll(byDeltaX: 0, deltaY: 250) }
        XCTAssertTrue(review.isHittable); review.click()
        let sheet = application.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", kept.path, kept.path)).firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", removed.path, removed.path)).firstMatch.exists)
        let remove = sheet.buttons["Remove 1 item"]
        XCTAssertFalse(remove.isEnabled)
        let acknowledge = sheet.checkBoxes["I’ve checked other apps’ model paths"]
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 10)); acknowledge.click()
        XCTAssertTrue(remove.isEnabled)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Review matching model files"; capture.lifetime = .keepAlways; add(capture)
        remove.click()
        let moved = expectation(for: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: removed.path) }, evaluatedWith: nil)
        wait(for: [moved], timeout: 60)
        XCTAssertEqual(try Data(contentsOf: kept), contents)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).contains { $0.hasSuffix("b.safetensors") })

        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate { _, _ in compare.isEnabled }, evaluatedWith: nil)
        wait(for: [ready], timeout: 60)
        compare.click()
        XCTAssertTrue(text("No identical standalone model files found", in: application).waitForExistence(timeout: 60))
        let cleanup = application.radioGroups["reclaim-tab"].radioButtons["Quarantine & cleanup"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 10)); cleanup.click()
        let putBack = application.buttons["Put back"].firstMatch
        XCTAssertTrue(putBack.waitForExistence(timeout: 20)); putBack.click()
        let restored = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: removed.path) }, evaluatedWith: nil)
        wait(for: [restored], timeout: 30)
        XCTAssertEqual(try Data(contentsOf: removed), contents)
        XCTAssertEqual(try Data(contentsOf: kept), contents)

        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        var comparedBeforeMove = false, comparedAfterMove = false
        for url in try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            let array = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
            let record = try XCTUnwrap(array.first)
            let args = try XCTUnwrap(record["argv"] as? [String])
            XCTAssertEqual(record["executable"] as? String, python)
            XCTAssertEqual(record["agentPath"] as? String, engine.path)
            XCTAssertEqual(args.first, script.path)
            XCTAssertNotNil(record["cwd"] as? String)
            XCTAssertNotNil(record["startUTC"] as? String)
            XCTAssertNotNil(record["endUTC"] as? String)
            XCTAssertGreaterThan(try XCTUnwrap(record["pid"] as? Int), 0)
            XCTAssertEqual(record["terminationStatus"] as? Int, 0)
            XCTAssertEqual(record["terminationReason"] as? String, "exit")
            XCTAssertEqual(record["stdoutTruncated"] as? Bool, false)
            XCTAssertEqual(record["stderrTruncated"] as? Bool, false)
            XCTAssertNotNil(Data(base64Encoded: try XCTUnwrap(record["stderrBase64"] as? String)))
            guard args.contains("--compare-assets") else { continue }
            let exclusion = try XCTUnwrap(args.firstIndex(of: "--asset-exclude-root"))
            XCTAssertEqual(args[exclusion + 1], quarantine.path)
            let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(record["stdoutBase64"] as? String)))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            XCTAssertEqual(envelope["status"] as? String, "ok")
            let data = try XCTUnwrap(envelope["data"] as? [String: Any])
            let report = try XCTUnwrap(data["asset_scan"] as? [String: Any])
            XCTAssertEqual(report["compared"] as? Bool, true)
            XCTAssertEqual((report["errors"] as? [Any])?.count, 0)
            XCTAssertTrue((report["excluded_roots"] as? [String] ?? []).contains(quarantine.path))
            let groups = try XCTUnwrap(data["duplicates"] as? [[String: Any]])
            if report["checked"] as? Int == 2 {
                XCTAssertEqual(report["candidates"] as? Int, 2)
                XCTAssertTrue(groups.contains { $0["verification"] as? String == "full_sha256" && $0["identity"] as? String == "asset:sha256:\(digest)" })
                comparedBeforeMove = true
            } else if report["checked"] as? Int == 0 {
                XCTAssertEqual(report["candidates"] as? Int, 0)
                XCTAssertFalse(groups.contains { $0["identity"] as? String == "asset:sha256:\(digest)" })
                let storage = try XCTUnwrap(data["storage"] as? [String: Any])
                let items = try XCTUnwrap(storage["items"] as? [[String: Any]])
                XCTAssertFalse(items.contains { ($0["path"] as? String ?? "").hasPrefix(quarantine.path + "/") })
                comparedAfterMove = true
            }
        }
        XCTAssertTrue(comparedBeforeMove)
        XCTAssertTrue(comparedAfterMove)
    }
}
