import AppKit
import SwiftUI

// MARK: - ModelActions

/// The actions a Library model offers, shared by the inspector's action row
/// and the table's context menu so both route through the same coordinator
/// calls.
@MainActor
struct ModelActions {
    let appHost: AppHost
    let model: LibraryModel
    let onRouteSelection: (AppRoute) -> Void

    /// Ready models have nothing to prepare; offering it only renders a
    /// "destination already exists" blocker.
    var canPrepare: Bool { model.readiness != .ready }

    /// Run and Compare serve chat models only; other types are not offered them.
    var canServe: Bool { ModelTaskPresentation.isServable(model) }

    func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.item.path, forType: .string)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.item.path)])
    }

    func prepare() {
        appHost.selectedModelPath = model.item.path
        appHost.modelWorkflow.inspect(source: model.item, snapshot: appHost.librarySnapshot)
        onRouteSelection(.prepare)
    }

    func compare() {
        appHost.selectedModelPath = model.item.path
        onRouteSelection(.compare)
    }

    func run() {
        appHost.selectedModelPath = model.item.path
        if model.readiness == .ready {
            appHost.modelWorkflow.prepareServe(model: model)
        }
        onRouteSelection(.run)
    }
}

// MARK: - ModelDetailsPresentation

/// Pure rows for the identity card: the path once, source paths only when
/// they differ from it, and conditional rows only when they carry a fact.
enum ModelDetailsPresentation {
    static func identityRows(for model: LibraryModel, prepareDestination: String?) -> [DetailRow] {
        var rows: [DetailRow] = [DetailRow("Path", model.item.path)]
        let extraSources = model.sourcePaths.filter { $0 != model.item.path }
        if !extraSources.isEmpty {
            rows.append(DetailRow("Source", extraSources.joined(separator: "\n")))
        }
        if !model.outputPaths.isEmpty {
            rows.append(DetailRow("Outputs", model.outputPaths.joined(separator: "\n")))
        }
        rows.append(DetailRow("Architecture", known(model.item.architecture)))
        if let task = model.item.task {
            rows.append(DetailRow("Type", task.type.title))
            if !task.useCases.isEmpty {
                rows.append(DetailRow("Use cases", task.useCases.map(ModelTaskPresentation.useCaseTitle).joined(separator: ", ")))
            }
            rows.append(DetailRow("Classified by", "\(task.source) (\(task.confidence))"))
        }
        if let draft = model.item.draft {
            rows.append(DetailRow(
                "Drafter for",
                "\(draft.target ?? "an unnamed target") — speculative decoding only; it borrows that model's embeddings and output head, so it runs beside it, never alone.",
                prose: true
            ))
        }
        rows.append(DetailRow("Parameters", known(model.item.parameters)))
        rows.append(DetailRow("Quantization", known(model.item.quantization)))
        rows.append(DetailRow("Size", LibraryTablePresentation.byteCount(model.item.bytes)))
        if let tensors = model.item.tensorCount {
            rows.append(DetailRow("Tensors", "\(tensors)"))
        }
        if let shard = model.item.shard?.trimmingCharacters(in: .whitespacesAndNewlines), !shard.isEmpty {
            rows.append(DetailRow("Shard", shard))
        }
        let modified = model.item.modifiedAt.map {
            Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened)
        }
        rows.append(DetailRow("Modified", modified ?? "Unknown"))
        rows.append(DetailRow("Readiness", "\(model.readiness.title) — \(readinessExplanation(for: model))", prose: true))
        if model.readiness == .duplicate {
            rows.append(DetailRow("Duplicate status", "Duplicate variant reported by the latest library scan. Review the raw model evidence before preparing it.", prose: true))
        }
        if model.readiness == .needsConversion, let prepareDestination {
            rows.append(DetailRow("Prepare destination", prepareDestination))
        }
        return rows
    }

    static func readinessExplanation(for model: LibraryModel) -> String {
        switch model.readiness {
        case .ready:
            if !model.outputPaths.isEmpty {
                return "An MLX output path was detected for this local model."
            }
            return "The scan marked this local model ready."
        case .needsConversion:
            return "No local MLX output was detected, so this model still needs Prepare work."
        case .needsRuntime:
            return "The scan marked the runtime as missing for this model."
        case .incompleteCache:
            return model.item.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The scan reported incomplete local metadata for this model."
        case .unsupported:
            if model.item.readable == false {
                return "The local file was not readable during the scan."
            }
            return "The scan marked this local model unsupported."
        case .duplicate:
            return "This local variant is redundant with another copy in the same family group."
        case .quarantined:
            return "This model is quarantined and should not be used for Prepare or Run."
        }
    }

    static func known(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    /// The identity line under the name: repo id for cache entries, otherwise
    /// the scan's model key, followed by quantization and size.
    static func identityLine(for model: LibraryModel) -> String {
        let identity = HFRepoID.forPath(model.item.path) ?? known(model.item.modelKey)
        return [identity, known(model.item.quantization), LibraryTablePresentation.byteCount(model.item.bytes)]
            .joined(separator: " · ")
    }

    /// Header subline candidates, longest first: "{type} · {quant} · {size}",
    /// then without the size, then without the quantization. Parts the scan
    /// does not know are left out. The header shows the first that fits.
    static func headerLines(for model: LibraryModel) -> [String] {
        let type = model.item.task?.type.title
        let quantization = known(model.item.quantization) == "Unknown" ? nil : known(model.item.quantization)
        let size = LibraryTablePresentation.byteCount(model.item.bytes)
        let candidates = [
            [type, quantization, size],
            [type, quantization],
            [type],
        ].map { $0.compactMap { $0 }.joined(separator: " · ") }
        var lines: [String] = []
        for line in candidates where !line.isEmpty && !lines.contains(line) {
            lines.append(line)
        }
        return lines.isEmpty ? [size] : lines
    }

    static func headerLine(for model: LibraryModel) -> String {
        headerLines(for: model)[0]
    }

    /// Labels whose values are identifiers and stay monospaced.
    private static let identifierLabels: Set<String> = ["Path", "Source", "Outputs", "Prepare destination"]

    private static let headerFactLabels: Set<String> = ["Type", "Quantization", "Size"]

    /// The Details rows: every `identityRows` row, leaving out unknown values,
    /// an Outputs row identical to Path, and the type, quantization and size
    /// the header already states. Facts are prose; identifiers stay monospaced.
    static func displayRows(for model: LibraryModel, prepareDestination: String?) -> [DetailRow] {
        let rows = identityRows(for: model, prepareDestination: prepareDestination)
        let path = rows.first { $0.label == "Path" }?.value
        let headerFacts = Set((headerLines(for: model).first ?? "").components(separatedBy: " · "))
        return rows.compactMap { row in
            guard row.value != "Unknown" else { return nil }
            if row.label == "Outputs", row.value == path { return nil }
            if headerFactLabels.contains(row.label), headerFacts.contains(row.value) { return nil }
            if row.prose || identifierLabels.contains(row.label) { return row }
            return DetailRow(row.label, row.value, prose: true)
        }
    }
}

