import SwiftUI

struct TailnetSharingWizard: View {
    let server: ServerInfo
    @ObservedObject var coordinator: TailnetSharingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var port = "8443"
    @State private var copyError: String?
    @State private var showsPort = false

    static func modelListCommand(apiBase: String) -> String? {
        guard let components = URLComponents(string: apiBase), components.scheme == "https",
              let host = components.host, !host.isEmpty, host == host.lowercased(),
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path == "/v1",
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), apiBase == "https://\(host):\(port)/v1" else { return nil }
        return #"""
        ( LC_ALL=C; export LC_ALL
        case "$MLX_API_KEY" in
          ''|*[![:graph:]]*) printf '%s\n' 'Set MLX_API_KEY to the endpoint key (printable characters without spaces).' >&2; exit 1 ;;
          *) key=$(printf '%s' "$MLX_API_KEY" | sed 's/[\\"]/\\&/g')
             printf 'header = "Authorization: Bearer %s"\nurl = "https://\#(host):\#(port)/v1/models"\n' "$key" | curl --config - ;;
        esac )
        """#
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Share via Tailscale").font(WorkbenchTypography.title)
            Text("Share this chat endpoint with devices allowed by your tailnet policy. Requests also require its API key.")
                .font(WorkbenchTypography.secondary)
            if let status = coordinator.status, status.state == "sharing" {
                Text(coordinator.ownsSession ? "Sharing on" : "Sharing session active")
                    .font(WorkbenchTypography.label)
                if status.endpointPort == server.port {
                    if let base = status.apiBase {
                        ServingConnectionField(title: "API URL", value: base, identifier: "tailnet-copy-api-url")
                        Text("Test from another device").font(WorkbenchTypography.label)
                        Text("Set MLX_API_KEY on the other device, then list models. Sharing status does not confirm a peer connection.")
                            .font(WorkbenchTypography.secondary)
                        if let command = Self.modelListCommand(apiBase: base) {
                            ServingConnectionField(title: "Model-list command", value: command, identifier: "tailnet-copy-test-command")
                        } else {
                            Text("The API URL is invalid. Check sharing status before testing.")
                                .foregroundStyle(WorkbenchColor.failure)
                        }
                    }
                    if let model = status.modelID { ServingConnectionField(title: "Model ID", value: model, identifier: "tailnet-copy-model-id") }
                    if let hash = server.apiKeySHA256 {
                        Button("Copy API key") {
                            do { ServedModelsSelection.copyCredential(try EndpointCredentialStore.token(for: hash)) }
                            catch { copyError = AppHost.render(error) }
                        }.accessibilityIdentifier("tailnet-copy-api-key")
                    }
                }
                if coordinator.ownsSession {
                    Button("Stop sharing", role: .destructive) { Task { await coordinator.stop() } }
                        .disabled(coordinator.busy).accessibilityIdentifier("tailnet-stop")
                }
            } else if let status = coordinator.status, status.state == "ready" {
                if let model = status.modelID { LabeledContent("Model", value: model) }
                if let base = status.apiBase { ServingConnectionField(title: "HTTPS API URL", value: base) }
                Text("Tailnet policy controls which devices can reach this node and port. Review your grants or ACLs before sharing.")
                    .font(WorkbenchTypography.secondary)
                Link("Tailscale access control", destination: URL(string: "https://tailscale.com/docs/features/access-control")!)
                Button("Start sharing") { Task { await coordinator.start(server: server) } }
                    .buttonStyle(.workbenchPrimary).disabled(coordinator.busy).accessibilityIdentifier("tailnet-start")
            } else {
                Text("Tailscale, MagicDNS and HTTPS are checked before sharing. Enabling HTTPS can publish this device’s DNS name in a certificate transparency log.")
                    .font(WorkbenchTypography.secondary)
                if coordinator.errorCode == "tailscale_missing" {
                    Link("Install Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                } else if coordinator.errorCode == "tailscale_disconnected" {
                    Text("Open Tailscale and connect this device, then check again.").font(WorkbenchTypography.secondary)
                } else if ["tailscale_dns_required", "tailscale_https_required"].contains(coordinator.errorCode ?? "") {
                    Link("Set up MagicDNS and HTTPS", destination: URL(string: "https://tailscale.com/docs/how-to/set-up-https-certificates")!)
                }
                if showsPort || coordinator.errorCode == "tailscale_port_conflict" {
                    TextField("HTTPS port", text: $port).frame(width: 120).accessibilityIdentifier("tailnet-https-port")
                }
                Button("Check again") { Task { await coordinator.check(server: server, httpsPort: Int(port) ?? 0) } }
                    .disabled(coordinator.busy).accessibilityIdentifier("tailnet-check")
            }
            if let error = coordinator.error ?? copyError { Text(error).foregroundStyle(WorkbenchColor.failure).textSelection(.enabled) }
            if coordinator.busy { ProgressView() }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(WorkbenchSpacing.lg).frame(width: 560)
        .onChange(of: coordinator.errorCode) { _, code in
            if code == "tailscale_port_conflict" { showsPort = true }
        }
        .task { await coordinator.check(server: server, httpsPort: Int(port) ?? 8443) }
    }
}
