import SwiftUI

// MARK: - SettingsView
// Edit the local mlx-workbench config: roots, agent path, output, quarantine, qbits.

struct SettingsView: View {
    @ObservedObject var appHost: AppHost

    @State private var ggufRootsText = ""
    @State private var mlxRootsText = ""
    @State private var outputDir = ""
    @State private var mlxAgentPath = ""
    @State private var host = "127.0.0.1"
    @State private var quarantineDir = ""
    @State private var qBits = 4
    @State private var signatures = true
    @State private var portText = "8765"
    @State private var verificationEnabled = true
    @State private var watchEnabled = true
    @State private var fitReserveText = "4"
    @State private var staleDaysText = "60"
    @State private var comparisonMaxTokensText = "512"
    @State private var isSaving = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                form
                StatusSection
                if let notice {
                    Text(notice).font(.caption).foregroundColor(.green)
                }
                Spacer()
            }
            .padding()
        }
        .onAppear { loadFromConfig() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "mlx-agent")
            HStack {
                TextField("Path to mlx-agent checkout", text: $mlxAgentPath)
                    .textFieldStyle(.roundedBorder)
                Button("Detect") { mlxAgentPath = Config.discoverAgentPath() }
            }

            SectionTitle(text: "Scan roots")
            VStack(alignment: .leading, spacing: 4) {
                TextField("GGUF roots (one per line)", text: $ggufRootsText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                Text("Discovered: \(appHost.discoveredRoots.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            SectionTitle(text: "MLX roots")
            TextField("MLX roots (one per line)", text: $mlxRootsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            SectionTitle(text: "Output")
            HStack {
                TextField("Output directory", text: $outputDir)
                    .textFieldStyle(.roundedBorder)
            }

            SectionTitle(text: "Integration host")
            HStack {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            SectionTitle(text: "Quarantine")
            HStack {
                TextField("Quarantine directory", text: $quarantineDir)
                    .textFieldStyle(.roundedBorder)
            }

            SectionTitle(text: "Conversion")
            HStack(spacing: 24) {
                Picker("Default bits", selection: $qBits) {
                    Text("4-bit").tag(4)
                    Text("8-bit").tag(8)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Toggle("Signatures", isOn: $signatures)
            }

            SectionTitle(text: "Premium features")
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Verify conversions (canary quality gate)", isOn: $verificationEnabled)
                Toggle("Watch & regression alerts", isOn: $watchEnabled)
                HStack {
                    TextField("Fit reserve GB", text: $fitReserveText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text("Memory kept free for the system when judging fit.")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    TextField("Stale after days", text: $staleDaysText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text("Reclaim advisor flags models unused this long.")
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    TextField("Comparison max tokens", text: $comparisonMaxTokensText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text("Per-prompt cap during measured comparisons.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Discard Changes") { loadFromConfig() }
                Spacer()
                Button("Save") { save() }
                    .disabled(isSaving)
            }
        }
        .formSection {}
    }

    private var StatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Status")
            agentStatusRows
            Divider()
            runtimeStatusRows
        }
        .formSection {}
    }

    @ViewBuilder
    private var agentStatusRows: some View {
        switch appHost.agentHealth {
        case .notConfigured:
            Label("Agent: not configured", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
        case .notUsable(_, let cli, let reason):
            Label("Agent not ready: \(reason): \(cli)", systemImage: "xmark.circle")
                .foregroundColor(.red)
        case .notFound(_, let cli):
            Label("Agent missing: \(cli)", systemImage: "xmark.circle")
                .foregroundColor(.red)
        case .ready(_, let cli):
            Label("Agent ready: \(cli)", systemImage: "checkmark.circle")
                .foregroundColor(.green)
        }
        Label("Config: \(appHost.configPath)", systemImage: "file")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var runtimeStatusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appHost.runtimeReport.convert.message).font(.caption)
            Text(appHost.runtimeReport.serve.message).font(.caption)
        }
    }

    private func loadFromConfig() {
        let config = appHost.config
        ggufRootsText = config.ggufRoots.joined(separator: "\n")
        mlxRootsText = config.mlxRoots.joined(separator: "\n")
        outputDir = config.outputDir
        mlxAgentPath = config.mlxAgentPath
        host = config.host
        quarantineDir = config.quarantineDir
        qBits = config.qBits
        signatures = config.signatures
        portText = "\(config.port)"
        verificationEnabled = config.verificationEnabled
        watchEnabled = config.watchEnabled
        fitReserveText = String(format: "%g", config.fitReserveGB)
        staleDaysText = "\(config.reclaimStaleDays)"
        comparisonMaxTokensText = "\(config.comparisonMaxTokens)"
    }

    private func save() {
        isSaving = true
        notice = nil
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            notice = "Port must be an integer between 1 and 65535."
            isSaving = false
            return
        }
        guard let reserve = Double(fitReserveText.trimmingCharacters(in: .whitespacesAndNewlines)),
              Config.FIT_RESERVE_RANGE.contains(reserve) else {
            notice = "Fit reserve must be a number between 0 and 16 GB."
            isSaving = false
            return
        }
        guard let staleDays = Int(staleDaysText.trimmingCharacters(in: .whitespacesAndNewlines)),
              Config.STALE_DAYS_RANGE.contains(staleDays) else {
            notice = "Stale days must be an integer between 2 and 365."
            isSaving = false
            return
        }
        guard let maxTokens = Int(comparisonMaxTokensText.trimmingCharacters(in: .whitespacesAndNewlines)),
              Config.COMPARISON_MAX_TOKENS_RANGE.contains(maxTokens) else {
            notice = "Comparison max tokens must be an integer between 64 and 4096."
            isSaving = false
            return
        }
        let roots = ggufRootsText
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let mlxRoots = mlxRootsText
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let newConfig = Config(
            schemaVersion: Config.SCHEMA_VERSION,
            ggufRoots: roots.isEmpty ? Config.discoverGgufRoots() : roots,
            mlxRoots: mlxRoots,
            outputDir: outputDir.isEmpty ? Config.defaults().outputDir : outputDir,
            mlxAgentPath: mlxAgentPath,
            quarantineDir: quarantineDir.isEmpty ? Config.defaults().quarantineDir : quarantineDir,
            qBits: qBits,
            signatures: signatures,
            host: host.isEmpty ? "127.0.0.1" : host,
            port: port,
            verificationEnabled: verificationEnabled,
            watchEnabled: watchEnabled,
            fitReserveGB: reserve,
            reclaimStaleDays: staleDays,
            comparisonMaxTokens: maxTokens
        )
        Task {
            defer { isSaving = false }
            _ = appHost.saveConfig(newConfig)
            if let error = appHost.lastError {
                notice = error
                return
            }
            if appHost.config.mlxAgentPath != newConfig.mlxAgentPath {
                _ = await appHost.setAgentPath(newConfig.mlxAgentPath)
            }
            notice = "Settings saved to \(appHost.configPath)"
        }
    }
}
