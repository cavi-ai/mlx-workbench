import Charts
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - QuantView
// Compare tab: measured comparison of ready variants via prompt-set replay
// (premium spec 03). Key metrics stay on screen; per-prompt outputs and
// diffs stay behind disclosures. Past runs are browsable history.

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
    static func options(forSlot index: Int, slots: [String?], candidates: [LibraryModel]) -> [LibraryModel] {
        let taken = Set(slots.enumerated().compactMap { $0.offset == index ? nil : $0.element })
        return candidates.filter { !taken.contains($0.item.path) }
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

    static func canRun(slots: [String?], activeRunID: UUID?) -> Bool {
        !variantPaths(slots).isEmpty && activeRunID == nil
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

struct QuantView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var comparison: ComparisonCoordinator
    private let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive

    @State private var mode: ComparisonMode = .chat
    @State private var showingSetEditor = false
    @State private var variantSlots: [String?] = [nil, nil]
    @State private var selectedPromptSetID: String = BuiltinPromptSets.coding.id
    @State private var selectedRunID: ComparisonRun.ID?
    @State private var diffLeftPath: String?
    @State private var diffRightPath: String?
    @State private var promoteContext: PromoteContext?
    @State private var promotedWinnerPath: String?
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

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                resultsArea
                WorkflowChartsView(workflow: appHost.workflowEvidence, models: appHost.librarySnapshot?.models ?? [],
                    environment: appHost.watch.currentFingerprintDescription, hardware: appHost.hardwareProfile,
                    mode: mode, activeRunID: comparison.activeRunID, onCompare: loadWorkflowComparison,
                    onReview: reviewWorkflowModel,
                    onApply: { review, role, endpoint in try await appHost.applyModelGuidance(review, role: role, enableEndpoint: endpoint) },
                    metric: $workflowChartMetric, inspectedModelPath: $inspectedWorkflowModelPath)
                if let importMessage { Text(importMessage).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
                ErrorBanner(text: importError)
                setupBar
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
                            promptSetID: selectedPromptSet?.id ?? "", mode: mode, onReclaim: { onRouteSelection(.reclaim) },
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
        .sheet(isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } })) {
            if let importPreview {
                WorkflowImportPreviewView(preview: importPreview,
                    models: (appHost.librarySnapshot?.models ?? []).map { WorkflowCaptureModel(path: $0.item.path, name: $0.displayName, signature: $0.item.signature) },
                    environment: appHost.watch.currentFingerprintDescription,
                    onCancel: { self.importPreview = nil }, onConfirm: confirmImport)
            }
        }
        .task(id: isRouteActive) { consumeImportRequest() }
        .onChange(of: appHost.workflowReportImportRequested) { _, _ in consumeImportRequest() }
        .onChange(of: comparison.activeRunID) { _, newValue in
            if let newValue { selectedRunID = newValue }
        }
        .onAppear {
            if !initializedSuggestions, let recent = comparison.runs.first(where: { run in run.effectiveMode == mode && modePromptSets.contains(where: { $0.id == run.promptSetID }) }), modePromptSets.contains(where: { $0.id == recent.promptSetID }) {
                selectedPromptSetID = recent.promptSetID
            }
            applySuggestions()
            if selectedRunID == nil {
                selectedRunID = comparison.runs.first?.id
            }
        }
        .onChange(of: selectedPromptSetID) { _, _ in
            guard !manuallySelectedModels else { return }
            initializedSuggestions = false
            applySuggestions()
        }
        .onChange(of: readyModels.map { $0.item.path }) { _, _ in
            guard comparison.activeRunID == nil else { return }
            if let familyFilter, !readyModels.contains(where: { ComparePresentation.familyLabel($0) == familyFilter }) { self.familyFilter = nil }
            let reconciled = ComparisonInsights.reconcile(slots: variantSlots, available: Set(readyModels.map { $0.item.path }))
            if reconciled != variantSlots { variantSlots = reconciled; selectionReason = "Unavailable models were cleared; your remaining selections were kept." }
            applySuggestions()
        }
    }

    private func consumeImportRequest() {
        guard isRouteActive, appHost.workflowReportImportRequested else { return }
        appHost.workflowReportImportRequested = false
        importReport()
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
            importMessage = "Imported \(count) new workflow records. Matching reports appear in Workflow performance."
            importError = nil
            appHost.analyzeReclaim()
        } catch { importError = AppHost.render(error); importMessage = nil }
        self.importPreview = nil
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
        ComparisonViewLogic.candidates(from: appHost.librarySnapshot?.models ?? [], mode: mode)
    }

    private var filteredModels: [LibraryModel] {
        ComparePresentation.filtered(readyModels, family: familyFilter, size: sizeFilter, query: modelSearch)
    }

    private var modePromptSets: [PromptSet] {
        ComparisonViewLogic.promptSets(comparison.promptSets, for: mode)
    }

    private var selectedPromptSet: PromptSet? {
        modePromptSets.first { $0.id == selectedPromptSetID } ?? modePromptSets.first
    }

    private static let slotLetters = ["A", "B", "C", "D"]

    private var setupBar: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(WorkbenchColor.accent)
                Text("Compare models")
                    .font(WorkbenchTypography.roundedHeading)
            }

            ViewThatFits(in: .horizontal) {
                comparisonModePicker.pickerStyle(.segmented).labelsHidden().fixedSize()
                comparisonModePicker.pickerStyle(.menu)
            }
            .disabled(comparison.activeRunID != nil)
            .onChange(of: mode) { _, newMode in
                familyFilter = nil
                sizeFilter = .all
                modelSearch = ""
                initializedSuggestions = false
                manuallySelectedModels = false
                applySuggestions()
                selectedPromptSetID = ComparisonViewLogic.promptSets(comparison.promptSets, for: newMode).first?.id ?? ""
            }

            if readyModels.isEmpty {
                Text(mode == .chat
                    ? "No ready models in the latest Library snapshot."
                    : "No ready \(mode.acceptedTaskTypes.map { $0.title.lowercased() }.joined(separator: " or ")) models in the latest Library snapshot.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }

            if !readyModels.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.sm) { modelFilters }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { modelFilters }
                }
                if filteredModels.isEmpty {
                    Text("No models match these filters. Your selected models are kept.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), alignment: .leading)],
                    alignment: .leading,
                    spacing: WorkbenchSpacing.xs
                ) {
                    slotControls
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { comparisonControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { comparisonControls }
            }
            .padding(.top, WorkbenchSpacing.sm)
            .overlay(alignment: .top) {
                Rectangle().fill(WorkbenchColor.accent.opacity(0.18)).frame(height: 1)
            }
            if comparison.activeRunID != nil {
                ProgressView(comparison.progressMessage ?? "Measuring…")
            }
            ErrorBanner(text: comparison.lastError)
            ErrorBanner(text: comparison.persistenceError)
        }
        .padding(WorkbenchSpacing.surfaceInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchColor.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: WorkbenchRadius.page))
        .overlay {
            RoundedRectangle(cornerRadius: WorkbenchRadius.page)
                .strokeBorder(WorkbenchColor.accent.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder private var modelFilters: some View {
        TextField("Find a model…", text: $modelSearch)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
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
            HStack(spacing: WorkbenchSpacing.xs) {
                Text(Self.slotLetters[min(index, Self.slotLetters.count - 1)])
                    .font(WorkbenchTypography.roundedLabel)
                    .foregroundStyle(WorkbenchColor.accent)
                    .frame(width: 24, height: 24)
                    .background(WorkbenchColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                    .accessibilityHidden(true)
                Picker("Model \(Self.slotLetters[min(index, Self.slotLetters.count - 1)])", selection: slotBinding(index)) {
                    Text("None").tag(String?.none)
                    if let selected = ComparePresentation.selectedOutsideFilter(forSlot: index, slots: variantSlots, candidates: readyModels, filtered: filteredModels) {
                        Section("Selected outside filters") {
                            Text(modelOptionLabel(selected)).tag(Optional(selected.item.path))
                        }
                    }
                    ForEach(ComparePresentation.groups(ComparePresentation.options(forSlot: index, slots: variantSlots, candidates: filteredModels), by: modelGrouping)) { group in
                        Section(group.title) {
                            ForEach(group.models, id: \.item.path) { model in
                                Text(modelOptionLabel(model)).tag(Optional(model.item.path))
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(variantSlots[index].map { shortName($0) } ?? "Choose a model")

                if index >= 2 {
                    Button { removeSlot(index) } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .help("Remove this model")
                        .accessibilityLabel("Remove model \(Self.slotLetters[min(index, Self.slotLetters.count - 1)])")
                }
            }
            .padding(WorkbenchSpacing.xs)
            .background(WorkbenchColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchRadius.control)
                    .strokeBorder(WorkbenchColor.hairline.opacity(0.5), lineWidth: 1)
            }
        }

        if variantSlots.count < ComparePresentation.maxSlots {
            Button { variantSlots.append(nil) } label: { Label("Add model", systemImage: "plus") }
                .buttonStyle(.borderless)
                .foregroundStyle(WorkbenchColor.accent)
                .help("Add a model")
                .accessibilityLabel("Add a model")
        }
    }

    private func modelOptionLabel(_ model: LibraryModel) -> String {
        let size = modelGrouping == .disk ? (model.item.bytes > 0 ? ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file) : "Disk unknown") : model.item.parameters
        return [model.displayName, model.item.quantization, size].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var comparisonControls: some View {
        Picker("Prompt set", selection: $selectedPromptSetID) {
            ForEach(modePromptSets) { set in
                Text(set.name).tag(set.id)
            }
        }
        .font(WorkbenchTypography.emphasis)
        .frame(maxWidth: 260, alignment: .leading)

        if mode == .chat {
            Button("Import OpenCode prompts") {
                if let imported = comparison.importHistory() {
                    selectedPromptSetID = imported.id
                }
            }
            .buttonStyle(.bordered)
            .help("Read-only import of your opencode user prompts as a prompt set.")
        }
            Button("New set…") { showingSetEditor = true }
                .buttonStyle(.bordered)
                .help("Build a prompt set\(mode.inputKind.map { " with your own \($0.rawValue) files" } ?? "").")
                .sheet(isPresented: $showingSetEditor) {
                    MediaPromptSetEditor(mode: mode) { set in
                        comparison.savePromptSet(set)
                        selectedPromptSetID = set.id
                    }
                }

        Button { startRun() } label: { Label("Run comparison", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.accent)
            .font(WorkbenchTypography.emphasis)
            .controlSize(.large)
            .disabled(!ComparePresentation.canRun(slots: variantSlots, activeRunID: comparison.activeRunID))
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if let run = selectedRun {
            runDetail(run)
        } else {
            HStack { Spacer(); championsMenu }
            Text("Pick models above and run a comparison to see results here.")
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private func runHeader(_ run: ComparisonRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            ComparisonHistoryPicker(runs: comparison.runs, selection: $selectedRunID)
            .frame(maxWidth: 420, alignment: .leading)
            championsMenu
            Spacer()
            if run.effectiveMode == .chat, let winner = run.winner, run.state == .completed {
                Label("Fastest: \(shortName(winner.modelPath))", systemImage: "bolt.fill")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.accent)
                Button("Use fastest…") {
                    promoteContext = PromoteContext(run: run, winner: winner)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var comparisonModePicker: some View {
        Picker("Mode", selection: $mode) {
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
                        if let value = champion.run.effectiveMode == .chat ? result.aggregateTokensPerSecond : result.aggregateMetric {
                            Button {
                                selectedRunID = champion.run.id
                            } label: {
                                Label("\(champion.run.effectiveMode.primaryMetric.title): \(shortName(result.modelPath)) · \(champion.run.effectiveMode.primaryMetric.format(value))\(champion.performance.count > 1 ? " (tie)" : "")", systemImage: "trophy.fill")
                            }
                        }
                    }
                    ForEach(champion.quality) { result in
                        if let score = champion.run.qualityReviews?[result.modelPath]?.score {
                            Button {
                                selectedRunID = champion.run.id
                            } label: {
                                Label("Task quality: \(shortName(result.modelPath)) · \(score)/5\(champion.quality.count > 1 ? " (tie)" : "")", systemImage: "trophy.fill")
                            }
                        }
                    }
                    if champion.quality.isEmpty { Text("Task quality: not established") }
                    ForEach(champion.latency) { result in
                        if let value = result.aggregateTTFTSeconds {
                            Button("First token: \(shortName(result.modelPath)) · \(String(format: "%.2f s", value))\(champion.latency.count > 1 ? " (tie)" : "")") {
                                selectedRunID = champion.run.id
                            }
                        }
                    }
                    Text("Measured \((champion.run.finishedAt ?? champion.run.startedAt).formatted(date: .abbreviated, time: .shortened))")
                } header: {
                    Text("\(champion.run.promptSetName) · \(champion.run.effectiveMode.title)")
                }
            }
        } label: {
            Label("Champions", systemImage: "trophy.fill")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.warning)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current task champions on this Mac. Select an award to view its measured run; ties are shared.")
    }

    // MARK: - Selected run detail

    private func runDetail(_ run: ComparisonRun) -> some View {
        let successful = run.results.filter { $0.error == nil }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            runHeader(run)

            if promotedWinnerPath != nil {
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

            if run.effectiveMode == .chat {
                if !successful.isEmpty {
                    speedChart(successful)
                }

                DisclosureGroup("Outputs and per-model results") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                        ForEach(run.results) { result in
                            variantCard(result, run: run)
                        }
                        if run.state == .completed, successful.count >= 2 {
                            diffSection(run)
                        }
                    }
                    .padding(.top, WorkbenchSpacing.sm)
                }
            } else {
                MediaRunResultsView(
                    run: run,
                    store: comparison.outputStore ?? ComparisonOutputStore(),
                    name: { shortName($0) }
                )
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
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                Text("Speed")
                    .font(WorkbenchTypography.roundedTitle)
                Text("TOKENS / SECOND")
                    .font(WorkbenchTypography.label)
                    .tracking(1)
                    .foregroundStyle(WorkbenchColor.muted)
                Spacer()
                if average > 0 {
                    Text(String(format: "Avg decode %.1f tok/s", average))
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
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
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartXAxis {
                AxisMarks(position: .bottom)
            }
            .frame(height: CGFloat(max(results.count, 1)) * 44 + 40)
        }.monospacedDigit()
    }

    private func variantCard(_ result: VariantResult, run: ComparisonRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shortName(result.modelPath))
                    .font(WorkbenchTypography.emphasis)
                Spacer()
                if let tps = result.aggregateTokensPerSecond {
                    Text(String(format: "%.1f tok/s out", tps)).font(WorkbenchTypography.secondary)
                }
                if let prefill = result.aggregatePrefillTokensPerSecond {
                    Text(String(format: "%.0f tok/s in (est.)", prefill))
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                if let ttft = result.aggregateTTFTSeconds {
                    Text(String(format: "TTFT %.2fs", ttft))
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }

            if let error = result.error {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
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
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(toolCalls > 0 && valid == toolCalls ? WorkbenchColor.success : WorkbenchColor.warning)
                }
                DisclosureGroup("Per-prompt outputs (\(result.samples.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.samples, id: \.promptID) { sample in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(sample.promptID).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                                    Spacer()
                                    if let tps = sample.tokensPerSecond {
                                        Text(String(format: "%.1f tok/s", tps))
                                            .font(WorkbenchTypography.secondary)
                                            .foregroundStyle(WorkbenchColor.muted)
                                    }
                                    if let prefill = sample.prefillTokensPerSecond {
                                        Text(String(format: "in %.0f", prefill))
                                            .font(WorkbenchTypography.secondary)
                                            .foregroundStyle(WorkbenchColor.muted)
                                    }
                                    if let toolCalls = sample.toolCalls {
                                        Text("\(toolCalls) call(s): \((sample.toolNames ?? []).joined(separator: ", "))")
                                            .font(WorkbenchTypography.secondary)
                                            .foregroundStyle(WorkbenchColor.muted)
                                    }
                                }
                                Text(sample.outputExcerpt)
                                    .font(WorkbenchTypography.value)
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
        .background(WorkbenchColor.canvas)
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
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
        }
    }

    private func statChip(_ label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            Text(String(format: "%.1f", value))
                .font(WorkbenchTypography.value)
                .foregroundStyle(WorkbenchColor.ink)
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
                                    .font(WorkbenchTypography.value)
                                    .foregroundStyle(diffColor(line.kind))
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
        case .context: return WorkbenchColor.ink
        case .added: return WorkbenchColor.success
        case .removed: return WorkbenchColor.failure
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

    private func slotBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { index < variantSlots.count ? variantSlots[index] : nil },
            set: { if index < variantSlots.count { initializedSuggestions = true; manuallySelectedModels = true; selectionReason = "Your model selection."; variantSlots[index] = $0 } }
        )
    }

    private func applySuggestions() {
        guard !initializedSuggestions, comparison.activeRunID == nil, !readyModels.isEmpty else { return }
        let suggestion = ComparisonInsights.suggestion(candidates: readyModels, lastServed: appHost.usage.lastServedByPath, selectedPath: appHost.selectedModelPath, runs: comparison.runs, mode: mode, environment: appHost.watch.currentFingerprintDescription, promptSetID: selectedPromptSet?.id)
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
            variantSlots = slots
            initializedSuggestions = true
            manuallySelectedModels = true
            selectionReason = selection.reason
        }
        return selection
    }

    private func removeSlot(_ index: Int) {
        guard index >= 2, index < variantSlots.count else { return }
        variantSlots.remove(at: index)
    }

    private func startRun() {
        guard let promptSet = selectedPromptSet else { return }
        let variants = ComparePresentation.variantPaths(variantSlots).compactMap { path in
            readyModels.first { $0.item.path == path }
                .map { (path: $0.item.path, signature: $0.item.signature) }
        }
        comparison.start(variants: variants, promptSet: promptSet, mode: mode)
    }

    private func setPreferred(_ path: String, for useCase: UseCase) {
        appHost.setPreferredModel(path, for: useCase)
    }

    private func shortName(_ path: String) -> String {
        ComparePresentation.displayName(for: path, models: appHost.librarySnapshot?.models ?? [])
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
                .font(WorkbenchTypography.secondary)
        } else {
            Toggle(isOn: $enableEndpoint) {
                VStack(alignment: .leading, spacing: 2) {
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
