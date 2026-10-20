import SwiftUI

struct ActivityStatusRecovery: View {
    let error: String
    let context: String
    let isRefreshing: Bool
    let onRetry: () -> Void
    let onHealth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            FailureNotice(error: error, details: .whenDifferent)
            Text("Retry reads status without restarting work. Health shows the engine and runtime checks.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(isRefreshing ? "Refreshing status…" : "Retry status", action: onRetry)
                    .disabled(isRefreshing)
                    .accessibilityIdentifier("activity-retry-\(context)-status")
                Button("Open Health", action: onHealth)
                    .accessibilityIdentifier("activity-health-\(context)")
            }.controlSize(.small)
        }
    }
}

struct ActivityStudySection: View {
    @ObservedObject var lab: LabCoordinator
    let jobs: [LabJob]
    let error: String?
    var isWorking = false
    var historical = false
    var isRefreshing = false
    let onRetry: () -> Void
    let onHealth: () -> Void
    let onOpen: () -> Void
    @State private var expanded = false

    var body: some View {
        if !jobs.isEmpty || error != nil || isWorking {
            WorkbenchSurface {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    HStack {
                        Text(historical ? "Earlier study jobs" : "Study jobs").font(WorkbenchTypography.cardTitle)
                        Spacer()
                        Button("Open Studies", action: onOpen).buttonStyle(.bordered)
                    }
                    if let error {
                        ActivityStatusRecovery(error: error, context: "study", isRefreshing: isRefreshing,
                                               onRetry: onRetry, onHealth: onHealth)
                    }
                    if error != nil, !jobs.isEmpty {
                        Text("Showing latest available study jobs.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    if isWorking, jobs.isEmpty { ProgressView("Study job running…") }
                    if historical {
                        DisclosureGroup(jobs.count == 1 ? "Show 1 job" : "Show \(jobs.count) jobs", isExpanded: $expanded) {
                            LabJobRows(lab: lab, jobs: jobs).padding(.top, WorkbenchSpacing.sm)
                        }
                    } else { LabJobRows(lab: lab, jobs: jobs) }
                }
            }
            .accessibilityIdentifier(historical ? "activity-study-history" : "activity-study-jobs")
        }
    }
}

struct ActivityTrainingSection: View {
    let jobs: [TrainingJob]
    let error: String?
    var historical = false
    var isRefreshing = false
    let onRetry: () -> Void
    let onHealth: () -> Void
    let onOpen: () -> Void
    let onViewLog: (String) -> Void
    let onCancel: (TrainingJob) -> Void
    @State private var expanded = false

    var body: some View {
        if !jobs.isEmpty || error != nil {
            WorkbenchSurface {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    HStack {
                        Text(historical ? "Earlier training jobs" : "Training jobs").font(WorkbenchTypography.cardTitle)
                        Spacer()
                        Button("Open Training", action: onOpen).buttonStyle(.bordered)
                    }
                    if let error {
                        ActivityStatusRecovery(error: error, context: "training", isRefreshing: isRefreshing,
                                               onRetry: onRetry, onHealth: onHealth)
                    }
                    if error != nil, !jobs.isEmpty {
                        Text("Showing last known training jobs.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    if historical {
                        DisclosureGroup(jobs.count == 1 ? "Show 1 job" : "Show \(jobs.count) jobs", isExpanded: $expanded) {
                            rows.padding(.top, WorkbenchSpacing.sm)
                        }
                    } else { rows }
                }
            }
            .accessibilityIdentifier(historical ? "activity-training-history" : "activity-training-jobs")
        }
    }

    private var rows: some View {
        ForEach(jobs) { job in
            let row = TrainingJobRow(job: job, home: NSHomeDirectory())
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack {
                    Text(row.repo).font(WorkbenchTypography.emphasis).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    StatusBadge(status: row.status, pulses: false)
                }
                if let guidance = row.recoveryGuidance {
                    Text(guidance).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xs) {
                    if let log = row.logPath, !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("View log") { onViewLog(log) }.accessibilityIdentifier("activity-view-training-log")
                    }
                    if row.recoveryGuidance != nil {
                        Button("Review training setup", action: onOpen)
                            .accessibilityIdentifier("activity-review-training-setup")
                    }
                    if row.canCancel { Button("Cancel training") { onCancel(job) } }
                }.controlSize(.small)
            }
        }
    }
}
