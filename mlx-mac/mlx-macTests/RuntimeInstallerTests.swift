import Foundation
import AppKit
import SwiftUI
import XCTest

@testable import mlx_workbench

@MainActor
final class RuntimeInstallerTests: XCTestCase {
    func testUpdateToolDeadlineStopsItsOwnedProcess() async throws {
        let root = try directory(), pidFile = root.appendingPathComponent("update-pid")
        let result = await WorkbenchIO.perform { Result {
            try DMGReleaseInstaller.run("/bin/sh", ["-c", "echo $$ > \"$1\"; exec sleep 30", "update", pidFile.path], timeout: 0.2)
        } }
        guard case .failure(BoundedProcessCapture.Failure.timedOut) = result else { return XCTFail("Expected updater timeout") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testLoginToolDrainsLargeDiagnosticsWithoutBlocking() async throws {
        let output = try await WorkbenchIO.perform { Result {
            try LaunchAgentManager.launchctl("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null; printf installed"], timeout: 3)
        } }.get()
        XCTAssertEqual(output, "installed")
    }

    func testLoginToolDeadlineStopsItsOwnedProcess() async {
        let result = await WorkbenchIO.perform { Result {
            try LaunchAgentManager.launchctl("/bin/sleep", ["30"], timeout: 0.1)
        } }
        guard case .failure(BoundedProcessCapture.Failure.timedOut) = result else { return XCTFail("Expected login item timeout") }
    }

    func testSpeechClipCancellationStopsItsOwnedProcess() async throws {
        let root = try directory(), pidFile = root.appendingPathComponent("speech-pid")
        let task = Task {
            try await SpeechClipSynthesizer.run("/bin/sh", ["-c", "echo $$ > \"$1\"; exec sleep 30", "speech", pidFile.path])
        }
        try await waitForFile(pidFile)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testSpeechClipDeadlineAndExitFailureAreReported() async {
        do { try await SpeechClipSynthesizer.run("/bin/sleep", ["30"], timeout: 0.1); XCTFail("Expected timeout") }
        catch BoundedProcessCapture.Failure.timedOut { }
        catch { XCTFail("Unexpected error: \(error)") }
        do { try await SpeechClipSynthesizer.run("/bin/sh", ["-c", "exit 7"]); XCTFail("Expected tool failure") }
        catch SpeechCanaryError.toolFailed(_, let status) { XCTAssertEqual(status, 7) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCaptureDrainsBothPipesAndKeepsDiagnosticsOutOfStandardOutput() async throws {
        let output = try await WorkbenchIO.perform { Result {
            try BoundedProcessCapture.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null; dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null; printf answer"], timeout: 5)
        } }.get()
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.utf8.count, 262_150)
        XCTAssertTrue(output.stdout.hasSuffix("answer"))
        XCTAssertEqual(output.stderr.utf8.count, 65_536)
    }

    func testCaptureTimeoutStopsTheOwnedChild() async throws {
        let root = try directory(), pidFile = root.appendingPathComponent("pid")
        let result = await WorkbenchIO.perform { Result {
            try BoundedProcessCapture.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30 & child=$!; echo $child > \"$1\"; wait", "capture", pidFile.path], timeout: 0.3)
        } }
        guard case .failure(BoundedProcessCapture.Failure.timedOut) = result else { return XCTFail("Expected bounded timeout: \(result)") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "The child must exit before timeout is reported")
    }

    func testCaptureRejectsOversizedStandardOutput() async {
        let result = await WorkbenchIO.perform { Result {
            try BoundedProcessCapture.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null"], timeout: 5, outputLimit: 1024)
        } }
        guard case .failure(BoundedProcessCapture.Failure.outputTooLarge) = result else { return XCTFail("Expected bounded output refusal") }
    }

    func testCaptureCancellationWaitsForTheOwnedProcessToExit() async throws {
        let root = try directory(), pidFile = root.appendingPathComponent("cancel-pid")
        let cancellation = CLIInvocationCancellation()
        let task = Task {
            await WorkbenchIO.perform { Result {
                try BoundedProcessCapture.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo $$ > \"$1\"; exec sleep 30", "capture", pidFile.path],
                    timeout: 10, cancellation: cancellation)
            } }
        }
        try await waitForFile(pidFile)
        cancellation.cancel()
        let result = await task.value
        guard case .failure(is CancellationError) = result else { return XCTFail("Expected cancellation") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func report(ready: Bool) -> RuntimeReport {
        RuntimeReport(convert: ConvertStatus(ok: ready, modules: [:], executables: [:], missingModules: [],
            missingExecutables: [], install: "make install", message: ready ? "Conversion tools found." : "Missing conversion tools."),
            serve: ServeStatus(ok: ready, executables: [:], missingExecutables: [], install: "make install",
                message: ready ? "Serving tools found." : "Missing serving tools."),
            install: "make install", ok: ready, python: "/usr/bin/python3")
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
    }

    func testInstallationRequiresAnAttachedRuntimeCheck() async throws {
        let root = try directory()
        try "install:\n\t@touch unexpected\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let installer = RuntimeInstaller(repoRoot: { root })
        XCTAssertFalse(installer.canInstall)
        await installer.install()
        XCTAssertEqual(installer.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }

    func testPrerequisitesAreRecheckedBeforeMakeAndTheirEnvironmentIsUsed() async throws {
        let root = try directory()
        try "install:\n\t@echo \"$$WORKBENCH_PREREQUISITE_TEST\" > result\n"
            .write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let ready = report(ready: true)
        let plan = RuntimeInstallPrerequisites(root: root.path,
            environment: ["PATH": "/usr/bin:/bin", "WORKBENCH_PREREQUISITE_TEST": "selected-tools"],
            issues: [], pythonSummary: "Fixture")
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: { ready }, checkPrerequisites: { _ in plan })
        XCTAssertFalse(installer.canInstallBaseRuntime)
        await installer.refreshPrerequisites()
        XCTAssertTrue(installer.canInstallBaseRuntime)
        await installer.install()
        XCTAssertEqual(installer.state, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result")).trimmingCharacters(in: .whitespacesAndNewlines), "selected-tools")
    }

    private actor PrerequisiteSequence {
        var reports: [RuntimeInstallPrerequisites]
        let delayMarker: URL?
        init(_ reports: [RuntimeInstallPrerequisites], delayMarker: URL? = nil) {
            self.reports = reports
            self.delayMarker = delayMarker
        }
        func next() async -> RuntimeInstallPrerequisites {
            let result = reports.removeFirst()
            if reports.isEmpty, let delayMarker {
                try? Data().write(to: delayMarker)
                try? await Task.sleep(for: .seconds(30))
            }
            return result
        }
    }

    func testCancellingTheConfirmationRecheckNeverStartsMake() async throws {
        let root = try directory()
        try "install:\n\t@touch unexpected\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let ready = report(ready: true)
        let plan = RuntimeInstallPrerequisites(root: root.path, environment: [:], issues: [], pythonSummary: "Ready")
        let marker = root.appendingPathComponent("checking")
        let sequence = PrerequisiteSequence([plan, plan], delayMarker: marker)
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: { ready }, checkPrerequisites: { _ in await sequence.next() })
        await installer.refreshPrerequisites()
        let task = Task { await installer.install() }
        try await waitForFile(marker)
        installer.cancel()
        await task.value
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }

    func testChangedPrerequisitesPreventAnyInstallation() async throws {
        let root = try directory()
        try "install:\n\t@touch unexpected\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let ready = report(ready: true)
        let sequence = PrerequisiteSequence([
            RuntimeInstallPrerequisites(root: root.path, environment: [:], issues: [], pythonSummary: "Ready"),
            RuntimeInstallPrerequisites(root: root.path, environment: [:], issues: [.init(detail: "Python was removed")], pythonSummary: "Missing"),
        ])
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: { ready }, checkPrerequisites: { _ in await sequence.next() })
        await installer.refreshPrerequisites()
        XCTAssertTrue(installer.canInstallBaseRuntime)
        await installer.install()
        guard case .failed = installer.state else { return XCTFail("Expected prerequisite failure") }
        XCTAssertFalse(installer.canInstallBaseRuntime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }

    func testPrerequisiteTimeoutStopsItsProcessAndChild() async throws {
        let root = try directory()
        let script = """
        /bin/sleep 30 &
        child=$!
        trap 'kill "$child"; wait "$child"; exit 0' TERM
        printf '%s' "$child" > child
        wait "$child"
        """
        do {
            try await RuntimeInstaller.runInstall(repoRoot: root, executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script], timeout: 1, terminationGrace: 0.2, onLine: { _ in })
            XCTFail("Expected a bounded prerequisite check")
        } catch RuntimeInstaller.InstallError.timedOut {
            let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child"))))
            XCTAssertNotEqual(kill(pid, 0), 0)
        }
    }

