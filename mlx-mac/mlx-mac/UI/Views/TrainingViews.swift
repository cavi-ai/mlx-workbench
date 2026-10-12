import SwiftUI

/// Raw evidence stays one click away and collapsed by default.
struct TrainingRawDisclosure: View {
    let title: String
    let text: String
    var maxHeight: CGFloat = WorkbenchSize.Training.evidenceMaxHeight
    /// Lets the owner open the disclosure; without it the disclosure keeps its own state.
    var expanded: Binding<Bool>?
    @State private var ownExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: expanded ?? $ownExpanded) {
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

/// One failed request: a single sentence, with the agent's own output one click away.
struct TrainingLoadFailure: View {
    let sentence: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(sentence)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.failure)
                .fixedSize(horizontal: false, vertical: true)
            TrainingRawDisclosure(title: "Agent output", text: detail)
        }
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
                StatusBadge(status: row.status, pulses: pulses)
            }
            if row.canCompare || row.logPath != nil || row.canCancel {
                ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xs) {
                    if row.canCompare {
                        Button("Compare with base") { actions.compare(row) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if let log = row.logPath {
                        Button("Open log") { actions.openLog(log) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if row.canCancel {
                        Button("Cancel training", role: .destructive) { actions.cancel(row) }.buttonStyle(.bordered).controlSize(.small)
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
    let presentation: TrainingPresentation
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
                if let error = presentation.jobsError {
                    TrainingLoadFailure(sentence: TrainingPresentation.jobsFailureSentence, detail: error)
                }
                if presentation.showsNoJobs {
                    Text(TrainingPresentation.noJobsSentence)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(presentation.jobs) { row in
                        Divider()
                        TrainingJobRowView(row: row, pulses: pulses, actions: actions)
                    }
                }
            }
        }
    }
}

/// The report the last Inspect returned, tagged with the evaluation it belongs to.
struct TrainingRetainedEvidence: Equatable {
    let evaluationID: String
    let reportText: String
    let sha256: String

    var shortID: String { String(evaluationID.prefix(TrainingPresentation.shortIDLength)) }
}

struct TrainingEvaluationsCard: View {
    let presentation: TrainingPresentation
    let retained: TrainingRetainedEvidence?
    let inspectingID: String?
    @Binding var retainedExpanded: Bool
    let inspect: (String) -> Void

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("Retained training evaluations").font(WorkbenchTypography.cardTitle)
                if let error = presentation.historyError {
                    TrainingLoadFailure(sentence: TrainingPresentation.evaluationsFailureSentence, detail: error)
                }
                if presentation.showsNoEvaluations {
                    Text(TrainingPresentation.noEvaluationsSentence)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let rows = presentation.evaluations
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
                            if inspectingID == row.id {
                                ProgressView().controlSize(.small)
                            }
                            Button("Inspect") { inspect(row.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(inspectingID == row.id)
                        }
                    }
                }
                if let retained {
                    Divider()
                    TrainingRawDisclosure(
                        title: "Evaluation \(retained.shortID): outputs and frozen recipe",
                        text: retained.reportText + "\n\nSHA-256: " + retained.sha256,
                        expanded: $retainedExpanded
                    )
                }
            }
        }
    }
}
