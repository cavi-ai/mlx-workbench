import AppKit
import SwiftUI

struct SettingsInputValidation {
    enum Field: String, CaseIterable, Hashable {
        case fitReserve, staleDays, comparisonTokens

        var label: String {
            switch self {
            case .fitReserve: return "Fit reserve"
            case .staleDays: return "Stale after"
            case .comparisonTokens: return "Comparison max tokens"
            }
        }

        var accessibilityIdentifier: String { "settings-field-" + rawValue }
    }

    struct InvalidField: Equatable {
        let field: Field
        let instruction: String
        var guidance: String { field.label + ": " + instruction }
    }

    var fitReserve = "4"
    var staleDays = "60"
    var comparisonTokens = "512"

    var fitReserveError: String? {
        let trimmed = fitReserve.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reserve = Double(trimmed), Config.FIT_RESERVE_RANGE.contains(reserve) else {
            return "Enter a number between 0 and 16."
        }
        return nil
    }

    var staleDaysError: String? {
        let trimmed = staleDays.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = Int(trimmed), Config.STALE_DAYS_RANGE.contains(days) else {
            return "Enter an integer between 2 and 365."
        }
        return nil
    }

    var comparisonTokensError: String? {
        let trimmed = comparisonTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokens = Int(trimmed), Config.COMPARISON_MAX_TOKENS_RANGE.contains(tokens) else {
            return "Enter an integer between 64 and 4096."
        }
        return nil
    }

    var firstInvalid: InvalidField? {
        let errors: [(Field, String?)] = [
            (.fitReserve, fitReserveError),
            (.staleDays, staleDaysError), (.comparisonTokens, comparisonTokensError),
        ]
        for (field, instruction) in errors {
            if let instruction { return InvalidField(field: field, instruction: instruction) }
        }
        return nil
    }
}

// MARK: - SettingsView
// Edit the local mlx-workbench config: roots, agent path, output, quarantine, qbits.
//
// Grouped sections on the canvas with a pinned save bar. Model locations lead
// with a ledger of what each folder contributed to the last scan. Fields
// validate inline; Save is only enabled when the draft is dirty and every
// field parses inside its accepted range. Directory checks run in
// `SettingsDirectoryProbe`, never during view evaluation.

struct SettingsView: View {
    let appHost: AppHost
    @ObservedObject private var updater: UpdateCoordinator
    @StateObject private var engineDetection = SettingsEngineDetection()
    @Environment(\.isRouteActive) private var isRouteActive
    private let probe: SettingsDirectoryProbe
    private let onRouteSelection: (AppRoute) -> Void

    init(
        appHost: AppHost,
        probe: SettingsDirectoryProbe = .live,
        onRouteSelection: @escaping (AppRoute) -> Void
    ) {
        self.appHost = appHost
        _updater = ObservedObject(wrappedValue: appHost.updater)
        self.probe = probe
        self.onRouteSelection = onRouteSelection
        _mlxAgentPath = State(initialValue: appHost.config.mlxAgentPath)
    }

