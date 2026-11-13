import XCTest
@testable import mlx_workbench

final class TerminalSessionTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @MainActor
    func testOpenCodeRunsInTheChosenFolderWithThePathFromTheLoginShell() async throws {
        // An absolute path: system shell files may reset HOME before .zshrc runs.
        try write("path=('\(home.appendingPathComponent("bin").path)' $path)\n", to: ".zshrc")
        try write("#!/bin/sh\nprintf 'opencode ran in %s\\n' \"$(basename \"$PWD\")\"\n", to: "bin/opencode", executable: true)
        let folder = home.appendingPathComponent("project-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = TerminalSession()
        defer { session.stop() }
        session.launch(.opencode, in: folder, shell: "/bin/zsh", environment: environment())
        try await waitUntil { session.state != .running && session.transcript().contains("opencode ran in") }

        XCTAssertEqual(session.state, .exited(0))
        XCTAssertTrue(session.transcript().contains("opencode ran in \(folder.lastPathComponent)"), session.transcript())
    }

    @MainActor
    func testOpenCodeMissingFromTheLoginShellPathReportsNotInstalled() async throws {
        try write("path=(/usr/bin /bin)\n", to: ".zshrc")

        let session = TerminalSession()
        defer { session.stop() }
        session.launch(.opencode, in: home, shell: "/bin/zsh", environment: environment())
        try await waitUntil { session.state != .running }

        XCTAssertEqual(session.state, .notInstalled)
        XCTAssertTrue(session.transcript().contains("opencode"), session.transcript())
    }

    @MainActor
    func testStopEndsAnInteractiveShell() async throws {
        try write("PS1='ready> '\n", to: ".zshrc")

        let session = TerminalSession()
        defer { session.stop() }
        session.launch(.shell, in: home, shell: "/bin/zsh", environment: environment())
        try await waitUntil { session.transcript().contains("ready>") }
        XCTAssertEqual(session.state, .running)

        session.stop()
        try await waitUntil { session.state != .running }

        XCTAssertEqual(session.state, .stopped)
    }

    /// No real user files load: HOME and ZDOTDIR point at the test home.
    private func environment() -> [String: String] {
        ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory()]
    }

    private func write(_ text: String, to path: String, executable: Bool = false) throws {
        let url = home.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for the terminal") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
