import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - QuantView
// Compare tab: measured comparison of ready variants via prompt-set replay
// (premium spec 03). Lettered lanes lead with the mode's primary metric above
// a prompt-by-lane output grid; diffs stay behind a disclosure. Past runs are
// browsable history.

enum ComparePresentation {
    /// Measured comparisons replay chat prompts; only chat-servable types qualify.
    static func candidates(from models: [LibraryModel]) -> [LibraryModel] {
        ComparisonViewLogic.candidates(from: models, mode: .chat)
    }

    static let maxSlots = 4

    enum ParameterSize: String, CaseIterable, Identifiable {
        case all, under3, from3To8, from8To20, over20, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All sizes"
            case .under3: return "Under 3B"
            case .from3To8: return "3–<8B"
            case .from8To20: return "8–<20B"
            case .over20: return "20B+"
            case .unknown: return "Unknown size"
            }
        }
        static func bucket(_ model: LibraryModel) -> Self {
            guard let size = FitAdvisor.parameterBillions(model.item.parameters), size.isFinite else { return .unknown }
            if size < 3 { return .under3 }
            if size < 8 { return .from3To8 }
            if size < 20 { return .from8To20 }
            return .over20
        }
    }

    /// Disk footprint is available even when the scan has no parameter count.
    enum SizeFilter: String, CaseIterable, Identifiable {
        case all, under2, from2To5, from5To10, over10, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All sizes"
            case .under2: return "Under 2 GB"
            case .from2To5: return "2–<5 GB"
            case .from5To10: return "5–<10 GB"
            case .over10: return "10 GB+"
            case .unknown: return "Unknown disk size"
            }
        }
        static func bucket(_ model: LibraryModel) -> Self {
            let bytes = model.item.bytes
            if bytes <= 0 { return .unknown }
            if bytes < 2_000_000_000 { return .under2 }
            if bytes < 5_000_000_000 { return .from2To5 }
            if bytes < 10_000_000_000 { return .from5To10 }
            return .over10
        }
    }

    /// A name-based series label for browsing, never an architecture claim.
    /// Snapshot hashes from older scan results are not useful menu labels.
    static func familyLabel(_ model: LibraryModel) -> String {
        let identity = HFRepoID.forPath(model.item.path) ?? model.displayName
        let name = identity.split(separator: "/").last.map(String.init) ?? identity
        var stem = name
        if let size = stem.range(of: #"(?i)[-_\s]+e?\d+(?:\.\d+)?[bm](?=[-_\s]|$)"#, options: .regularExpression) {
            stem = String(stem[..<size.lowerBound])
        }
        stem = stem.replacingOccurrences(of: #"(?i)(?:[-_\s]+(?:mlx|gguf|instruct|chat|\d+bit))+$"#, with: "", options: .regularExpression)
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty || stem.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil {
            return "Unknown family"
        }
        return stem
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case family, parameters, disk, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .family: return "Family"
            case .parameters: return "Parameter size"
            case .disk: return "Disk size"
            case .none: return "Name"
            }
        }
    }

    struct OptionGroup: Identifiable {
        let title: String
        let models: [LibraryModel]
        var id: String { title }
    }

    static func filtered(_ models: [LibraryModel], family: String?, size: SizeFilter, query: String) -> [LibraryModel] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter {
            (family == nil || familyLabel($0) == family) && (size == .all || SizeFilter.bucket($0) == size)
                && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || familyLabel($0).localizedCaseInsensitiveContains(search))
        }
    }

    static func groups(_ models: [LibraryModel], by grouping: Grouping) -> [OptionGroup] {
        func key(_ model: LibraryModel) -> String {
            switch grouping {
            case .family: return familyLabel(model)
            case .parameters: return ParameterSize.bucket(model).title
            case .disk: return SizeFilter.bucket(model).title
            case .none: return "Models"
            }
        }
        let grouped = Dictionary(grouping: models, by: key)
        let order: [String]
        switch grouping {
        case .parameters: order = ParameterSize.allCases.filter { $0 != .all }.map(\.title)
        case .disk: order = SizeFilter.allCases.filter { $0 != .all }.map(\.title)
        default: order = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return order.compactMap { title in
            grouped[title].map { OptionGroup(title: title, models: $0.sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.item.path < $1.item.path : comparison == .orderedAscending
            }) }
        }
    }

    static func selectedOutsideFilter(forSlot index: Int, slots: [String?], candidates: [LibraryModel], filtered: [LibraryModel]) -> LibraryModel? {
        guard slots.indices.contains(index), let path = slots[index], !filtered.contains(where: { $0.item.path == path }) else { return nil }
        return candidates.first { $0.item.path == path }
    }

    /// Chosen paths in slot order, without empty slots or repeats.
    static func variantPaths(_ slots: [String?]) -> [String] {
        var seen = Set<String>()
        return slots.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// Models a slot's menu offers: everything except what the other slots
    /// already hold. The slot's own choice stays selectable.
    static func options(forSlot index: Int, slots: [String?], candidates: [LibraryModel], repeatedPaths: Set<String> = []) -> [LibraryModel] {
        let taken = Set(slots.enumerated().compactMap { $0.offset == index ? nil : $0.element })
        return candidates.filter { !taken.contains($0.item.path) || repeatedPaths.contains($0.item.path) }
    }

    /// The model the operator is looking at plus one sibling of the same
    /// model key, so the first comparison needs no picking.
    static func preselectedSlots(selectedPath: String?, candidates: [LibraryModel]) -> [String?] {
        guard let selectedPath,
              let model = candidates.first(where: {
                  $0.item.path == selectedPath || $0.outputPaths.contains(selectedPath)
              }) else { return [nil, nil] }
        let sibling = model.item.modelKey.flatMap { key in
            candidates.first { $0.item.path != model.item.path && $0.item.modelKey == key }
        }
        return [model.item.path, sibling?.item.path]
    }

    static func canRun(slots: [String?], activeRunID: UUID?, availablePaths: Set<String>? = nil) -> Bool {
        runUnavailableReason(slots: slots, activeRunID: activeRunID, availablePaths: availablePaths) == nil
    }

    static func runUnavailableReason(slots: [String?], activeRunID: UUID?,
                                     availablePaths: Set<String>? = nil, hasPromptSet: Bool = true,
                                     savingPromptSet: Bool = false, hasPrompts: Bool = true) -> String? {
        if activeRunID != nil { return "Wait for the current comparison to finish." }
        if savingPromptSet { return "Wait for the prompt set save to finish." }
        if !hasPromptSet { return "Choose a prompt set." }
        if !hasPrompts { return "Choose a prompt set with at least one prompt." }
        if variantPaths(slots).isEmpty { return "Choose at least one model." }
        if let availablePaths, let index = slots.firstIndex(where: { path in
            path.map { !availablePaths.contains($0) } ?? false
        }) {
            return "Model \(letter(index)) is unavailable. Replace it or choose None."
        }
        return nil
    }

    /// A readable label for a model path recorded in a run: the Library's
    /// name, else the HF repo id (snapshot folders are commit hashes), else
    /// the folder name.
    static func displayName(for path: String, models: [LibraryModel]) -> String {
        if let model = models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) {
            return model.displayName
        }
        if let repoID = HFRepoID.forPath(path) {
            return repoID
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ComparisonRunButton: View {
    let unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button {
            guard unavailableReason == nil else { return }
            action()
        } label: { Label("Run comparison", systemImage: "play.fill") }
        .tint(WorkbenchColor.accent)
        .font(WorkbenchTypography.emphasis).controlSize(.large)
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? "Run the selected prompt set against these models.")
        .accessibilityHint(unavailableReason ?? "Run the selected prompt set against these models.")
    }
}

struct ComparisonRunGuidance: View {
    let reason: String?

