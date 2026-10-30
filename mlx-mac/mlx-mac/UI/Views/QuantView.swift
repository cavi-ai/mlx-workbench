import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - QuantView
// Compare tab: measured comparison of ready variants via prompt-set replay
// (premium spec 03). Lettered lanes lead with the mode's primary metric above
// a prompt-by-lane output grid; diffs stay behind a disclosure. Past runs are
// browsable history.

struct QuantView: View {
    let appHost: AppHost
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var servingProfiles: ServingProfileCoordinator
    private let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive

    @State private var compareContentWidth = WorkbenchSize.assumedContentWidth
    @State private var mode: ComparisonMode = .chat
    @State private var showingSetEditor = false
    /// A saved-set edit or a customized copy; new sets use `showingSetEditor`.
    @State private var pendingPromptSetDraft: PromptSetDraft?
    @State private var promptSetCopyError: String?
    @State private var pendingPromptSetRename: PromptSet?
    @State private var pendingPromptSetRemoval: PromptSet?
    @State private var pendingReuseSetup: ComparisonRunSetup?
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
            reserveGB: appHost.config.fitReserveGB, protected: appHost.occupancy.protectedPaths)
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
        VStack(spacing: 0) {
            if shownRun?.effectiveMode != .chat { WorkbenchPageHeading(route: .compare) }
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    if shownRun == nil {
                        HStack {
                            Spacer()
                            StudiesNavigationButton(onRouteSelection: onRouteSelection)
                        }
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
                                    appHost.handoffs.send(ClientWiringRequest(modelPath: path, preferredPort: port), as: .wireClient)
                                    onRouteSelection(.clientSetup)
                                }, onImport: importReport, isReadingReport: isReadingReport || isChoosingReport)
                        }
                        .padding(.top, WorkbenchSpacing.sm)
                    }
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                }
                .frame(maxWidth: shownRun?.effectiveMode == .chat ? .infinity : 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .accessibilityIdentifier("comparison-scroll")
            .background(GeometryReader { proxy in
                let available = max(0, proxy.size.width - 2 * WorkbenchSpacing.pageInset)
                Color.clear.preference(key: CompareContentWidthKey.self,
                    value: shownRun?.effectiveMode == .chat ? available : min(1100, available))
            })
            .onPreferenceChange(CompareContentWidthKey.self) { width in
                if width > 0 { compareContentWidth = width }
            }
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
        .onChange(of: appHost.handoffs[.compareServingProfiles]?.id) { _, _ in consumeProfileComparisonRequest() }
        .task(id: isRouteActive) { consumeModelComparisonRequest() }
        .task(id: isRouteActive) { consumeFamilyComparisonRequest() }
        .task(id: isRouteActive) { consumeResultsRequest() }
        .onChange(of: appHost.handoffs[.reviewComparisonResults]?.id) { _, _ in consumeResultsRequest() }
        .onChange(of: appHost.handoffs[.compareFamily]?.id) { _, _ in consumeFamilyComparisonRequest() }
        .onChange(of: appHost.handoffs[.compareModel]?.id) { _, _ in consumeModelComparisonRequest() }
        .sheet(item: $pendingReuseSetup) { setup in
            ComparisonRunSetupSheet(setup: setup,
                availablePaths: Set(readyModels.map { $0.item.path }), name: shortName,
                onApply: applyReusedSetup, onSave: { draft in
                    guard comparison.activeRunID == nil else { return "Wait for the current comparison to finish." }
                    return await comparison.createPromptSet(draft) == nil
                        ? (comparison.promptSetManagementError ?? "Prompt set could not be saved.") : nil
                })
        }
        .onChange(of: appHost.handoffs[.importWorkflowReport]) { _, _ in consumeImportRequest() }
        .sheet(item: $pendingPromptSetRename) { set in
            PromptSetRenameSheet(set: set) { name in
                comparison.renamePromptSet(id: set.id, name: name)
                    ? nil : (comparison.promptSetManagementError ?? "Prompt set could not be renamed.")
            }
        }
        .sheet(item: $pendingPromptSetDraft) { draft in
            ComparisonPromptSetEditor(draft: draft, onSave: savePromptSetDraft)
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
        .disabled(comparison.isLoadingHistory)
        .task(id: comparison.isLoadingHistory) {
            guard !comparison.isLoadingHistory, !Task.isCancelled else { return }
            if !initializedSuggestions,
               let restored = ComparePresentation.restoredPromptSetID(runs: comparison.runs, mode: mode, promptSets: modePromptSets) {
                selectedPromptSetID = restored
            }
            applySuggestions()
            consumeResultsRequest()
        }
        .onChange(of: selectedPromptSetID) { _, newID in
            if let reusedPromptSet, newID != reusedPromptSet.id { self.reusedPromptSet = nil }
            guard !manuallySelectedModels else { return }
            initializedSuggestions = false
            applySuggestions()
        }
        .onChange(of: readyModels.map { $0.item.path }) { _, _ in
            guard !comparison.isLoadingHistory, comparison.activeRunID == nil else { return }
            if let familyFilter, !readyModels.contains(where: { ComparePresentation.familyLabel($0) == familyFilter }) { self.familyFilter = nil }
            if reusedPromptSet == nil && laneSources.isEmpty {
                let reconciled = ComparisonInsights.reconcile(slots: variantSlots, available: Set(readyModels.map { $0.item.path }))
                if reconciled != variantSlots { variantSlots = reconciled; selectionReason = "Unavailable models were cleared; your remaining selections were kept." }
            }
            applySuggestions()
        }
    }

    private func consumeImportRequest() {
        guard isRouteActive, let request = appHost.handoffs[.importWorkflowReport] else { return }
        appHost.handoffs.finish(request, as: .importWorkflowReport)
        importReport()
    }

    private var canApplyLibrarySelection: Bool {
        comparison.activeRunID == nil && !comparison.savingPromptSet && servingProfiles.activeID == nil
            && !showingSetEditor && pendingPromptSetDraft == nil
            && pendingReuseSetup == nil && pendingPromptSetRename == nil
    }

    private func consumeModelComparisonRequest() {
        guard isRouteActive, let request = appHost.handoffs[.compareModel] else { return }
        guard canApplyLibrarySelection else {
            reuseError = "Finish the current comparison, save, editor or profile verification, then use the selected Library model."
            return
        }
        guard let model = request.resolve(in: appHost.librarySnapshot?.models ?? []) else {
            reuseError = "The selected Library model is no longer ready for this comparison mode. Refresh Library and select it again."
            appHost.handoffs.finish(request, as: .compareModel)
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
        appHost.handoffs.finish(request, as: .compareModel)
    }

    private func consumeResultsRequest() {
        guard isRouteActive, let request = appHost.handoffs[.reviewComparisonResults] else { return }
        guard comparison.hasLoadedHistory, canApplyLibrarySelection else {
            reuseError = "Finish the current comparison or editor, then open the requested saved results."; return
        }
        guard let next = request.selection(in: comparison.runs, from: currentSelection, promptSets: comparison.promptSets) else {
            reuseError = "The requested comparison is no longer available."
            appHost.handoffs.finish(request, as: .reviewComparisonResults); return
        }
        apply(next)
        reuseError = nil
        appHost.handoffs.finish(request, as: .reviewComparisonResults)
    }

    private func consumeFamilyComparisonRequest() {
        guard isRouteActive, let request = appHost.handoffs[.compareFamily] else { return }
        guard canApplyLibrarySelection else {
            reuseError = "Finish the current comparison or editor, then use the selected showdown models."; return
        }
        guard let models = request.resolve(in: appHost.librarySnapshot?.models ?? []) else {
            reuseError = "A showdown model changed or is unavailable. Select the entrants again in Reclaim."
            appHost.handoffs.finish(request, as: .compareFamily); return
        }
        reusedPromptSet = nil
        changeMode(to: request.mode)
        if !modePromptSets.contains(where: { $0.id == selectedPromptSetID }) { selectedPromptSetID = modePromptSets.first?.id ?? "" }
        variantSlots = models.map { Optional($0.item.path) }
        slotIDs = (0..<ComparePresentation.maxSlots).map { _ in UUID().uuidString }
        strataSettings = [:]; laneSources = [:]; settingsSearchGoal = nil
        familyFilter = nil; sizeFilter = .all; modelSearch = ""
        initializedSuggestions = true; manuallySelectedModels = true
        selectedRunID = nil; reuseError = nil
        selectionReason = "Showdown from Reclaim. Choose prompts that exercise each model’s intended purpose, run the comparison, then rate task quality."
        appHost.handoffs.finish(request, as: .compareFamily)
    }

    private func consumeProfileComparisonRequest() {
        guard isRouteActive, let request = appHost.handoffs[.compareServingProfiles] else { return }
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
            appHost.handoffs.finish(request, as: .compareServingProfiles)
        } catch { reuseError = AppHost.render(error); appHost.handoffs.finish(request, as: .compareServingProfiles) }
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
        let run = ComparePresentation.shownRun(runs: comparison.runs, mode: mode, selectedRunID: selectedRunID, activeRunID: comparison.activeRunID)
        return comparison.detailedRun?.id == run?.id ? comparison.detailedRun : run
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
            if appHost.handoffs[.compareServingProfiles] != nil {
                Button("Use requested profiles") { consumeProfileComparisonRequest() }
                    .disabled(comparison.activeRunID != nil || comparison.savingPromptSet || servingProfiles.activeID != nil)
            }
            if appHost.handoffs[.reviewComparisonResults] != nil {
                Button("Open requested saved results") { consumeResultsRequest() }
                    .disabled(!canApplyLibrarySelection || !comparison.hasLoadedHistory)
            }
            if appHost.handoffs[.compareFamily] != nil {
                Button("Use selected showdown models") { consumeFamilyComparisonRequest() }
                    .disabled(!canApplyLibrarySelection)
            }
            if appHost.handoffs[.compareModel] != nil {
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
            ComparisonPromptSetEditor(draft: PromptSetDraft(mode: mode), onSave: savePromptSetDraft)
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
            .buttonStyle(.workbenchPrimary)
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
            if run.historyDetailsOmitted == true {
                VStack(alignment: .leading) {
                    runHeader
                    if let error = comparison.detailError { ErrorBanner(text: error) }
                    else { ProgressView("Loading recorded outputs…") }
                    Button("Load outputs") { Task { await comparison.loadDetails(for: run.id) } }
                }.task(id: run.id) { await comparison.loadDetails(for: run.id) }
            } else { runDetail(run) }
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
                        pendingReuseSetup = try ComparisonRunSetup(run: run, outputStore: comparison.outputStore)
                        reuseError = nil
                    }
                    catch { reuseError = error.localizedDescription }
                } label: { Label("Reuse setup", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(comparison.activeRunID != nil || run.historyDetailsOmitted == true || run.promptEntries?.isEmpty != false)
                    .help(run.promptEntries?.isEmpty != false
                          ? "This older run has no recorded prompt snapshot."
                          : "Edit the recorded prompts and settings for a new comparison.")
            }
            Spacer()
            if shownRun != nil {
                StudiesNavigationButton(onRouteSelection: onRouteSelection)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
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
        return Group {
            if run.effectiveMode == .chat { runDetailBody(run, winnerPath: winnerPath) }
            else { WorkbenchSurface { runDetailBody(run, winnerPath: winnerPath) } }
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

    private func runDetailBody(_ run: ComparisonRun, winnerPath: String?) -> some View {
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

            if run.effectiveMode == .chat {
                ChatComparisonResultsView(run: run,
                    store: comparison.outputStore ?? ComparisonOutputStore(), contentWidth: compareContentWidth,
                    name: { shortName($0) },
                    onReview: { path, score in comparison.reviewQuality(runID: run.id, modelPath: path, score: score) },
                    reviewError: comparison.persistenceError,
                    onPromote: { winner in promoteContext = PromoteContext(run: run, winner: winner) },
                    laneActions: { lane in laneActions(lane, run: run, winnerPath: nil) })
                    .id(run.id)
            } else {
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
        }
    }

    /// Chat lanes carry the promote button on the winner and the preferred-model menu.
    @ViewBuilder
    private func laneActions(_ lane: CompareLane, run: ComparisonRun, winnerPath: String?) -> some View {
        if run.state == .completed, run.laneConfigurations?.first(where: { $0.id == lane.resultKey })?.servingProfileID != nil,
           let result = run.results.first(where: { $0.id == lane.resultKey }), result.error == nil,
           !result.samples.isEmpty, result.samples.allSatisfy(\.hasCompletedAnswer) {
            Button("Verify measured profile…") {
                Task {
                    do {
                        let profile = try await servingProfiles.prepareMeasuredVerification(run: run, laneID: lane.resultKey)
                        profileSaveRequest = ServingProfileSaveRequest(run: run, laneID: lane.resultKey, letter: lane.letter, action: .verifyMeasured(profile))
                    } catch { profileActionError = AppHost.render(error) }
                }
            }.buttonStyle(.workbenchPrimary).controlSize(.small)
                .disabled(comparison.activeRunID != nil || servingProfiles.activeID != nil)
        }
        if run.settingsSearchCandidateID == lane.resultKey {
            Button("Save and verify suggestion…") {
                profileSaveRequest = ServingProfileSaveRequest(run: run, laneID: lane.resultKey, letter: lane.letter, action: .verifySuggestion)
            }.buttonStyle(.workbenchPrimary).controlSize(.small)
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
        Task {
            guard await comparison.removePromptSet(id: set.id) else { return }
            if reusedPromptSet?.id == set.id { reusedPromptSet = nil }
            if selectedPromptSetID == set.id { selectedPromptSetID = modePromptSets.first?.id ?? "" }
        }
    }

    private func openPromptSetCopy() {
        guard let set = selectedPromptSet, comparison.activeRunID == nil, !comparison.savingPromptSet else { return }
        do {
            pendingPromptSetDraft = try PromptSetDraft(copying: set)
            promptSetCopyError = nil
        } catch { promptSetCopyError = error.localizedDescription }
    }

    private func openPromptSetEditor() {
        guard let set = selectedPromptSet else { return }
        pendingPromptSetDraft = comparison.preparePromptSetEdit(id: set.id)
    }

    /// Saves edits to a saved set, or creates a new or copied set and selects it.
    private func savePromptSetDraft(_ draft: PromptSetDraft) async -> String? {
        if draft.original != nil {
            return await comparison.savePromptSetEdits(draft)
                ? nil : (comparison.promptSetManagementError ?? "Prompt set could not be saved.")
        }
        guard let set = await comparison.createPromptSet(draft) else {
            return comparison.promptSetManagementError ?? "Prompt set could not be created."
        }
        selectedPromptSetID = set.id
        return nil
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
        pendingReuseSetup = nil
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