// MARK: - Fit region

/// The inspector's fit region. The only inspector view that observes the
/// memory monitor, so a probe re-renders this region and not the details.
struct LibraryInspectorFit: View {
    @ObservedObject var resources: SystemResourceMonitor
    let reserveGB: Double
    let hardware: HardwareProfile
    let model: LibraryModel

    var body: some View {
        let budget = ModelBudgetPresentation(
            memory: resources.memory,
            reserveGB: reserveGB,
            contextTokens: resources.contextTokens,
            model: model,
            hardware: hardware,
            hasProbed: resources.hasProbed
        )
        let fit = LibraryFitPresentation.make(
            model: model,
            memory: resources.memory,
            hasProbed: resources.hasProbed,
            contextTokens: resources.contextTokens,
            reserveGB: reserveGB,
            hardware: hardware
        )
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Label("Fits now", systemImage: "memorychip")
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(WorkbenchColor.muted)
                    .symbolRenderingMode(.hierarchical)
                switch fit.state {
                case .estimated:
                    CapacityBar(presentation: budget, isCompact: true)
                    HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                        Image(systemName: budget.verdictSymbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(budget.tone.color)
                        Text(budget.verdictText)
                            .font(WorkbenchTypography.body)
                            .foregroundStyle(WorkbenchColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Estimated at \(budget.contextText)")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                case .redacted:
                    CapacityBar(presentation: budget, isCompact: true)
                    Text("Reading memory")
                        .font(WorkbenchTypography.body)
                        .foregroundStyle(WorkbenchColor.muted)
                        .redacted(reason: .placeholder)
                case .unavailable, .notEstimated:
                    Text(fit.help)
                        .font(WorkbenchTypography.body)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fit.accessibilityLabel)
    }
}

// MARK: - ModelDetailsView

struct ModelDetailsView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var verification: VerificationCoordinator

    let model: LibraryModel
    let onRouteSelection: (AppRoute) -> Void

    init(appHost: AppHost, model: LibraryModel, onRouteSelection: @escaping (AppRoute) -> Void) {
        self.appHost = appHost
        _verification = ObservedObject(wrappedValue: appHost.verification)
        self.model = model
        self.onRouteSelection = onRouteSelection
    }

    private var actions: ModelActions {
        ModelActions(appHost: appHost, model: model, onRouteSelection: onRouteSelection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                header
                LibraryInspectorFit(
                    resources: appHost.resources,
                    reserveGB: appHost.config.fitReserveGB,
                    hardware: appHost.hardwareProfile,
                    model: model
                )
                actionRow

                if showsImageGeneration {
                    WorkbenchSurface {
                        ImageGenerationPanel(
                            coordinator: appHost.imageGeneration,
                            modelPath: model.item.path,
                            isPrimary: !actions.canPrepare
                        )
                    }
                }

                WorkbenchSurface {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        SectionTitle(text: "Details")
                        DetailGrid(rows: ModelDetailsPresentation.displayRows(for: model, prepareDestination: prepareDestination))
                    }
                }

                WorkbenchSurface { verificationSection }
                WorkbenchSurface { performanceSection }
                WorkbenchSurface { lineageSection }

                if let error = model.item.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    WorkbenchSurface {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                            SectionTitle(text: "Observed issue")
                            InlineMessage(kind: .warning, text: error)
                        }
                    }
                }