    @State private var ggufRoots: [String] = []
    @State private var mlxRoots: [String] = []
    @State private var outputDir = ""
    @State private var mlxAgentPath = ""
    @State private var quarantineDir = ""
    @State private var qBits = 4
    @State private var signatures = true
    @State private var verificationEnabled = true
    @State private var watchEnabled = true
    @State private var fitReserveText = "4"
    @State private var staleDaysText = "60"
    @State private var comparisonMaxTokensText = "512"
    @State private var isSaving = false
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var loadedSignature = ""
    @State private var agentBudgetLimit = "64"
    @State private var agentBudgetReserve = "8"
    @State private var agentBudgetMessage = ""
    @State private var agentBudgetBusy = false
    @State private var localAudioChoice = LocalAudioRouting()
    @State private var localAudioEndpoints: [LocalAudioEndpoint] = []
    @State private var localAudioEndpointID = ""
    @State private var localAudioMessage = ""
    @State private var localAudioBusy = false
    @State private var layout = SettingsLayout()
    @State private var directories: [String: SettingsDirectoryState] = [:]
    @FocusState private var focusedField: SettingsInputValidation.Field?

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                            engineSection
                            locationsSection
                            storageSection
                            servingSection
                            localAudioSection
                            conversionSection
                            advisorsSection
                            updatesSection
                        }
                        .frame(maxWidth: WorkbenchSize.Settings.contentMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(WorkbenchSpacing.pageInset)
                    }
                    .defaultScrollAnchor(.top)
                    .disabled(isSaving)

                    Divider()
                        .overlay(WorkbenchColor.hairline)

                    saveBar(proxy: proxy)
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .onChange(of: viewport.size.width, initial: true) { _, width in
                layout = SettingsLayout(viewportWidth: width, previous: layout)
            }
        }
        .onAppear { loadFromConfig() }
        .task(id: probeKey) { await runProbe() }
        .task(id: appHost.config.mlxAgentPath) { await refreshAgentBudget() }
        .task { await refreshLocalAudio(loadPreference: true) }
        .onChange(of: isRouteActive) { _, active in
            if !active, engineDetection.isDetecting { engineDetection.cancel() }
        }
        .onDisappear { engineDetection.cancel() }
        .onChange(of: mlxAgentPath) { _, path in
            if let detectedPath = engineDetection.state.path, detectedPath != path { engineDetection.cancel() }
        }
    }

    // MARK: - Ledger input

    private var presentation: SettingsPresentation {
        SettingsPresentation.make(
            saved: appHost.config,
            ggufRoots: ggufRoots,
            mlxRoots: mlxRoots,
            outputDir: outputDir,
            snapshot: appHost.librarySnapshot,
            scannedRoots: appHost.scannedRoots,
            directories: directories,
            isScanning: appHost.isScanning
        )
    }

    // MARK: - Engine

    private var engineSection: some View {
        let status = SettingsEngineStatus.make(
            health: appHost.agentHealth, savedPath: appHost.config.mlxAgentPath, draftPath: mlxAgentPath
        )
        return SettingsSection(title: "Engine") {
            SettingsRow(label: "Engine status", stacked: layout.stacksRows) {
                SettingsStatusLabel(word: status.word, detail: status.detail, symbol: status.symbol, tone: status.tone)
            }
            SettingsSeparator()
            SettingsRow(label: "mlx-agent checkout", warning: pathWarning(mlxAgentPath), stacked: layout.stacksRows) {
                SettingsPathField(
                    label: "mlx-agent checkout", text: $mlxAgentPath, placeholder: "/path/to/mlx-agent",
                    detect: detectEngine, isDetecting: engineDetection.isDetecting
                )
                .disabled(engineDetection.isDetecting)
            }
            if let feedback = engineDetectionStatus {
                SettingsSeparator()
                SettingsRow(label: "Detection", stacked: layout.stacksRows) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                        if engineDetection.isDetecting { ProgressView().controlSize(.small) }
                        SettingsStatusLabel(word: feedback.word, detail: feedback.detail, symbol: feedback.symbol, tone: feedback.tone)
                            .accessibilityIdentifier("settings-engine-detection")
                    }
                    if case .notFound = engineDetection.state {
                        Button("Open Health") { onRouteSelection(.health) }.buttonStyle(.borderless)
                    }
                }
            }
            if !appHost.runtimeReport.ok {
                SettingsSeparator()
                SettingsRow(label: "Runtime", stacked: layout.stacksRows) {
                    HStack(spacing: WorkbenchSpacing.sm) {
                        if appHost.isCheckingRuntime {
                            RuntimeCheckStatusView()
                        } else {
                            Label("Runtime needs setup", systemImage: "exclamationmark.triangle.fill")
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.warning)
                            Button("Open Health") { onRouteSelection(.health) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }
            }
        } footer: {
            Text("The vendored mlx-agent checkout used for scan, prepare, and run.")
            Text(appHost.configPath)
                .font(WorkbenchTypography.compactValue)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(appHost.configPath)
        }
    }

    private var engineDetectionStatus: SettingsEngineStatus? {
        switch engineDetection.state {
        case .idle: return nil
        case .searching:
            return SettingsEngineStatus(word: "Searching for engine…", detail: "Checking standard locations and the prepared bundled runtime.", symbol: "magnifyingglass", tone: .neutral)
        case .found:
            let saved = mlxAgentPath == appHost.config.mlxAgentPath
            return SettingsEngineStatus(word: "Checkout detected", detail: saved ? "The current checkout was found. No changes needed." : "Review the path, then Save to use this checkout.", symbol: "checkmark.circle.fill", tone: .positive)
        case .notFound:
            return SettingsEngineStatus(word: "No engine detected", detail: "Your current path was kept. Choose a checkout, or open Health to prepare the bundled engine.", symbol: "exclamationmark.triangle.fill", tone: .warning)
        case .failed(_, let message):
            return SettingsEngineStatus(word: "Detection failed", detail: message + " Your current path was kept.", symbol: "exclamationmark.triangle.fill", tone: .negative)
        }
    }

    private func detectEngine() {
        guard !isSaving, !engineDetection.isDetecting else { return }
        let original = mlxAgentPath
        Task {
            guard let path = await engineDetection.detect(currentPath: original), mlxAgentPath == original else { return }
            mlxAgentPath = path
        }
    }

    // MARK: - Model locations

    private var locationsSection: some View {
        let ledger = presentation
        return SettingsSection(
            title: "Model locations", symbol: "externaldrive", pulses: appHost.isScanning && isRouteActive,
            isHero: true
        ) {
            rootsBlock(
                title: "GGUF roots", rows: ledger.gguf, empty: SettingsPresentation.emptyGGUF,
                roots: $ggufRoots, suggestions: ggufSuggestions
            )
            SettingsSeparator()
            rootsBlock(title: "MLX roots", rows: ledger.mlx, empty: SettingsPresentation.emptyMLX, roots: $mlxRoots, suggestions: [])
        } footer: {
            TimelineView(.everyMinute) { context in
                Text(SettingsPresentation.footer(snapshot: appHost.librarySnapshot, now: context.date))
            }
            if let outside = SettingsPresentation.outsideText(ledger.outsideModels) {
                Text(outside)
            }
        }
    }

    private func rootsBlock(
        title: String, rows: [SettingsLedgerRow], empty: String, roots: Binding<[String]>, suggestions: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(title)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            if rows.isEmpty {
                SettingsEmptyState(symbol: "folder.badge.plus", text: empty)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { SettingsSeparator() }
                    SettingsLedgerRowView(
                        row: row,
                        stacksFigures: layout.stacksLedgerFigures,
                        isRouteActive: isRouteActive,
                        stamp: appHost.librarySnapshot?.generatedAt,
                        isScanning: appHost.isScanning,
                        onRescan: { appHost.requestRescan() },
                        onRemove: { roots.wrappedValue.removeAll { SettingsPath.trimmed($0) == row.path } }
                    )
                }
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                Button("Add Folder…") { Self.addDirectories(to: roots) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !suggestions.isEmpty {
                    Menu("Add Detected") {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { roots.wrappedValue.append(suggestion) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, WorkbenchSize.Settings.rowVerticalPadding)
    }

    private var ggufSuggestions: [String] {
        appHost.discoveredRoots.filter { !ggufRoots.contains($0) }
    }

    // MARK: - Storage

    private var storageSection: some View {
        SettingsSection(title: "Storage") {
            SettingsRow(label: "Output directory", warning: pathWarning(outputDir), stacked: layout.stacksRows) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    SettingsPathField(label: "Output directory", text: $outputDir, placeholder: "~/models/mlx")
                    if let row = presentation.output {
                        SettingsFigureLine(
                            row: row, isRouteActive: isRouteActive, stamp: appHost.librarySnapshot?.generatedAt,
                            isScanning: appHost.isScanning, onRescan: { appHost.requestRescan() }
                        )
                    } else {
                        Text("Saving uses the default folder.")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                }
            }
            SettingsSeparator()
            SettingsRow(label: "Quarantine directory", warning: pathWarning(quarantineDir), stacked: layout.stacksRows) {
                SettingsPathField(
                    label: "Quarantine directory", text: $quarantineDir,
                    placeholder: "~/.local/share/mlx-workbench/quarantine"
                )
            }
        } footer: {
            Text("Where converted models and quarantined files are written.")
        }
    }

    // MARK: - Serving

    private var servingSection: some View {
        SettingsSection(title: "Serving") {
            SettingsRow(label: "Model endpoints", stacked: layout.stacksRows) {
                Button("Open Run") { onRouteSelection(.run) }
            }
            SettingsSeparator()
            SettingsRow(label: "Agent memory limit", hint: "Shared by MLX Agent model workers and included agent processes.", stacked: layout.stacksRows) {
                HStack {
                    TextField("Agent memory limit in GB", text: $agentBudgetLimit)
                        .frame(width: 72).accessibilityIdentifier("agent-memory-limit")
                    Text("GB")
                }
            }
            SettingsSeparator()
            SettingsRow(label: "Transient reserve", hint: "Kept inside the agent limit for temporary allocations.", stacked: layout.stacksRows) {
                HStack {
                    TextField("Transient reserve in GB", text: $agentBudgetReserve)
                        .frame(width: 72).accessibilityIdentifier("agent-memory-reserve")
                    Text("GB")
                }
            }
            SettingsSeparator()
            SettingsRow(label: "Memory policy", stacked: layout.stacksRows) {
                VStack(alignment: .leading) {
                    HStack {
                        Button("Apply budget") { Task { await applyAgentBudget() } }
                            .disabled(agentBudgetBusy || !agentBudgetInputValid)
                            .accessibilityIdentifier("apply-agent-memory-budget")
                        Button("Refresh") { Task { await refreshAgentBudget() } }.disabled(agentBudgetBusy)
                        if agentBudgetBusy { ProgressView().controlSize(.small) }
                    }
                    if !agentBudgetMessage.isEmpty {
                        Text(agentBudgetMessage).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            .textSelection(.enabled)
                    }
                }
            }
        } footer: {
            Text("Manage loopback servers and each endpoint's port in Run.")
        }
    }

    private var agentBudgetInputValid: Bool {
        guard let limit = Double(agentBudgetLimit), let reserve = Double(agentBudgetReserve) else { return false }
        return limit.isFinite && reserve.isFinite && limit > 0 && reserve >= 0 && reserve < limit
    }

    @MainActor private func refreshAgentBudget() async {
        guard !WorkbenchStatePaths.isHostedUnitTest() else { return }
        agentBudgetBusy = true
        defer { agentBudgetBusy = false }
        do {
            guard let budget = try await appHost.api.agentMemoryBudget() else {
                agentBudgetMessage = "No shared agent memory budget is configured."
                return
            }
            agentBudgetLimit = String(Double(budget.limitBytes) / 1e9)
            agentBudgetReserve = String(Double(budget.reserveBytes) / 1e9)
            agentBudgetMessage = String(format: "%.1f GB accounted · %.1f GB limit", Double(budget.accountedBytes) / 1e9, Double(budget.limitBytes) / 1e9)
        } catch { agentBudgetMessage = error.localizedDescription }
    }

    @MainActor private func applyAgentBudget() async {
        guard let limit = Double(agentBudgetLimit), let reserve = Double(agentBudgetReserve), agentBudgetInputValid else { return }
        agentBudgetBusy = true
        defer { agentBudgetBusy = false }
        do {
            let budget = try await appHost.api.configureAgentMemoryBudget(limitGB: limit, reserveGB: reserve)
            agentBudgetMessage = budget.withinBudget ? "Budget applied. New model jobs use the shared limit." : "Budget applied. Unload an idle model before starting another job."
        } catch { agentBudgetMessage = error.localizedDescription }
    }

    private var localAudioSection: some View {
        SettingsSection(title: "Artist Brain local audio") {
            SettingsRow(label: "Sound effects and ambience", stacked: layout.stacksRows) {
                Picker("Audio source", selection: $localAudioChoice.source) {
                    ForEach(LocalAudioRouting.Source.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }.labelsHidden().accessibilityIdentifier("local-audio-source")
            }
            if localAudioChoice.source == .specific {
                SettingsSeparator()
                SettingsRow(label: "Served model", hint: "Start a compatible audio task endpoint in Run, then refresh.", stacked: layout.stacksRows) {
                    Picker("Served audio model", selection: $localAudioEndpointID) {
                        Text("Select a served model").tag("")
                        ForEach(localAudioEndpoints, id: \.baseURL) { endpoint in
                            Text("\(URL(fileURLWithPath: endpoint.model).lastPathComponent) · \(endpoint.port) · \(endpoint.kind == "music_generation" ? "Music (experimental FX)" : "Sound effects")")
                                .tag(endpoint.baseURL)
                        }
                    }.labelsHidden().accessibilityIdentifier("local-audio-model")
                }
            }
            SettingsSeparator()
            SettingsRow(label: "Audio routing", stacked: layout.stacksRows) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    HStack {
                        Button("Save audio choice") { Task { await saveLocalAudio() } }
                            .disabled(localAudioBusy || (localAudioChoice.source == .specific && !localAudioEndpoints.contains { $0.baseURL == localAudioEndpointID }))
                            .accessibilityIdentifier("save-local-audio")
                        Button("Refresh models") { Task { await refreshLocalAudio(loadPreference: false) } }.disabled(localAudioBusy)
                        if localAudioBusy { ProgressView().controlSize(.small) }
                    }
                    if !localAudioMessage.isEmpty {
                        Text(localAudioMessage).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                    }
                }
            }
        } footer: {
            Text("Use the music model shares Artist Brain's music endpoint and JIT worker. FX and ambience from a music model are experimental and may contain music. A specific model must advertise a compatible audio task. In Run, the purpose picker uses the model being inspected.")
        }
    }

    @MainActor private func refreshLocalAudio(loadPreference: Bool) async {
        guard !WorkbenchStatePaths.isHostedUnitTest() else { return }
        localAudioBusy = true
        defer { localAudioBusy = false }
        do {
            if loadPreference {
                localAudioChoice = try await Task.detached { try LocalAudioRoutingStore.load() }.value
                localAudioEndpointID = localAudioChoice.endpoint?.baseURL ?? ""
            }
            localAudioEndpoints = try await discoverLocalAudio()
            if !localAudioEndpoints.contains(where: { $0.baseURL == localAudioEndpointID }) { localAudioEndpointID = "" }
            localAudioMessage = "\(localAudioEndpoints.count) compatible local endpoint(s). Save to apply the choice to Artist Brain."
        } catch { localAudioMessage = error.localizedDescription }
    }

    @MainActor private func discoverLocalAudio() async throws -> [LocalAudioEndpoint] {
        let snapshot = try await appHost.api.discoverServingServices()
        let candidates = snapshot.servers.compactMap { server -> LocalAudioEndpoint? in
            guard server.state == "running", server.runtime == "tasks", server.apiKeySHA256 == nil,
                  let path = server.path, let port = server.port, let receipts = server.receiptsDirectory,
                  let kind = ["sound_effects", "music_generation"].first(where: { server.taskKinds?.contains($0) == true }) else { return nil }
            return LocalAudioEndpoint(model: path, port: port, kind: kind, receiptsDirectory: receipts)
        }
        return await Task.detached {
            candidates.filter { (try? $0.validate()) != nil }.sorted { $0.port < $1.port }
        }.value
    }

    @MainActor private func saveLocalAudio() async {
        localAudioBusy = true
        defer { localAudioBusy = false }
        do {
            var choice = localAudioChoice
            if choice.source == .specific {
                let endpoints = try await discoverLocalAudio()
                guard let endpoint = endpoints.first(where: { $0.baseURL == localAudioEndpointID }) else {
                    throw LocalAudioRoutingError.invalidEndpoint
                }
                choice.endpoint = endpoint
            } else { choice.endpoint = nil }
            let saved = choice
            try await Task.detached { try LocalAudioRoutingStore.save(saved) }.value
            localAudioChoice = choice
            localAudioMessage = "Saved. Artist Brain uses \(choice.source == .music ? "its music endpoint" : "the selected audio endpoint") for sound effects and ambience."
        } catch { localAudioMessage = error.localizedDescription }
    }

    // MARK: - Conversion defaults

    private var conversionSection: some View {
        SettingsSection(title: "Conversion defaults") {
            SettingsRow(label: "Default quantization", stacked: layout.stacksRows) {
                Picker("Default bits", selection: $qBits) {
                    ForEach(Config.Q_BITS_CHOICES.sorted(), id: \.self) { bits in Text("\(bits)-bit").tag(bits) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: WorkbenchSize.Settings.bitsPickerWidth, alignment: .leading)
            }
            SettingsSeparator()
            SettingsToggleRow(title: "Sign converted outputs", isOn: $signatures, stacked: layout.stacksRows)
        } footer: {
            Text("Defaults applied to new Prepare previews.")
        }
    }

    // MARK: - Advisors

    private var advisorsSection: some View {
        SettingsSection(title: "Advisors") {
            SettingsToggleRow(
                title: "Verify conversions (canary quality gate)", isOn: $verificationEnabled, stacked: layout.stacksRows
            )
            SettingsSeparator()
            SettingsToggleRow(title: "Watch & regression alerts", isOn: $watchEnabled, stacked: layout.stacksRows)
            SettingsSeparator()
            SettingsRow(
                label: "Fit reserve", hint: "Memory kept free for the system when judging fit.",
                message: fitReserveError, stacked: layout.stacksRows
            ) {
                unitField(
                    "Fit reserve in gigabytes", prompt: "4", text: $fitReserveText, unit: "GB", field: .fitReserve
                )
            }
            SettingsSeparator()
            SettingsRow(
                label: "Stale after", hint: "Reclaim advisor flags models unused this long.",
                message: staleDaysError, stacked: layout.stacksRows
            ) {
                unitField("Stale after days", prompt: "60", text: $staleDaysText, unit: "days", field: .staleDays)
            }
            SettingsSeparator()
            SettingsRow(
                label: "Comparison max tokens", hint: "Per-prompt cap during measured comparisons.",
                message: comparisonTokensError, stacked: layout.stacksRows
            ) {
                unitField("Comparison maximum tokens", prompt: "512", text: $comparisonMaxTokensText, unit: "tokens", field: .comparisonTokens)
            }
        } footer: {
            Text("Quality gate, watch alerts, and advisor tuning.")
        }
    }

    private func unitField(
        _ label: String, prompt: String, text: Binding<String>, unit: String, field: SettingsInputValidation.Field
    ) -> some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityIdentifier(field.accessibilityIdentifier)
                .id(field)
                .focused($focusedField, equals: field)
                .frame(width: WorkbenchSize.Settings.fieldNarrow, alignment: .leading)
            Text(unit)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        SettingsSection(title: "Updates") {
            SettingsRow(label: "Channel", hint: updater.installsReleases ? updater.channel.releaseBlurb : updater.channel.blurb, stacked: layout.stacksRows) {
                Picker("Channel", selection: $updater.channel) {
                    ForEach(UpdateCoordinator.Channel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: WorkbenchSize.Settings.channelPickerMaximum, alignment: .leading)
                .disabled(updater.phase == .applying)
            }
            SettingsSeparator()
            SettingsRow(label: "Status", stacked: layout.stacksRows) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WorkbenchSpacing.xs) {
                            updateButtons
                            updateSummary
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            HStack(spacing: WorkbenchSpacing.xs) { updateButtons }
                            updateSummary
                        }
                    }
                    if case .available(let offer) = updater.phase, offer.dirtyFiles > 0 {
                        Text("\(offer.dirtyFiles) uncommitted change(s) in the checkout — commit or discard them before updating.")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !updater.logTail.isEmpty {
                        DisclosureGroup("Update log") {
                            ScrollView {
                                Text(updater.logTail.joined(separator: "\n"))
                                    .font(WorkbenchTypography.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: WorkbenchSize.Settings.updateLogMaxHeight)
                        }
                    }
                }
            }
        } footer: {
            Text(updater.installsReleases
                ? "Install new releases or nightly builds from GitHub."
                : "Keep this app in step with its own repository.")
            if updater.repoRoot == nil && !updater.installsReleases {
                Text("This app is not running from a repository checkout, so in-app updates are unavailable. Install updates by replacing the app with a newly built one.")
            }
        }
    }

    @ViewBuilder
    private var updateButtons: some View {
        Button("Check for updates") {
            Task { await updater.check() }
        }
        .buttonStyle(.bordered)
        .disabled(!updater.canUpdate)
        if case .available(let offer) = updater.phase {
            Button("Update to \(offer.target)") {
                Task { await updater.apply(offer: offer) }
            }
            .buttonStyle(.workbenchPrimary)
        }
        if case .updated = updater.phase {
            Button(updater.installsReleases ? "Relaunch" : "Rebuild & relaunch") {
                Task { await updater.rebuildAndRelaunch() }
            }
            .buttonStyle(.workbenchPrimary)
        }
        if case .checking = updater.phase {
            ProgressView().controlSize(.small)
        }
        if case .applying = updater.phase {
            ProgressView().controlSize(.small)
        }
    }

    private var updateSummary: some View {
        Text(updater.summary)
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Save bar

    private func saveBar(proxy: ScrollViewProxy) -> some View {
        let invalid = validation.firstInvalid
        let failure = noticeIsError ? notice : nil
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let invalid {
                Label {
                    Text(invalid.guidance).accessibilityIdentifier("settings-save-guidance")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.failure)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let failure {
                Label {
                    Text(failure).accessibilityIdentifier("settings-save-error")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.failure)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: WorkbenchSpacing.sm) {
                if invalid != nil {
                    Button("Fix field") { fixField(proxy: proxy) }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                        .accessibilityIdentifier("settings-fix-field")
                } else if failure == nil {
                    saveStateFeedback
                }

                Spacer()

                Button("Discard") { loadFromConfig() }
                    .buttonStyle(.bordered)
                    .disabled(!isDirty || isSaving || engineDetection.isDetecting)
                    .accessibilityIdentifier("settings-discard")
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(!isDirty || !isValid || isSaving || engineDetection.isDetecting)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings-save")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, WorkbenchSpacing.pageInset)
        .padding(.vertical, WorkbenchSpacing.sm)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var saveStateFeedback: some View {
        if isSaving {
            ProgressView().controlSize(.small)
            Text("Saving settings…").font(WorkbenchTypography.secondary).accessibilityIdentifier("settings-action-status")
        } else if let feedback = engineDetectionStatus {
            if engineDetection.isDetecting { ProgressView().controlSize(.small) }
            Label {
                Text(feedback.word).accessibilityIdentifier("settings-action-status")
            } icon: {
                Image(systemName: feedback.symbol)
            }
                .font(WorkbenchTypography.secondary).foregroundStyle(feedback.tone.color)
        } else if isDirty {
            Text("Unsaved changes")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.warning)
        } else if let notice {
            Label {
                Text(notice).accessibilityIdentifier("settings-save-success")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.success)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("All changes saved")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    private func fixField(proxy: ScrollViewProxy) {
        guard !isSaving, let invalid = validation.firstInvalid else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(invalid.field, anchor: .center)
            focusedField = invalid.field
        }
    }

    // MARK: - Validation

    private var validation: SettingsInputValidation {
        SettingsInputValidation(fitReserve: fitReserveText,
            staleDays: staleDaysText, comparisonTokens: comparisonMaxTokensText)
    }

    private var fitReserveError: String? { validation.fitReserveError }
    private var staleDaysError: String? { validation.staleDaysError }
    private var comparisonTokensError: String? { validation.comparisonTokensError }
    private var isValid: Bool { validation.firstInvalid == nil }

    /// The probe's non-blocking warning for a draft path; nil until the probe has answered.
    private func pathWarning(_ path: String) -> String? {
        directories[SettingsPath.trimmed(path)]?.warning
    }

    // MARK: - Directory probe

    private struct ProbeKey: Hashable {
        let paths: [String]
        let scannedAt: Date?
    }

    private var probeKey: ProbeKey {
        let paths = ([mlxAgentPath, outputDir, quarantineDir] + ggufRoots + mlxRoots)
            .map(SettingsPath.trimmed)
            .filter { !$0.isEmpty }
        return ProbeKey(paths: paths, scannedAt: appHost.librarySnapshot?.generatedAt)
    }

    private func runProbe() async {
        let paths = probeKey.paths
        let probe = probe
        let result = await Task.detached(priority: .utility) { probe.states(for: paths) }.value
        guard !Task.isCancelled else { return }
        directories = result
    }

    // MARK: - Dirty tracking

    private var draftSignature: String {
        [
            ggufRoots.joined(separator: "\n"),
            mlxRoots.joined(separator: "\n"),
            outputDir, mlxAgentPath, quarantineDir,
            "\(qBits)", "\(signatures)",
            "\(verificationEnabled)", "\(watchEnabled)",
            fitReserveText, staleDaysText, comparisonMaxTokensText,
        ].joined(separator: "\u{1F}")
    }

    private var isDirty: Bool { draftSignature != loadedSignature }

    // MARK: - Load / save

    private func loadFromConfig() {
        engineDetection.cancel()
        let config = appHost.config
        ggufRoots = config.ggufRoots
        mlxRoots = config.mlxRoots
        outputDir = config.outputDir
        mlxAgentPath = config.mlxAgentPath
        quarantineDir = config.quarantineDir
        qBits = config.qBits
        signatures = config.signatures
        verificationEnabled = config.verificationEnabled
        watchEnabled = config.watchEnabled
        fitReserveText = String(format: "%g", config.fitReserveGB)
        staleDaysText = "\(config.reclaimStaleDays)"
        comparisonMaxTokensText = "\(config.comparisonMaxTokens)"
        notice = nil
        loadedSignature = draftSignature
    }

    private func save() {
        guard isValid, !isSaving, !engineDetection.isDetecting else { return }
        engineDetection.cancel()
        isSaving = true
        notice = nil
        noticeIsError = true
        // Validation above guarantees these parses succeed.
        let reserve = Double(fitReserveText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.fitReserveGB
        let staleDays = Int(staleDaysText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.reclaimStaleDays
        let maxTokens = Int(comparisonMaxTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? appHost.config.comparisonMaxTokens
        let roots = ggufRoots.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let mlx = mlxRoots.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var newConfig = appHost.config
        newConfig.ggufRoots = roots
        newConfig.mlxRoots = mlx
        newConfig.outputDir = outputDir.isEmpty ? Config.defaults(ggufRoots: []).outputDir : outputDir
        newConfig.mlxAgentPath = mlxAgentPath
        newConfig.quarantineDir = quarantineDir.isEmpty ? Config.defaults(ggufRoots: []).quarantineDir : quarantineDir
        newConfig.qBits = qBits
        newConfig.signatures = signatures
        newConfig.verificationEnabled = verificationEnabled
        newConfig.watchEnabled = watchEnabled
        newConfig.fitReserveGB = reserve
        newConfig.reclaimStaleDays = staleDays
        newConfig.comparisonMaxTokens = maxTokens
        Task { [newConfig] in
            defer { isSaving = false }
            guard await appHost.saveSettingsConfig(newConfig) else {
                notice = appHost.lastError ?? "Settings could not be saved."
                return
            }
            noticeIsError = false
            notice = "Saved to \(appHost.configPath)"
            loadedSignature = draftSignature
        }
    }

    // MARK: - Folder picker

    private static func addDirectories(to roots: Binding<[String]>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.wrappedValue.contains(url.path) {
            roots.wrappedValue.append(url.path)
        }
    }
}

// MARK: - Settings building blocks

/// A titled group on the canvas: header, one inset surface of rows, footer text.
struct SettingsSection<Content: View, Footer: View>: View {
    let title: String
    var symbol: String? = nil
    var pulses = false
    var isHero = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.accent)
                        .livePulse(pulses)
                }
                Text(title)
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.ink)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, WorkbenchSize.Settings.groupPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchColor.surface, in: shape)
                .background(isHero ? WorkbenchColor.accent.opacity(.wash) : Color.clear, in: shape)
                .overlay {
                    shape.strokeBorder(isHero ? WorkbenchColor.accent.opacity(.stroke) : WorkbenchColor.hairline, lineWidth: WorkbenchSpacing.hairline)
                }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs, content: footer)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, WorkbenchSpacing.xxs)
        }
    }
}

