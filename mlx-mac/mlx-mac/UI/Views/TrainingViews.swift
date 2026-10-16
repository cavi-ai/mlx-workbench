import SwiftUI

struct TrainingInspectionPanel: View {
    let inspection: TrainingInspection
    let repair: (TrainingField) -> Void
    let openHealth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(inspection.ready ? "Local setup checks passed" : "Training setup needs attention")
                .font(WorkbenchTypography.emphasis)
                .accessibilityIdentifier("training-inspection-summary")
            ForEach(inspection.checks) { check in
                HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                    Image(systemName: check.status == .ready ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(check.status == .ready ? WorkbenchColor.success : WorkbenchColor.warning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(check.title).font(WorkbenchTypography.label)
                        Text(check.message).font(WorkbenchTypography.secondary)
                            .accessibilityIdentifier("training-inspection-\(check.id.rawValue)")
                        if let remediation = check.remediation {
                            Text(remediation).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                        if let field = check.repairField {
                            Button("Fix field") { repair(field) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityIdentifier("training-inspection-fix-\(check.id.rawValue)")
                        } else if check.id == .runtime && check.status == .blocked {
                            Button("Open Health", action: openHealth).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Checks executable availability and local inputs without loading the model. Preview rechecks the files; training still requires confirmation.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
}

/// Raw evidence stays one click away and collapsed by default.
struct TrainingRawDisclosure: View {
    let title: String
    let text: String
    var maxHeight: CGFloat = WorkbenchSize.Training.evidenceMaxHeight
    /// Lets the owner open the disclosure; without it the disclosure keeps its own state.
    var expanded: Binding<Bool>?
    var textIdentifier: String?
    @State private var ownExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: expanded ?? $ownExpanded) {
            ScrollView {
                Text(text)
                    .font(WorkbenchTypography.compactValue)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(textIdentifier ?? "")
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
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                Text(sentence)
                    .font(WorkbenchTypography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier ?? "")
            }.foregroundStyle(WorkbenchColor.failure)
            TrainingRawDisclosure(title: "Agent output", text: detail, textIdentifier: identifier.map { $0 + "-detail" })
        }
    }
}

struct TrainingJobActions {
    let compare: (TrainingJobRow) -> Void
    let openLog: (String) -> Void
    let cancel: (TrainingJobRow) -> Void
    var cancelingPIDs: Set<Int> = []
    var serve: ((TrainingJobRow) -> Void)? = nil
    var isServingBusy = false
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
                        if let serve = actions.serve {
                            Button("Use in Run") { serve(row) }.buttonStyle(.bordered).controlSize(.small)
                                .disabled(actions.isServingBusy).help("Review serving this adapter with its pinned base model.")
                        }
                    }
                    if let log = row.logPath {
                        Button("Open log") { actions.openLog(log) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if row.canCancel {
                        Button(actions.cancelingPIDs.contains(row.pid) ? "Canceling…" : "Cancel training", role: .destructive) { actions.cancel(row) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(actions.cancelingPIDs.contains(row.pid))
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
                        .disabled(presentation.jobsLoading).accessibilityIdentifier("training-refresh-jobs")
                }
                if presentation.jobsLoading || (!presentation.jobsLoaded && presentation.jobsError == nil) {
                    TrainingCollectionLoading(text: presentation.jobsLoaded ? "Refreshing training jobs…" : "Loading training jobs…", identifier: "training-jobs-loading")
                }
                if let error = presentation.jobsError {
                    TrainingLoadFailure(sentence: TrainingPresentation.jobsFailureSentence, detail: error, identifier: "training-jobs-error")
                    Text(presentation.jobsLoaded ? "Showing the last loaded results. Refresh to retry." : "Refresh to retry.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if presentation.showsNoJobs {
                    TrainingCollectionEmpty(text: TrainingPresentation.noJobsSentence, symbol: "list.bullet.rectangle", identifier: "training-jobs-empty")
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
    var refresh: (() -> Void)? = nil
    var inspectionError: String? = nil

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack {
                    Text("Retained training evaluations").font(WorkbenchTypography.cardTitle)
                    Spacer()
                    if let refresh {
                        Button("Refresh", action: refresh).buttonStyle(.bordered).controlSize(.small)
                            .disabled(presentation.historyLoading).accessibilityIdentifier("training-refresh-history")
                    }
                }
                if presentation.historyLoading || (!presentation.historyLoaded && presentation.historyError == nil) {
                    TrainingCollectionLoading(text: presentation.historyLoaded ? "Refreshing training evaluations…" : "Loading training evaluations…", identifier: "training-history-loading")
                }
                if let error = presentation.historyError {
                    TrainingLoadFailure(sentence: TrainingPresentation.evaluationsFailureSentence, detail: error, identifier: "training-history-error")
                    Text(presentation.historyLoaded ? "Showing the last loaded results. Refresh to retry." : "Refresh to retry.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if presentation.showsNoEvaluations {
                    TrainingCollectionEmpty(text: TrainingPresentation.noEvaluationsSentence, symbol: "doc.text.magnifyingglass", identifier: "training-history-empty")
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
                                .disabled(inspectingID != nil)
                                .accessibilityIdentifier("training-inspect-" + row.id)
                        }
                    }
                }
                if let inspectingID {
                    TrainingCollectionLoading(text: "Inspecting \(inspectingID)…", identifier: "training-inspection-loading")
                }
                if let inspectionError {
                    TrainingLoadFailure(sentence: "Evaluation couldn't be inspected.", detail: inspectionError, identifier: "training-inspection-error")
                }
                if let retained {
                    Divider()
                    Text("Retained evaluation: \(retained.evaluationID)")
                        .font(WorkbenchTypography.emphasis).textSelection(.enabled)
                        .accessibilityIdentifier("training-retained-evaluation")
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


private struct TrainingCollectionLoading: View {
    let text: String
    let identifier: String

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            ProgressView().controlSize(.small)
            Text(text).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct TrainingCollectionEmpty: View {
    let text: String
    let symbol: String
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }.foregroundStyle(WorkbenchColor.muted)
    }
}
