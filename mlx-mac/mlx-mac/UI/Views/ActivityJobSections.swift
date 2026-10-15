import SwiftUI

struct ActivityStudySection: View {
    @ObservedObject var lab: LabCoordinator
    let jobs: [LabJob]
    let error: String?
    var isWorking = false
    var historical = false
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
                    ErrorBanner(text: error)
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
    let onOpen: () -> Void
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
                    ErrorBanner(text: error)
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
            HStack {
                Text(job.repo + " · " + job.state).font(WorkbenchTypography.secondary)
                Spacer()
                if job.state == "running" {
                    Button("Cancel training") { onCancel(job) }
                }
            }
        }
    }
}
