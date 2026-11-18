import AppKit
import SwiftTerm
import SwiftUI

/// Runs OpenCode or a shell in a chosen folder inside the Workbench window.
struct TerminalWorkspaceView: View {
    let appHost: AppHost
    var onRouteSelection: (AppRoute) -> Void = { _ in }
    @StateObject private var session = TerminalSession()
    @AppStorage("terminal.harness") private var harnessRaw = TerminalHarness.opencode.rawValue
    @AppStorage("terminal.folder") private var folderPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var setupNotice: SetupNotice?
    @State private var isCheckingSetup = false
    @State private var showsSetup = false

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
            if let setupNotice {
                setupBar(setupNotice)
                Divider()
            }
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
        .onChange(of: harnessRaw) { _, _ in setupNotice = nil }
        .sheet(isPresented: $showsSetup, onDismiss: { setupNotice = nil }) {
            ClientSetupWizard(appHost: appHost, client: .opencode, server: setupNotice?.server,
                              onRouteSelection: onRouteSelection)
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
        Button("Launch \(harness.title)", action: launch)
            .buttonStyle(.workbenchPrimary)
            .disabled(session.state == .running || isCheckingSetup)
            .help(session.state == .running ? "Stop the running terminal first." : "Open \(harness.title) in \(folderName).")
            .accessibilityIdentifier("terminal-launch")
    }

    /// OpenCode launches directly only when its global config lists a model a running Workbench chat server serves.
    private func launch() {
        setupNotice = nil
        let target = folder
        guard harness == .opencode else { session.launch(harness, in: target); return }
        isCheckingSetup = true
        Task {
            defer { isCheckingSetup = false }
            let notice: SetupNotice?
            do {
                let servers = try await appHost.api.serveStatus()
                notice = Self.setupNotice(await appHost.wiring.openCodeSetup(servers: servers), servers: servers)
            } catch {
                notice = SetupNotice(text: "Server status is unavailable, so OpenCode's Workbench models were not checked.",
                                     server: nil, serverRunning: true)
            }
            if let notice { setupNotice = notice } else { session.launch(.opencode, in: target) }
        }
    }

    private struct SetupNotice {
        let text: String
        /// Preselected in setup: the only running chat server.
        let server: ServerInfo?
        let serverRunning: Bool
    }

    private static func setupNotice(_ result: OpenCodeSetupCheck.Result, servers: [ServerInfo]) -> SetupNotice? {
        let chat = servers.filter { WireEndpoint(server: $0) != nil }
        let detail: String
        switch result {
        case .ready: return nil
        case .noWorkbenchEntry: detail = "Its config has no Workbench provider."
        case .notServing(let port): detail = "Its Workbench provider points at port \(port), where no running chat server serves its model."
        case .unreadable(let reason): detail = "Its config needs review: \(reason)."
        }
        let stopped = chat.isEmpty ? " No chat server is running; start one in Run." : ""
        return SetupNotice(text: "OpenCode has no Workbench models. \(detail)\(stopped)",
                           server: chat.count == 1 ? chat[0] : nil, serverRunning: !chat.isEmpty)
    }

    private func setupBar(_ notice: SetupNotice) -> some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(WorkbenchColor.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if notice.serverRunning {
                Button("Set up OpenCode") { showsSetup = true }
                    .accessibilityIdentifier("terminal-setup-opencode")
            } else {
                Button("Open Run") { onRouteSelection(.run) }
                    .accessibilityIdentifier("terminal-open-run")
            }
            Button("Launch anyway") { setupNotice = nil; session.launch(.opencode, in: folder) }
                .accessibilityIdentifier("terminal-launch-anyway")
        }
        .font(WorkbenchTypography.body)
        .padding(.horizontal, WorkbenchSpacing.pageInset)
        .padding(.vertical, WorkbenchSpacing.xs)
        .accessibilityIdentifier("terminal-opencode-setup")
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
