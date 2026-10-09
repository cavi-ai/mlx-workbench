import SwiftUI
import AppKit

// MARK: - DuplicatesView
// The Reclaim route: where the bytes are, what can be reclaimed, the quarantine
// shelf, cleanup history and duplicate groups from the convert scan.

struct DuplicatesView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var reclaim: ReclaimCoordinator
    @Environment(\.isRouteActive) private var isRouteActive

    @State private var selectedOpportunities: Set<String> = []
    @State private var showAllQuarantined = false
    @State private var showsDuplicates = false
    @State private var layout = ReclaimLayout()
    @State private var analyzedGeneration: Date?

    private static let recentQuarantineCount = 8

    init(appHost: AppHost) {
        self.appHost = appHost
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
    }

    /// Duplicate groups come from the authoritative library scan shared with
    /// Library and Reclaim — this view never runs its own scan.
    private var groups: [DuplicateGroup] {
        appHost.scanResult?.duplicates ?? []
    }

    private var libraryGeneration: Date? { appHost.librarySnapshot?.generatedAt }

    /// Only opportunities that are still actionable can be part of a selection.
    private var effectiveSelection: Set<String> {
        selectedOpportunities.intersection(Set(reclaim.opportunities.filter(\.actionable).map(\.id)))
    }

    private var presentedSheets: Set<ReclaimSheet> {
        ReclaimSheets.presented(
            hasTrashPlan: reclaim.trashPlan != nil,
            hasFolderPlan: reclaim.folderPlan != nil,
            sourcePlanWorkflowID: nil,
            reviewedSourceID: nil,
            hasRestorePlan: false,
            isRouteActive: isRouteActive
        )
    }

    var body: some View {
        let models = appHost.librarySnapshot?.models ?? []
        let ledger = ReclaimLedger(
            opportunities: reclaim.opportunities,
            quarantined: reclaim.quarantined,
            candidates: reclaim.sourceCandidates,
            sourcesChecked: reclaim.sourcesChecked,
            history: reclaim.sourceHistory,
            hasLibrary: appHost.librarySnapshot != nil,
            models: models,
            generatedAt: libraryGeneration
        )
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    ErrorBanner(text: reclaim.lastError)
                    ErrorBanner(text: reclaim.sourceHistoryError)
                    ErrorBanner(text: appHost.lastError)
                    ReclaimLedgerView(ledger: ledger, isStacked: layout.stacksStages)
                    suggestionsSection(models)
                    Divider()
                    quarantinedSection(models)
                    Divider()
                    SourceHistorySection(reclaim: reclaim, models: models, layout: layout)
                    Divider()
                    duplicatesSection
                }
                .frame(maxWidth: WorkbenchSize.Reclaim.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: viewport.size.width, initial: true) { _, width in
                layout = ReclaimLayout(viewportWidth: width, previous: layout)
            }
        }
        .toolbar {
            if isRouteActive {
                ToolbarItem(placement: .primaryAction) {
                    Button { appHost.requestRescan() } label: {
                        Label("Rescan library", systemImage: "arrow.clockwise")
                    }
                    .disabled(appHost.isScanning)
                    .help("Rescan library")
                }
            }
        }
        .onAppear {
            for trigger in ReclaimTriggers.onMount(hasScan: appHost.scanResult != nil, isScanning: appHost.isScanning) {
                switch trigger {
                case .analyze: analyze()
                case .refreshQuarantined: reclaim.refreshQuarantined()
                case .rescan: appHost.requestRescan()
                }
            }
        }
        .onChange(of: libraryGeneration) { reanalyzeIfNeeded() }
        .onChange(of: ReclaimFreshness.hasOpenPreview(reclaim)) { _, isOpen in
            if !isOpen { reanalyzeIfNeeded() }
        }
        .sheet(isPresented: Binding(get: { presentedSheets.contains(.moveToTrash) }, set: { if !$0 { reclaim.cancelTrash() } })) {
            if let plan = reclaim.trashPlan {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Label("Move to Trash", systemImage: "trash").font(WorkbenchTypography.title)
                    Text(URL(fileURLWithPath: plan.record.from).lastPathComponent).font(WorkbenchTypography.emphasis)
                    Text(ByteCountFormatter.string(fromByteCount: plan.snapshot.bytes, countStyle: .file)).font(WorkbenchTypography.value)
                    Text("This item will leave quarantine. You can recover it from Trash in Finder; Put back here will no longer be available. Empty Trash in Finder to free disk space.")
                        .font(WorkbenchTypography.secondary)
                    Text(plan.snapshot.path).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                    HStack {
                        Button("Cancel") { reclaim.cancelTrash() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        if reclaim.isApplying { ProgressView().controlSize(.small) }
                        Button("Move to Trash") { Task { await reclaim.confirmTrash() } }.buttonStyle(.borderedProminent)
                    }.disabled(reclaim.isApplying)
                }
                .padding(WorkbenchSpacing.lg).frame(width: 460)
                .interactiveDismissDisabled(reclaim.isApplying)
            }
        }
        .sheet(isPresented: Binding(get: { presentedSheets.contains(.quarantineFolder) }, set: { if !$0 { reclaim.cancelFolder() } })) {
            if let plan = reclaim.folderPlan {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Label("Quarantine model folder", systemImage: "folder.badge.minus").font(WorkbenchTypography.title)
                    Text(URL(fileURLWithPath: plan.snapshot.path).lastPathComponent).font(WorkbenchTypography.emphasis)
                    Text("\(plan.snapshot.fileCount ?? 0) files · \(ByteCountFormatter.string(fromByteCount: plan.snapshot.bytes, countStyle: .file))").font(WorkbenchTypography.value)
                    Text("Review whether other tasks still need this model. The entire folder will move to quarantine; Put back restores it. Quarantine keeps it on disk until you move it to Trash and empty Trash in Finder.").font(WorkbenchTypography.secondary)
                    Text(plan.snapshot.path).font(WorkbenchTypography.value).textSelection(.enabled)
                    Text("Destination: \(plan.quarantineDir)").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                    HStack {
                        Button("Cancel") { reclaim.cancelFolder() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        if reclaim.isApplying { ProgressView().controlSize(.small) }
                        Button("Quarantine folder") { Task {
                            await reclaim.confirmFolder()
                            if reclaim.lastError == nil { appHost.requestRescan() }
                        } }.buttonStyle(.borderedProminent)
                    }.disabled(reclaim.isApplying)
                }.padding(WorkbenchSpacing.lg).frame(width: 480).interactiveDismissDisabled(reclaim.isApplying)
            }
        }
    }

    // MARK: - Analysis

    private func analyze() {
        appHost.analyzeReclaim()
        analyzedGeneration = libraryGeneration
    }

    private func reanalyzeIfNeeded() {
        guard ReclaimFreshness.shouldReanalyze(
            analyzed: analyzedGeneration,
            current: libraryGeneration,
            hasOpenPreview: ReclaimFreshness.hasOpenPreview(reclaim),
            hasUnreadMoves: !reclaim.lastMoves.isEmpty
        ) else { return }
        analyze()
    }

    // MARK: - Suggestions (Disk Pressure Advisor)

    private func suggestionsSection(_ models: [LibraryModel]) -> some View {
        let state = ReclaimSuggestionsState(
            opportunityCount: reclaim.opportunities.count,
            candidateCount: reclaim.sourceCandidates.count,
            lastMoveCount: reclaim.lastMoves.count,
            cacheAvailable: reclaim.doctorScan != nil,
            cacheFindingCount: reclaim.cacheFindings.count
        )
        let selection = effectiveSelection
        let primary = ReclaimProminence.primary(
            hasPlan: reclaim.plan != nil,
            hasSelection: !selection.isEmpty,
            hasPrunePreview: reclaim.cachePruneHash != nil
        )
        return WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                suggestionsHeader(state)
                Text("Review replacements by task. Preview GGUF files or local MLX folders before quarantining them, then use Trash when you are ready to remove them.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if state.showsEmpty {
                    ReclaimDesignedState(symbol: "checkmark.circle", text: "No reclaim opportunities from the latest snapshot.")
                }
                ForEach(ReclaimSuggestionGroup.groups(reclaim.opportunities)) { group in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text(group.kind.title)
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.muted)
                        ForEach(group.opportunities) { opportunity in
                            if let chain = opportunity.replacement {
                                ModelReplacementChainCard(chain: chain, onReviewFolder: { path in Task { await reclaim.previewFolder(path) } })
                            } else {
                                ReclaimSuggestionRowView(
                                    row: ReclaimSuggestionRow(opportunity, models: models),
                                    isCompact: layout.compactSuggestions,
                                    isSelected: opportunityBinding(opportunity.id)
                                )
                            }
                        }
                    }
                }
                SourceCleanupSection(reclaim: reclaim, modelWorkflow: appHost.modelWorkflow, models: models, layout: layout, rescan: { appHost.requestRescan() })
                if !reclaim.cacheFindings.isEmpty { cacheFindingsView(models, primary: primary) }
                if !reclaim.opportunities.isEmpty { actionBar(primary: primary, selection: selection) }
                if state.showsMoveResults { moveResults }
                if let note = reclaim.cachePruneNote {
                    Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.accent)
                }
            }
        }
    }

    private func suggestionsHeader(_ state: ReclaimSuggestionsState) -> some View {
        Group {
            if layout.wrapsHeader {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    SectionTitle(text: "Suggestions")
                    ReclaimFlowLayout() { suggestionControls(state) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                    SectionTitle(text: "Suggestions")
                    Spacer()
                    ReclaimFlowLayout() { suggestionControls(state) }
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionControls(_ state: ReclaimSuggestionsState) -> some View {
        Button("Analyze") { analyze() }
            .buttonStyle(.bordered)
        Button("Review model folder…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Review folder"
            panel.message = "Choose a local MLX model folder inside your configured scan roots. Shared Hugging Face cache snapshots are protected."
            panel.begin { response in
                guard response == .OK, let path = panel.url?.path else { return }
                Task { await reclaim.previewFolder(path) }
            }
        }
        .buttonStyle(.borderless)
        .disabled(reclaim.isApplying)
        if state.showsCacheControls {
            Button("Check HF cache") { Task { await reclaim.checkCache() } }
                .buttonStyle(.borderless)
        }
    }

    private func actionBar(primary: ReclaimAction?, selection: Set<String>) -> some View {
        Group {
            if layout.compactSuggestions {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    planSummary
                    HStack(spacing: WorkbenchSpacing.xs) { reclaimActions(primary: primary, selection: selection) }
                }
            } else {
                HStack(spacing: WorkbenchSpacing.xs) {
                    planSummary
                    Spacer()
                    reclaimActions(primary: primary, selection: selection)
                }
            }
        }
    }

    @ViewBuilder
    private var planSummary: some View {
        if let plan = reclaim.plan {
            Text("Quarantine \(plan.items.count) file(s) · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                .font(WorkbenchTypography.tabular)
        }
    }

    @ViewBuilder
    private func reclaimActions(primary: ReclaimAction?, selection: Set<String>) -> some View {
        Button("Preview reclaim") { reclaim.preview(selected: selection) }
            .reclaimButtonStyle(.previewReclaim, primary: primary)
            .disabled(selection.isEmpty)
        if let plan = reclaim.plan {
            Button("Confirm quarantine") {
                reclaim.confirm(previewHash: plan.previewHash)
                selectedOpportunities = []
            }
            .reclaimButtonStyle(.confirmQuarantine, primary: primary)
            .disabled(reclaim.isApplying)
        }
    }

    private var moveResults: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            ForEach(reclaim.lastMoves, id: \.path) { move in
                if let destination = move.destination {
                    Text("Moved \(URL(fileURLWithPath: move.path).lastPathComponent) → \(destination)")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
                } else {
                    Text("\(URL(fileURLWithPath: move.path).lastPathComponent): \(move.error ?? "failed")")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
                }
            }
        }
    }

    private func opportunityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedOpportunities.contains(id) },
            set: { isOn in
                if isOn { selectedOpportunities.insert(id) } else { selectedOpportunities.remove(id) }
            }
        )
    }

    // MARK: - HF-cache prune (authoritative doctor flow)

    private func cacheFindingsView(_ models: [LibraryModel], primary: ReclaimAction?) -> some View {
        let summary = ReclaimCacheSummary(findings: reclaim.cacheFindings)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Incomplete Hugging Face cache items")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.sm) { cacheSummaryText(summary); Spacer(); pruneButton(primary: primary) }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { cacheSummaryText(summary); pruneButton(primary: primary) }
            }
            DisclosureGroup("Incomplete cache items (\(summary.count))") {
                ForEach(reclaim.cacheFindings) { finding in
                    let name = ReclaimNames.resolve(paths: [finding.path], models: models)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        HStack {
                            Text(name.title).font(WorkbenchTypography.label).help(name.detail ?? finding.path)
                            Spacer()
                            Text(finding.size.map { ReclaimFormat.byteCount($0) } ?? "size not recorded")
                                .font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.muted)
                        }
                        Text(finding.path).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(finding.path)
                    }.padding(.vertical, WorkbenchSpacing.xxxs)
                }
            }.font(WorkbenchTypography.secondary)
        }
    }

    private func cacheSummaryText(_ summary: ReclaimCacheSummary) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(summary.text).font(WorkbenchTypography.secondaryTabular)
            Text("Removes permanently").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
    }

    @ViewBuilder
    private func pruneButton(primary: ReclaimAction?) -> some View {
        if reclaim.cachePruneHash == nil {
            Button("Preview prune") { Task { await reclaim.previewCachePrune() } }
                .buttonStyle(.bordered)
        } else {
            Button("Confirm prune") { Task { await reclaim.confirmCachePrune() } }
                .reclaimButtonStyle(.confirmPrune, primary: primary)
        }
    }

    // MARK: - Quarantine ledger (review + put back)

    private func quarantinedSection(_ models: [LibraryModel]) -> some View {
        let total = reclaim.quarantined.count
        let visible = reclaim.quarantined.prefix(showAllQuarantined ? total : Self.recentQuarantineCount)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                SectionTitle(text: "Quarantine")
                Spacer()
                Text(ReclaimFormat.count(total, "file")).font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.muted)
            }
            Text("Put files back, or move them to macOS Trash after review. Quarantine keeps the files on disk; empty Trash in Finder to free space.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if reclaim.quarantined.isEmpty {
                ReclaimDesignedState(symbol: "tray", text: "Nothing is currently in quarantine.")
            } else {
                ForEach(visible, id: \.to) { record in
                    ReclaimQuarantineRowView(
                        row: ReclaimQuarantineRow(record, models: models),
                        isCompact: layout.compactQuarantine,
                        isBusy: reclaim.isApplying,
                        onPutBack: { Task { await reclaim.restore(record); if reclaim.lastError == nil { appHost.requestRescan() } } },
                        onTrash: { Task { await reclaim.previewTrash(record) } }
                    )
                }
                if total > Self.recentQuarantineCount {
                    Button(showAllQuarantined ? "Show recent files" : "Show all \(total) files") { showAllQuarantined.toggle() }
                }
            }
            if let note = reclaim.trashNote { Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
        }
    }

    // MARK: - Duplicate groups

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if appHost.isScanning {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if groups.isEmpty {
                SectionTitle(text: "Duplicate groups")
                if !appHost.isScanning {
                    ReclaimDesignedState(symbol: "square.on.square", text: "No duplicate groups found.")
                }
            } else {
                DisclosureGroup("Duplicate groups (\(groups.count))", isExpanded: $showsDuplicates) {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                        ForEach(groups) { group in groupRow(group) }
                    }.padding(.top, WorkbenchSpacing.xs)
                }.font(WorkbenchTypography.emphasis)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.modelKey ?? group.id).font(WorkbenchTypography.label)
                Spacer()
                if let reclaimable = group.reclaimableBytes {
                    Text("Reclaims \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))")
                        .font(WorkbenchTypography.secondaryTabular)
                }
            }
            ForEach(group.sources, id: \.self) { path in
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                    Image(systemName: "doc")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                    Text(path)
                        .font(WorkbenchTypography.compactValue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                    Spacer()
                    if group.keep == path {
                        Text("keep").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.accent)
                    }
                }
            }
            if let redundant = group.redundant, !redundant.isEmpty {
                Text("\(redundant.count) redundant")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }
}
