import SwiftUI

// MARK: - DuplicatesView
// Exact vs variant duplicate groups from convert scan; quarantine keepers.

struct DuplicatesView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var reclaim: ReclaimCoordinator

    @State private var selectedOpportunities: Set<String> = []

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
                reclaimSection
                quarantinedSection
                HStack(spacing: 10) {
                    Button("Rescan library") { appHost.requestRescan() }
                        .disabled(appHost.isScanning)
                    Spacer()
                }
                if appHost.isScanning {
                    ProgressView("Scanning…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ErrorBanner(text: appHost.lastError)
                if groups.isEmpty && !appHost.isScanning {
                    Text("No duplicate groups found.")
                        .foregroundStyle(WorkbenchColor.muted)
                        .padding(.top, 12)
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
    }

    // MARK: - Reclaim (Disk Pressure Advisor)

    private var reclaimSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { reclaimHeader }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { reclaimHeader }
            }
            Text("Ranked opportunities with evidence. Confirming moves `.gguf` files to quarantine — nothing is ever deleted.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            if reclaim.opportunities.isEmpty {
                Text("No reclaim opportunities from the latest snapshot.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                ForEach(reclaim.opportunities) { opportunity in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: opportunityBinding(opportunity.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
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

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { reclaimActions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { reclaimActions }
                }

                cachePruneSection

                if !reclaim.lastMoves.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
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
            Text("\(ByteCountFormatter.string(fromByteCount: reclaim.totalReclaimableBytes, countStyle: .file)) reclaimable")
                .font(WorkbenchTypography.value)
                .foregroundStyle(WorkbenchColor.warning)
        }
        Button("Analyze") { appHost.analyzeReclaim() }
            .buttonStyle(.bordered)
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
            Text("Move \(plan.items.count) file(s), reclaim \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
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
            SectionTitle(text: "Recently quarantined")
            Text("Everything this Mac has moved aside, newest first. Nothing is ever deleted — put a file back with one click if it was wanted.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            if reclaim.quarantined.isEmpty {
                Text("Nothing is currently in quarantine.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                let visible = reclaim.quarantined.prefix(8)
                ForEach(Array(visible.enumerated()), id: \.element.to) { _, record in
                    HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                        VStack(alignment: .leading, spacing: 2) {
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
                        Button("Put back") { reclaim.restore(record) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                if reclaim.quarantined.count > visible.count {
                    Text("Showing the \(visible.count) most recent of \(reclaim.quarantined.count) records.")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
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
        VStack(alignment: .leading, spacing: 8) {
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
                HStack(alignment: .top, spacing: 8) {
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
