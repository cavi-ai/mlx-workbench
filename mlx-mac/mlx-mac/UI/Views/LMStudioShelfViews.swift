import AppKit
import SwiftUI

// MARK: - Actions

struct LMStudioShelfActions {
    let openSettings: () -> Void
    let prepare: (String) -> Void
    let run: (String) -> Void
    let showInLibrary: (String) -> Void
    let reveal: (String) -> Void
    let copyPath: (String) -> Void
}

// MARK: - Shelf

/// The legend, summary strip and lanes. The only LM Studio view that observes the memory
/// monitor, so a probe re-evaluates the shelf and not the page.
struct LMStudioShelf: View {
    @ObservedObject var resources: SystemResourceMonitor
    let resolution: LMStudioShelfResolver.Resolution?
    let snapshot: LibrarySnapshot?
    let index: LMStudioShelfIndex?
    let isScanning: Bool
    let lastError: String?
    let reserveGB: Double
    let hardware: HardwareProfile
    let layout: LMStudioLayout
    let home: URL
    let actions: LMStudioShelfActions

    @Environment(\.isRouteActive) private var isRouteActive

    private var presentation: LMStudioShelfPresentation {
        LMStudioShelfPresentation.make(
            resolution: resolution, snapshot: snapshot, index: index, isScanning: isScanning, lastError: lastError,
            memory: resources.memory, hasProbed: resources.hasProbed, contextTokens: resources.contextTokens,
            reserveGB: reserveGB, hardware: hardware
        )
    }