                WorkbenchSurface {
                    DisclosureGroup("Raw model evidence") {
                        let evidence = LibraryPresentation.userFacingEvidence(model.evidence)
                            + ["signature=\(ModelDetailsPresentation.known(model.item.signature))"]
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            ForEach(evidence, id: \.self) { entry in
                                Text(entry)
                                    .font(WorkbenchTypography.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.top, WorkbenchSpacing.xxs)
                    }
                }
            }
            .padding(WorkbenchSpacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Every image model shows its Generate panel. Before Prepare has produced
    /// the MLX output, Prepare to run is the one prominent action and the
    /// panel's Generate is secondary and disabled.
    private var showsImageGeneration: Bool {
        model.item.task?.type == .imageGeneration
    }

    /// Ready models that are neither served nor rendered have no routing
    /// action; Verify now is their one prominent button.
    private var verifyIsPrimary: Bool {
        model.readiness == .ready && !actions.canServe && model.item.task?.type != .imageGeneration
    }

    private var header: some View {
        let lines = ModelDetailsPresentation.headerLines(for: model)
        return HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            Image(systemName: (model.item.task?.type ?? .other).symbolName)
                .font(WorkbenchTypography.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WorkbenchColor.accent)
                .frame(width: WorkbenchSize.symbolTile, height: WorkbenchSize.symbolTile)
                .background(
                    WorkbenchColor.accent.opacity(.fill),
                    in: RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(model.displayName)
                    .font(WorkbenchTypography.title)
                    .lineLimit(2)
                    .truncationMode(.tail)
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: index < lines.count - 1, vertical: false)
                    }
                }
                if model.readiness != .ready {
                    StatusBadge(state: model.readiness.rawValue)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One prominent button per state; Copy Path and Reveal in Finder live in
    /// the overflow menu. When the row does not fit, the secondary buttons and
    /// the menu drop to a second line; labels never shorten.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.xs) {
                primaryAction
                secondaryActions
                Spacer(minLength: 0)
                overflowMenu
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                primaryAction
                HStack(spacing: WorkbenchSpacing.xs) {
                    secondaryActions
                    Spacer(minLength: 0)
                    overflowMenu
                }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if actions.canPrepare {
            Button("Prepare to run") { actions.prepare() }
                .buttonStyle(.borderedProminent)
                .fixedSize()
        } else if actions.canServe {
            Button("Select for Run") { actions.run() }
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if actions.canServe {
            if actions.canPrepare {
                Button("Select for Run") { actions.run() }
                    .fixedSize()
            }
            Button("Select for Compare") { actions.compare() }
                .fixedSize()
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Copy Path") { actions.copyPath() }
            Button("Reveal in Finder") { actions.revealInFinder() }
        } label: {
            Label("More actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(model.displayName)")
    }

    private var prepareDestination: String? {
        guard model.readiness == .needsConversion else { return nil }
        switch ModelWorkflowResolver.destination(for: model.item, library: appHost.librarySnapshot) {
        case .reuseExisting(let existing):
            return "Existing equivalent MLX model: \(existing.item.path)"
        case .available(let destination):
            return destination.path
        case .blocked(let destination, let reason):
            return "\(destination.path)\nBlocked: \(reason)"
        }
    }

    // MARK: - Verification

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Verification")
            DetailGrid(rows: verificationRows)
            if model.readiness == .ready {
                if verifyIsPrimary {
                    Button("Verify now") { verifyNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(appHost.verification.activeModelPath != nil)
                } else {
                    Button("Verify now") { verifyNow() }
                        .disabled(appHost.verification.activeModelPath != nil)
                }
            }
        }
    }

    private func verifyNow() {
        appHost.verification.verifyNow(modelPath: model.item.path, signature: model.item.signature)
    }

    private var verificationRows: [DetailRow] {
        switch appHost.verification.status(for: model.item.path, signature: model.item.signature) {
        case .verified(let report):
            return [DetailRow("Status", "Verified (canary suite v\(report.suiteVersion))", prose: true)] + metricRows(report)
        case .failed(let report):
            return [DetailRow("Status", "Failed — \(report.outcome.summary)", prose: true)] + metricRows(report)
        case .keptAnyway(let report):
            return [DetailRow("Status", "Kept despite a failed verification", prose: true)] + metricRows(report)
        case .stale(let report):
            return [DetailRow("Status", "Stale — the file changed since verification on \(format(report.finishedAt))", prose: true)]
        case .inProgress:
            return [DetailRow("Status", appHost.verification.progressMessage ?? "Verification in progress…", prose: true)]
        case .unverified:
            return [DetailRow("Status", "Not verified by the canary suite.", prose: true)]
        }
    }

    private func metricRows(_ report: VerificationReport) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let tps = report.tokensPerSecond {
            rows.append(DetailRow("Decode speed", String(format: "%.1f tok/s%@", tps, report.metricsEstimated ? " (estimated)" : "")))
        }
        if let ttft = report.timeToFirstTokenSeconds {
            rows.append(DetailRow("First token", String(format: "%.2fs", ttft)))
        }
        for canary in report.canaries {
            rows.append(DetailRow(canary.title, canary.passed ? "Passed" : "Failed: \(canary.failureReason ?? "unknown")", prose: true))
        }
        return rows
    }