    var body: some View {
        if let reason {
            Label(reason, systemImage: "info.circle")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Lanes and run selection

/// One variant of the shown run, lettered in run order.
struct CompareLane: Equatable, Identifiable {
    enum State: Equatable {
        case measured
        case measuring
        case waiting
        case failed(String)
        /// Completed with no positive value for the mode's metric.
        case noMeasurement
        /// Completed without a result for this variant (an interrupted run).
        case notMeasured
    }

    let index: Int
    let path: String
    let state: State
    let value: Double?
    /// Share of the best lane (1 for leaders); set only when at least two lanes are ranked.
    let fraction: Double?
    let isLeader: Bool
    var resultID: String? = nil
    var profileName: String? = nil
    var resultKey: String { resultID ?? path }

    var letter: String { ComparePresentation.letter(index) }
    var id: String { "\(index)|\(path)" }
}

/// The mode, run pick and prompt set that Compare keeps coherent.
struct CompareSelection: Equatable {
    var mode: ComparisonMode
    var selectedRunID: UUID?
    var promptSetID: String
}

extension ComparePresentation {
    static let slotLetters = ["A", "B", "C", "D"]

    static func letter(_ index: Int) -> String {
        slotLetters[min(max(index, 0), slotLetters.count - 1)]
    }

    /// One lane per run variant in run order; results are matched by model path.
    static func lanes(for run: ComparisonRun) -> [CompareLane] {
        let values = run.results.compactMap { run.metricValue(of: $0) }
        let ranked = run.state != .cancelled && run.state != .interrupted && values.count >= 2
        let best = run.effectiveMode.primaryMetric.higherIsBetter ? values.max() : values.min()
        let leaders = Set(run.leaders.map(\.id))
        return run.variants.enumerated().map { index, path in
            let key = run.variantIdentities[index]
            let result = run.results.first { $0.id == key }
            let value = result.flatMap { run.metricValue(of: $0) }
            let state: CompareLane.State
            if let result {
                if let error = result.error { state = .failed(error) } else { state = value == nil ? .noMeasurement : .measured }
            } else if run.state == .running {
                state = index == run.results.count ? .measuring : .waiting
            } else {
                state = .notMeasured
            }
            var fraction: Double?
            if ranked, let value, let best {
                fraction = run.effectiveMode.primaryMetric.higherIsBetter ? value / best : best / value
            }
            return CompareLane(index: index, path: path, state: state, value: value, fraction: fraction,
                isLeader: ranked && leaders.contains(key), resultID: key,
                profileName: run.hasValidLaneIdentities ? run.laneConfigurations?.first(where: { $0.id == key })?.servingProfileName : nil)
        }
    }

    /// The formatted value split into its numeral and unit, in the order the format gives them.
    static func splitValue(_ formatted: String) -> (number: String, unit: String) {
        let tokens = formatted.split(separator: " ").map(String.init)
        guard let numeric = tokens.firstIndex(where: { Double($0) != nil }) else { return (formatted, "") }
        let unit = tokens.enumerated().filter { $0.offset != numeric }.map(\.element).joined(separator: " ")
        return (tokens[numeric], unit)
    }

    static func laneStatus(_ state: CompareLane.State) -> String? {
        switch state {
        case .measured: return nil
        case .measuring: return "Measuring…"
        case .waiting: return "Waiting"
        case .failed(let error): return error
        case .noMeasurement: return "No measurement"
        case .notMeasured: return "Not measured"
        }
    }

    /// The first non-empty line of an error, trimmed; the rest belongs in a details view.
    static func firstLine(of error: String) -> String {
        error.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// A variant that failed as a whole has no sample to show; its lane header carries the error.
    static func showsNotRun(sample: ComparisonSample?, result: VariantResult?) -> Bool {
        sample == nil && result?.error != nil
    }

    static func laneAccessibilityLabel(_ lane: CompareLane, name: String, metric: ComparisonMetric) -> String {
        var parts = [lane.letter, name]
        switch lane.state {
        case .measured:
            lane.value.map { parts.append(metric.format($0)) }
            if lane.isLeader { parts.append("fastest") } else if let fraction = lane.fraction {
                parts.append("\(Int((fraction * 100).rounded()))% of fastest")
            }
        case .measuring: parts.append("measuring")
        case .waiting: parts.append("waiting")
        case .failed: parts.append("failed")
        case .noMeasurement: parts.append("no measurement")
        case .notMeasured: parts.append("not measured")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Mode and run coherence

    /// The run the results area renders: the active run, else the pick when it belongs to the
    /// mode, else the mode's newest run.
    static func shownRun(runs: [ComparisonRun], mode: ComparisonMode, selectedRunID: UUID?, activeRunID: UUID?) -> ComparisonRun? {
        if let activeRunID, let active = runs.first(where: { $0.id == activeRunID }) { return active }
        if let selectedRunID, let picked = runs.first(where: { $0.id == selectedRunID }), picked.effectiveMode == mode {
            return picked
        }
        return runs.filter { $0.effectiveMode == mode }.max { $0.startedAt < $1.startedAt }
    }

    static func showsEmptyState(runs: [ComparisonRun], mode: ComparisonMode, selectedRunID: UUID?, activeRunID: UUID?) -> Bool {
        shownRun(runs: runs, mode: mode, selectedRunID: selectedRunID, activeRunID: activeRunID) == nil
    }

    static func emptyTitle(for mode: ComparisonMode) -> String {
        "No \(mode.title.lowercased()) comparisons yet"
    }

    /// The prompt set of the mode's newest run, so opening Compare resumes where the last run left off.
    static func restoredPromptSetID(runs: [ComparisonRun], mode: ComparisonMode, promptSets: [PromptSet]) -> String? {
        runs.filter { run in run.effectiveMode == mode && promptSets.contains { $0.id == run.promptSetID } }
            .max { $0.startedAt < $1.startedAt }?
            .promptSetID
    }

    /// A real mode change clears the run pick and takes the new mode's first prompt set.
    static func changeMode(_ selection: CompareSelection, to mode: ComparisonMode, promptSets: [PromptSet]) -> CompareSelection {
        guard mode != selection.mode else { return selection }
        let sets = ComparisonViewLogic.promptSets(promptSets, for: mode)
        return CompareSelection(mode: mode, selectedRunID: nil, promptSetID: sets.first?.id ?? "")
    }

    /// Picking a run from history or Champions shows exactly that run; a run of another mode
    /// switches the mode and takes that run's prompt set when it still exists.
    static func pick(_ run: ComparisonRun, from selection: CompareSelection, promptSets: [PromptSet]) -> CompareSelection {
        var next = selection
        next.selectedRunID = run.id
        guard run.effectiveMode != selection.mode else { return next }
        let sets = ComparisonViewLogic.promptSets(promptSets, for: run.effectiveMode)
        next.mode = run.effectiveMode
        next.promptSetID = sets.contains { $0.id == run.promptSetID } ? run.promptSetID : (sets.first?.id ?? "")
        return next
    }

    // MARK: Grid geometry

    struct GridLayout: Equatable {
        let promptWidth: CGFloat
        let laneWidth: CGFloat
        /// True when the lanes do not fit at their minimum width.
        let scrolls: Bool

        /// Square thumbnails and 16:9 video frames fill the column inside its cell inset.
        var mediaSide: CGFloat {
            min(laneWidth - 2 * WorkbenchSize.Compare.cellInset, WorkbenchSize.Compare.thumbnailMaximum)
        }
    }

    /// Lanes share the width up to their maximum; below the minimum they keep their ideal width and scroll.
    static func gridLayout(contentWidth: CGFloat, laneCount: Int) -> GridLayout {
        let size = WorkbenchSize.Compare.self
        let lanes = CGFloat(max(laneCount, 1))
        let prompt = contentWidth < size.compactBreakpoint ? size.promptColumnCompact : size.promptColumn
        let share = (contentWidth - prompt - lanes * size.columnSpacing) / lanes
        if share >= size.laneMinimum { return GridLayout(promptWidth: prompt, laneWidth: min(share, size.laneMaximum), scrolls: false) }
        return GridLayout(promptWidth: prompt, laneWidth: size.laneIdeal, scrolls: true)
    }

    /// The muted line under a slot's model: quantization, then parameters or disk size.
    static func tileLine(_ model: LibraryModel) -> String? {
        let parameters = model.item.parameters.flatMap { $0.isEmpty ? nil : $0 }
        let disk = model.item.bytes > 0 ? ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file) : nil
        let line = [model.item.quantization, parameters ?? disk].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

struct QuantView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var servingProfiles: ServingProfileCoordinator
    private let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive

    @State private var compareContentWidth = WorkbenchSize.assumedContentWidth
    @State private var mode: ComparisonMode = .chat
    @State private var showingSetEditor = false
    @State private var pendingPromptSetEdit: MusicPromptSetEdit?
    @State private var pendingGeneralPromptSetEdit: ComparisonPromptSetDraft?
    @State private var pendingMusicPromptSetCopy: MusicPromptSetDraft?
    @State private var pendingGeneralPromptSetCopy: ComparisonPromptSetDraft?
    @State private var promptSetCopyError: String?
    @State private var pendingPromptSetRename: PromptSet?
    @State private var pendingPromptSetRemoval: PromptSet?
    @State private var pendingReuseSetup: MusicComparisonSetup?
    @State private var pendingGeneralReuseSetup: ComparisonRunSetup?
    @State private var reusedPromptSet: PromptSet?
    @State private var reuseError: String?
    @State private var slotIDs = (0..<ComparePresentation.maxSlots).map { _ in UUID().uuidString }
    @State private var strataSettings: [String: StrataComparisonOptions] = [:]
    @State private var laneSources: [String: ComparisonLaneConfiguration] = [:]
    @State private var settingsSearchGoal: StrataSettingsSearchGoal?
    @State private var showingSettingsSearch = false
    @State private var variantSlots: [String?] = [nil, nil]
    @State private var selectedPromptSetID: String = BuiltinPromptSets.coding.id
    @State private var selectedRunID: ComparisonRun.ID?
    @State private var profileSaveRequest: ServingProfileSaveRequest?
    @State private var profileActionError: String?
    @State private var promoteContext: PromoteContext?
    @State private var promotedWinner: PromotedWinner?
    @State private var showingFilters = false
    @State private var initializedSuggestions = false
    @State private var manuallySelectedModels = false
    @State private var selectionReason = "Waiting for eligible Library models."
    @State private var familyFilter: String?
    @State private var sizeFilter: ComparePresentation.SizeFilter = .all
    @State private var modelSearch = ""
    @State private var modelGrouping: ComparePresentation.Grouping = .family
    @State private var importPreview: WorkflowImportPreview?
    @State private var isReadingReport = false
    @State private var isChoosingReport = false
    @State private var importMessage: String?
    @State private var importError: String?
    @State private var workflowChartMetric: WorkflowCharts.Metric = .runtime
    @State private var inspectedWorkflowModelPath: String?

    private func reviewWorkflowModel(_ task: AgentTaskGuidance, path: String) async throws -> ModelGuidanceReview {
        var evidence = ComparisonInsights.agentEvidence(models: appHost.librarySnapshot?.models ?? [], runs: [],
            workflow: appHost.workflowEvidence.records, environment: appHost.watch.currentFingerprintDescription,
            hardware: appHost.hardwareProfile, memory: appHost.resources.memory,
            capturedAt: appHost.resources.capturedAt, contextTokens: appHost.resources.contextTokens,
            reserveGB: appHost.config.fitReserveGB, protected: appHost.occupiedModelPaths)
        // Preserve the displayed cohort for the existing fresh-evidence recheck.
        evidence.taskGuidance = [task]
        return try await appHost.reviewModelGuidance(evidence: evidence, taskID: task.id, path: path)
    }

    /// A completed run plus its fastest variant, presented for promotion.
    struct PromoteContext: Identifiable {
        let run: ComparisonRun
        let winner: VariantResult
        var id: ComparisonRun.ID { run.id }
    }

    /// The model promoted from one specific run.
    struct PromotedWinner: Equatable {
        let runID: ComparisonRun.ID
        let path: String
    }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _servingProfiles = ObservedObject(wrappedValue: appHost.servingProfiles)
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                HStack {
                    Spacer()
                    StudiesNavigationButton(onRouteSelection: onRouteSelection)
                }
                if shownRun == nil { setupBar }
                resultsArea
                WorkflowChartsView(workflow: appHost.workflowEvidence, models: appHost.librarySnapshot?.models ?? [],
                    environment: appHost.watch.currentFingerprintDescription, hardware: appHost.hardwareProfile,
                    mode: mode, activeRunID: comparison.activeRunID, onCompare: loadWorkflowComparison,
                    onReview: reviewWorkflowModel,
                    onApply: { review, role, endpoint in try await appHost.applyModelGuidance(review, role: role, enableEndpoint: endpoint) },
                    metric: $workflowChartMetric, inspectedModelPath: $inspectedWorkflowModelPath)
                if let importMessage { Text(importMessage).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
                ErrorBanner(text: importError)
                if shownRun != nil { setupBar }
                DisclosureGroup("Model fit and workflow evidence") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        Text(selectionReason)
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                        Button("Reset suggested models") { initializedSuggestions = false; manuallySelectedModels = false; applySuggestions() }
                            .disabled(comparison.activeRunID != nil || readyModels.isEmpty)
                        ComparisonInsightsView(appHost: appHost, comparison: comparison, workflow: appHost.workflowEvidence,
                            models: ComparePresentation.variantPaths(variantSlots).compactMap { path in
                                readyModels.first { $0.item.path == path }
                            },
                            promptSetID: selectedPromptSet?.id ?? "", promptEntries: selectedPromptSet?.prompts ?? [],
                            mode: mode, onReclaim: { onRouteSelection(.reclaim) },
                            onWire: { path in
                                let endpoint = appHost.endpoint.config
                                let port = endpoint.enabled && HFRepoID.matches(endpoint.modelPath, path) ? endpoint.port : nil
                                appHost.clientWiringRequest = ClientWiringRequest(modelPath: path, preferredPort: port)
                                onRouteSelection(.clientSetup)
                            }, onImport: importReport, isReadingReport: isReadingReport || isChoosingReport)
                    }
                    .padding(.top, WorkbenchSpacing.sm)
                }
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(WorkbenchSpacing.pageInset)
        }
        .sheet(isPresented: $showingSettingsSearch) {
            StrataSettingsSearchSheet(models: readyModels.filter { $0.item.servingRuntime == "strata" }) { model, setup in
                guard comparison.activeRunID == nil, !comparison.savingPromptSet,
                      let current = readyModels.first(where: { $0.item.path == model.item.path && $0.item.servingRuntime == "strata" }) else {
                    return "The selected model or comparison is no longer available."
                }
                do {
                    guard let memory = MemorySnapshot.probe(), setup.headroomGB <= Double(memory.totalBytes) / 1e9 else {
                        return "Choose a headroom target within this Mac's total RAM; memory reporting must be available."
                    }
                    let lanes = try setup.lanes(modelPath: current.item.path, signature: current.item.signature)
                    variantSlots = lanes.map { Optional($0.modelPath) }
                    slotIDs = lanes.map(\.id)
                    strataSettings = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0.strataOptions!) })
                    laneSources = [:]
                    settingsSearchGoal = setup.goal
                    initializedSuggestions = true; manuallySelectedModels = true
                    selectionReason = "Four Strata configurations at one fixed context."
                    return nil
                } catch { return AppHost.render(error) }
            }
        }
        .sheet(isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } })) {
            if let importPreview {
                WorkflowImportPreviewView(preview: importPreview,
                    models: (appHost.librarySnapshot?.models ?? []).map { WorkflowCaptureModel(path: $0.item.path, name: $0.displayName, signature: $0.item.signature) },
                    environment: appHost.watch.currentFingerprintDescription,
                    onCancel: { self.importPreview = nil }, onConfirm: confirmImport)
            }
        }
        .task(id: isRouteActive) { consumeImportRequest() }
        .task(id: isRouteActive) { consumeProfileComparisonRequest() }
        .onChange(of: appHost.servingProfileComparisonRequest?.id) { _, _ in consumeProfileComparisonRequest() }
        .task(id: isRouteActive) { consumeModelComparisonRequest() }
        .onChange(of: appHost.modelComparisonRequest?.id) { _, _ in consumeModelComparisonRequest() }
        .sheet(item: $pendingReuseSetup) { setup in
            MusicComparisonSetupSheet(setup: setup,
                availablePaths: Set(readyModels.map { $0.item.path }), name: shortName,
                onApply: applyReusedSetup, onSave: { set in
                    guard comparison.savePromptSet(set) else {
                        throw MusicComparisonSetup.InvalidSetup(message: comparison.persistenceError ?? "Prompt set could not be saved.")
                    }
                })
        }
        .sheet(item: $pendingGeneralReuseSetup) { setup in
            ComparisonRunSetupSheet(setup: setup,
                availablePaths: Set(readyModels.map { $0.item.path }), name: shortName,
                onApply: applyReusedSetup, onSave: { draft in
                    guard comparison.activeRunID == nil else { return "Wait for the current comparison to finish." }
                    return await comparison.createPromptSetWithInputCopies(draft) == nil
                        ? (comparison.promptSetManagementError ?? "Prompt set could not be saved.") : nil
                })
        }
        .onChange(of: appHost.workflowReportImportRequested) { _, _ in consumeImportRequest() }
        .sheet(item: $pendingPromptSetRename) { set in
            PromptSetRenameSheet(set: set) { name in
                comparison.renamePromptSet(id: set.id, name: name)
                    ? nil : (comparison.promptSetManagementError ?? "Prompt set could not be renamed.")
            }
        }
        .sheet(item: $pendingPromptSetEdit) { edit in
            MusicPromptSetEditSheet(edit: edit) { edited in
                comparison.saveMusicPromptSetEdits(edited)
                    ? nil : (comparison.promptSetManagementError ?? "Prompt set could not be saved.")
            }
        }
        .sheet(item: $pendingGeneralPromptSetEdit) { edit in
            ComparisonPromptSetEditor(draft: edit) { edited in
                await comparison.savePromptSetEditsWithInputCopies(edited)
                    ? nil : (comparison.promptSetManagementError ?? "Prompt set could not be saved.")
            }
        }
        .sheet(item: $pendingMusicPromptSetCopy) { draft in
            MusicPromptSetCreateSheet(draft: draft) { customized in
                guard let set = comparison.createMusicPromptSet(customized) else {
                    return comparison.promptSetManagementError ?? "Prompt set could not be created."
                }
                selectedPromptSetID = set.id
                return nil
            }
        }
        .sheet(item: $pendingGeneralPromptSetCopy) { draft in
            ComparisonPromptSetEditor(draft: draft) { customized in
                guard let set = await comparison.createPromptSetWithInputCopies(customized) else {
                    return comparison.promptSetManagementError ?? "Prompt set could not be created."
                }
                selectedPromptSetID = set.id
                return nil
            }
        }
        .alert("Remove saved prompt set?", isPresented: Binding(
            get: { pendingPromptSetRemoval != nil },
            set: { if !$0 { pendingPromptSetRemoval = nil } }), presenting: pendingPromptSetRemoval) { set in
                Button("Remove", role: .destructive) { removePromptSet(set) }
                Button("Cancel", role: .cancel) { }
            } message: { set in
                Text("‘\(set.name)’ will be removed from the prompt set picker. Its unreferenced input copies will be reclaimed. Past runs, saved outputs and quality reviews will be kept.")
            }
        .onChange(of: comparison.activeRunID) { _, newValue in
            if let newValue { selectedRunID = newValue }
        }
        .onAppear {
            if !initializedSuggestions,
               let restored = ComparePresentation.restoredPromptSetID(runs: comparison.runs, mode: mode, promptSets: modePromptSets) {
                selectedPromptSetID = restored
            }
            applySuggestions()
        }
        .onChange(of: selectedPromptSetID) { _, newID in
            if let reusedPromptSet, newID != reusedPromptSet.id { self.reusedPromptSet = nil }
            guard !manuallySelectedModels else { return }
            initializedSuggestions = false
            applySuggestions()
        }
        .onChange(of: readyModels.map { $0.item.path }) { _, _ in
            guard comparison.activeRunID == nil else { return }
            if let familyFilter, !readyModels.contains(where: { ComparePresentation.familyLabel($0) == familyFilter }) { self.familyFilter = nil }
            if reusedPromptSet == nil && laneSources.isEmpty {
                let reconciled = ComparisonInsights.reconcile(slots: variantSlots, available: Set(readyModels.map { $0.item.path }))
                if reconciled != variantSlots { variantSlots = reconciled; selectionReason = "Unavailable models were cleared; your remaining selections were kept." }
            }
            applySuggestions()
        }
    }

    private func consumeImportRequest() {
        guard isRouteActive, appHost.workflowReportImportRequested else { return }
        appHost.workflowReportImportRequested = false
        importReport()
    }

    private var canApplyLibrarySelection: Bool {
        comparison.activeRunID == nil && !comparison.savingPromptSet && servingProfiles.activeID == nil
            && !showingSetEditor && pendingPromptSetEdit == nil && pendingGeneralPromptSetEdit == nil
            && pendingMusicPromptSetCopy == nil && pendingGeneralPromptSetCopy == nil
            && pendingReuseSetup == nil && pendingGeneralReuseSetup == nil && pendingPromptSetRename == nil
    }

    private func consumeModelComparisonRequest() {
        guard isRouteActive, let request = appHost.modelComparisonRequest else { return }
        guard canApplyLibrarySelection else {
            reuseError = "Finish the current comparison, save, editor or profile verification, then use the selected Library model."
            return
        }
        guard let model = request.resolve(in: appHost.librarySnapshot?.models ?? []) else {
            reuseError = "The selected Library model is no longer ready for this comparison mode. Refresh Library and select it again."
            appHost.modelComparisonRequest = nil
            return
        }
        reusedPromptSet = nil
        changeMode(to: request.mode)
        if !modePromptSets.contains(where: { $0.id == selectedPromptSetID }) {
            selectedPromptSetID = modePromptSets.first?.id ?? ""
        }
        variantSlots = [model.item.path, nil]
        slotIDs = (0..<ComparePresentation.maxSlots).map { _ in UUID().uuidString }
        strataSettings = [:]; laneSources = [:]; settingsSearchGoal = nil
        familyFilter = nil; sizeFilter = .all; modelSearch = ""
        initializedSuggestions = true; manuallySelectedModels = true
        selectedRunID = nil; reuseError = nil
        selectionReason = "Selected from Library. Add another model or run this model against the chosen prompts."
        appHost.modelComparisonRequest = nil
    }

    private func consumeProfileComparisonRequest() {
        guard isRouteActive, let request = appHost.servingProfileComparisonRequest else { return }
        guard comparison.activeRunID == nil, !comparison.savingPromptSet, servingProfiles.activeID == nil else {
            reuseError = "Wait for the comparison, prompt-set save or profile verification to finish."
            return
        }
        do {
            _ = try servingProfiles.prepareComparison(baseline: request.baseline, candidate: request.candidate)
            guard let model = ComparisonViewLogic.candidates(from: appHost.librarySnapshot?.models ?? [], mode: .chat)
                .first(where: { $0.item.path == request.baseline.modelPath && $0.item.servingRuntime == "strata" }) else {
                throw WorkflowEvidenceError.invalid("The profiles' local Strata model is unavailable in Library.")
            }
            let lanes = request.lanes(signature: model.item.signature)
            mode = .chat; settingsSearchGoal = nil; reusedPromptSet = nil
            variantSlots = lanes.map { Optional($0.modelPath) }; slotIDs = lanes.map(\.id)
            while slotIDs.count < ComparePresentation.maxSlots { slotIDs.append(UUID().uuidString) }
            strataSettings = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0.strataOptions!) })
            laneSources = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
            familyFilter = nil; sizeFilter = .all; modelSearch = ""
            initializedSuggestions = true; manuallySelectedModels = true
            selectionReason = "Recorded profile settings: A · \(request.baseline.name); B · \(request.candidate.name). Choose one prompt set, then Run comparison."
            selectedRunID = nil; reuseError = nil
            appHost.servingProfileComparisonRequest = nil
        } catch { reuseError = AppHost.render(error); appHost.servingProfileComparisonRequest = nil }
    }

    private func importReport() {
        guard !isReadingReport, !isChoosingReport, importPreview == nil else { return }
        isChoosingReport = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            isChoosingReport = false
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                isReadingReport = true
                defer { isReadingReport = false }
                do {
                    let report = try await Task.detached(priority: .userInitiated) { try WorkflowEvidenceStore.readReport(url) }.value
                    importPreview = try appHost.workflowEvidence.previewReport(report)
                    importError = nil
                    importMessage = nil
                } catch { importError = AppHost.render(error); importMessage = nil }
            }
        }
    }

    private func confirmImport() {
        guard let importPreview else { return }
        do {
            let count = try appHost.workflowEvidence.confirmImport(importPreview)
            importMessage = "Imported \(count) new workflow records."
            importError = nil
            appHost.analyzeReclaim()
        } catch { importError = AppHost.render(error); importMessage = nil }
        self.importPreview = nil
    }

    // MARK: - Selection

    private var shownRun: ComparisonRun? {
        ComparePresentation.shownRun(runs: comparison.runs, mode: mode, selectedRunID: selectedRunID, activeRunID: comparison.activeRunID)
    }

    private var currentSelection: CompareSelection {
        CompareSelection(mode: mode, selectedRunID: selectedRunID, promptSetID: selectedPromptSetID)
    }

    /// Mode, run pick and prompt set change together here, never from a change handler.
    private func apply(_ next: CompareSelection) {
        let modeChanged = next.mode != mode
        if modeChanged { reusedPromptSet = nil }
        mode = next.mode
        selectedRunID = next.selectedRunID
        selectedPromptSetID = next.promptSetID
        guard modeChanged else { return }
        familyFilter = nil
        sizeFilter = .all
        modelSearch = ""
        initializedSuggestions = false
        manuallySelectedModels = false
        applySuggestions()
    }

    private func changeMode(to newMode: ComparisonMode) {
        apply(ComparePresentation.changeMode(currentSelection, to: newMode, promptSets: comparison.promptSets))
    }

    private func pick(_ run: ComparisonRun) {
        apply(ComparePresentation.pick(run, from: currentSelection, promptSets: comparison.promptSets))
    }

    private var modeBinding: Binding<ComparisonMode> {
        Binding(get: { mode }, set: { changeMode(to: $0) })
    }

    private var shownRunBinding: Binding<UUID?> {
        Binding(get: { shownRun?.id }, set: { id in
            if let id, let run = comparison.runs.first(where: { $0.id == id }) { pick(run) }
        })
    }

    // MARK: - Measured comparison setup

    private var readyModels: [LibraryModel] {
        ComparisonViewLogic.candidates(from: appHost.librarySnapshot?.models ?? [], mode: mode)
    }

    private var filteredModels: [LibraryModel] {
        ComparePresentation.filtered(readyModels, family: familyFilter, size: sizeFilter, query: modelSearch)
    }

    private var modePromptSets: [PromptSet] {
        let stored = ComparisonViewLogic.promptSets(comparison.promptSets, for: mode)
        return reusedPromptSet.map { $0.effectiveMode == mode ? [$0] + stored : stored } ?? stored
    }

    private var runUnavailableReason: String? {
        if servingProfiles.activeID != nil { return "Wait for serving-profile verification to finish." }
        if let reason = comparison.runStateUnavailableReason { return reason }
        if let reason = ComparePresentation.runUnavailableReason(slots: variantSlots, activeRunID: comparison.activeRunID,
            availablePaths: Set(readyModels.map { $0.item.path }), hasPromptSet: selectedPromptSet != nil,
            savingPromptSet: comparison.savingPromptSet, hasPrompts: selectedPromptSet?.prompts.isEmpty == false) { return reason }
        if let goal = settingsSearchGoal, mode == .chat, !goal.matches(selectedChatLanes) {
            return "Settings search needs its four matching lanes. Prepare it again or switch to manual comparison."
        }
        return selectedStrataSlots.compactMap { strataSettings[slotIDs[$0]]?.validationError }.first
    }

    private var selectedChatLanes: [ComparisonLaneConfiguration] {
        variantSlots.indices.compactMap { index in
            guard let path = variantSlots[index], let model = readyModels.first(where: { $0.item.path == path }) else { return nil }
            var lane = ComparisonLaneConfiguration(id: slotIDs[index], modelPath: path, modelSignature: model.item.signature,
                strataOptions: repeatedStrataPaths.contains(path) ? strataSettings[slotIDs[index]] ?? StrataComparisonOptions() : nil)
            if let source = laneSources[lane.id], source.modelPath == lane.modelPath, source.strataOptions == lane.strataOptions {
                lane.servingProfileID = source.servingProfileID; lane.servingProfileName = source.servingProfileName
            }
            return lane
        }
    }

    private var repeatedStrataPaths: Set<String> {
        mode == .chat ? Set(readyModels.filter { $0.item.servingRuntime == "strata" }.map { $0.item.path }) : []
    }

    private var selectedStrataSlots: [Int] {
        variantSlots.indices.filter { index in
            variantSlots[index].map { repeatedStrataPaths.contains($0) } == true
        }
    }

    private var selectedPromptSet: PromptSet? {
        modePromptSets.first { $0.id == selectedPromptSetID } ?? modePromptSets.first
    }

    private var setupBar: some View {
        WorkbenchCard("Compare models", systemImage: "slider.horizontal.3", style: .tinted) {
            ViewThatFits(in: .horizontal) {
                comparisonModePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                comparisonModePicker.pickerStyle(.menu)
            }
            .disabled(comparison.activeRunID != nil)
            if mode == .chat, !repeatedStrataPaths.isEmpty {
                Button("Find best settings…") { showingSettingsSearch = true }
                    .disabled(comparison.activeRunID != nil || comparison.savingPromptSet)
                if let goal = settingsSearchGoal {
                    Text("Settings search · \(goal.contextTokens) context tokens · \(goal.headroomGB.formatted()) GB observed headroom target")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    Button("Switch to manual comparison") { settingsSearchGoal = nil }
                        .disabled(comparison.activeRunID != nil)
                }
            }

            if readyModels.isEmpty {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Text(mode == .chat
                        ? "No ready models in the latest Library snapshot."
                        : "No ready \(mode.acceptedTaskTypes.map { $0.title.lowercased() }.joined(separator: " or ")) models in the latest Library snapshot.")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                    Button("Open Library") { onRouteSelection(.library) }
                        .buttonStyle(.bordered)
                }
            }

            if !readyModels.isEmpty || !ComparePresentation.variantPaths(variantSlots).isEmpty {
                if filteredModels.isEmpty {
                    Text("No models match these filters. Your selected models are kept.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: WorkbenchSize.Compare.tileMinimum, maximum: WorkbenchSize.Compare.tileMaximum),
                        spacing: WorkbenchSize.Compare.tileSpacing, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: WorkbenchSize.Compare.tileSpacing
                ) {
                    slotControls
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { inlineControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { wrappedControls }
            }
            .padding(.top, WorkbenchSpacing.sm)
            .overlay(alignment: .top) {
                Rectangle().fill(WorkbenchColor.accent.opacity(.stroke)).frame(height: WorkbenchSpacing.hairline)
            }
            if !selectedStrataSlots.isEmpty {
                Text("Select the same Strata model in another lane to compare settings. Each lane runs separately.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            if comparison.activeRunID != nil {
                ComparisonProgressControls(message: comparison.progressMessage ?? "Measuring…",
                    isCancelling: comparison.isCancelling, cleanupPending: comparison.cleanupPending,
                    onCancel: comparison.cancel, onRetry: comparison.retryCleanup)
            }
            if reusedPromptSet != nil {
                Text("Reused setup · temporary. Change models below, then run a new comparison.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            if comparison.activeRunID == nil {
                ComparisonRunGuidance(reason: runUnavailableReason)
            }
            if appHost.servingProfileComparisonRequest != nil {
                Button("Use requested profiles") { consumeProfileComparisonRequest() }
                    .disabled(comparison.activeRunID != nil || comparison.savingPromptSet || servingProfiles.activeID != nil)
            }
            if appHost.modelComparisonRequest != nil {
                Button("Use selected Library model") { consumeModelComparisonRequest() }
                    .disabled(!canApplyLibrarySelection)
            }
            ErrorBanner(text: reuseError)
            ErrorBanner(text: comparison.lastError)
            ErrorBanner(text: comparison.persistenceError)
            ErrorBanner(text: comparison.promptSetManagementError)
            ErrorBanner(text: promptSetCopyError)
        }
        .sheet(isPresented: $showingSetEditor) {
            if mode == .musicGeneration {
                MusicPromptSetCreateSheet { draft in
                    guard let set = comparison.createMusicPromptSet(draft) else {
                        return comparison.promptSetManagementError ?? "Prompt set could not be created."
                    }
                    selectedPromptSetID = set.id
                    return nil
                }
            } else {
                ComparisonPromptSetEditor(draft: ComparisonPromptSetDraft(mode: mode)) { draft in
                    guard let set = await comparison.createPromptSetWithInputCopies(draft) else {
                        return comparison.promptSetManagementError ?? "Prompt set could not be created."
                    }
                    selectedPromptSetID = set.id
                    return nil
                }
            }
        }
    }

    private var filtersActive: Bool { familyFilter != nil || sizeFilter != .all || !modelSearch.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filterButton: some View {
        Button { showingFilters = true } label: {
            Label(filtersActive ? "Filter · \(filteredModels.count) of \(readyModels.count)" : "Filter",
                systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.bordered)
        .disabled(readyModels.isEmpty)
        .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                modelFilters
            }
            .padding(WorkbenchSpacing.md)
            .frame(width: WorkbenchSize.Compare.filterPopoverWidth, alignment: .leading)
        }
    }

    @ViewBuilder private var modelFilters: some View {
        TextField("Find a model…", text: $modelSearch)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Find a comparison model")
        Picker("Family", selection: $familyFilter) {
            Text("All families").tag(String?.none)
            ForEach(Array(Set(readyModels.map { ComparePresentation.familyLabel($0) })).sorted(), id: \.self) { family in
                Text(family).tag(Optional(family))
            }
        }.frame(maxWidth: 230).help("Families are grouped by model name; they are not architecture classifications.")
        Picker("Disk size", selection: $sizeFilter) {
            ForEach(ComparePresentation.SizeFilter.allCases) { size in Text(size.title).tag(size) }
        }.fixedSize().help("Model files on disk, in decimal GB. This is not runtime memory usage.")
        Picker("Group by", selection: $modelGrouping) {
            ForEach(ComparePresentation.Grouping.allCases) { grouping in Text(grouping.title).tag(grouping) }
        }.fixedSize()
        Text("\(filteredModels.count)/\(readyModels.count)")
            .font(WorkbenchTypography.secondary).monospacedDigit().foregroundStyle(WorkbenchColor.muted)
            .help("Matching models / ready models. Existing selections stay available outside filters.")
        if familyFilter != nil || sizeFilter != .all || !modelSearch.isEmpty {
            Button("Clear") { familyFilter = nil; sizeFilter = .all; modelSearch = "" }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var slotControls: some View {
        ForEach(Array(variantSlots.indices), id: \.self) { index in
            slotTile(index)
        }

        if variantSlots.count < ComparePresentation.maxSlots {
            Button { variantSlots.append(nil) } label: { Label("Add model", systemImage: "plus") }
                .buttonStyle(.borderless)
                .foregroundStyle(WorkbenchColor.accent)
                .help("Add a model")
                .accessibilityLabel("Add a model")
        }
    }

    private func slotTile(_ index: Int) -> some View {
        let model = variantSlots[index].flatMap { path in readyModels.first { $0.item.path == path } }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                LetterChip(letter: ComparePresentation.letter(index))
                    .accessibilityHidden(true)
                Menu {
                    Button("None") { slotBinding(index).wrappedValue = nil }
                    if let selected = ComparePresentation.selectedOutsideFilter(forSlot: index, slots: variantSlots, candidates: readyModels, filtered: filteredModels) {
                        Section("Selected outside filters") {
                            Button(modelOptionLabel(selected)) { slotBinding(index).wrappedValue = selected.item.path }
                        }
                    }
                    ForEach(ComparePresentation.groups(ComparePresentation.options(forSlot: index, slots: variantSlots, candidates: filteredModels, repeatedPaths: repeatedStrataPaths), by: modelGrouping)) { group in
                        Section(group.title) {
                            ForEach(group.models, id: \.item.path) { model in
                                Button {
                                    slotBinding(index).wrappedValue = model.item.path
                                } label: {
                                    if variantSlots[index] == model.item.path {
                                        Label(modelOptionLabel(model), systemImage: "checkmark")
                                    } else {
                                        Text(modelOptionLabel(model))
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(model.map(modelOptionLabel) ?? variantSlots[index].map { "Unavailable · \(shortName($0))" } ?? "Choose a model")
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Model \(ComparePresentation.letter(index))")
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(variantSlots[index].map { shortName($0) } ?? "Choose a model")

                if index >= 2 {
                    Button { removeSlot(index) } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .help("Remove this model")
                        .accessibilityLabel("Remove model \(ComparePresentation.letter(index))")
                }
            }
            if let line = model.flatMap(ComparePresentation.tileLine) {
                Text(line)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(1)
            }
            if model?.item.servingRuntime == "strata" {
                Text("Strata · Metal · GGUF")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                if mode == .chat {
                    if let lane = selectedChatLanes.first(where: { $0.id == slotIDs[index] }), let name = lane.servingProfileName {
                        Text("Recorded profile: \(name)").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                    DisclosureGroup("Strata settings") {
                        StrataComparisonControls(options: Binding(
                            get: { strataSettings[slotIDs[index]] ?? StrataComparisonOptions() },
                            set: { strataSettings[slotIDs[index]] = $0 }))
                    }.disabled(comparison.activeRunID != nil)
                }
            }
        }
        .padding(WorkbenchSpacing.xs)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: WorkbenchRadius.control)
                .strokeBorder(WorkbenchColor.hairline, lineWidth: WorkbenchSpacing.hairline)
        }
    }

    private func modelOptionLabel(_ model: LibraryModel) -> String {
        let size = modelGrouping == .disk ? (model.item.bytes > 0 ? ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file) : "Disk unknown") : model.item.parameters
        let name = model.displayName.split(separator: "/").last.map(String.init) ?? model.displayName
        return [name, model.item.quantization, size].compactMap { $0 }.joined(separator: " · ")
    }

    private var promptSetPicker: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            ComparisonPromptSetPicker(sets: modePromptSets, selection: $selectedPromptSetID, temporaryID: reusedPromptSet?.id)
            .frame(maxWidth: WorkbenchSize.Compare.promptSetMaximum, alignment: .leading)
            PromptSetActions(name: selectedPromptSet?.name,
                isEnabled: comparison.activeRunID == nil && comparison.canManagePromptSet(id: selectedPromptSetID),
                isCopyEnabled: selectedPromptSet != nil && comparison.activeRunID == nil && !comparison.savingPromptSet,
                onEdit: openPromptSetEditor,
                onRename: { pendingPromptSetRename = selectedPromptSet },
                onRemove: { pendingPromptSetRemoval = selectedPromptSet },
                onCopy: openPromptSetCopy)
        }
    }

    private var newSetButton: some View {
        Button("New set…") { showingSetEditor = true }
            .buttonStyle(.bordered)
            .help("Build a prompt set\(mode.inputKind.map { " with your own \($0.rawValue) files" } ?? "").")
    }

    @ViewBuilder private var importPromptsButton: some View {
        if mode == .chat {
            Button("Import OpenCode prompts") {
                if let imported = comparison.importHistory() {
                    selectedPromptSetID = imported.id
                }
            }
            .buttonStyle(.bordered)
            .help("Read-only import of your opencode user prompts as a prompt set.")
        }
    }

    private var runButton: some View {
        ComparisonRunButton(unavailableReason: runUnavailableReason, action: startRun)
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder private var inlineControls: some View {
        promptSetPicker
        newSetButton
        importPromptsButton
        filterButton
        Spacer()
        runButton
    }

    @ViewBuilder private var wrappedControls: some View {
        runButton
        HStack(spacing: WorkbenchSpacing.xs) {
            promptSetPicker
            newSetButton
        }
        HStack(spacing: WorkbenchSpacing.xs) {
            importPromptsButton
            filterButton
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if let run = shownRun {
            runDetail(run)
        } else {
            WorkbenchSurface {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    runHeader
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Label(ComparePresentation.emptyTitle(for: mode), systemImage: "chart.bar.xaxis")
                            .font(WorkbenchTypography.label)
                        Text("Choose a mode, models and prompts, then Run comparison.")
                            .font(WorkbenchTypography.secondary)
                    }
                    .foregroundStyle(WorkbenchColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var runHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            ComparisonHistoryPicker(runs: comparison.runs, selection: shownRunBinding)
                .frame(maxWidth: WorkbenchSize.Compare.historyMaximum, alignment: .leading)
                .disabled(comparison.activeRunID != nil)
            if let run = shownRun, run.state == .cancelled || run.state == .interrupted {
                Text(run.state == .cancelled ? "Cancelled · recorded samples retained" : "Interrupted · comparison did not finish")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let run = shownRun, run.state == .completed {
                Button {
                    do {
                        if run.effectiveMode == .musicGeneration {
                            pendingReuseSetup = try MusicComparisonSetup(run: run)
                        } else {
                            pendingGeneralReuseSetup = try ComparisonRunSetup(run: run, outputStore: comparison.outputStore)
                        }
                        reuseError = nil
                    }
                    catch { reuseError = error.localizedDescription }
                } label: { Label("Reuse setup", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(comparison.activeRunID != nil || run.promptEntries?.isEmpty != false)
                    .help(run.promptEntries?.isEmpty != false
                          ? "This older run has no recorded prompt snapshot."
                          : "Edit the recorded prompts and settings for a new comparison.")
            }
            Spacer()
            championsMenu
                .disabled(comparison.activeRunID != nil)
        }
    }

    private var comparisonModePicker: some View {
        Picker("Mode", selection: modeBinding) {
            ForEach(ComparisonMode.allCases) { entry in
                Text(entry.title).tag(entry)
            }
        }
    }

    private var championsMenu: some View {
        let champions = ComparisonInsights.champions(models: appHost.librarySnapshot?.models ?? [], runs: comparison.runs,
            environment: appHost.watch.currentFingerprintDescription)
        return Menu {
            if champions.isEmpty {
                Text("No current task champions")
                Text("Complete a comparison on this Mac to establish them.")
            }
            ForEach(champions) { champion in
                Section {
                    ForEach(champion.performance) { result in
                        if let value = champion.run.metricValue(of: result) {
                            Button {
                                pick(champion.run)
                            } label: {
                                Label("\(champion.run.effectiveMode.primaryMetric.title): \(shortName(result.modelPath)) · \(champion.run.effectiveMode.primaryMetric.format(value))\(champion.performance.count > 1 ? " (tie)" : "")", systemImage: "trophy.fill")
                            }
                        }
                    }
                    ForEach(champion.quality) { result in
                        if let score = champion.run.qualityReviews?[result.id]?.score {
                            Button {
                                pick(champion.run)
                            } label: {
                                Label("Task quality: \(shortName(result.modelPath)) · \(score)/5\(champion.quality.count > 1 ? " (tie)" : "")", systemImage: "trophy.fill")
                            }
                        }
                    }
                    if champion.quality.isEmpty { Text("Task quality: not established") }
                    ForEach(champion.latency) { result in
                        if let value = result.aggregateTTFTSeconds {
                            Button("First token: \(shortName(result.modelPath)) · \(String(format: "%.2f s", value))\(champion.latency.count > 1 ? " (tie)" : "")") {
                                pick(champion.run)
                            }
                        }
                    }
                    Text("Measured \((champion.run.finishedAt ?? champion.run.startedAt).formatted(date: .abbreviated, time: .shortened))")
                } header: {
                    Text("\(champion.run.promptSetName) · \(champion.run.effectiveMode.title)")
                }
            }
        } label: {
            Label {
                Text("Champions").foregroundStyle(WorkbenchColor.ink)
            } icon: {
                Image(systemName: "trophy.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(WorkbenchColor.accent)
            }
            .font(WorkbenchTypography.label)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current task champions on this Mac. Select an award to view its measured run; ties are shared.")
    }

    // MARK: - Selected run detail

    private func runDetail(_ run: ComparisonRun) -> some View {
        let winnerPath = run.effectiveMode == .chat && run.state == .completed && !run.hasCustomServingConfiguration ? run.winner?.modelPath : nil
        return WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                runHeader

                if run.effectiveMode == .chat, run.variants.count > 1,
                   run.results.contains(where: { $0.servingEvidence?.runtime == "strata" }) {
                    Text(Set(run.variants).count < run.variants.count
                        ? "These lanes compare serving settings for the same weights. Speed does not establish answer quality."
                        : "These results compare the selected model variants. A speed difference does not isolate the runtime or establish equivalent response quality.")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let promotedWinner, promotedWinner.runID == run.id {
                    HStack(spacing: WorkbenchSpacing.sm) {
                        Label("Fastest model selected.", systemImage: "checkmark.circle.fill")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.success)
                        Button("Wire into clients…") { onRouteSelection(.clientSetup) }
                            .controlSize(.small)
                        Button("Review reclaim…") { onRouteSelection(.reclaim) }
                            .controlSize(.small)
                    }
                }

                MediaRunResultsView(
                    run: run,
                    store: comparison.outputStore ?? ComparisonOutputStore(),
                    contentWidth: compareContentWidth,
                    isRouteActive: isRouteActive,
                    name: { shortName($0) },
                    onReview: { path, score in comparison.reviewQuality(runID: run.id, modelPath: path, score: score) },
                    reviewError: comparison.persistenceError,
                    laneActions: { lane in laneActions(lane, run: run, winnerPath: winnerPath) }
                )
                .id(run.id)

                if ComparisonDiff.isAvailable(run) {
                    TextComparisonPanel(run: run, store: comparison.outputStore ?? ComparisonOutputStore(),
                        name: { shortName($0) },
                        onReview: { path, score in comparison.reviewQuality(runID: run.id, modelPath: path, score: score) },
                        reviewError: comparison.persistenceError)
                        .id(run.id)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CompareContentWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(CompareContentWidthKey.self) { width in
                if width > 0 { compareContentWidth = width }
            }
        }
        .sheet(item: $profileSaveRequest) { request in
            if case .save = request.action { SaveServingProfileSheet(profiles: servingProfiles, request: request) }
            else {
                ComparisonProfileVerificationSheet(profiles: servingProfiles, request: request) { profile in
                    do { _ = try servingProfiles.resolve(profile) } catch { return AppHost.render(error) }
                    guard let model = readyModels.first(where: { $0.item.path == profile.modelPath }) else {
                        return "The verified model is not available in the current Library."
                    }
                    appHost.modelWorkflow.prepareServe(model: model, exactPath: profile.modelPath)
                    appHost.modelWorkflow.selectServingProfile(profile)
                    onRouteSelection(.run)
                    return nil
                }
            }
        }
        .alert("Profile verification unavailable", isPresented: Binding(get: { profileActionError != nil }, set: { if !$0 { profileActionError = nil } })) {
            Button("OK") { profileActionError = nil }
        } message: { Text(profileActionError ?? "") }
        .sheet(item: $promoteContext) { context in
            PromoteWinnerSheet(
                appHost: appHost,
                context: context,
                onPromoted: { path in promotedWinner = PromotedWinner(runID: context.run.id, path: path) }
            )
        }
    }

    /// Chat lanes carry the promote button on the winner and the preferred-model menu.
    @ViewBuilder
    private func laneActions(_ lane: CompareLane, run: ComparisonRun, winnerPath: String?) -> some View {
        if run.state == .completed, run.laneConfigurations?.first(where: { $0.id == lane.resultKey })?.servingProfileID != nil,
           let result = run.results.first(where: { $0.id == lane.resultKey }), result.error == nil,
           !result.samples.isEmpty, result.samples.allSatisfy(\.hasCompletedAnswer) {
            Button("Verify measured profile…") {
                do {
                    let profile = try servingProfiles.prepareMeasuredVerification(run: run, laneID: lane.resultKey)
                    profileSaveRequest = ServingProfileSaveRequest(run: run, laneID: lane.resultKey, letter: lane.letter, action: .verifyMeasured(profile))
                } catch { profileActionError = AppHost.render(error) }
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(comparison.activeRunID != nil || servingProfiles.activeID != nil)
        }
        if run.settingsSearchCandidateID == lane.resultKey {
            Button("Save and verify suggestion…") {
                profileSaveRequest = ServingProfileSaveRequest(run: run, laneID: lane.resultKey, letter: lane.letter, action: .verifySuggestion)
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(comparison.activeRunID != nil || servingProfiles.activeID != nil)
        }
        if run.effectiveMode == .chat, run.state == .completed,
           let result = run.results.first(where: { $0.id == lane.resultKey }), result.error == nil, result.servingEvidence?.runtime == "strata" {
            Button("Save serving profile…") {
                profileSaveRequest = ServingProfileSaveRequest(run: run, laneID: lane.resultKey, letter: lane.letter)
            }.buttonStyle(.bordered).controlSize(.small)
        }
        if run.effectiveMode == .chat, !run.hasCustomServingConfiguration, lane.path == winnerPath || (run.useCase != nil && lane.state == .measured) {
            HStack(spacing: WorkbenchSpacing.xs) {
                if lane.path == winnerPath, let winner = run.winner {
                    Button("Use fastest…") { promoteContext = PromoteContext(run: run, winner: winner) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let useCase = run.useCase, lane.state == .measured {
                    Menu {
                        Button("Set as preferred for \(useCase.title)") { setPreferred(lane.path, for: useCase) }
                            .disabled(appHost.recommendationPreferences.preferredModelIDs[useCase] == lane.path)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More actions for this model")
                    .accessibilityLabel("More actions for model \(lane.letter)")
                }
            }
        }
    }

    // MARK: - Actions

    private func slotBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { index < variantSlots.count ? variantSlots[index] : nil },
            set: { if index < variantSlots.count { initializedSuggestions = true; manuallySelectedModels = true; selectionReason = "Your model selection."; if variantSlots[index] != $0 { strataSettings[slotIDs[index]] = nil }; variantSlots[index] = $0 } }
        )
    }

    private func applySuggestions() {
        guard !initializedSuggestions, comparison.activeRunID == nil, !readyModels.isEmpty else { return }
        let suggestion = ComparisonInsights.suggestion(candidates: readyModels, lastServed: appHost.usage.lastServedByPath,
            selectedPath: appHost.selectedModelPath, runs: comparison.runs, mode: mode,
            environment: appHost.watch.currentFingerprintDescription, promptSetID: selectedPromptSet?.id,
            promptEntries: selectedPromptSet?.prompts)
        strataSettings = [:]
        laneSources = [:]
        variantSlots = suggestion.paths
        selectionReason = suggestion.reason
        initializedSuggestions = true
    }

    private func loadWorkflowComparison(_ taskID: String) -> WorkflowCharts.ComparisonSelection {
        // Rebuild from current identities at click time; never apply the view's
        // older snapshot after inventory, evidence, environment or run state changes.
        let models = appHost.librarySnapshot?.models ?? []
        let tasks = AgentTaskAdvisor.guidance(models: models, runs: [], workflow: appHost.workflowEvidence.records,
            environment: appHost.watch.currentFingerprintDescription, hardware: appHost.hardwareProfile,
            memory: nil, contextTokens: 8192, reserveGB: 0)
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            return WorkflowCharts.ComparisonSelection(slots: nil, reason: "Workflow evidence changed. Select the cohort again.")
        }
        let selection = WorkflowCharts.comparisonSelection(task, models: models, mode: mode, activeRunID: comparison.activeRunID)
        if let slots = selection.slots {
            strataSettings = [:]
            laneSources = [:]
            variantSlots = slots
            initializedSuggestions = true
            manuallySelectedModels = true
            selectionReason = selection.reason
        }
        return selection
    }

    private func removeSlot(_ index: Int) {
        guard index >= 2, index < variantSlots.count else { return }
        strataSettings[slotIDs[index]] = nil
        slotIDs.remove(at: index)
        slotIDs.append(UUID().uuidString)
        variantSlots.remove(at: index)
    }

    private func startRun() {
        guard let promptSet = selectedPromptSet,
              runUnavailableReason == nil else { return }
        if mode == .chat {
            comparison.start(lanes: selectedChatLanes, promptSet: promptSet, settingsSearchGoal: settingsSearchGoal)
        } else {
            let variants = ComparePresentation.variantPaths(variantSlots).compactMap { path in
                readyModels.first { $0.item.path == path }.map { (path: $0.item.path, signature: $0.item.signature) }
            }
            comparison.start(variants: variants, promptSet: promptSet, mode: mode)
        }
    }

    private func removePromptSet(_ set: PromptSet) {
        guard comparison.removePromptSet(id: set.id) else { return }
        if reusedPromptSet?.id == set.id { reusedPromptSet = nil }
        if selectedPromptSetID == set.id { selectedPromptSetID = modePromptSets.first?.id ?? "" }
    }

    private func openPromptSetCopy() {
        guard let set = selectedPromptSet, comparison.activeRunID == nil, !comparison.savingPromptSet else { return }
        do {
            if set.effectiveMode == .musicGeneration {
                pendingMusicPromptSetCopy = try MusicPromptSetDraft(copying: set)
            } else {
                pendingGeneralPromptSetCopy = try ComparisonPromptSetDraft(copying: set)
            }
            promptSetCopyError = nil
        } catch { promptSetCopyError = error.localizedDescription }
    }

    private func openPromptSetEditor() {
        guard let set = selectedPromptSet else { return }
        if set.effectiveMode == .musicGeneration {
            pendingPromptSetEdit = comparison.prepareMusicPromptSetEdit(id: set.id)
        } else {
            pendingGeneralPromptSetEdit = comparison.preparePromptSetEdit(id: set.id)
        }
    }

    private func applyReusedSetup(_ setup: MusicComparisonSetup, _ promptSet: PromptSet) {
        guard comparison.activeRunID == nil else { return }
        strataSettings = [:]
        laneSources = [:]
        useRecordedSetup(mode: .musicGeneration, paths: setup.modelPaths, name: setup.sourceName, promptSet: promptSet)
        pendingReuseSetup = nil
    }

    private func applyReusedSetup(_ setup: ComparisonRunSetup, _ promptSet: PromptSet) -> String? {
        guard comparison.activeRunID == nil else { return "Wait for the current comparison to finish." }
        strataSettings = [:]
        laneSources = [:]
        for (index, path) in setup.modelPaths.enumerated() {
            if let options = setup.laneConfigurations?[index].strataOptions ?? setup.strataOptions?[path] {
                strataSettings[slotIDs[index]] = options
            }
            if let lane = setup.laneConfigurations?[index] { laneSources[slotIDs[index]] = lane }
        }
        useRecordedSetup(mode: setup.draft.mode, paths: setup.modelPaths, name: setup.sourceName, promptSet: promptSet)
        pendingGeneralReuseSetup = nil
        return nil
    }

    private func useRecordedSetup(mode: ComparisonMode, paths: [String], name: String, promptSet: PromptSet) {
        settingsSearchGoal = nil
        initializedSuggestions = true
        manuallySelectedModels = true
        self.mode = mode
        familyFilter = nil
        sizeFilter = .all
        modelSearch = ""
        reusedPromptSet = promptSet
        selectedPromptSetID = promptSet.id
        variantSlots = paths.map { Optional($0) }
        while variantSlots.count < 2 { variantSlots.append(nil) }
        selectionReason = "Recorded model selection from \(name)."
        reuseError = nil
    }

    private func setPreferred(_ path: String, for useCase: UseCase) {
        appHost.setPreferredModel(path, for: useCase)
    }

    private func shortName(_ path: String) -> String {
        ComparePresentation.displayName(for: path, models: appHost.librarySnapshot?.models ?? [])
    }
}

struct ComparisonProgressControls: View {
    let message: String
    let isCancelling: Bool
    let cleanupPending: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            if !cleanupPending || isCancelling { ProgressView().controlSize(.small).accessibilityHidden(true) }
            Text(message).font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WorkbenchSpacing.sm)
            if cleanupPending {
                Button("Retry cleanup", action: onRetry).disabled(isCancelling)
                    .help("Retry stopping this comparison's owned server before starting another run.")
                    .accessibilityIdentifier("comparison-retry-cleanup")
            } else {
                Button(isCancelling ? "Cancelling…" : "Cancel comparison", action: onCancel).disabled(isCancelling)
                    .help("Stop this comparison's owned work and retain recorded samples. Server startup may need to finish before cleanup.")
                    .accessibilityIdentifier("comparison-cancel")
            }
        }
    }
}

struct StrataSettingsSearchSheet: View {
    let models: [LibraryModel]
    let onUse: (LibraryModel, StrataSettingsSearchSetup) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var modelPath: String
    @State private var lowerBudget = "2"
    @State private var upperBudget = "4"
    @State private var headroom = "8"
    @State private var context = 8192
    @State private var objective = StrataSettingsSearchObjective.firstAnswer
    @State private var warmEachPrompt = false
    @State private var error: String?

    init(models: [LibraryModel], onUse: @escaping (LibraryModel, StrataSettingsSearchSetup) -> String?) {
        self.models = models; self.onUse = onUse
        _modelPath = State(initialValue: models.first?.item.path ?? "")
    }
    private var setup: StrataSettingsSearchSetup? {
        guard let lower = Double(lowerBudget.trimmingCharacters(in: .whitespaces)),
              let upper = Double(upperBudget.trimmingCharacters(in: .whitespaces)),
              let target = Double(headroom.trimmingCharacters(in: .whitespaces)) else { return nil }
        return StrataSettingsSearchSetup(lowerExpertMemoryGB: lower, upperExpertMemoryGB: upper, contextTokens: context,
            headroomGB: target, objective: objective, warmEachPrompt: warmEachPrompt)
    }
    private var validation: String? { setup?.validationError ?? (setup == nil ? "Enter numeric expert budgets and a headroom target." : nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Find best Strata settings").font(WorkbenchTypography.cardTitle)
            Picker("Model", selection: $modelPath) {
                ForEach(models, id: \.item.path) { model in Text(model.item.name).tag(model.item.path) }
            }
            Picker("Fixed context", selection: $context) {
                ForEach([2048, 4096, 8192, 16384, 32768, 65536, 131072], id: \.self) { value in Text("\(value) tokens").tag(value) }
            }
            Picker("Minimize latency to", selection: $objective) {
                ForEach(StrataSettingsSearchObjective.allCases) { Text($0.title).tag($0) }
            }
            Text(objective.explanation)
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("Warm each prompt before measuring", isOn: $warmEachPrompt)
            Text("Adds a one-token request immediately before each measured prompt. Warm-up responses are excluded from samples; total run time increases. Recorded cache counts still determine comparability.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Expert budgets (GB)")
                TextField("Lower", text: $lowerBudget).frame(width: 80)
                TextField("Upper", text: $upperBudget).frame(width: 80)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Text("Observed headroom target (GB)")
                TextField("Headroom", text: $headroom).frame(width: 80).textFieldStyle(.roundedBorder)
            }
            Text("Four lanes test each budget with speculation off and on, using the same prompt set and context. Use setup prepares the lanes; Run comparison starts them sequentially. Existing memory admission guards still apply.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            Text("Rate every lane's task quality after the run. A suggested configuration needs a score of 4 or 5, complete answers, matching fingerprints and sufficient observed headroom. Verify its serving profile before use.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            ErrorBanner(text: validation ?? error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use setup") {
                    guard let setup, let model = models.first(where: { $0.item.path == modelPath }) else { return }
                    error = onUse(model, setup)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(validation != nil || !models.contains(where: { $0.item.path == modelPath }))
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 540)
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
    private var winnerName: String {
        ComparePresentation.displayName(for: winnerPath, models: appHost.librarySnapshot?.models ?? [])
    }
    private var endpoint: EndpointSupervisor { appHost.endpoint }
    private var winnerVerified: Bool { appHost.isModelVerified(winnerPath) }
    private var endpointAlreadyWinner: Bool {
        endpoint.config.enabled && endpoint.config.modelPath == winnerPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Promote \(winnerName)")
                .font(WorkbenchTypography.emphasis)
            Text(statsLine)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            if let useCase = context.run.useCase {
                Label("Set as preferred for \(useCase.title)", systemImage: "star.fill")
                    .font(WorkbenchTypography.secondary)
            }

            endpointSection

            ErrorBanner(text: errorText)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isApplying ? "Promoting…" : "Promote") { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 460)
    }

    private var statsLine: String {
        var parts: [String] = []
        if let tps = context.winner.aggregateTokensPerSecond {
            parts.append(ComparisonMetric.tokensPerSecond.format(tps))
        }
        if let ttft = context.winner.aggregateTTFTSeconds {
            parts.append(ComparisonViewLogic.firstToken(ttft))
        }
        return parts.isEmpty ? "Fastest measured variant in this run." : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var endpointSection: some View {
        if endpointAlreadyWinner {
            Label("Already the always-on endpoint model (port \(endpoint.config.port)).",
                  systemImage: "checkmark.circle")
                .font(WorkbenchTypography.secondary)
        } else {
            Toggle(isOn: $enableEndpoint) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text("Keep it always-on")
                        .font(WorkbenchTypography.secondary)
                    Text(endpointCaption)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
            .disabled(!winnerVerified && !allowUnverified)

            if !winnerVerified {
                Toggle("Enable anyway (unverified)", isOn: $allowUnverified)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                Text("This model has not passed the verification canary suite.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
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
            do { try appHost.savePreferredModel(winnerPath, for: useCase) }
            catch { errorText = AppHost.render(error); return }
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

struct StrataComparisonControls: View {
    @Binding var options: StrataComparisonOptions
    var helpText = "A smaller expert budget pages more weights from disk. Custom settings are recorded with this run and excluded from default recommendations."

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Toggle("Draft-and-verify speculation", isOn: $options.speculation)
            Picker("Expert memory", selection: $options.expertMemoryGB) {
                Text("Automatic").tag(Optional<Double>.none)
                ForEach(Array(Set([0.5, 2, 4, 8, 12, 16, 24, 32, 48, 64] + (options.expertMemoryGB.map { [$0] } ?? []))).sorted(), id: \.self) { budget in
                    Text("\(budget.formatted()) GB").tag(Optional(budget))
                }
            }.fixedSize()
            Picker("Context capacity", selection: $options.contextTokens) {
                ForEach(Array(Set([2048, 8192, 32768, 131072, options.contextTokens])).sorted(), id: \.self) { count in
                    Text("\(count) tokens").tag(count)
                }
            }.fixedSize()
            if let error = options.validationError { Text(error).foregroundStyle(.red) }
            Text(helpText)
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }.padding(.top, WorkbenchSpacing.sm)
    }
}
