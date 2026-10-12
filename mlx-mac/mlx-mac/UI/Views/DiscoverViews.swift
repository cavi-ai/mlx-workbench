import AppKit
import SwiftUI

// MARK: - Fit field

/// The candidate list: the budget legend and one row per candidate. The only Discover
/// view that observes the memory monitor, so a probe re-evaluates the rows and not the page.
struct DiscoverFitField: View {
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var intake: IntakeCoordinator
    let state: DiscoveryState
    /// Changes with every landed result, so bars fill again for new results only.
    let resultToken: Int
    let reserveGB: Double
    let hardware: HardwareProfile
    let library: LibrarySnapshot?
    let layout: DiscoverLayout
    /// Whether the running discovery was started in Fast mode.
    let fast: Bool
    let onClear: () -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.isRouteActive) private var isRouteActive

    private var status: DiscoverStatePresentation { DiscoverStatePresentation.make(state, fast: fast) }

    private var presentation: DiscoverPresentation {
        DiscoverPresentation.make(
            candidates: state.candidates,
            memory: resources.memory,
            hasProbed: resources.hasProbed,
            reserveGB: reserveGB,
            contextTokens: resources.contextTokens,
            hardware: hardware,
            library: library
        )
    }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            switch status.kind {
            case .idle, .empty:
                notice(status)
            case .failed:
                FailureNotice(error: status.sentence, details: .whenDifferent)
            case .running:
                notice(status)
                legend(presentation.legend)
                placeholderRows
            case .populated:
                let built = presentation
                resultsHeader(count: built.rows.count)
                legend(built.legend)
                rows(built.rows)
            }
        }
    }

    private func notice(_ status: DiscoverStatePresentation) -> some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            if status.kind == .running {
                // The placeholder rows carry the in-flight pulse; the symbol stays still.
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityLabel("Discovering models")
            } else {
                Image(systemName: status.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            Text(status.sentence)
                .font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(WorkbenchColor.muted)
    }

    private func resultsHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Candidates (\(count))")
                .font(WorkbenchTypography.section)
                .foregroundStyle(WorkbenchColor.ink)
            Spacer()
            Button("Clear", action: onClear)
                .buttonStyle(.bordered)
        }
    }

    private func legend(_ legend: DiscoverLegend) -> some View {
        DiscoverLegendView(legend: legend, wraps: layout.legendWraps)
    }

    /// The candidates are the page's one surface; the header, legend and catalog sit on the canvas.
    private func rows(_ rows: [DiscoverRow]) -> some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    DiscoverRowView(
                        row: row, isWide: layout.isWideRow, intakeIsBusy: intake.isBusy,
                        onAdd: { DiscoverIntakeAction.perform(repo: row.repo, intake: intake) { openWindow(id: IntakeWindow.id) } },
                        onCopy: { copy(row.repo) },
                        onOpen: { openOnHuggingFace(row.repo) }
                    )
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
        .id(resultToken)
    }

    private var placeholderRows: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<WorkbenchSize.Discover.placeholderRows, id: \.self) { index in
                    DiscoverRowView(
                        row: DiscoverRow.placeholder(index), isWide: layout.isWideRow, intakeIsBusy: true,
                        onAdd: {}, onCopy: {}, onOpen: {}
                    )
                    if index < WorkbenchSize.Discover.placeholderRows - 1 {
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

    private func copy(_ repo: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(repo, forType: .string)
    }

    private func openOnHuggingFace(_ repo: String) {
        if let url = URL(string: "https://huggingface.co/\(repo)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Legend

struct DiscoverLegendView: View {
    let legend: DiscoverLegend
    let wraps: Bool

    @Environment(\.isRouteActive) private var isRouteActive

    private var title: some View {
        Label(DiscoverLegend.title, systemImage: "memorychip")
            .font(WorkbenchTypography.metadata)
            .foregroundStyle(WorkbenchColor.muted)
            .symbolRenderingMode(.hierarchical)
    }

    private var lead: some View {
        Text(legend.lead ?? "\(ModelBudgetPresentation.placeholderLead) GB")
            .font(WorkbenchTypography.display)
            .foregroundStyle(WorkbenchColor.ink)
            .contentTransition(.numericText())
            .workbenchAnimation(WorkbenchMotion.standard, value: isRouteActive ? legend.lead : nil)
            .redacted(reason: legend.reading == .loading ? .placeholder : [])
    }

    private var caption: some View {
        Text(wraps ? legend.compactCaption : legend.caption)
            .font(WorkbenchTypography.metadata)
            .foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            title
            if wraps {
                if legend.reading != .unavailable { lead }
                caption
            } else {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                    if legend.reading != .unavailable { lead }
                    caption
                }
            }
        }
        .help(legend.help)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

struct DiscoverRowView: View {
    let row: DiscoverRow
    let isWide: Bool
    let intakeIsBusy: Bool
    let onAdd: () -> Void
    let onCopy: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Group {
            if isWide {
                HStack(alignment: .top, spacing: WorkbenchSize.Discover.columnGap) {
                    verdictSymbol
                    nameColumn.frame(minWidth: WorkbenchSize.Discover.nameMinimum, maxWidth: .infinity, alignment: .leading)
                    fitColumn.frame(width: WorkbenchSize.Discover.barWidth, alignment: .leading)
                    figures.frame(width: WorkbenchSize.Discover.figuresWidth, alignment: .leading)
                    addButton.frame(width: WorkbenchSize.Discover.actionWidth, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack(alignment: .top, spacing: WorkbenchSize.Discover.columnGap) {
                        verdictSymbol
                        nameColumn
                    }
                    fitColumn
                    HStack(alignment: .center, spacing: WorkbenchSize.Discover.columnGap) {
                        figures
                        Spacer(minLength: 0)
                        addButton
                    }
                }
            }
        }
        .padding(.vertical, WorkbenchSpacing.sm)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy repo id", action: onCopy)
            Button("Open on Hugging Face", action: onOpen)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAction(named: "Copy repo id", onCopy)
        .accessibilityAction(named: "Open on Hugging Face", onOpen)
    }

    private var verdictSymbol: some View {
        Image(systemName: row.fit.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(row.fit.tone.color)
            .frame(width: WorkbenchSize.Discover.symbolColumn)
            .accessibilityHidden(true)
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(row.repo)
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.ink)
                .lineLimit(2)
                .truncationMode(.middle)
            ReclaimFlowLayout(spacing: WorkbenchSpacing.xxs, lineSpacing: WorkbenchSpacing.xxs) {
                ForEach(row.roles, id: \.self) { role in
                    Text(role)
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                        .padding(.horizontal, WorkbenchSpacing.xs)
                        .padding(.vertical, WorkbenchSpacing.xxxs)
                        .background(WorkbenchColor.well, in: Capsule())
                }
                if row.isInLibrary {
                    Label("In Library", systemImage: "checkmark.circle.fill")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.ink)
                        .symbolRenderingMode(.hierarchical)
                }
                if let license = row.license {
                    Text("License \(license)")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
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

    private var fitColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(row.fit.word)
                .font(WorkbenchTypography.emphasis)
                .foregroundStyle(wordColor)
                .lineLimit(1)
                .redacted(reason: row.fit.state == .redacted ? .placeholder : [])
            if row.fit.showsTrack {
                DiscoverFitBar(fill: row.fit.fill, tone: row.fit.tone)
            }
            if let weights = row.fit.weightsText {
                Text(weights)
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if let note = row.fit.basisNote {
                Text(note)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(row.fit.help)
    }

    private var figures: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            if let downloads = row.downloadsText {
                Label(downloads, systemImage: "arrow.down.circle")
                    .accessibilityLabel("\(downloads) downloads")
            }
            if let likes = row.likesText {
                Label(likes, systemImage: "heart")
                    .accessibilityLabel("\(likes) likes")
            }
        }
        .font(WorkbenchTypography.secondaryTabular)
        .foregroundStyle(WorkbenchColor.muted)
        .lineLimit(1)
    }

    private var addButton: some View {
        Button(DiscoverIntakeAction.title, action: onAdd)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!DiscoverIntakeAction.isEnabled(intakeIsBusy: intakeIsBusy))
            .help(DiscoverIntakeAction.help(intakeIsBusy: intakeIsBusy))
    }
}

// MARK: - Bar

/// The candidate's share of the model budget. It fills once when its row first
/// appears on the active route; later probes move the fill without animating.
struct DiscoverFitBar: View {
    let fill: Double?
    let tone: ModelBudgetPresentation.Tone

    @Environment(\.isRouteActive) private var isRouteActive
    @State private var revealed = false

    var body: some View {
        Capsule()
            .fill(WorkbenchColor.well)
            .frame(height: WorkbenchSize.Discover.barHeight)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tone.color)
                        .frame(width: proxy.size.width * (revealed ? (fill ?? 0) : 0))
                }
            }
            .workbenchAnimation(WorkbenchMotion.standard, value: revealed && isRouteActive)
            .onAppear { revealed = true }
            .accessibilityHidden(true)
    }
}
