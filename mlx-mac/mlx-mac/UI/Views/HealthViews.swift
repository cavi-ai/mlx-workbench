import AppKit
import SwiftUI

// MARK: - Tone

extension HealthTone {
    var color: Color {
        switch self {
        case .positive: return WorkbenchColor.success
        case .negative: return WorkbenchColor.failure
        case .pending: return WorkbenchColor.muted
        case .caution: return WorkbenchColor.warning
        }
    }
}

extension View {
    /// The one prominent control of a region gets the filled style; the others are bordered.
    @ViewBuilder
    func healthProminence(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.workbenchPrimary)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - Connector

/// Straight segments in the fork container's coordinates.
struct HealthConnector: Shape {
    let segments: [HealthConnectorSegment]

    func path(in rect: CGRect) -> SwiftUI.Path {
        var path = SwiftUI.Path()
        for segment in segments {
            path.move(to: segment.from)
            path.addLine(to: segment.to)
        }
        return path
    }
}

enum HealthAnchor: Hashable {
    case icon(HealthLinkID)
    /// The gap between the two columns (one row) or the two rows (two rows).
    case slot
}

struct HealthAnchorKey: PreferenceKey {
    static var defaultValue: [HealthAnchor: Anchor<CGRect>] = [:]

    static func reduce(value: inout [HealthAnchor: Anchor<CGRect>], nextValue: () -> [HealthAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The fork's lines, drawn behind the links from the measured icon bounds.
private struct HealthConnectorLayer: View {
    let mode: HealthLayout.ForkMode
    let links: [HealthLink]
    let anchors: [HealthAnchor: Anchor<CGRect>]
    let proxy: GeometryProxy

    var body: some View {
        let icons = Dictionary(uniqueKeysWithValues: links.compactMap { link in
            anchors[.icon(link.id)].map { (link.id, proxy[$0]) }
        })
        let segments = HealthConnectorPlan.segments(
            mode: mode, links: links, icons: icons, slot: anchors[.slot].map { proxy[$0] }
        )
        ZStack {
            HealthConnector(segments: segments.filter { !$0.isLive })
                .stroke(
                    WorkbenchColor.muted,
                    style: StrokeStyle(lineWidth: WorkbenchSize.stageTrack, dash: [WorkbenchSpacing.xxxs, WorkbenchSpacing.xxxs])
                )
            HealthConnector(segments: segments.filter(\.isLive))
                .stroke(WorkbenchColor.accent, style: StrokeStyle(lineWidth: WorkbenchSize.stageTrack))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Link

struct HealthLinkView: View {
    let link: HealthLink
    let isRouteActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSize.Health.linkSymbolGap) {
            Image(systemName: link.symbol)
                .font(WorkbenchTypography.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(link.tone.color)
                .contentTransition(isRouteActive ? .symbolEffect(.replace) : .identity)
                .workbenchAnimation(value: link.symbol)
                .frame(width: WorkbenchSize.Health.symbolColumn)
                .anchorPreference(key: HealthAnchorKey.self, value: .bounds) { [.icon(link.id): $0] }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(link.title)
                    .font(WorkbenchTypography.emphasis)
                Text(link.stateWord)
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(link.tone.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let detail = link.detail {
                    if link.detailIsPath {
                        Text(detail)
                            .font(WorkbenchTypography.compactValue)
                            .foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(detail)
                    } else {
                        Text(detail)
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if !link.parts.isEmpty {
                    ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xxs) {
                        ForEach(link.parts) { part in
                            HealthPartChip(part: part)
                        }
                    }
                    .padding(.top, WorkbenchSpacing.xxs)
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: WorkbenchSize.Health.linkMinimum, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct HealthPartChip: View {
    let part: HealthPart

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xxs) {
            Image(systemName: part.isPresent ? "checkmark.circle.fill" : "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(part.isPresent ? WorkbenchColor.success : WorkbenchColor.failure)
                .frame(width: WorkbenchSize.Health.partGlyph)
            Text(part.name)
                .font(WorkbenchTypography.metadata)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(part.name), \(part.isPresent ? "present" : "missing")")
    }
}

// MARK: - Hero

/// The readiness hero: verdict, the fork of four links, the environment evidence and the resolving controls.
struct HealthHeroView: View {
    let chain: HealthChain
    let fingerprint: EnvironmentFingerprint
    let forkMode: HealthLayout.ForkMode
    let isRouteActive: Bool
    let installCommand: String
    @ObservedObject var installer: RuntimeInstaller
    @ObservedObject var verification: VerificationCoordinator
    let onRuntimeInstalled: () -> Void
    let onOpenSettings: () -> Void
    let onReviewOnOverview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                Image(systemName: chain.verdict.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(chain.verdict.isReady ? WorkbenchColor.success : WorkbenchColor.warning)
                    .contentTransition(isRouteActive ? .symbolEffect(.replace) : .identity)
                    .workbenchAnimation(value: chain.verdict.symbol)
                    .accessibilityHidden(true)
                Text(chain.verdict.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(WorkbenchTypography.display)
            .lineLimit(2)
            fork
            HealthEvidenceStrip(
                fingerprint: fingerprint, verification: verification, onReview: onReviewOnOverview
            )
            actions
        }
    }

    // MARK: Fork

    @ViewBuilder
    private var fork: some View {
        let layout = forkLayout
        layout
            .backgroundPreferenceValue(HealthAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    HealthConnectorLayer(mode: forkMode, links: chain.links, anchors: anchors, proxy: proxy)
                }
            }
    }

    @ViewBuilder
    private var forkLayout: some View {
        switch forkMode {
        case .oneRow:
            HStack(alignment: .top, spacing: WorkbenchSize.Health.forkGap) {
                column(chain.foundation)
                Color.clear
                    .frame(width: WorkbenchSize.Health.connectorWidth)
                    .anchorPreference(key: HealthAnchorKey.self, value: .bounds) { [.slot: $0] }
                column(chain.capabilities)
            }
        case .twoRow:
            VStack(alignment: .leading, spacing: 0) {
                pair(chain.foundation)
                Color.clear
                    .frame(height: WorkbenchSpacing.lg)
                    .anchorPreference(key: HealthAnchorKey.self, value: .bounds) { [.slot: $0] }
                pair(chain.capabilities)
            }
        case .stacked:
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                ForEach(chain.links) { link in
                    HealthLinkView(link: link, isRouteActive: isRouteActive)
                        .padding(.leading, link.id == .prepare || link.id == .run ? stackedIndent : 0)
                }
            }
        }
    }

    /// The capabilities sit one level under the foundations in the stacked tree.
    private var stackedIndent: CGFloat { WorkbenchSize.Health.symbolColumn + WorkbenchSize.Health.linkSymbolGap }

    private func column(_ links: [HealthLink]) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            ForEach(links) { HealthLinkView(link: $0, isRouteActive: isRouteActive) }
        }
    }

    private func pair(_ links: [HealthLink]) -> some View {
        HStack(alignment: .top, spacing: WorkbenchSize.Health.forkGap) {
            ForEach(links) { HealthLinkView(link: $0, isRouteActive: isRouteActive) }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if chain.actions.showsInstallCommand {
            Text(installCommand)
                .font(WorkbenchTypography.value)
                .foregroundStyle(WorkbenchColor.warning)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if chain.actions.showsInstall {
            RuntimeInstallView(installer: installer, onFinished: onRuntimeInstalled)
        } else if installer.state != .idle {
            RuntimeInstallStatusView(installer: installer)
        }
        if chain.actions.showsInstallCommand || chain.actions.showsOpenSettings {
            ReclaimFlowLayout {
                if chain.actions.showsInstallCommand {
                    Button("Copy command") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(installCommand, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if chain.actions.showsOpenSettings {
                    Button("Open Settings", action: onOpenSettings)
                        .healthProminence(chain.actions.openSettingsIsProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// The base probe does not inspect isolated model runtimes.
struct HealthRuntimeScopeView: View {
    @ObservedObject var backends: HealthBackendSession
    @ObservedObject var intake: IntakeCoordinator
    let source: String
    let onRefresh: () -> Void
    let onAddModel: () -> Void
    let onOpenRun: () -> Void
    @Environment(\.isRouteActive) private var isRouteActive

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Model-specific runtimes")
                Text("The checks above cover the base conversion tools and mlx-lm server. The optional MLX backends below use separate environments. Installed is an installation record, not proof that a model can run.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(backends.isRefreshing ? "Refreshing backends…" : "Refresh backends", action: onRefresh)
                        .buttonStyle(.bordered).disabled(backends.isRefreshing)
                    if backends.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let checkedAt = backends.checkedAt {
                    Text("Checked " + checkedAt.formatted(date: .abbreviated, time: .standard))
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if backends.isStale {
                    Text(backends.isRefreshing ? "Previous result while refreshing." : "Last available result; the latest refresh failed.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                        .accessibilityIdentifier("health-backends-stale")
                }
                ErrorBanner(text: backends.error)
                if backends.snapshot == nil, !backends.isRefreshing, backends.error == nil {
                    Text("Optional backend installations have not been checked.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                if backends.snapshot != nil, backends.rows.isEmpty {
                    Text("No optional MLX backends were reported.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                ForEach(backends.rows) { row in
                    Divider()
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.id).font(WorkbenchTypography.emphasis).textSelection(.enabled)
                            Spacer(minLength: WorkbenchSpacing.xs)
                            Text(row.status).font(WorkbenchTypography.secondary)
                                .foregroundStyle(backends.isStale ? WorkbenchColor.muted : row.tone.color)
                                .fixedSize()
                                .accessibilityIdentifier("health-backend-" + row.id + "-status")
                        }
                        Text("Target version: " + row.version).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        if !row.tasks.isEmpty {
                            Text(row.tasks).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("For a missing backend, choose a model in Add from Hugging Face to review its installation. Strata is separate from this list. For serving-capable models, Run checks the selected runtime before confirmation.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.sm) { actions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { actions }
                }
            }
        }
        .task(id: isRouteActive ? source : nil) {
            if isRouteActive { await backends.refresh(source: source) }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Add from Hugging Face…", action: onAddModel).buttonStyle(.bordered).disabled(intake.isBusy)
            .help(intake.isBusy ? "An intake is in progress" : "Choose a model and review its required backend before installing")
        Button("Open Run", action: onOpenRun).buttonStyle(.bordered)
    }
}

// MARK: - Evidence

/// The environment fingerprint and how many verified models were verified under it.
struct HealthEvidenceStrip: View {
    let fingerprint: EnvironmentFingerprint
    @ObservedObject var verification: VerificationCoordinator
    let onReview: () -> Void

    var body: some View {
        let evidence = EnvironmentEvidence.make(reports: verification.reports, fingerprint: fingerprint)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(evidence.parts)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            switch evidence.status {
            case .pending:
                caption(EnvironmentEvidence.pendingText)
            case .noVerifiedModels:
                caption(EnvironmentEvidence.emptyText)
            case .counted(let current, let earlier, _):
                ReclaimFlowLayout(spacing: WorkbenchSpacing.lg, lineSpacing: WorkbenchSpacing.xs) {
                    if let text = evidence.currentText {
                        count(current, text, color: WorkbenchColor.ink)
                    }
                    if let text = evidence.earlierText {
                        count(earlier, text, color: WorkbenchColor.muted)
                        Button(EnvironmentEvidence.reviewTitle, action: onReview)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                .help(evidence.unrecordedHelp ?? "")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.muted)
    }

    private func count(_ value: Int, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Text("\(value)")
                .font(WorkbenchTypography.hero)
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .workbenchAnimation(value: value)
            Text(text)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Findings

struct HealthFindingGroupView: View {
    let group: HealthFindingGroup
    let isCompact: Bool
    let wrapsHeader: Bool
    let onOpenReclaim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                Image(systemName: group.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WorkbenchColor.warning)
                    .frame(width: WorkbenchSize.Health.findingSymbol)
                    .accessibilityHidden(true)
                Text(group.heading)
                    .font(WorkbenchTypography.label)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                ForEach(group.rows) { row in
                    HealthFindingRowView(row: row, isCompact: isCompact)
                }
                if let line = group.prunableLine { prunable(line) }
            }
            .padding(.leading, WorkbenchSize.Health.findingSymbol + WorkbenchSpacing.sm)
        }
    }

    @ViewBuilder
    private func prunable(_ line: String) -> some View {
        let text = Text(line)
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.warning)
            .fixedSize(horizontal: false, vertical: true)
        let button = Button("Open Reclaim", action: onOpenReclaim)
            .buttonStyle(.bordered)
            .controlSize(.small)
        if wrapsHeader {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { text; button }
        } else {
            HStack(spacing: WorkbenchSpacing.sm) { text; Spacer(minLength: WorkbenchSpacing.sm); button }
        }
    }
}

private struct HealthFindingRowView: View {
    let row: HealthFindingRow
    let isCompact: Bool

    private var remediationLine: String? {
        let parts = [row.remediation, isCompact ? row.size : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(row.title)
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let detail = row.detail {
                    Text(detail)
                        .font(WorkbenchTypography.compactValue)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(detail)
                }
                if let line = remediationLine {
                    Text(line)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: isCompact ? nil : WorkbenchSize.Health.findingNameMinimum, maxWidth: .infinity, alignment: .leading)
            if !isCompact, let size = row.size {
                Text(size)
                    .font(WorkbenchTypography.tabular)
                    .frame(width: WorkbenchSize.Health.findingSizeColumn, alignment: .trailing)
            }
        }
    }
}
