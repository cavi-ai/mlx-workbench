import AppKit
import Darwin
import SwiftTerm

/// A command-line tool the Terminal page can launch, or the shell itself.
enum TerminalHarness: String, CaseIterable, Identifiable {
    case opencode, shell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opencode: "OpenCode"
        case .shell: "Shell"
        }
    }

    /// The command the login shell runs; nil opens the shell itself.
    var command: String? {
        switch self {
        case .opencode: "opencode"
        case .shell: nil
        }
    }

    var installURL: URL? {
        switch self {
        case .opencode: URL(string: "https://opencode.ai/docs/")
        case .shell: nil
        }
    }
}

enum TerminalSessionState: Equatable {
    case idle
    case running
    /// The exit status, or nil when a signal ended the process.
    case exited(Int32?)
    case stopped
    /// The login shell could not find the harness command.
    case notInstalled
    case failedToStart(String)
}

/// One terminal on the Terminal page. A launch runs the harness through the
/// user's login shell so their PATH and shell configuration apply.
@MainActor
final class TerminalSession: ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var state: TerminalSessionState = .idle
    @Published private(set) var harness: TerminalHarness?
    @Published private(set) var title = ""
    @Published private(set) var view: LocalProcessTerminalView?
    private var stopRequested = false

    nonisolated static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    static func arguments(for harness: TerminalHarness) -> [String] {
        guard let command = harness.command else { return ["-l", "-i"] }
        return ["-l", "-i", "-c", command]
    }

    /// The parent environment with terminal identity set for the child.
    static func environment(base: [String: String], shell: String, folder: URL) -> [String] {
        var values = base.filter { !$0.key.hasPrefix("TERM_") }
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "mlx-workbench"
        values["SHELL"] = shell
        values["PWD"] = folder.path
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }
        return values.map { "\($0.key)=\($0.value)" }.sorted()
    }

    func launch(
        _ harness: TerminalHarness,
        in folder: URL,
        shell: String = TerminalSession.loginShell,
        environment base: [String: String] = ProcessInfo.processInfo.environment
    ) {
        stop()
        view?.processDelegate = nil
        let terminal = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        terminal.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.nativeForegroundColor = .textColor
        terminal.processDelegate = self
        self.harness = harness
        title = harness.title
        view = terminal
        stopRequested = false
        state = .running
        terminal.startProcess(
            executable: shell,
            args: Self.arguments(for: harness),
            environment: Self.environment(base: base, shell: shell, folder: folder),
            currentDirectory: folder.path
        )
    }

    /// Hangs up the terminal, as closing a terminal window does; interactive shells ignore SIGTERM.
    func stop() {
        guard state == .running, let pid = view?.process.shellPid, pid > 0 else { return }
        stopRequested = true
        kill(pid, SIGHUP)
    }

    /// The text on the terminal's main screen.
    func transcript() -> String {
        guard let view else { return "" }
        return String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard source === view, !title.isEmpty else { return }
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === view else { return }
        if stopRequested {
            state = .stopped
        } else {
            state = exitCode == 127 && harness?.command != nil ? .notInstalled : .exited(exitCode)
        }
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard source === view else { return }
        state = .failedToStart(String(describing: error))
    }
}
