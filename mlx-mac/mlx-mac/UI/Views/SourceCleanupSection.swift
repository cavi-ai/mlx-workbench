import AppKit
import SwiftUI

/// Original sources after verification: the eligible candidates, what is not eligible, and the two
/// source sheets. It renders inside the suggestions surface and loads the cleanup history at page mount.
struct SourceCleanupSection: View {
    @ObservedObject var reclaim: ReclaimCoordinator
    @ObservedObject var modelWorkflow: ModelWorkflowCoordinator
    var models: [LibraryModel] = []
    var layout = ReclaimLayout()
    var rescan: () -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var reviewedSourceID: UUID?

    private var eligible: [SourceCleanupCandidate] { reclaim.sourceCandidates.filter { $0.bytes != nil } }
    private var blocked: [SourceCleanupCandidate] { reclaim.sourceCandidates.filter { $0.bytes == nil } }

    private var originalsState: ReclaimOriginalsState {
        ReclaimOriginalsState(isChecking: reclaim.isCheckingSources, isChecked: reclaim.sourcesChecked, eligibleCount: eligible.count)
    }

    private var checkOriginalsButton: some View {
        Button("Check originals") { Task { await reclaim.checkSources(workflows: modelWorkflow.history) } }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(reclaim.isCheckingSources || reclaim.isApplying)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Original sources after verification")
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(WorkbenchColor.muted)
                Spacer()
                if originalsState == .none || originalsState == .listed { checkOriginalsButton }
            }
            switch originalsState {
            case .checking:
                ProgressView("Checking conversion receipts and shared files…").controlSize(.small)
            case .unchecked:
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                    ReclaimDesignedState(symbol: "externaldrive", text: ReclaimOriginalsState.uncheckedText)
                    Spacer()
                    checkOriginalsButton
                }
            case .none:
                Text("No eligible originals from your verified conversions.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            case .listed:
                EmptyView()
            }
            ForEach(eligible) { candidate in candidateRow(candidate) }
            if !blocked.isEmpty {
                DisclosureGroup("Not eligible (\(blocked.count))") {
                    ForEach(blocked) { candidate in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text(candidate.title).font(WorkbenchTypography.label)
                            Text(candidate.reason ?? "Review this source manually.")
                                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }.padding(.vertical, WorkbenchSpacing.xxs)
                    }
                }.font(WorkbenchTypography.secondary)
            }
            if let note = reclaim.sourceCleanupNote {
                Label(note, systemImage: "checkmark.circle").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
            }
        }
        .task { await reclaim.refreshSourceHistory() }
        .sheet(isPresented: Binding(
            get: { ReclaimSheets.showsMoveOriginals(planWorkflowID: reclaim.sourcePlan?.workflow.id, reviewedSourceID: reviewedSourceID, isRouteActive: isRouteActive) },
            set: { if !$0 {
                let reviewed = reviewedSourceID
                reviewedSourceID = nil
                if reclaim.sourcePlan?.workflow.id == reviewed { reclaim.cancelSource() }
            } }
        )) { cleanupPreview }
        .sheet(isPresented: Binding(
            get: { ReclaimSheets.showsRestoreOriginals(hasPlan: reclaim.sourceRestorePlan != nil, isRouteActive: isRouteActive) },
            set: { if !$0 { reclaim.cancelSourceRestore() } }
        )) { restorePreview }
    }

    private func candidateRow(_ candidate: SourceCleanupCandidate) -> some View {
        let name = ReclaimNames.resolve(paths: [candidate.workflow.completedModelPath ?? candidate.workflow.outputPath], models: models)
        let bytes = LibraryTablePresentation.byteCount(candidate.bytes ?? 0)
        return HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            Image(systemName: "externaldrive")
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Reclaim.symbolColumn)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(name.title).font(WorkbenchTypography.emphasis).lineLimit(2).truncationMode(.middle)
                    .help(name.detail ?? candidate.title)
                Text(layout.compactSuggestions ? "Original source · \(bytes) to Trash" : "Original source · moves to Trash after review")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(2)
                if layout.compactSuggestions { previewButton(candidate) }
            }
            .frame(minWidth: layout.compactSuggestions ? nil : WorkbenchSize.Reclaim.suggestionNameMinimum, maxWidth: .infinity, alignment: .leading)
            if !layout.compactSuggestions {
                Text(bytes).font(WorkbenchTypography.tabular)
                    .frame(width: WorkbenchSize.Reclaim.byteColumn, alignment: .trailing)
                previewButton(candidate)
            }
        }
        .padding(.vertical, WorkbenchSpacing.xxs)
    }

    private func previewButton(_ candidate: SourceCleanupCandidate) -> some View {
        Button("Review originals") { Task {
            guard let current = modelWorkflow.history.first(where: { $0.id == candidate.id }) else { return }
            await reclaim.previewSource(current)
            if reclaim.sourcePlan?.workflow.id == current.id { reviewedSourceID = current.id }
        } }.buttonStyle(.bordered).controlSize(.small).disabled(reclaim.isApplying || reclaim.isCheckingSources)
    }

    @ViewBuilder
    private var cleanupPreview: some View {
        if let plan = reclaim.sourcePlan {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Label("Move originals to Trash", systemImage: "trash").font(WorkbenchTypography.title)
                Text("\(plan.paths.count) items · \(LibraryTablePresentation.byteCount(plan.bytes))").font(WorkbenchTypography.value)
                Text("The verified conversion stays in place. Shared blobs are protected. Empty Trash in Finder to free space.").font(WorkbenchTypography.secondary)
                ScrollView { VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    ForEach(plan.paths, id: \.self) { Text($0).font(WorkbenchTypography.compactValue).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240)
                HStack {
                    Button("Cancel") { reclaim.cancelSource() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Move originals to Trash") { Task {
                        guard let current = modelWorkflow.history.first(where: { $0.id == plan.workflow.id }) else {
                            reclaim.cancelSource(); return
                        }
                        await reclaim.confirmSource(current)
                        rescan()
                    } }.buttonStyle(.borderedProminent)
                }.disabled(reclaim.isApplying)
            }.padding(WorkbenchSpacing.lg).frame(width: 540).interactiveDismissDisabled(reclaim.isApplying)
        }
    }

    @ViewBuilder
    private var restorePreview: some View {
        if let plan = reclaim.sourceRestorePlan {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Label("Restore original sources", systemImage: "arrow.uturn.backward").font(WorkbenchTypography.title)
                Text("\(plan.items.count) items · \(LibraryTablePresentation.byteCount(plan.bytes))").font(WorkbenchTypography.value)
                Text("Restore these items to their original locations. Existing files will never be overwritten.").font(WorkbenchTypography.secondary)
                if plan.includesLegacyRecords {
                    Text("Earlier entries did not record file identity. This preview describes what is currently in Trash.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                }
                ScrollView { VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach(plan.items, id: \.record.id) { item in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text("From: \(item.record.to ?? "")")
                            Text("To: \(item.record.from)")
                        }.font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240)
                HStack {
                    Button("Cancel") { reclaim.cancelSourceRestore() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Restore originals") { Task { await reclaim.confirmSourceRestore(); rescan() } }
                        .buttonStyle(.borderedProminent)
                }.disabled(reclaim.isApplying)
            }.padding(WorkbenchSpacing.lg).frame(width: 540).interactiveDismissDisabled(reclaim.isApplying)
        }
    }
}

/// Cleanup history: every batch the app moved to Trash, collapsed by default.
struct SourceHistorySection: View {
    @ObservedObject var reclaim: ReclaimCoordinator
    let models: [LibraryModel]
    let layout: ReclaimLayout
    @State private var isExpanded = false
    @State private var showAllHistory = false

    private static let recentCount = 5

    var body: some View {
        if reclaim.sourceHistory.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                SectionTitle(text: "Cleanup history")
                ReclaimDesignedState(symbol: "clock.arrow.circlepath", text: "No original sources have been moved to Trash yet.")
            }
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Text("Trash keeps files on disk until you empty it in Finder.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    ForEach(reclaim.sourceHistory.prefix(showAllHistory ? reclaim.sourceHistory.count : Self.recentCount).map { ReclaimHistoryRow($0, models: models) }) { row in
                        historyRow(row)
                    }
                    if reclaim.sourceHistory.count > Self.recentCount {
                        Button(showAllHistory ? "Show recent cleanups" : "Show all \(reclaim.sourceHistory.count) cleanups") { showAllHistory.toggle() }
                            .font(WorkbenchTypography.secondary)
                    }
                }.padding(.top, WorkbenchSpacing.xs)
            } label: {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Label("Cleanup history (\(reclaim.sourceHistory.count))", systemImage: "clock.arrow.circlepath")
                        .font(WorkbenchTypography.emphasis)
                    Spacer()
                    Button("Refresh") { Task { await reclaim.refreshSourceHistory() } }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(reclaim.isApplying || reclaim.isCheckingSources)
                }
            }
        }
    }

    private func historyRow(_ row: ReclaimHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if layout.compactHistory {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    title(row)
                    Text(row.subtitle).font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.muted)
                    HStack(spacing: WorkbenchSpacing.xs) { actions(row.batch) }
                }
            } else {
                HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        title(row)
                        if let context = row.context {
                            Text(context).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(2)
                        }
                    }
                    .frame(minWidth: WorkbenchSize.Reclaim.historyNameMinimum, maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: WorkbenchSpacing.xxxs) {
                        if let bytes = row.bytes { Text(bytes).font(WorkbenchTypography.tabular) }
                        Text(row.date).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(2)
                    }.frame(width: WorkbenchSize.Reclaim.historyBytesColumn, alignment: .trailing)
                    actions(row.batch)
                }
            }
            DisclosureGroup(row.itemsLabel) {
                ForEach(row.batch.items) { item in
                    let name = ReclaimNames.resolve(paths: [item.record.from], models: models)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        HStack {
                            Text(name.title).font(WorkbenchTypography.label).help(name.detail ?? item.record.from)
                            Spacer()
                            Text(item.state.rawValue).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                        Text(item.record.from).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(item.record.from)
                    }.padding(.vertical, WorkbenchSpacing.xxxs)
                }
            }.font(WorkbenchTypography.secondary)
        }
        .padding(.leading, WorkbenchSize.Reclaim.historyIndent)
    }

    private func title(_ row: ReclaimHistoryRow) -> some View {
        Text(row.name.title)
            .font(WorkbenchTypography.label)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(row.name.detail ?? row.batch.title)
    }

    @ViewBuilder
    private func actions(_ batch: SourceCleanupBatch) -> some View {
        if batch.items.contains(where: \.canReveal) {
            Button("Reveal in Trash") { Task {
                await reclaim.refreshSourceHistory()
                let ids = Set(batch.items.map(\.id))
                let paths = reclaim.sourceHistory.flatMap(\.items).filter { ids.contains($0.id) && $0.canReveal }.compactMap { $0.record.to }
                if !paths.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
            } }
            .buttonStyle(.bordered).controlSize(.small).disabled(reclaim.isApplying || reclaim.isCheckingSources)
        }
        if !batch.restorableIDs.isEmpty {
            Button("Review restore") { Task { await reclaim.previewSourceRestore(ids: batch.restorableIDs) } }
                .buttonStyle(.bordered).controlSize(.small).disabled(reclaim.isApplying || reclaim.isCheckingSources)
        }
    }
}