    var body: some View {
        let built = presentation
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            switch built.state {
            case .resolving, .scanning:
                DiscoverLegendView(legend: built.legend, wraps: layout.legendWraps)
                placeholderLane
            case .notFound:
                notice("questionmark.folder", LMStudioShelfState.notFoundSentence)
            case .folderMissing(let path):
                notice("externaldrive.badge.exclamationmark", LMStudioShelfState.folderMissingSentence(path: abbreviated(path)))
            case .libraryNotScanned:
                notice("tray", LMStudioShelfState.libraryNotScannedSentence)
            case .scanFailed(let error):
                FailureNotice(error: error, details: .whenDifferent)
            case .emptyFolder:
                notice("tray", LMStudioShelfState.emptyFolderSentence)
            case .folderNotice(let folderNotice):
                laneNotice(folderNotice)
            case .lanes(let lanes):
                DiscoverLegendView(legend: built.legend, wraps: layout.legendWraps)
                summary(built.summary)
                ForEach(lanes) { lane in
                    laneView(lane)
                }
            }
        }
    }

    private func abbreviated(_ path: String) -> String { LMStudioFolderLine.abbreviated(path, home: home) }

    private func notice(_ symbol: String, _ sentence: String) -> some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(sentence)
                .font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(WorkbenchColor.muted)
    }

    private func summary(_ summary: LMStudioSummary) -> some View {
        ReclaimFlowLayout(spacing: WorkbenchSpacing.lg, lineSpacing: WorkbenchSpacing.xs) {
            ForEach(Array(summary.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text(item.figure)
                        .font(WorkbenchTypography.tabular)
                        .foregroundStyle(WorkbenchColor.ink)
                        .contentTransition(isRouteActive ? .numericText() : .identity)
                        .workbenchAnimation(value: snapshot?.generatedAt)
                    Text(item.label)
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func laneNotice(_ laneNotice: LMStudioLane.Notice) -> some View {
        switch laneNotice {
        case .configuredNotScanned:
            notice("arrow.triangle.2.circlepath", LMStudioShelfState.configuredNotScannedSentence)
        case .notConfigured(let path):
            notice("folder.badge.questionmark", LMStudioShelfState.notConfiguredSentence(path: abbreviated(path)))
            HStack(spacing: WorkbenchSpacing.xs) {
                Button("Open Settings", action: actions.openSettings).buttonStyle(.bordered)
                Button("Copy Path") { actions.copyPath(path) }.buttonStyle(.bordered)
            }
        }
    }

    private func laneView(_ lane: LMStudioLane) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(lane.title)
                .font(WorkbenchTypography.section)
                .foregroundStyle(WorkbenchColor.ink)
            if let laneNotice = lane.notice {
                self.laneNotice(laneNotice)
            } else {
                WorkbenchSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lane.rows) { row in
                            LMStudioRowView(row: row, tier: layout.rowTier, actions: actions)
                            if row.id != lane.rows.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                if let footer = lane.footer {
                    Text(footer)
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
        }
    }

    private var placeholderLane: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<WorkbenchSize.LMStudio.placeholderRows, id: \.self) { index in
                    LMStudioRowView(row: LMStudioRow.placeholder(index), tier: layout.rowTier, actions: nil)
                    if index < WorkbenchSize.LMStudio.placeholderRows - 1 {
                        Divider()
                    }
                }
            }
            .redacted(reason: .placeholder)
            .livePulse(isRouteActive)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Row

struct LMStudioRowView: View {
    let row: LMStudioRow
    let tier: LMStudioLayout.RowTier
    /// Nil for a placeholder row.
    let actions: LMStudioShelfActions?

    private var isWide: Bool { tier == .wide }

    var body: some View {
        Group {
            switch tier {
            case .wide:
                HStack(alignment: .top, spacing: WorkbenchSize.LMStudio.columnGap) {
                    verdictSymbol
                    nameColumn.frame(minWidth: WorkbenchSize.LMStudio.nameMinimum, maxWidth: .infinity, alignment: .leading)
                    fitColumn.frame(width: WorkbenchSize.LMStudio.fitColumn, alignment: .leading)
                    figures.frame(width: WorkbenchSize.LMStudio.figuresWidth, alignment: .leading)
                    actionButton.frame(width: WorkbenchSize.LMStudio.actionWidth, alignment: .trailing)
                }
            case .medium:
                HStack(alignment: .top, spacing: WorkbenchSize.LMStudio.columnGap) {
                    verdictSymbol
                    nameColumn.frame(minWidth: WorkbenchSize.LMStudio.nameMediumMinimum, maxWidth: .infinity, alignment: .leading)
                    fitColumn.frame(width: WorkbenchSize.LMStudio.fitColumn, alignment: .leading)
                    VStack(alignment: .trailing, spacing: WorkbenchSpacing.xs) {
                        figures
                        actionButton
                    }
                    .frame(width: max(WorkbenchSize.LMStudio.figuresWidth, WorkbenchSize.LMStudio.actionWidth), alignment: .trailing)
                }
            case .stacked:
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack(alignment: .top, spacing: WorkbenchSize.LMStudio.columnGap) {
                        verdictSymbol
                        nameColumn
                    }
                    fitColumn
                    HStack(alignment: .center, spacing: WorkbenchSize.LMStudio.columnGap) {
                        figures
                        Spacer(minLength: 0)
                        actionButton
                    }
                }
            }
        }
        .padding(.vertical, WorkbenchSpacing.sm)
        .contentShape(Rectangle())
        .contextMenu {
            if let actions {
                Button("Show in Library") { actions.showInLibrary(row.id) }
                Button("Reveal in Finder") { actions.reveal(row.id) }
                Button("Copy Path") { actions.copyPath(row.id) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.accessibilityHint)
        .accessibilityActions {
            if let title = row.action.title {
                Button(title, action: performAction)
            }
            Button(LMStudioRow.menuActionNames[0]) { actions?.showInLibrary(row.id) }
            Button(LMStudioRow.menuActionNames[1]) { actions?.reveal(row.id) }
            Button(LMStudioRow.menuActionNames[2]) { actions?.copyPath(row.id) }
        }
    }

    private func performAction() {
        switch row.action {
        case .prepare: actions?.prepare(row.id)
        case .run(let path): actions?.run(path)
        case .none: break
        }
    }

    private var symbolName: String {
        if row.isUnreadable { return "exclamationmark.triangle" }
        switch row.fit.tone {
        case .fits: return "checkmark.circle"
        case .tight: return "exclamationmark.circle"
        case .wontFit: return "xmark.circle"
        case .neutral: return "questionmark.circle"
        }
    }

    private var verdictSymbol: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(row.isUnreadable ? WorkbenchColor.failure : row.fit.tone.color)
            .frame(width: WorkbenchSize.LMStudio.symbolColumn)
            .accessibilityHidden(true)
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(row.repo)
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.ink)
                .lineLimit(2)
                .truncationMode(.middle)
            if let detail = row.detail, detail != row.repo {
                Text(detail)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if row.isUnreadable {
                Text(LMStudioRow.unreadableSentence)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.failure)
            }
            if !row.tags.isEmpty {
                ReclaimFlowLayout(spacing: WorkbenchSpacing.xxs, lineSpacing: WorkbenchSpacing.xxs) {
                    ForEach(row.tags, id: \.title) { tag in
                        Text(tag.title)
                            .font(WorkbenchTypography.metadata)
                            .foregroundStyle(WorkbenchColor.muted)
                            .padding(.horizontal, WorkbenchSpacing.xs)
                            .padding(.vertical, WorkbenchSpacing.xxxs)
                            .background(WorkbenchColor.well, in: Capsule())
                            .help(tag.help ?? "")
                    }
                }
            }
        }
    }

    private var wordColor: Color {
        switch row.fit.tone {
        case .tight, .wontFit: return row.fit.tone.color
        case .fits: return WorkbenchColor.ink
        case .neutral: return WorkbenchColor.muted
        }
    }

    @ViewBuilder
    private var fitColumn: some View {
        if !row.isUnreadable {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(row.fit.word)
                    .font(WorkbenchTypography.emphasis)
                    .foregroundStyle(wordColor)
                    .lineLimit(1)
                    .redacted(reason: row.fit.state == .redacted ? .placeholder : [])
                if row.fit.state == .estimated {
                    DiscoverFitBar(fill: row.fit.fill, tone: row.fit.tone)
                    if !isWide, let need = row.fit.needBytes {
                        Text("needs \(ModelBudgetPresentation.gb(need)) GB")
                            .font(WorkbenchTypography.secondaryTabular)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                }
            }
            .frame(width: isWide ? nil : WorkbenchSize.LMStudio.fitColumn, alignment: .leading)
            .help(row.fit.needBytes.map { "\(row.fit.help). Needs \(ModelBudgetPresentation.gb($0)) GB." } ?? row.fit.help)
        }
    }

    private var figures: some View {
        Text(row.figuresText)
            .font(WorkbenchTypography.secondaryTabular)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let title = row.action.title {
            Button(title, action: performAction)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(row.action == .prepare ? "Opens a conversion preview for this file" : "Opens Run with this model")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
