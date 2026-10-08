import AppKit
import SwiftUI

struct SourceCleanupSection: View {
    @ObservedObject var reclaim: ReclaimCoordinator
    @ObservedObject var modelWorkflow: ModelWorkflowCoordinator
    var rescan: () -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var showAllHistory = false
    @State private var reviewedSourceID: UUID?

    private var eligible: [SourceCleanupCandidate] { reclaim.sourceCandidates.filter { $0.bytes != nil } }
    private var blocked: [SourceCleanupCandidate] { reclaim.sourceCandidates.filter { $0.bytes == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack { header; checkButton }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { header; checkButton }
            }
            Text("Keep the verified conversion. Review its originals before moving them to Trash.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if reclaim.isCheckingSources {
                ProgressView("Checking conversion receipts and shared files…").controlSize(.small)
            } else if !reclaim.sourcesChecked {
                Text("Check originals to find sources that can be removed safely.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else if eligible.isEmpty {
                Text("No eligible originals from your verified conversions.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            ForEach(eligible) { candidate in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.sm) { candidateLabel(candidate); Spacer(); previewButton(candidate) }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { candidateLabel(candidate); previewButton(candidate) }
                }.padding(.vertical, WorkbenchSpacing.xxs)
            }
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
            if !reclaim.sourceHistory.isEmpty {
                Divider()
                HStack {
                    Label("Cleanup history", systemImage: "clock.arrow.circlepath").font(WorkbenchTypography.emphasis)
                    Spacer()
                    Button("Refresh") { Task { await reclaim.refreshSourceHistory() } }.controlSize(.small)
                        .disabled(reclaim.isApplying || reclaim.isCheckingSources)
                }
                Text("Trash keeps files on disk until you empty it in Finder.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                ForEach(Array(reclaim.sourceHistory.prefix(showAllHistory ? reclaim.sourceHistory.count : 5))) { batch in
                    historyRow(batch)
                }
                if reclaim.sourceHistory.count > 5 {
                    Button(showAllHistory ? "Show recent cleanups" : "Show all \(reclaim.sourceHistory.count) cleanups") { showAllHistory.toggle() }
                        .font(WorkbenchTypography.secondary)
                }
            }
            if let note = reclaim.sourceCleanupNote {
                Label(note, systemImage: "checkmark.circle").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
            }
            ErrorBanner(text: reclaim.sourceHistoryError)
            ErrorBanner(text: reclaim.lastError)
        }
        .formSection {}
        .task { await reclaim.refreshSourceHistory() }
        .sheet(isPresented: Binding(get: { isRouteActive && reviewedSourceID != nil && reclaim.sourcePlan?.workflow.id == reviewedSourceID }, set: { if !$0 {
            let reviewed = reviewedSourceID
            reviewedSourceID = nil
            if reclaim.sourcePlan?.workflow.id == reviewed { reclaim.cancelSource() }
        } })) { cleanupPreview }
        .sheet(isPresented: Binding(get: { isRouteActive && reclaim.sourceRestorePlan != nil }, set: { if !$0 { reclaim.cancelSourceRestore() } })) { restorePreview }
    }

    private var header: some View {
        CardHeader("Original sources", systemImage: "externaldrive.badge.checkmark")
    }

    private var checkButton: some View {
        Button("Check originals") { Task { await reclaim.checkSources(workflows: modelWorkflow.history) } }
            .buttonStyle(.bordered).disabled(reclaim.isCheckingSources || reclaim.isApplying)
    }

    private func candidateLabel(_ candidate: SourceCleanupCandidate) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(candidate.title).font(WorkbenchTypography.emphasis).lineLimit(2)
            Text("\(LibraryTablePresentation.byteCount(candidate.bytes ?? 0)) to Trash")
                .font(WorkbenchTypography.value).foregroundStyle(WorkbenchColor.warning)
        }
    }

    private func previewButton(_ candidate: SourceCleanupCandidate) -> some View {
        Button("Review originals") { Task {
            guard let current = modelWorkflow.history.first(where: { $0.id == candidate.id }) else { return }
            await reclaim.previewSource(current)
            if reclaim.sourcePlan?.workflow.id == current.id { reviewedSourceID = current.id }
        } }.buttonStyle(.bordered).controlSize(.small).disabled(reclaim.isApplying || reclaim.isCheckingSources)
    }

    private func historyRow(_ batch: SourceCleanupBatch) -> some View {
        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack { historyLabel(batch); Spacer(); historyActions(batch) }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { historyLabel(batch); historyActions(batch) }
                }
                DisclosureGroup("\(batch.items.count) source \(batch.items.count == 1 ? "item" : "items")") {
                    ForEach(batch.items) { item in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            HStack {
                                Text(URL(fileURLWithPath: item.record.from).lastPathComponent).font(WorkbenchTypography.label)
                                Spacer()
                                Text(item.state.rawValue).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            }
                            Text(item.record.from).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                                .lineLimit(2).textSelection(.enabled)
                        }.padding(.vertical, WorkbenchSpacing.xxxs)
                    }
                }.font(WorkbenchTypography.secondary)
            }
        }
    }

    private func historyLabel(_ batch: SourceCleanupBatch) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(batch.title).font(WorkbenchTypography.label).lineLimit(2)
            HStack {
                if let date = batch.movedAt { Text(date, format: .dateTime.month().day().hour().minute()) }
                else { Text("Earlier cleanup · date not recorded") }
                if let bytes = batch.bytes { Text("· \(LibraryTablePresentation.byteCount(bytes)) moved") }
            }.font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }
    }

    private func historyActions(_ batch: SourceCleanupBatch) -> some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            if batch.items.contains(where: \.canReveal) {
                Button("Reveal in Trash") { Task {
                    await reclaim.refreshSourceHistory()
                    let ids = Set(batch.items.map(\.id))
                    let paths = reclaim.sourceHistory.flatMap(\.items).filter { ids.contains($0.id) && $0.canReveal }.compactMap { $0.record.to }
                    if !paths.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
                } }
            }
            if !batch.restorableIDs.isEmpty {
                Button("Review restore") { Task { await reclaim.previewSourceRestore(ids: batch.restorableIDs) } }
            }
        }.buttonStyle(.bordered).controlSize(.small).disabled(reclaim.isApplying || reclaim.isCheckingSources)
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
