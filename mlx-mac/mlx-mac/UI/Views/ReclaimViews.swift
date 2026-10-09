import SwiftUI

// MARK: - Flow layout

/// Lays controls on one line and wraps the last ones first when the offered width runs out.
struct ReclaimFlowLayout: Layout {
    var spacing: CGFloat = WorkbenchSpacing.xs
    var lineSpacing: CGFloat = WorkbenchSpacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), frames)
    }
}

// MARK: - Prominence

extension View {
    /// The action the region marks prominent gets the filled style; every other action is bordered.
    @ViewBuilder
    func reclaimButtonStyle(_ action: ReclaimAction, primary: ReclaimAction?) -> some View {
        if action == primary {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - Designed state

struct ReclaimDesignedState: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(WorkbenchColor.muted)
        }
    }
}

// MARK: - Ledger

struct ReclaimLedgerView: View {
    let ledger: ReclaimLedger
    let isStacked: Bool

    var body: some View {
        if isStacked {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { tiles }
        } else {
            HStack(alignment: .top, spacing: WorkbenchSize.Reclaim.stageGap) { tiles }
        }
    }

    private func numeral(_ stage: ReclaimLedger.Stage) -> some View {
        Text(stage.numeral)
            .font(WorkbenchTypography.hero)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
            .workbenchAnimation(value: stage.changeKey)
    }

    private func muted(_ text: String, lines: Int = 2) -> some View {
        Text(text)
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(lines)
    }

    /// The Ready stage also carries the snapshot age and the originals line.
    private func extra(_ stage: ReclaimLedger.Stage) -> String? {
        guard stage.id == .ready else { return nil }
        return [stage.asOf, ledger.originalsLine].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var tiles: some View {
        ForEach(ledger.stages) { stage in
            Group {
                if isStacked {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                            Text(stage.title)
                                .font(WorkbenchTypography.label)
                                .foregroundStyle(WorkbenchColor.muted)
                            Spacer(minLength: WorkbenchSpacing.sm)
                            numeral(stage)
                        }
                        Text([stage.detail, stage.caption].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(WorkbenchTypography.secondary)
                            .lineLimit(1)
                        if let subject = stage.subject { muted(subject, lines: 1) }
                        if let extra = extra(stage) { muted(extra, lines: 1) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(stage.title)
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.muted)
                        numeral(stage)
                        Text(stage.detail)
                            .font(WorkbenchTypography.secondary)
                            .lineLimit(2)
                        if let subject = stage.subject { muted(subject) }
                        if !stage.caption.isEmpty { muted(stage.caption) }
                        if let extra = extra(stage) { muted(extra) }
                    }
                }
            }
            .frame(minWidth: isStacked ? nil : WorkbenchSize.Reclaim.stageMinimum, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Suggestion row

struct ReclaimSuggestionRowView: View {
    let row: ReclaimSuggestionRow
    let isCompact: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            Image(systemName: row.symbol)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Reclaim.symbolColumn)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(row.name.title)
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(row.name.detail ?? row.paths.joined(separator: "\n"))
                Text(isCompact ? "\(row.evidence) · \(row.bytes)" : row.evidence)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(2)
                if let reason = row.reason {
                    Text(reason)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(row.paths, id: \.self) { path in
                    Text(path)
                        .font(WorkbenchTypography.compactValue)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                }
            }
            .frame(minWidth: isCompact ? nil : WorkbenchSize.Reclaim.suggestionNameMinimum, maxWidth: .infinity, alignment: .leading)
            if !isCompact {
                Text(row.bytes)
                    .font(WorkbenchTypography.tabular)
                    .frame(width: WorkbenchSize.Reclaim.byteColumn, alignment: .trailing)
            }
            Group {
                if row.isActionable {
                    Toggle(isOn: $isSelected) { Text("Select \(row.name.title)") }
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                } else {
                    Color.clear
                }
            }
            .frame(width: WorkbenchSize.Reclaim.checkboxColumn)
        }
        .padding(.vertical, WorkbenchSpacing.xxs)
    }
}

// MARK: - Quarantine row

struct ReclaimQuarantineRowView: View {
    let row: ReclaimQuarantineRow
    let isCompact: Bool
    let isBusy: Bool
    let onPutBack: () -> Void
    let onTrash: () -> Void

    var body: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    identity
                    Text("\(row.bytes) · \(row.date)")
                        .font(WorkbenchTypography.secondaryTabular)
                        .foregroundStyle(WorkbenchColor.muted)
                    HStack(spacing: WorkbenchSpacing.xs) { actions }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                    identity.frame(minWidth: WorkbenchSize.Reclaim.quarantineNameMinimum, maxWidth: .infinity, alignment: .leading)
                    Text(row.bytes)
                        .font(WorkbenchTypography.tabular)
                        .frame(width: WorkbenchSize.Reclaim.byteColumn, alignment: .trailing)
                    Text(row.date)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(2)
                        .frame(width: WorkbenchSize.Reclaim.dateColumn, alignment: .leading)
                    actions
                }
            }
        }
        .padding(.vertical, WorkbenchSpacing.xxs)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(row.name.title)
                .font(WorkbenchTypography.emphasis)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(row.name.detail ?? row.record.from)
            Text(row.record.from)
                .font(WorkbenchTypography.compactValue)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(row.record.from)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Put back", action: onPutBack)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        Button(action: onTrash) { Label("Move to Trash", systemImage: "trash") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
    }
}