    // MARK: - Performance

    /// Aggregated measured evidence across all completed comparison runs for
    /// this exact model (path + signature). Numbers only — the charts and
    /// per-prompt detail live in Compare.
    private var performanceSection: some View {
        let profile = ([model.item.path] + model.outputPaths)
            .lazy
            .compactMap {
                ModelPerformanceProfile.derive(
                    modelPath: $0,
                    signature: model.item.signature,
                    runs: appHost.comparison.runs
                )
            }
            .first
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Performance")
            if let profile {
                DetailGrid(rows: performanceRows(profile))
            } else {
                Text("No measured runs for this model yet.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                if actions.canServe {
                    Button("Measure in Compare") { actions.compare() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func performanceRows(_ profile: ModelPerformanceProfile) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let measuredAt = profile.lastMeasuredAt {
            rows.append(DetailRow("Last measured", format(measuredAt)))
        }
        rows.append(DetailRow("Measured runs", "\(profile.runCount)"))
        if let average = profile.averageTokensPerSecond {
            rows.append(DetailRow("Decode speed", String(format: "avg %.1f tok/s", average)))
        }
        if let best = profile.bestTokensPerSecond, let worst = profile.worstTokensPerSecond {
            rows.append(DetailRow("Range", String(format: "%.1f – %.1f tok/s", worst, best)))
        }
        if let prefill = profile.averagePrefillTokensPerSecond {
            rows.append(DetailRow("Prefill speed", String(format: "avg %.0f tok/s (est.)", prefill)))
        }
        if let ttft = profile.bestTTFTSeconds {
            rows.append(DetailRow("Best first token", String(format: "%.2fs", ttft)))
        }
        return rows
    }

    // MARK: - Lineage

    private var lineageSection: some View {
        let lineage = appHost.lineage(for: model.item.path)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                SectionTitle(text: "Lineage")
                Spacer()
                Button("Copy Markdown") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(lineage.markdown, forType: .string)
                }
                .controlSize(.small)
                Button("Export JSON…") { exportLineage(lineage) }
                    .controlSize(.small)
            }
            if lineage.events.isEmpty {
                Text("No recorded history for this model yet.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                ForEach(lineage.events) { event in
                    HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                        Image(systemName: event.kind.systemImage)
                            .foregroundStyle(event.kind == .verificationFailed ? WorkbenchColor.failure : WorkbenchColor.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            HStack {
                                Text(event.kind.title).font(WorkbenchTypography.emphasis)
                                if event.stale {
                                    Text("predates current bytes")
                                        .font(WorkbenchTypography.secondary)
                                        .foregroundStyle(WorkbenchColor.warning)
                                }
                                Spacer()
                                Text(event.at, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(WorkbenchTypography.secondary)
                                    .foregroundStyle(WorkbenchColor.muted)
                            }
                            Text(event.summary)
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                            ForEach(event.detail.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key): \(value)")
                                    .font(WorkbenchTypography.value)
                                    .foregroundStyle(WorkbenchColor.muted)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .opacity(event.stale ? 0.6 : 1)
                }
            }
        }
    }

    private func exportLineage(_ lineage: ModelLineage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(model.item.name)-lineage.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(lineage) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
