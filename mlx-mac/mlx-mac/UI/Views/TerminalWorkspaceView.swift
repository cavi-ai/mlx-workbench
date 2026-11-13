import AppKit
import SwiftTerm
import SwiftUI

/// Runs OpenCode or a shell in a chosen folder inside the Workbench window.
struct TerminalWorkspaceView: View {
    @StateObject private var session = TerminalSession()
    @AppStorage("terminal.harness") private var harnessRaw = TerminalHarness.opencode.rawValue
    @AppStorage("terminal.folder") private var folderPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Environment(\.isRouteActive) private var isRouteActive

    private var harness: TerminalHarness { TerminalHarness(rawValue: harnessRaw) ?? .opencode }

    private var folder: URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var folderName: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, WorkbenchSpacing.pageInset)
                .padding(.vertical, WorkbenchSpacing.sm)
            Divider()
            if let view = session.view {
                TerminalHost(view: view)
                if let notice {
                    Divider()
                    noticeBar(notice)
                }
            } else {
                ContentUnavailableView {
                    Label("No terminal running", systemImage: AppRoute.terminal.symbolName)
                } description: {
                    Text("Launch \(harness.title) in \(folderName). It runs through your login shell, so your PATH and shell settings apply.")
                } actions: {
                    launchButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: isRouteActive) { _, active in
            guard !active, let view = session.view, view.window?.firstResponder === view else { return }
            view.window?.makeFirstResponder(nil)
        }
    }

    private var controls: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Picker("Harness", selection: $harnessRaw) {
                ForEach(TerminalHarness.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(action: chooseFolder) {
                Label(folderName, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("Folder the terminal starts in: \(folder.path)")
            Spacer(minLength: WorkbenchSpacing.sm)
            if session.state == .running {
                Button("Stop", role: .destructive) { session.stop() }
                    .accessibilityIdentifier("terminal-stop")
            }
            launchButton
        }
    }

    private var launchButton: some View {
        Button("Launch \(harness.title)") { session.launch(harness, in: folder) }
            .buttonStyle(.workbenchPrimary)
            .disabled(session.state == .running)
            .help(session.state == .running ? "Stop the running terminal first." : "Open \(harness.title) in \(folderName).")
            .accessibilityIdentifier("terminal-launch")
    }

    private struct Notice {
        let text: String
        let failure: Bool
        let installURL: URL?
    }

    private var notice: Notice? {
        let title = session.harness?.title ?? harness.title
        switch session.state {
        case .notInstalled:
            return Notice(text: "\(title) is not on your login shell's PATH.", failure: true, installURL: session.harness?.installURL)
        case .failedToStart(let message):
            return Notice(text: "\(title) could not start: \(message)", failure: true, installURL: nil)
        case .exited(let code?) where code != 0:
            return Notice(text: "\(title) exited with code \(code).", failure: true, installURL: nil)
        case .exited(nil):
            return Notice(text: "\(title) ended after a signal.", failure: true, installURL: nil)
        case .exited:
            return Notice(text: "\(title) exited.", failure: false, installURL: nil)
        case .stopped:
            return Notice(text: "\(title) was stopped.", failure: false, installURL: nil)
        case .idle, .running:
            return nil
        }
    }

    private func noticeBar(_ notice: Notice) -> some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Label(notice.text, systemImage: notice.failure ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(notice.failure ? WorkbenchColor.failure : Color.secondary)
            if let url = notice.installURL {
                Link("Install \(session.harness?.title ?? harness.title)", destination: url)
            }
            Spacer(minLength: 0)
        }
        .font(WorkbenchTypography.body)
        .padding(.horizontal, WorkbenchSpacing.pageInset)
        .padding(.vertical, WorkbenchSpacing.xs)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder the terminal starts in."
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
    }
}

/// Hosts the session's terminal view and gives it keyboard focus.
private struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
