import SwiftUI

/// Raw evidence stays one click away and collapsed by default.
struct TrainingRawDisclosure: View {
    let title: String
    let text: String
    var maxHeight: CGFloat = WorkbenchSize.Training.evidenceMaxHeight

    var body: some View {
        DisclosureGroup {
            ScrollView {
                Text(text)
                    .font(WorkbenchTypography.compactValue)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .padding(.top, WorkbenchSpacing.xxs)
        } label: {
            Text(title)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }
}

/// Status capsule that pulses only while its route is the one shown.
struct TrainingStatusBadge: View {
    let status: WorkbenchStatus
    let pulses: Bool

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xxs) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .livePulse(status.isLive && pulses)
            Text(status.label)
                .font(WorkbenchTypography.label)
                .lineLimit(1)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.xxxs)
        .foregroundStyle(status.color)
        .background(status.color.opacity(.fill), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

struct TrainingJobActions {
    let compare: (TrainingJobRow) -> Void
    let openLog: (String) -> Void
    let cancel: (TrainingJobRow) -> Void
}

struct TrainingJobRowView: View {
    let row: TrainingJobRow
    let pulses: Bool
    let actions: TrainingJobActions

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text(row.repo)
                        .font(WorkbenchTypography.cardTitle)
                        .foregroundStyle(WorkbenchColor.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.outputPath)
                        .font(WorkbenchTypography.compactValue)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.outputPath)
                }
                Spacer(minLength: WorkbenchSpacing.xs)
                TrainingStatusBadge(status: row.status, pulses: pulses)
            }
            if row.canCompare || row.logPath != nil || row.canCancel {
                ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xs) {
                    if row.canCompare {
                        Button("Compare with base") { actions.compare(row) }.buttonStyle(.bordered)
                    }
                    if let log = row.logPath {
                        Button("Open log") { actions.openLog(log) }.buttonStyle(.bordered)
                    }
                    if row.canCancel {
                        Button("Cancel training", role: .destructive) { actions.cancel(row) }.buttonStyle(.bordered)
                    }
                }
            }
            if let identity = row.adapterIdentity {
                TrainingRawDisclosure(title: "Adapter content identity", text: identity.jsonText)
            }
        }
        .padding(.vertical, WorkbenchSpacing.xs)
    }
}

struct TrainingJobsCard: View {
    let rows: [TrainingJobRow]
    let pulses: Bool
    let refresh: () -> Void
    let actions: TrainingJobActions

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack {
                    Text("Training jobs").font(WorkbenchTypography.cardTitle)
                    Spacer()
                    Button("Refresh", action: refresh).buttonStyle(.bordered).controlSize(.small)
                }
                if rows.isEmpty {
                    Text(TrainingPresentation.noJobsSentence)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(rows) { row in
                        Divider()
                        TrainingJobRowView(row: row, pulses: pulses, actions: actions)
                    }
                }
            }
        }
    }
}

struct TrainingRetainedEvidence: Equatable {
    let reportText: String
    let sha256: String
}

struct TrainingEvaluationsCard: View {
    let rows: [TrainingEvaluationRow]
    let retained: TrainingRetainedEvidence?
    let inspect: (String) -> Void

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("Retained training evaluations").font(WorkbenchTypography.cardTitle)
                if rows.isEmpty {
                    Text(TrainingPresentation.noEvaluationsSentence)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(rows) { row in
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                            Text(row.shortID)
                                .font(WorkbenchTypography.value)
                                .foregroundStyle(WorkbenchColor.ink)
                                .help(row.id)
                            if let date = row.dateText {
                                Text(date)
                                    .font(WorkbenchTypography.metadata)
                                    .foregroundStyle(WorkbenchColor.muted)
                            }
                            Spacer(minLength: WorkbenchSpacing.xs)
                            Button("Inspect") { inspect(row.id) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if let retained {
                    Divider()
                    TrainingRawDisclosure(
                        title: "Evaluation outputs and frozen recipe",
                        text: retained.reportText + "\n\nSHA-256: " + retained.sha256
                    )
                }
            }
        }
    }
}
