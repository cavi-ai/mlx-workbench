import SwiftUI
import AppKit

// MARK: - DuplicatesView
// Exact vs variant duplicate groups from convert scan; quarantine keepers.

struct DuplicatesView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var reclaim: ReclaimCoordinator

    @State private var selectedOpportunities: Set<String> = []
    @State private var showAllQuarantined = false

    init(appHost: AppHost) {
        self.appHost = appHost
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
    }

    /// Duplicate groups come from the authoritative library scan shared with
    /// Library and Reclaim — this view never runs its own scan.
    private var groups: [DuplicateGroup] {
        appHost.scanResult?.duplicates ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                SourceCleanupSection(reclaim: reclaim, modelWorkflow: appHost.modelWorkflow, rescan: { appHost.requestRescan() })
                reclaimSection
                quarantinedSection
                HStack(spacing: WorkbenchSpacing.xs) {
                    Button("Rescan library") { appHost.requestRescan() }
                        .disabled(appHost.isScanning)
                    Spacer()
                }
                if appHost.isScanning {
                    ProgressView("Scanning…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, WorkbenchSpacing.lg)
                }
                ErrorBanner(text: appHost.lastError)
                if groups.isEmpty && !appHost.isScanning {
                    Text("No duplicate groups found.")
                        .foregroundStyle(WorkbenchColor.muted)
                        .padding(.top, WorkbenchSpacing.sm)
                }
                ForEach(groups) { group in
                    groupCard(group)
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .onAppear {
            appHost.analyzeReclaim()
            reclaim.refreshQuarantined()
            if appHost.scanResult == nil, !appHost.isScanning {
                appHost.requestRescan()
            }
        }
        .sheet(isPresented: Binding(get: { reclaim.trashPlan != nil }, set: { if !$0 { reclaim.cancelTrash() } })) {
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
        .sheet(isPresented: Binding(get: { reclaim.folderPlan != nil }, set: { if !$0 { reclaim.cancelFolder() } })) {
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

    // MARK: - Reclaim (Disk Pressure Advisor)

    private var reclaimSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { reclaimHeader }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { reclaimHeader }
            }
            Text("Review replacements by task. Preview GGUF files or local MLX folders before quarantining them, then use Trash when you are ready to remove them.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            if reclaim.opportunities.isEmpty {
                Text("No reclaim opportunities from the latest snapshot.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                ForEach(reclaim.opportunities) { opportunity in
                    if let chain = opportunity.replacement {
                        ModelReplacementChainCard(chain: chain, onReviewFolder: { path in Task { await reclaim.previewFolder(path) } })
                    } else {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                        Toggle(isOn: opportunityBinding(opportunity.id)) {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                                HStack(spacing: WorkbenchSpacing.xxs) {
                                    Text(opportunity.kind.title).font(WorkbenchTypography.secondary).fontWeight(.medium)
                                    Text(ByteCountFormatter.string(fromByteCount: opportunity.bytes, countStyle: .file))
                                        .font(WorkbenchTypography.secondary)
                                        .foregroundStyle(WorkbenchColor.warning)
                                    if opportunity.confidence == .review {
                                        Text("review").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                                    }
                                    if !opportunity.actionable {
                                        Text("manual only").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                                    }
                                }
                                Text(opportunity.evidence)
                                    .font(WorkbenchTypography.secondary)
                                    .foregroundStyle(WorkbenchColor.muted)
                                ForEach(opportunity.paths, id: \.self) { path in
                                    Text(path)
                                        .font(WorkbenchTypography.value)
                                        .foregroundStyle(WorkbenchColor.muted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!opportunity.actionable)
                    }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { reclaimActions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { reclaimActions }
                }

                cachePruneSection

                if !reclaim.lastMoves.isEmpty {
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
            }
            ErrorBanner(text: reclaim.lastError)
        }
        .formSection {}
    }

    @ViewBuilder
    private var reclaimHeader: some View {
        SectionTitle(text: "Reclaim")
        if reclaim.totalReclaimableBytes > 0 {
            Text("\(ByteCountFormatter.string(fromByteCount: reclaim.totalReclaimableBytes, countStyle: .file)) available to quarantine")
                .font(WorkbenchTypography.value)
                .foregroundStyle(WorkbenchColor.warning)
        }
        Button("Analyze") { appHost.analyzeReclaim() }
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
        }.disabled(reclaim.isApplying)
    }

    @ViewBuilder
    private var reclaimActions: some View {
        if reclaim.plan == nil {
            Button("Preview reclaim") { reclaim.preview(selected: selectedOpportunities) }
                .buttonStyle(.borderedProminent)
                .disabled(selectedOpportunities.isEmpty)
        } else {
            Button("Preview reclaim") { reclaim.preview(selected: selectedOpportunities) }
                .buttonStyle(.bordered)
                .disabled(selectedOpportunities.isEmpty)
        }
        if let plan = reclaim.plan {
            Text("Quarantine \(plan.items.count) file(s) · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                .font(WorkbenchTypography.value)
            Button("Confirm quarantine") {
                reclaim.confirm(previewHash: plan.previewHash)
                selectedOpportunities = []
            }
            .buttonStyle(.borderedProminent)
            .disabled(reclaim.isApplying)
        }
    }

    @ViewBuilder
    private var cacheActions: some View {
        Button("Check HF cache") { Task { await reclaim.checkCache() } }
            .buttonStyle(.bordered)
        if !reclaim.cacheFindings.isEmpty {
            Text("\(reclaim.cacheFindings.count) incomplete cache item(s), \(ByteCountFormatter.string(fromByteCount: reclaim.cacheReclaimableBytes, countStyle: .file)) reclaimable")
                .font(WorkbenchTypography.value)
                .foregroundStyle(WorkbenchColor.warning)
            if reclaim.cachePruneHash == nil {
                Button("Preview prune") { Task { await reclaim.previewCachePrune() } }
            } else {
                Button("Confirm prune") { Task { await reclaim.confirmCachePrune() } }
                    .buttonStyle(.borderedProminent)
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

    // MARK: - Quarantine ledger (review + put back)

    private var quarantinedSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                SectionTitle(text: "Quarantine")
                Spacer()
                Text("\(reclaim.quarantined.count) \(reclaim.quarantined.count == 1 ? "file" : "files")").font(WorkbenchTypography.value).foregroundStyle(WorkbenchColor.muted)
            }
            Text("Put files back, or move them to macOS Trash after review. Quarantine keeps the files on disk; empty Trash in Finder to free space.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            if reclaim.quarantined.isEmpty {
                Text("Nothing is currently in quarantine.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                let visible = reclaim.quarantined.prefix(showAllQuarantined ? reclaim.quarantined.count : 8)
                ForEach(Array(visible.enumerated()), id: \.element.to) { _, record in
                    HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text(URL(fileURLWithPath: record.from).lastPathComponent)
                                .font(WorkbenchTypography.secondary)
                            Text(record.from)
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))
                            .font(WorkbenchTypography.value).foregroundStyle(WorkbenchColor.muted)
                        Button("Put back") { Task { await reclaim.restore(record); if reclaim.lastError == nil { appHost.requestRescan() } } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(reclaim.isApplying)
                        Button { Task { await reclaim.previewTrash(record) } } label: { Label("Move to Trash", systemImage: "trash") }
                            .buttonStyle(.bordered).controlSize(.small).disabled(reclaim.isApplying)
                    }
                    .padding(.vertical, WorkbenchSpacing.xxxs)
                }
                if reclaim.quarantined.count > 8 {
                    Button(showAllQuarantined ? "Show recent files" : "Show all \(reclaim.quarantined.count) files") { showAllQuarantined.toggle() }
                }
            }
            if let note = reclaim.trashNote { Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
            ErrorBanner(text: reclaim.lastError)
        }
        .formSection {}
    }

    // MARK: - HF-cache prune (authoritative doctor flow)

    @ViewBuilder
    private var cachePruneSection: some View {
        if reclaim.doctorScan != nil {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { cacheActions }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { cacheActions }
            }
            if let note = reclaim.cachePruneNote {
                Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.accent)
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                SectionTitle(text: group.modelKey ?? group.id)
                Spacer()
                if let reclaim = group.reclaimableBytes {
                    Text("Reclaims \(ByteCountFormatter.string(fromByteCount: reclaim, countStyle: .file))")
                .font(WorkbenchTypography.value)
                .foregroundStyle(WorkbenchColor.warning)
                }
            }
            ForEach(group.sources, id: \.self) { path in
                HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                    Image(systemName: "doc")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                    Text(path)
                        .font(WorkbenchTypography.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    if group.keep == path {
                        Text("keep").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.accent)
                    }
                }
            }
            if let redundant = group.redundant, !redundant.isEmpty {
                Text("\(redundant.count) redundant")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.warning)
            }
        }
        .formSection {}
    }
}
