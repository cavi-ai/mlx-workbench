import Charts
import SwiftUI

// MARK: - QuantView
// Compare tab: measured comparison of ready variants via prompt-set replay
// (premium spec 03). Key metrics stay on screen; per-prompt outputs and
// diffs stay behind disclosures. Past runs are browsable history.

struct QuantView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var comparison: ComparisonCoordinator
    private let onRouteSelection: (String) -> Void

    @State private var selectedVariants: Set<String> = []
    @State private var selectedPromptSetID: String = BuiltinPromptSets.coding.id
    @State private var selectedRunID: ComparisonRun.ID?
    @State private var diffLeftPath: String?
    @State private var diffRightPath: String?
    @State private var promoteContext: PromoteContext?
    @State private var promotedWinnerPath: String?

    /// A completed run plus its fastest variant, presented for promotion.
    struct PromoteContext: Identifiable {
        let run: ComparisonRun
        let winner: VariantResult
        var id: ComparisonRun.ID { run.id }
    }

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                measuredComparisonSection
                historySection
                if let run = selectedRun {
                    runDetail(run)
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .onAppear {
            preselectVariantFamily()
            if selectedRunID == nil {
                selectedRunID = comparison.runs.first?.id
            }
        }
    }

    // MARK: - Selection

    private var selectedRun: ComparisonRun? {
        if let selectedRunID,
           let run = comparison.runs.first(where: { $0.id == selectedRunID }) {
            return run
        }
        return comparison.runs.first
    }

    // MARK: - Measured comparison setup

    private var readyModels: [LibraryModel] {
        appHost.librarySnapshot?.models.filter { $0.readiness == .ready } ?? []
    }

    private var selectedPromptSet: PromptSet? {
        comparison.promptSets.first { $0.id == selectedPromptSetID } ?? comparison.promptSets.first
    }

    private var measuredComparisonSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Measured comparison")
            Text("Replay a prompt set against ready variants and measure real decode speed and first-token latency. One variant at a time.")
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.graphiteMuted)

            if readyModels.isEmpty {
                Text("No ready models in the latest Library snapshot.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(readyModels, id: \.item.path) { model in
                    Toggle(isOn: variantBinding(model.item.path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(WorkbenchTypography.body)
                            Text(model.item.quantization ?? model.item.path)
                                .font(WorkbenchTypography.monoUtility)
                                .foregroundColor(WorkbenchColor.graphiteMuted)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { comparisonControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { comparisonControls }
            }

            if comparison.activeRunID != nil {
                ProgressView(comparison.progressMessage ?? "Measuring…")
            }
            ErrorBanner(text: comparison.lastError)
            ErrorBanner(text: comparison.persistenceError)
        }
        .formSection {}
    }

    @ViewBuilder
    private var comparisonControls: some View {
        Picker("Prompt set", selection: $selectedPromptSetID) {
            ForEach(comparison.promptSets) { set in
                Text(set.name).tag(set.id)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)

        Button("Import my prompts") {
            if let imported = comparison.importHistory() {
                selectedPromptSetID = imported.id
            }
        }
        .buttonStyle(.bordered)
        .help("Read-only import of your opencode user prompts as a prompt set.")

        Button("Run comparison") { startRun() }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
            .disabled(selectedVariants.isEmpty || comparison.activeRunID != nil)
    }

    // MARK: - Run history

    @ViewBuilder
    private var historySection: some View {
        if !comparison.runs.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Run history")
                ForEach(comparison.runs) { run in
                    Button {
                        selectedRunID = run.id
                    } label: {
                        HStack(spacing: WorkbenchSpacing.sm) {
                            StatusBadge(state: run.state == .completed ? "completed" : "running")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.promptSetName)
                                    .font(WorkbenchTypography.body)
                                    .foregroundColor(WorkbenchColor.graphiteInk)
                                Text("\(run.results.count) variant(s) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let winner = run.winner, let tps = winner.aggregateTokensPerSecond {
                                Text(String(format: "%.0f tok/s best", tps))
                                    .font(WorkbenchTypography.monoUtility)
                                    .foregroundColor(WorkbenchColor.fluxTeal)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, WorkbenchSpacing.xs)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous)
                                .fill(run.id == selectedRun?.id ? WorkbenchColor.fluxTeal.opacity(0.12) : Color.clear)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Run \(run.promptSetName), \(run.results.count) variants")
                }
            }
            .formSection {}
        }
    }

    // MARK: - Selected run detail

    private func runDetail(_ run: ComparisonRun) -> some View {
        let successful = run.results.filter { $0.error == nil }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "\(run.promptSetName) — \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                if let winner = run.winner, run.state == .completed {
                    Label("Fastest: \(shortName(winner.modelPath))", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundColor(WorkbenchColor.fluxTeal)
                    Button("Promote winner") {
                        promoteContext = PromoteContext(run: run, winner: winner)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if promotedWinnerPath != nil {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Label("Winner promoted.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(WorkbenchColor.verifiedGreen)
                    Button("Wire into clients…") { onRouteSelection(AppRoute.clientSetup.rawValue) }
                        .controlSize(.small)
                    Button("Reclaim losers…") { onRouteSelection(AppRoute.reclaim.rawValue) }
                        .controlSize(.small)
                }
            }

            if !successful.isEmpty {
                speedChart(successful)
            }

            ForEach(run.results) { result in
                variantCard(result, run: run)
            }

            if run.state == .completed, successful.count >= 2 {
                diffSection(run)
            }
        }
        .formSection {}
        .sheet(item: $promoteContext) { context in
            PromoteWinnerSheet(
                appHost: appHost,
                context: context,
                onPromoted: { path in promotedWinnerPath = path }
            )
        }
    }

    /// One glance: per-variant speed bars — decode (out) and prefill (in) —
    /// with the run's decode average marked. Horizontal bars keep long model
    /// names readable.
    private func speedChart(_ results: [VariantResult]) -> some View {
        struct Point: Identifiable {
            let id: String
            let variant: String
            let metric: String
            let value: Double
        }
        var points: [Point] = []
        for result in results {
            let name = shortName(result.modelPath)
            if let decode = result.aggregateTokensPerSecond {
                points.append(Point(id: "\(name)-out", variant: name, metric: "Decode (out)", value: decode))
            }
            if let prefill = result.aggregatePrefillTokensPerSecond {
                points.append(Point(id: "\(name)-in", variant: name, metric: "Prefill (in, est.)", value: prefill))
            }
        }
        let decodeValues = points.filter { $0.metric == "Decode (out)" }.map(\.value)
        let average = decodeValues.isEmpty ? 0 : decodeValues.reduce(0, +) / Double(decodeValues.count)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Speed (tok/s)")
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("tok/s", point.value),
                        y: .value("Variant", point.variant)
                    )
                    .foregroundStyle(by: .value("Metric", point.metric))
                    .cornerRadius(3)
                }
                if average > 0 {
                    RuleMark(x: .value("Decode average", average))
                        .foregroundStyle(WorkbenchColor.graphiteMuted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("avg out")
                                .font(.caption2)
                                .foregroundColor(WorkbenchColor.graphiteMuted)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(position: .bottom)
            }
            .frame(height: CGFloat(max(results.count, 1)) * 44 + 40)
        }
    }

    private func variantCard(_ result: VariantResult, run: ComparisonRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shortName(result.modelPath))
                    .font(.headline)
                Spacer()
                if let tps = result.aggregateTokensPerSecond {
                    Text(String(format: "%.1f tok/s out", tps)).font(.caption)
                }
                if let prefill = result.aggregatePrefillTokensPerSecond {
                    Text(String(format: "%.0f tok/s in (est.)", prefill))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let ttft = result.aggregateTTFTSeconds {
                    Text(String(format: "TTFT %.2fs", ttft))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = result.error {
                Text(error).font(.caption).foregroundColor(WorkbenchColor.systemRed)
            } else {
                sampleStatStrip(result)
                if let toolCalls = result.totalToolCalls {
                    let valid = result.totalToolCallsValid
                    Label(
                        valid == nil
                            ? "\(toolCalls) tool call(s)"
                            : "\(toolCalls) tool call(s), \(valid!) with usable arguments",
                        systemImage: toolCalls > 0 && valid == toolCalls ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption)
                    .foregroundColor(toolCalls > 0 && valid == toolCalls ? WorkbenchColor.verifiedGreen : WorkbenchColor.thermalAmber)
                }
                DisclosureGroup("Per-prompt outputs (\(result.samples.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.samples, id: \.promptID) { sample in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(sample.promptID).font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    if let tps = sample.tokensPerSecond {
                                        Text(String(format: "%.1f tok/s", tps))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let prefill = sample.prefillTokensPerSecond {
                                        Text(String(format: "in %.0f", prefill))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    if let toolCalls = sample.toolCalls {
                                        Text("\(toolCalls) call(s): \((sample.toolNames ?? []).joined(separator: ", "))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text(sample.outputExcerpt)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                if let useCase = run.useCase {
                    Button("Set as preferred for \(useCase.title)") {
                        setPreferred(result.modelPath, for: useCase)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appHost.recommendationPreferences.preferredModelIDs[useCase] == result.modelPath)
                }
            }
        }
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.alloyCanvas)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
    }

    /// High/low/average across this variant's per-prompt samples.
    @ViewBuilder
    private func sampleStatStrip(_ result: VariantResult) -> some View {
        let values = result.samples.compactMap(\.tokensPerSecond)
        if !values.isEmpty {
            let average = values.reduce(0, +) / Double(values.count)
            HStack(spacing: WorkbenchSpacing.md) {
                statChip("avg", value: average)
                statChip("high", value: values.max() ?? average)
                statChip("low", value: values.min() ?? average)
                if let bestTTFT = ComparisonAggregation.bestTTFT(result.samples) {
                    Text(String(format: "best TTFT %.2fs", bestTTFT))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func statChip(_ label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(String(format: "%.1f", value))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(WorkbenchColor.graphiteInk)
        }
    }

    // MARK: - Output diff (phase 2)

    private func diffSection(_ run: ComparisonRun) -> some View {
        let candidates = run.results.filter { $0.error == nil }
        let left = candidates.first { $0.modelPath == diffLeftPath }
        let right = candidates.first { $0.modelPath == diffRightPath }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Output diff")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { diffControls(candidates) }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { diffControls(candidates) }
            }

            if let left, let right, left.modelPath != right.modelPath {
                ForEach(ComparisonDiff.pairs(left, right)) { pair in
                    DisclosureGroup(pair.promptID) {
                        let lines = LineDiff.diff(before: pair.left, after: pair.right)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(diffText(line))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(diffColor(line.kind))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func diffText(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: return "  \(line.text)"
        case .added: return "+ \(line.text)"
        case .removed: return "- \(line.text)"
        }
    }

    private func diffColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return WorkbenchColor.graphiteInk
        case .added: return WorkbenchColor.verifiedGreen
        case .removed: return WorkbenchColor.systemRed
        }
    }

    @ViewBuilder
    private func diffControls(_ candidates: [VariantResult]) -> some View {
        Picker("Left", selection: $diffLeftPath) {
            Text("Choose…").tag(String?.none)
            ForEach(candidates) { result in
                Text(shortName(result.modelPath))
                    .tag(String?.some(result.modelPath))
            }
        }
        Picker("Right", selection: $diffRightPath) {
            Text("Choose…").tag(String?.none)
            ForEach(candidates) { result in
                Text(shortName(result.modelPath))
                    .tag(String?.some(result.modelPath))
            }
        }
    }

    // MARK: - Actions

    private func variantBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { selectedVariants.contains(path) },
            set: { isOn in
                if isOn { selectedVariants.insert(path) } else { selectedVariants.remove(path) }
            }
        )
    }

    private func preselectVariantFamily() {
        guard selectedVariants.isEmpty,
              let selectedPath = appHost.selectedModelPath,
              let model = readyModels.first(where: {
                  $0.item.path == selectedPath || $0.outputPaths.contains(selectedPath)
              }) else { return }
        selectedVariants = Set(
            readyModels.filter { $0.item.modelKey == model.item.modelKey }.map(\.item.path)
        )
    }

    private func startRun() {
        guard let promptSet = selectedPromptSet else { return }
        let variants = readyModels
            .filter { selectedVariants.contains($0.item.path) }
            .map { (path: $0.item.path, signature: $0.item.signature) }
        comparison.start(variants: variants, promptSet: promptSet)
    }

    private func setPreferred(_ path: String, for useCase: UseCase) {
        appHost.setPreferredModel(path, for: useCase)
    }

    private func shortName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Promote winner

/// One reviewed action that chains the comparison verdict into the rest of
/// the lifecycle: mark the winner preferred for the run's use case and,
/// optionally, keep it serving on the always-on endpoint. Client wiring and
/// loser reclaim stay in their own tabs, so every mutating step keeps its
/// own preview/confirm discipline.
struct PromoteWinnerSheet: View {
    @ObservedObject var appHost: AppHost
    let context: QuantView.PromoteContext
    let onPromoted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var enableEndpoint = true
    @State private var allowUnverified = false
    @State private var isApplying = false
    @State private var errorText: String?

    private var winnerPath: String { context.winner.modelPath }
    private var winnerName: String { URL(fileURLWithPath: winnerPath).lastPathComponent }
    private var endpoint: EndpointSupervisor { appHost.endpoint }
    private var winnerVerified: Bool { appHost.isModelVerified(winnerPath) }
    private var endpointAlreadyWinner: Bool {
        endpoint.config.enabled && endpoint.config.modelPath == winnerPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Promote \(winnerName)")
                .font(.headline)
            Text(statsLine)
                .font(.caption)
                .foregroundColor(.secondary)

            if let useCase = context.run.useCase {
                Label("Set as preferred for \(useCase.title)", systemImage: "star.fill")
                    .font(.callout)
            }

            endpointSection

            ErrorBanner(text: errorText)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isApplying ? "Promoting…" : "Promote") { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 460)
    }

    private var statsLine: String {
        var parts: [String] = []
        if let tps = context.winner.aggregateTokensPerSecond {
            parts.append(String(format: "%.1f tok/s", tps))
        }
        if let ttft = context.winner.aggregateTTFTSeconds {
            parts.append(String(format: "TTFT %.2fs", ttft))
        }
        return parts.isEmpty ? "Fastest measured variant in this run." : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var endpointSection: some View {
        if endpointAlreadyWinner {
            Label("Already the always-on endpoint model (port \(endpoint.config.port)).",
                  systemImage: "checkmark.circle")
                .font(.callout)
        } else {
            Toggle(isOn: $enableEndpoint) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it always-on")
                        .font(.callout)
                    Text(endpointCaption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!winnerVerified && !allowUnverified)

            if !winnerVerified {
                Toggle("Enable anyway (unverified)", isOn: $allowUnverified)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("This model has not passed the verification canary suite.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var endpointCaption: String {
        if endpoint.config.enabled {
            return "Swap the supervised endpoint to this model; port \(endpoint.config.port) stays stable for clients."
        }
        return "Supervise this model on the stable loopback port \(endpoint.config.port), restarting it if it crashes."
    }

    private func confirm() async {
        isApplying = true
        defer { isApplying = false }
        errorText = nil

        if let useCase = context.run.useCase {
            appHost.setPreferredModel(winnerPath, for: useCase)
        }

        if enableEndpoint, !endpointAlreadyWinner {
            if endpoint.config.enabled {
                await endpoint.swap(to: winnerPath, allowUnverified: allowUnverified)
            } else {
                await endpoint.enable(
                    modelPath: winnerPath,
                    port: endpoint.config.port,
                    allowUnverified: allowUnverified
                )
            }
            if let lastError = endpoint.lastError {
                errorText = lastError
                return
            }
        }

        onPromoted(winnerPath)
        dismiss()
    }
}
