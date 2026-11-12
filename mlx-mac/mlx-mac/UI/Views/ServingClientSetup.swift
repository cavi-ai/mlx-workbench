import SwiftUI

/// Endpoint-specific recipes leave client-owned settings and credentials under the user's control.
enum ServingClient: String, CaseIterable, Identifiable {
    case opencode, openclaw, hermes, codex, claude
    var id: String { rawValue }
    var requiresGateway: Bool { self == .codex || self == .claude }
    var title: String {
        switch self {
        case .opencode: "OpenCode"
        case .openclaw: "OpenClaw"
        case .hermes: "Hermes"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
    var documentation: URL {
        let value = switch self {
        case .opencode: "https://opencode.ai/docs/providers/"
        case .openclaw: "https://docs.openclaw.ai/gateway/config-tools/custom-providers"
        case .hermes: "https://hermes-agent.nousresearch.com/docs/integrations/providers"
        case .codex: "https://developers.openai.com/codex/config-reference"
        case .claude: "https://code.claude.com/docs/en/llm-gateway-connect"
        }
        return URL(string: value)!
    }
    func instructions(protected: Bool) -> String {
        switch self {
        case .opencode: "Preview and apply OpenCode configuration below, or merge this provider into its config."
        case .openclaw: "Merge this provider and model selection into ~/.openclaw/openclaw.json. Restart the gateway after saving."
        case .hermes: "Run hermes model, choose Custom endpoint and Chat Completions, then enter these connection values. Hermes saves the setup for later sessions."
        case .codex: "Run this command in your project. Overrides apply to this Codex session."
        case .claude: "Run this command in your project. Uses the gateway's Anthropic Messages adapter. Model tool support determines coding-agent compatibility."
        }
    }
    func setup(server: ServerInfo) -> String? {
        guard let port = server.port, (1...65535).contains(port), server.state == "running", server.runtime != "tasks" else { return nil }
        if [.codex, .claude].contains(self), server.jit != true { return nil }
        let base = "http://127.0.0.1:\(port)/v1"
        let model = server.modelIdentity
        let protected = server.apiKeySHA256 != nil
        let key = protected ? "${WORKBENCH_API_KEY}" : "workbench"
        switch self {
        case .opencode:
            return Self.json(["provider": ["mlx-local": ["npm": "@ai-sdk/openai-compatible", "options": ["baseURL": base, "apiKey": protected ? "{env:WORKBENCH_API_KEY}" : "workbench"], "models": [model: [String: String]()]]], "model": "mlx-local/" + model])
        case .openclaw:
            var provider: [String: Any] = ["baseUrl": base, "api": "openai-completions", "models": [["id": model, "name": URL(fileURLWithPath: model).lastPathComponent]]]
            if protected { provider["apiKey"] = key } else { provider["auth"] = "none" }
            return Self.json(["models": ["mode": "merge", "providers": ["workbench": provider]], "agents": ["defaults": ["model": ["primary": "workbench/" + model]]]])
        case .hermes:
            return "hermes model\n\nAPI mode: Chat Completions\nBase URL: \(base)\nModel: \(model)\nAPI key: \(protected ? "Paste the key from API & security" : "Leave blank")"
        case .codex:
            var args = ["codex", "-c", Self.shell("model_provider=\"workbench\""), "-c", Self.shell("model=" + Self.jsonString(model)), "-c", Self.shell("model_providers.workbench.name=\"MLX Workbench\""), "-c", Self.shell("model_providers.workbench.base_url=" + Self.jsonString(base)), "-c", Self.shell("model_providers.workbench.wire_api=\"responses\"")]
            if protected { args += ["-c", Self.shell("model_providers.workbench.env_key=\"WORKBENCH_API_KEY\"")] }
            return args.joined(separator: " \\\n  ")
        case .claude:
            return "ANTHROPIC_API_KEY='' ANTHROPIC_AUTH_TOKEN=\(protected ? "\"$WORKBENCH_API_KEY\"" : "'workbench'") \\\nANTHROPIC_BASE_URL=\(Self.shell("http://127.0.0.1:\(port)")) \\\nclaude --model \(Self.shell(model))"
        }
    }
    private static func shell(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func jsonString(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

struct ServingClientSetup: View {
    let appHost: AppHost
    let server: ServerInfo
    let onRouteSelection: (AppRoute) -> Void
    @State private var client: ServingClient = .opencode
    @State private var showsWizard = false
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Picker("App", selection: $client) {
                ForEach(ServingClient.allCases) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("serving-client-picker")
            Text("Connect this app to the selected model. Review the configuration, apply it with a backup, then test the connection.")
                .font(WorkbenchTypography.secondary)
            Button("Connect \(client.title)…") { showsWizard = true }
                .buttonStyle(.workbenchPrimary).accessibilityIdentifier("serving-connect-app")
            DisclosureGroup("Manual setup") {
                Text(client.instructions(protected: server.apiKeySHA256 != nil)).font(WorkbenchTypography.secondary)
                if let setup = client.setup(server: server) {
                if server.apiKeySHA256 != nil && client != .hermes {
                    Text("Set WORKBENCH_API_KEY in the client’s environment using Copy API key in API & security. The setup below contains no secret.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                Text(setup).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(WorkbenchSpacing.md)
                    .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                    .accessibilityIdentifier("serving-client-setup")
                HStack {
                    Button("Copy setup") { ServedModelsSelection.copy(setup) }.accessibilityIdentifier("serving-copy-client-setup")
                    Link("\(client.title) documentation", destination: client.documentation)
                }
                } else {
                Text("\(client.title) requires a managed chat endpoint with Load weights on request enabled. Its gateway provides Responses and Messages compatibility.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }.font(WorkbenchTypography.secondary)
        }
        .sheet(isPresented: $showsWizard) {
            ClientSetupWizard(appHost: appHost, client: client, server: server, onRouteSelection: onRouteSelection)
        }
    }
}
