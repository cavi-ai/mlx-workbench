import AppKit
import SwiftUI

// MARK: - SettingsView
// Edit the local mlx-workbench config: roots, agent path, output, quarantine, qbits.
//
// The page is organized as a column of focused cards (Engine, Model locations,
// Storage, Integration, Conversion, Premium features) with a pinned save bar.
// Fields validate inline; Save is only enabled when the draft is dirty and
// every field parses inside its accepted range.

struct SettingsView: View {
    @ObservedObject var appHost: AppHost

    @State private var ggufRoots: [String] = []
    @State private var mlxRoots: [String] = []
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
    @State private var noticeIsError = false
    @State private var loadedSignature = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    statusCard
                    engineCard
                    locationsCard
                    storageCard
                    integrationCard
                    conversionCard
                    premiumCard
                }
                .padding(WorkbenchSpacing.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .overlay(WorkbenchColor.hairline)

            saveBar
        }
        .background(WorkbenchColor.alloyCanvas)
        .onAppear { loadFromConfig() }
    }

    // MARK: - Cards

    private var statusCard: some View {
        SettingsCard(title: "Engine status", subtitle: "Live health of the local agent and runtime.") {
            HStack(spacing: WorkbenchSpacing.sm) {
                agentStatusBadge
                Spacer()
                Text(appHost.configPath)
                    .font(WorkbenchTypography.monoUtility)
                    .foregroundColor(WorkbenchColor.graphiteMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(appHost.configPath)
            }
            if !appHost.runtimeReport.ok {
                Text(appHost.runtimeReport.install)
                    .font(WorkbenchTypography.body)
                    .foregroundColor(WorkbenchColor.thermalAmber)
            }
        }
    }

    @ViewBuilder
    private var agentStatusBadge: some View {
        switch appHost.agentHealth {
        case .notConfigured:
            Label("Agent not configured", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(WorkbenchColor.thermalAmber)
        case .notUsable(_, _, let reason):
            Label("Agent not usable — \(reason)", systemImage: "xmark.circle.fill")
                .foregroundColor(WorkbenchColor.systemRed)
        case .notFound(let path, _):
            Label("Agent missing at \(path)", systemImage: "xmark.circle.fill")
                .foregroundColor(WorkbenchColor.systemRed)
        case .ready(let path, _):
            Label("Agent ready — \(path)", systemImage: "checkmark.circle.fill")
                .foregroundColor(WorkbenchColor.verifiedGreen)
        }
    }

    private var engineCard: some View {
        SettingsCard(title: "Engine", subtitle: "The vendored mlx-agent checkout used for scan, prepare, and run.") {
            SettingsPathRow(
                label: "mlx-agent checkout",
                text: $mlxAgentPath,
                placeholder: "/path/to/mlx-agent",
                validate: directoryValidation
            )
            HStack(spacing: WorkbenchSpacing.xs) {
                Button("Detect") { mlxAgentPath = Config.discoverAgentPath() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("Detect looks for a vendored or installed checkout with scripts/mlx-agent.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var locationsCard: some View {
        SettingsCard(title: "Model locations", subtitle: "Directories scanned for GGUF sources and MLX outputs.") {
            SettingsRootsEditor(
                label: "GGUF roots",
                roots: $ggufRoots,
                suggestions: ggufSuggestions
            )
            Divider().overlay(WorkbenchColor.hairline)
            SettingsRootsEditor(label: "MLX roots", roots: $mlxRoots, suggestions: [])
        }
    }

    private var ggufSuggestions: [String] {
        appHost.discoveredRoots.filter { !ggufRoots.contains($0) }
    }

    private var storageCard: some View {
        SettingsCard(title: "Storage", subtitle: "Where converted models and quarantined files are written.") {
            SettingsPathRow(
                label: "Output directory",
                text: $outputDir,
                placeholder: "~/models/mlx",
                allowEmpty: true,
                validate: directoryValidation
            )
            SettingsPathRow(
                label: "Quarantine directory",
                text: $quarantineDir,
                placeholder: "~/.local/share/mlx-workbench/quarantine",
                allowEmpty: true,
                validate: directoryValidation
            )
        }
    }

    private var integrationCard: some View {
        SettingsCard(title: "Integration", subtitle: "Loopback host and port for the Workbench API. Non-loopback hosts are rejected.") {
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                SettingsField(label: "Host", error: hostError, width: 200) {
                    TextField("127.0.0.1", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsField(label: "Port", error: portError, width: 120) {
                    TextField("8765", text: $portText)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var conversionCard: some View {
        SettingsCard(title: "Conversion defaults", subtitle: "Defaults applied to new Prepare previews.") {
            HStack(spacing: WorkbenchSpacing.lg) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Default quantization")
                        .font(WorkbenchTypography.navigation)
                        .foregroundColor(WorkbenchColor.graphiteMuted)
                    Picker("Default bits", selection: $qBits) {
                        Text("4-bit").tag(4)
                        Text("8-bit").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                Toggle("Sign converted outputs", isOn: $signatures)
            }
        }
    }

    private var premiumCard: some View {
        SettingsCard(title: "Premium features", subtitle: "Quality gate, watch alerts, and advisor tuning.") {
            Toggle("Verify conversions (canary quality gate)", isOn: $verificationEnabled)
            Toggle("Watch & regression alerts", isOn: $watchEnabled)
            Divider().overlay(WorkbenchColor.hairline)
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                SettingsField(label: "Fit reserve (GB)", error: fitReserveError, width: 120) {
                    TextField("4", text: $fitReserveText)
                        .textFieldStyle(.roundedBorder)
                }
                fieldHint("Memory kept free for the system when judging fit.")
            }
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                SettingsField(label: "Stale after (days)", error: staleDaysError, width: 120) {
                    TextField("60", text: $staleDaysText)
                        .textFieldStyle(.roundedBorder)
                }
                fieldHint("Reclaim advisor flags models unused this long.")
            }
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                SettingsField(label: "Comparison max tokens", error: comparisonTokensError, width: 120) {
                    TextField("512", text: $comparisonMaxTokensText)
                        .textFieldStyle(.roundedBorder)
                }
                fieldHint("Per-prompt cap during measured comparisons.")
            }
        }
    }

    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            if let notice {
                Label(notice, systemImage: noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(noticeIsError ? WorkbenchColor.systemRed : WorkbenchColor.verifiedGreen)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundColor(WorkbenchColor.thermalAmber)
            } else {
                Text("All changes saved")
                    .font(.caption)
                    .foregroundColor(WorkbenchColor.graphiteMuted)
            }

            Spacer()

            Button("Discard") { loadFromConfig() }
                .buttonStyle(.bordered)
                .disabled(!isDirty || isSaving)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .tint(WorkbenchColor.fluxTeal)
                .disabled(!isDirty || !isValid || isSaving)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, WorkbenchSpacing.pageInset)
        .padding(.vertical, WorkbenchSpacing.sm)
        .background(WorkbenchColor.instrumentSurface)
    }

    // MARK: - Validation

    private var portError: String? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            return "Enter an integer between 1 and 65535."
        }
        return nil
    }

    private var hostError: String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "127.0.0.1" : trimmed
        guard Config.LOOPBACK_HOSTS.contains(effective) else {
            return "Loopback only: 127.0.0.1, localhost, or ::1."
        }
        return nil
    }

    private var fitReserveError: String? {
        let trimmed = fitReserveText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reserve = Double(trimmed), Config.FIT_RESERVE_RANGE.contains(reserve) else {
            return "Enter a number between 0 and 16."
        }
        return nil
    }

    private var staleDaysError: String? {
        let trimmed = staleDaysText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = Int(trimmed), Config.STALE_DAYS_RANGE.contains(days) else {
            return "Enter an integer between 2 and 365."
        }
        return nil
    }

    private var comparisonTokensError: String? {
        let trimmed = comparisonMaxTokensText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokens = Int(trimmed), Config.COMPARISON_MAX_TOKENS_RANGE.contains(tokens) else {
            return "Enter an integer between 64 and 4096."
        }
        return nil
    }

    private var isValid: Bool {
        portError == nil && hostError == nil && fitReserveError == nil
            && staleDaysError == nil && comparisonTokensError == nil
    }

    /// Warn (never block) when a directory path does not exist yet.
    private func directoryValidation(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory) {
            return "Directory does not exist yet."
        }
        if !isDirectory.boolValue {
            return "Path exists but is not a directory."
        }
        return nil
    }

    // MARK: - Dirty tracking

    private var draftSignature: String {
        [
            ggufRoots.joined(separator: "\n"),
            mlxRoots.joined(separator: "\n"),
            outputDir, mlxAgentPath, host, quarantineDir,
            "\(qBits)", "\(signatures)", portText,
            "\(verificationEnabled)", "\(watchEnabled)",
            fitReserveText, staleDaysText, comparisonMaxTokensText,
        ].joined(separator: "\u{1F}")
    }

    private var isDirty: Bool { draftSignature != loadedSignature }

    // MARK: - Load / save

    private func loadFromConfig() {
        let config = appHost.config
        ggufRoots = config.ggufRoots
        mlxRoots = config.mlxRoots
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
        notice = nil
        loadedSignature = draftSignature
    }

    private func save() {
        guard isValid else { return }
        isSaving = true
        notice = nil
        noticeIsError = true
        // Validation above guarantees these parses succeed.
        let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.port
        let reserve = Double(fitReserveText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.fitReserveGB
        let staleDays = Int(staleDaysText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.reclaimStaleDays
        let maxTokens = Int(comparisonMaxTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.comparisonMaxTokens
        let roots = ggufRoots.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let mlx = mlxRoots.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let newConfig = Config(
            schemaVersion: Config.SCHEMA_VERSION,
            ggufRoots: roots.isEmpty ? Config.discoverGgufRoots() : roots,
            mlxRoots: mlx,
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
            noticeIsError = false
            notice = "Saved to \(appHost.configPath)"
            loadedSignature = draftSignature
        }
    }
}

// MARK: - Settings building blocks

/// A titled card grouping related settings, matching the instrument-surface
/// visual language used across the Workbench.
struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(title)
                    .font(WorkbenchTypography.section)
                    .foregroundColor(WorkbenchColor.graphiteInk)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(WorkbenchSpacing.surfaceInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchColor.instrumentSurface)
        .overlay {
            RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous)
                .stroke(WorkbenchColor.hairline, lineWidth: WorkbenchSpacing.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous))
    }
}

/// A labeled field with an inline validation message underneath.
struct SettingsField<Content: View>: View {
    let label: String
    var error: String? = nil
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(label)
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)
            content()
                .frame(width: width, alignment: .leading)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(WorkbenchColor.systemRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A directory path field with a native folder picker and inline existence
/// validation. `allowEmpty` keeps the row quiet until the user types.
struct SettingsPathRow: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var allowEmpty: Bool = false
    var validate: (String) -> String?

    private var message: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowEmpty && trimmed.isEmpty { return nil }
        return validate(trimmed)
    }

    var body: some View {
        SettingsField(label: label, error: message) {
            HStack(spacing: WorkbenchSpacing.xs) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDirectory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmed)
        }
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
        }
    }
}

/// An editable list of scan-root directories. Rows flag missing directories
/// inline; rows are added via a native folder picker or from detected
/// suggestions, and removed individually.
struct SettingsRootsEditor: View {
    let label: String
    @Binding var roots: [String]
    var suggestions: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(label)
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)

            if roots.isEmpty {
                Text("No directories added.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(roots, id: \.self) { root in
                    HStack(spacing: WorkbenchSpacing.xs) {
                        if !directoryExists(root) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(WorkbenchColor.thermalAmber)
                                .help("Directory does not exist yet.")
                        }
                        Text(root)
                            .font(WorkbenchTypography.monoUtility)
                            .foregroundColor(WorkbenchColor.graphiteInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: WorkbenchSpacing.xs)
                        Button(role: .destructive) {
                            roots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(WorkbenchColor.systemRed)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(root)")
                        .accessibilityLabel("Remove \(root)")
                    }
                }
            }

            HStack(spacing: WorkbenchSpacing.xs) {
                Button("Add Folder…") { addDirectory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !suggestions.isEmpty {
                    Menu("Add Detected") {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { roots.append(suggestion) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url.path) {
            roots.append(url.path)
        }
    }
}
