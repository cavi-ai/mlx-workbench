import SwiftUI

struct ClientSetupWizard: View {
    let appHost: AppHost
    let onRouteSelection: (AppRoute) -> Void
    @StateObject private var session: ClientSetupSession
    @ObservedObject private var wiring: WiringCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?

    init(appHost: AppHost, client: ServingClient = .opencode, server: ServerInfo? = nil,
         onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        _wiring = ObservedObject(wrappedValue: appHost.wiring)
        _session = StateObject(wrappedValue: ClientSetupSession(wiring: appHost.wiring, client: client, server: server,
            servers: { try await appHost.api.serveStatus() }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Connect app").font(WorkbenchTypography.title)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(session.busy)
            }
            Text(stageTitle).font(WorkbenchTypography.emphasis)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    if session.stage == .choose { selection }
                    else { identity }
                    if let error = session.error { ErrorBanner(text: error).accessibilityIdentifier("connect-app-error") }
                    switch session.stage {
                    case .choose: EmptyView()
                    case .review: review
                    case .saved: saved
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 700, height: 620)
        .interactiveDismissDisabled(session.busy)
        .task { await session.load() }
        .onDisappear { operation?.cancel() }
    }
    private var stageTitle: String {
        switch session.stage {
        case .choose: "Choose your app and model"
        case .review: "Review setup"
        case .saved: session.result == nil ? "Configuration saved" : "Connection tested"
        }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Picker("App", selection: Binding(get: { session.client }, set: { session.choose(client: $0) })) {
                ForEach(ServingClient.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("connect-app-client").disabled(session.busy)
            if let found = session.appFound {
                HStack {
                    Label(found ? "App found" : "App not found in standard locations", systemImage: found ? "checkmark.circle" : "app.dashed")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    if !found { Link("Install \(session.client.title)", destination: session.client.documentation) }
                }
                if !found { Text("You can save the connection now and install the app later.").font(WorkbenchTypography.secondary) }
            }
            if session.servers.isEmpty {
                Text("Start a chat or vision-language endpoint in Serving, then return to connect your app.")
                    .font(WorkbenchTypography.secondary)
                Button("Open Serving") { dismiss(); onRouteSelection(.run) }
            } else {
                Picker("Model endpoint", selection: Binding(get: { session.selectedID }, set: { session.choose(serverID: $0) })) {
                    Text("Choose a running endpoint").tag(String?.none)
                    ForEach(session.servers) { server in
                        Text(server.modelIdentity + " · :" + String(server.port ?? 0)).tag(Optional(server.id))
                    }
                }.accessibilityIdentifier("connect-app-endpoint").disabled(session.busy)
                identity
                if !session.supported {
                    Text("\(session.client.title) needs a saved endpoint with Load weights on request enabled. Choose a compatible endpoint or change its Memory settings in Serving.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                }
            }
            Text("Setup updates this app’s user configuration. Existing settings are retained; a backup supports rollback.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Button("Refresh apps and endpoints") { run { await session.load() } }.disabled(session.busy)
        }
    }
    @ViewBuilder private var identity: some View {
        if let server = session.selected, let endpoint = WireEndpoint(server: server) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                if session.stage != .choose { Text(session.client.title).font(WorkbenchTypography.emphasis) }
                Text(endpoint.baseURL).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    .accessibilityIdentifier("connect-app-reviewed-url")
                Text(endpoint.modelName).font(WorkbenchTypography.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("connect-app-reviewed-model")
                Label(server.apiKeySHA256 == nil ? "Loopback · no API key required" : "API key required · supplied automatically to this app",
                      systemImage: server.apiKeySHA256 == nil ? "network" : "lock.shield")
                    .font(WorkbenchTypography.secondary)
            }.padding(WorkbenchSpacing.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        }
    }
    @ViewBuilder private var review: some View {
        if let plan = session.plan {
            Text(plan.configPath).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            Text(plan.before == nil ? "Create this configuration file." : "Update this configuration and keep a backup.")
                .font(WorkbenchTypography.secondary)
            if plan.rewritesFile {
                Text("The file will be reformatted. Comments may be removed; unrelated setting values are retained.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            }
            if session.selected?.apiKeySHA256 != nil {
                Text("The inference key is written to this app’s configuration, readable only by your macOS user. The review masks key values.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            DisclosureGroup("Configuration changes") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    ForEach(Array(plan.redactedDiff.enumerated()), id: \.offset) { _, line in
                        Text((line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text)
                            .font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            .foregroundStyle(line.kind == .added ? WorkbenchColor.success : line.kind == .removed ? WorkbenchColor.failure : WorkbenchColor.muted)
                    }
                }
            }.font(WorkbenchTypography.secondary)
        }
    }
    private var saved: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if let receipt = session.receipt {
                Label("\(session.client.title) configuration saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(WorkbenchColor.success).accessibilityIdentifier("connect-app-saved")
                Text(receipt.configPath).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            }
            if let result = session.result {
                Label("Server responded over \(result.protocolName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(WorkbenchColor.success).accessibilityIdentifier("connect-app-tested")
                Text(result.answer).font(WorkbenchTypography.secondary).textSelection(.enabled)
                Text("Open a new \(session.client.title) session to use this model. Project settings or launch options can override user settings.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                Text("Test sends one short prompt using this client’s API protocol and the endpoint’s inference key. It may load the selected model.")
                    .font(WorkbenchTypography.secondary)
            }
            if session.client == .openclaw {
                Text("Restart an existing OpenClaw gateway to reload its configuration.").font(WorkbenchTypography.secondary)
            }
            if session.canUndo {
                Button("Undo setup") { session.undo() }
                    .disabled(session.busy).accessibilityIdentifier("connect-app-undo")
            }
            if session.appFound == false { Link("Install \(session.client.title)", destination: session.client.documentation) }
        }
    }
    private var actions: some View {
        HStack {
            if session.busy { ProgressView().controlSize(.small) }
            if session.stage != .choose {
                Button(session.stage == .saved ? "Connect another app" : "Back") { session.back() }.disabled(session.busy)
            }
            Spacer()
            switch session.stage {
            case .choose:
                Button("Review setup") { run { await session.preview() } }
                    .disabled(session.busy || !session.supported).buttonStyle(.workbenchPrimary)
                    .accessibilityIdentifier("connect-app-review")
            case .review:
                Button("Apply setup") { run { await session.apply() } }.disabled(session.busy)
                    .buttonStyle(.workbenchPrimary).accessibilityIdentifier("connect-app-apply")
            case .saved:
                if session.busy {
                    Button("Stop test") { operation?.cancel() }
                } else if session.result != nil {
                    Button("Test again") { run { await session.test() } }.accessibilityIdentifier("connect-app-test")
                    Button("Done") { dismiss() }.buttonStyle(.workbenchPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("Test connection") { run { await session.test() } }
                        .buttonStyle(.workbenchPrimary).accessibilityIdentifier("connect-app-test")
                }
            }
        }
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !session.busy else { return }
        operation = Task { await action() }
    }
}