    func testCancelWaitsForChildrenAndChecksBeforeRetryAndKeepsTheLog() async throws {
        let root = try directory()
        try "install:\n\t/bin/sh install.sh\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        // Exercise make's process tree with system tools; Python startup is
        // independent of the cancellation boundary and can delay its handshake.
        try """
        /bin/sleep 30 &
        child=$!
        trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
        printf '%s' "$child" > started
        printf 'Installing test tools\\n'
        /bin/sleep 15
        kill "$child" 2>/dev/null
        wait "$child" 2>/dev/null
        """.write(to: root.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        let missing = report(ready: false), ready = report(ready: true)
        var checkCount = 0
        var releaseCheck: CheckedContinuation<RuntimeReport, Never>?
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: {
            checkCount += 1
            if checkCount == 1 { return await withCheckedContinuation { releaseCheck = $0 } }
            return ready
        })
        let task = Task { await installer.install() }
        try await waitForFile(root.appendingPathComponent("started"))
        for _ in 0..<200 where !installer.logTail.contains("Installing test tools") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(installer.logTail.contains("Installing test tools"), "Progress must arrive before the installer exits")
        XCTAssertTrue(installer.canCancel)
        XCTAssertFalse(installer.canInstall)
        installer.cancel()
        XCTAssertEqual(installer.state, .stopping)
        XCTAssertFalse(installer.canCancel)
        await installer.install() // A second call must not start another attempt.
        for _ in 0..<1000 where releaseCheck == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(installer.state, .checking)
        XCTAssertFalse(installer.canInstall)
        XCTAssertEqual(checkCount, 1)
        let child = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("started"), encoding: .utf8)))
        XCTAssertNotEqual(kill(child, 0), 0, "The installer child exited before the check/retry boundary")
        XCTAssertTrue(unrelated.isRunning, "Cancellation must not stop another process")
        let release = try XCTUnwrap(releaseCheck)
        release.resume(returning: missing)
        await task.value
        XCTAssertEqual(installer.state, .cancelled)
        XCTAssertEqual(installer.runtimeReport, missing)
        XCTAssertTrue(installer.canInstall)
        XCTAssertTrue(installer.logTail.contains("Installing test tools"))
        XCTAssertNotNil(installer.recoveryMessage)
        try "install:\n\t@printf 'Retry succeeded\\n'\n".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        await installer.install()
        XCTAssertEqual(installer.state, .succeeded)
        XCTAssertEqual(installer.runtimeReport, ready)
        XCTAssertEqual(checkCount, 2)
        XCTAssertEqual(installer.logTail, ["Retry succeeded"])
        XCTAssertNil(installer.recoveryMessage)
    }

    func testCommandSuccessDoesNotClaimToolReadinessAndFailureKeepsTrailingOutput() async throws {
        let root = try directory()
        let makefile = root.appendingPathComponent("Makefile")
        let missing = report(ready: false)
        var checks = 0
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: { checks += 1; return missing })
        try "install:\n\t@printf 'Command finished'\n".write(to: makefile, atomically: true, encoding: .utf8)
        await installer.install()
        XCTAssertEqual(installer.state, .succeeded)
        XCTAssertEqual(installer.logTail, ["Command finished"])
        XCTAssertFalse(try XCTUnwrap(installer.runtimeReport).ok)
        XCTAssertNotNil(installer.recoveryMessage)
        XCTAssertTrue(try XCTUnwrap(installer.readinessSummary).contains("need setup"))
        try "install:\n\t@printf 'Package installation failed' >&2; exit 17\n".write(to: makefile, atomically: true, encoding: .utf8)
        await installer.install()
        guard case .failed = installer.state else { return XCTFail("Expected a failed installation") }
        XCTAssertTrue(installer.logTail.contains { $0.contains("Package installation failed") })
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(installer.canInstall)
    }

    func testPrecancelledAndFailedLaunchesDoNotStartACommand() async throws {
        let root = try directory()
        let token = CLIInvocationCancellation()
        token.cancel()
        do {
            try await RuntimeInstaller.runInstall(repoRoot: root, executable: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [root.appendingPathComponent("unexpected").path], cancellation: token, onLine: { _ in })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
        do {
            try await RuntimeInstaller.runInstall(repoRoot: root, executable: root.appendingPathComponent("missing"),
                arguments: [], onLine: { _ in })
            XCTFail("Expected launch failure")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testAppTerminationStopsRegisteredInstallerChildren() async throws {
        let root = try directory()
        let center = NotificationCenter()
        let registry = CLIProcessRegistry(notificationCenter: center, terminationGrace: 0.1)
        try """
        import pathlib, subprocess, time
        child = subprocess.Popen(['/bin/sleep', '30'])
        pathlib.Path('started').write_text(str(child.pid))
        try:
            time.sleep(15)
        finally:
            child.terminate()
            child.wait()
        """.write(to: root.appendingPathComponent("install.py"), atomically: true, encoding: .utf8)
        let task = Task {
            try await RuntimeInstaller.runInstall(repoRoot: root, executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["install.py"], registry: registry, terminationGrace: 0.1, onLine: { _ in })
        }
        try await waitForFile(root.appendingPathComponent("started"))
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        switch await task.result {
        case .success: XCTFail("A terminated install must not report success")
        case .failure: break
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("started"), encoding: .utf8)))
        XCTAssertNotEqual(kill(child, 0), 0)
    }

    func testInstallLogBoundsLongLinesAndKeepsTheLastOutput() async throws {
        let root = try directory()
        try "install:\n\t@/usr/bin/python3 -c \"print('x' * 100000); [print(i) for i in range(400)]; print('Final output')\"\n"
            .write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let ready = report(ready: true)
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: { ready })
        await installer.install()
        XCTAssertEqual(installer.state, .succeeded)
        XCTAssertLessThanOrEqual(installer.logTail.count, 200)
        XCTAssertTrue(installer.logTail.allSatisfy { $0.utf8.count <= 16 * 1024 })
        XCTAssertEqual(installer.logTail.last, "Final output")
    }

    func testInstallViewShowsRunningCheckingAndRecoveryWithoutClaimingReadiness() async throws {
        let root = try directory()
        let makefile = root.appendingPathComponent("Makefile")
        try "install:\n\t@printf 'Installing test tools\\n'; touch started; sleep 15\n"
            .write(to: makefile, atomically: true, encoding: .utf8)
        let missing = report(ready: false)
        var checkCount = 0
        var releaseCheck: CheckedContinuation<RuntimeReport, Never>?
        let installer = RuntimeInstaller(repoRoot: { root }, checkRuntime: {
            checkCount += 1
            if checkCount == 1 { return await withCheckedContinuation { releaseCheck = $0 } }
            return missing
        })
        let view = NSHostingView(rootView: RuntimeInstallView(installer: installer, onFinished: {})
            .padding(20).frame(width: 520, height: 440, alignment: .topLeading)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { installer.cancel(); window.close() }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Runtime-install-\(name)-compact"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let task = Task { await installer.install() }
        try await waitForFile(root.appendingPathComponent("started"))
        XCTAssertTrue(installer.canCancel)
        try await capture("running")
        installer.cancel()
        for _ in 0..<1000 where releaseCheck == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(installer.state, .checking)
        try await capture("checking")
        try XCTUnwrap(releaseCheck).resume(returning: missing)
        await task.value
        XCTAssertEqual(installer.state, .cancelled)
        try await capture("cancelled")
        try "install:\n\t@printf 'Command finished\\n'\n".write(to: makefile, atomically: true, encoding: .utf8)
        await installer.install()
        XCTAssertEqual(installer.state, .succeeded)
        XCTAssertFalse(try XCTUnwrap(installer.runtimeReport).ok)
        try await capture("command-finished-tools-missing")
        try "install:\n\t@echo 'Package install failed'; exit 1\n".write(to: makefile, atomically: true, encoding: .utf8)
        await installer.install()
        guard case .failed = installer.state else { return XCTFail("Expected installation failure") }
        try await capture("failed")
    }

    func testTaskCancellationStopsTheInstallerInsteadOfReportingSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("install.py")
        try """
        import pathlib, subprocess, time
        child = subprocess.Popen(['/bin/sleep', '30'])
        pathlib.Path('started').write_text(str(child.pid))
        try:
            print('Installing test tools', flush=True)
            time.sleep(3)
        finally:
            child.terminate()
            child.wait()
        """.write(to: script, atomically: true, encoding: .utf8)
        let task = Task {
            try await RuntimeInstaller.runInstall(repoRoot: root, executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path], onLine: { _ in })
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        task.cancel()
        switch await task.result {
        case .success: XCTFail("A cancelled installation must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