struct SettingsSeparator: View {
    var body: some View {
        Divider().overlay(WorkbenchColor.hairline)
    }
}

/// A label with its control: side by side when the group is wide, stacked when narrow.
struct SettingsRow<Control: View>: View {
    let label: String
    var hint: String? = nil
    var message: String? = nil
    var warning: String? = nil
    let stacked: Bool
    @ViewBuilder var control: () -> Control

    private var labelText: some View {
        Text(label)
            .font(WorkbenchTypography.body)
            .foregroundStyle(WorkbenchColor.ink)
    }

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            control()
            if let hint {
                Text(hint)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning {
                Text(warning)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    labelText
                    controlColumn
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSize.Settings.labelGap) {
                    labelText.frame(width: WorkbenchSize.Settings.labelColumn, alignment: .leading)
                    controlColumn
                }
            }
        }
        .padding(.vertical, WorkbenchSize.Settings.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A boolean as a label/control row: visible title in the label column, switch in the control column.
struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let stacked: Bool

    var body: some View {
        SettingsRow(label: title, stacked: stacked) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// A status word with its symbol and an optional sentence.
struct SettingsStatusLabel: View {
    let word: String
    let detail: String?
    let symbol: String
    let tone: SettingsTone

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Label(word, systemImage: symbol)
                .font(WorkbenchTypography.body)
                .foregroundStyle(tone.color)
            if let detail {
                Text(detail)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SettingsTone {
    var color: Color {
        switch self {
        case .neutral: return WorkbenchColor.muted
        case .positive: return WorkbenchColor.success
        case .warning: return WorkbenchColor.warning
        case .negative: return WorkbenchColor.failure
        }
    }
}

/// A designed empty state: symbol and one sentence; the add controls beneath resolve it.
struct SettingsEmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A directory path field with a native folder picker and an optional Detect action.
struct SettingsPathField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var detect: (() -> Void)? = nil
    var isDetecting = false

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            TextField(label, text: $text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(label)
            if let detect {
                Button(isDetecting ? "Detecting…" : "Detect", action: detect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Look for an existing checkout or prepared bundled engine. Nothing is installed or saved.")
                    .accessibilityIdentifier("settings-detect-engine")
            }
            Button("Choose…") { chooseDirectory() }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

/// A ledger state as symbol, sentence and, where a rescan resolves it, the action.
struct SettingsFigureLine: View {
    let row: SettingsLedgerRow
    let isRouteActive: Bool
    let stamp: Date?
    let isScanning: Bool
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Image(systemName: row.state.symbol)
                .foregroundStyle(row.state.tone == .neutral ? WorkbenchColor.muted : row.state.tone.color)
                .livePulse(isRouteActive && row.state == .scanning)
            SettingsFigureText(state: row.state, isRouteActive: isRouteActive, stamp: stamp)
            if row.state.offersRescan {
                Button("Rescan", action: onRescan)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isScanning)
            }
        }
        .font(WorkbenchTypography.secondary)
    }
}

/// Figures that count up through a numeric transition only when a new snapshot lands.
struct SettingsFigureText: View {
    let state: SettingsLedgerRow.State
    let isRouteActive: Bool
    let stamp: Date?

    var body: some View {
        Text(state.figures)
            .font(state.isCounted ? WorkbenchTypography.tabular : WorkbenchTypography.secondaryTabular)
            .foregroundStyle(
                state.isCounted ? WorkbenchColor.ink
                    : state.tone == .neutral ? WorkbenchColor.muted : state.tone.color
            )
            .contentTransition(isRouteActive ? .numericText() : .identity)
            .workbenchAnimation(value: stamp)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One folder in the ledger: symbol, name over full path, and what it contributed.
struct SettingsLedgerRowView: View {
    let row: SettingsLedgerRow
    let stacksFigures: Bool
    let isRouteActive: Bool
    let stamp: Date?
    let isScanning: Bool
    let onRescan: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
            Image(systemName: row.state.symbol)
                .font(WorkbenchTypography.cardTitle)
                .foregroundStyle(row.state.tone == .warning ? WorkbenchColor.warning : WorkbenchColor.accent)
                .frame(width: WorkbenchSize.Settings.symbolColumn)
                .livePulse(isRouteActive && row.state == .scanning)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(row.name)
                    .font(WorkbenchTypography.cardTitle)
                    .foregroundStyle(WorkbenchColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.path)
                    .font(WorkbenchTypography.compactValue)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.path)
                if stacksFigures { figures(alignment: .leading) }
            }
            .frame(minWidth: WorkbenchSize.Settings.pathMinimum, maxWidth: .infinity, alignment: .leading)
            if !stacksFigures {
                figures(alignment: .trailing)
                    .frame(width: WorkbenchSize.Settings.figuresWidth, alignment: .trailing)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(WorkbenchColor.muted)
            }
            .buttonStyle(.plain)
            .frame(width: WorkbenchSize.Settings.removeColumn)
            .help("Remove \(row.path)")
            .accessibilityLabel("Remove \(row.path)")
        }
        .padding(.vertical, WorkbenchSpacing.xs)
    }

    private func figures(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: WorkbenchSpacing.xxxs) {
            SettingsFigureText(state: row.state, isRouteActive: isRouteActive, stamp: stamp)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            if row.state.offersRescan {
                Button("Rescan", action: onRescan)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isScanning)
            }
        }
    }
}
