import Charts
import SwiftUI

struct WorkflowChartsView: View {
    @ObservedObject var workflow: WorkflowEvidenceStore
    let models: [LibraryModel]
    let environment: String?
    let hardware: HardwareProfile
    @State private var selectedTaskID: String?
    @State private var showBreakdown = false

    private var tasks: [AgentTaskGuidance] {
        AgentTaskAdvisor.guidance(models: models, runs: [], workflow: workflow.records, environment: environment,
            hardware: hardware, memory: nil, contextTokens: 8192, reserveGB: 0)
    }

    var body: some View {
        let available = tasks
        let selected = available.first { $0.id == selectedTaskID } ?? available.first
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Label("Workflow performance", systemImage: "chart.bar.xaxis")
                    .font(WorkbenchTypography.roundedHeading)
                Spacer()
                Text("WORKFLOW REPORTS").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            }
            if let selected {
                ViewThatFits(in: .horizontal) {
                    HStack { controls(available, selected: selected) }
                    VStack(alignment: .leading) { controls(available, selected: selected) }
                }
                let candidates = WorkflowCharts.chartCandidates(selected)
                if candidates.isEmpty {
                    Text("No current comparable timings in this cohort. Review the evidence below.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                } else {
                    ScrollView(.vertical) { chart(candidates) }
                        .frame(height: min(CGFloat(candidates.count) * 40 + (showBreakdown ? 80 : 48), 360))
                    Text("Seconds for \(candidates[0].sampleCount) samples · lower total runtime is faster. Latest report per model; capture dates appear in evidence.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    if showBreakdown {
                        ForEach(candidates.filter { !WorkflowCharts.missingTimings($0).isEmpty }) { candidate in
                            Text("\(candidate.name): \(WorkflowCharts.missingTimings(candidate).joined(separator: ", ")) unknown.")
                                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                }
                DisclosureGroup("Configuration and source evidence") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text("Configuration: \(selected.configurationFingerprint ?? "unknown — no cross-model comparison")")
                            .font(WorkbenchTypography.value).textSelection(.enabled)
                        Text("\(selected.useCase?.title ?? "No task role") · \(selected.candidates.first?.sampleCount ?? 0) samples. Different configurations and sample counts remain separate.")
                        ForEach(selected.candidates) { candidate in
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                Text(candidate.name).font(WorkbenchTypography.emphasis)
                                Text(candidate.modelPath).font(WorkbenchTypography.value).textSelection(.enabled)
                                Text("Captured \(candidate.measuredAt.formatted()) · report \(candidate.evidenceID)")
                                    .textSelection(.enabled)
                                if let record = workflow.records.first(where: { $0.id.uuidString == candidate.evidenceID }) {
                                    Text("Source: \(record.source)").textSelection(.enabled)
                                }
                                ForEach(candidate.exclusionReasons, id: \.self) { Text($0).foregroundStyle(WorkbenchColor.warning) }
                                if candidate.comparable {
                                    Text(timings(candidate))
                                }
                            }
                        }
                        Text("Measured timings do not establish model quality or current memory fit. Unattributed time has no measured cause; GPU, disk and network utilization are not measured.")
                            .foregroundStyle(WorkbenchColor.muted)
                    }.font(WorkbenchTypography.secondary).padding(.top, WorkbenchSpacing.xs)
                }.font(WorkbenchTypography.secondary)
            } else {
                Text("Import a Claude, OpenClaw or OpenCode workflow report to compare task runtime and timing breakdowns.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: WorkbenchRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchRadius.surface).stroke(WorkbenchColor.hairline, lineWidth: WorkbenchSpacing.hairline))
    }

    @ViewBuilder private func controls(_ tasks: [AgentTaskGuidance], selected: AgentTaskGuidance) -> some View {
        Picker("Harness / task", selection: Binding(get: { selected.id }, set: { selectedTaskID = $0 })) {
            ForEach(tasks) { task in
                Text("\(task.harness ?? "workflow") · \(task.title) · \(task.candidates.first?.sampleCount ?? 0) samples · \(task.configurationFingerprint.map { String($0.prefix(8)) } ?? "unknown config") · \(task.useCase?.title ?? "no role")").tag(task.id)
            }
        }.frame(maxWidth: 560)
        Picker("Chart", selection: $showBreakdown) {
            Text("Total runtime").tag(false)
            Text("Time breakdown").tag(true)
        }.pickerStyle(.segmented).frame(width: 270)
    }

    private func chart(_ candidates: [AgentTaskCandidate]) -> some View {
        Chart {
            ForEach(candidates) { candidate in
                if showBreakdown {
                    ForEach(WorkflowCharts.segments(candidate)) { segment in
                        BarMark(x: .value("Seconds", segment.seconds), y: .value("Model", candidate.modelPath))
                            .foregroundStyle(by: .value("Timing", segment.timing.rawValue))
                            .accessibilityLabel("\(candidate.name), \(segment.timing.rawValue)")
                            .accessibilityValue(String(format: "%.2f seconds", segment.seconds))
                    }
                } else {
                    BarMark(x: .value("Seconds", candidate.totalSeconds ?? 0), y: .value("Model", candidate.modelPath))
                        .foregroundStyle(WorkbenchColor.accent).cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(String(format: "%.2f s", candidate.totalSeconds ?? 0)).font(WorkbenchTypography.value)
                        }
                        .accessibilityLabel(candidate.name)
                        .accessibilityValue(String(format: "%.2f seconds total", candidate.totalSeconds ?? 0))
                }
            }
        }
        .chartYScale(domain: candidates.map(\.modelPath))
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let path = value.as(String.self), let candidate = candidates.first(where: { $0.modelPath == path }) {
                        Text(candidate.name).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: WorkflowCharts.Timing.allCases.map(\.rawValue),
            range: [WorkbenchColor.accent, WorkbenchColor.warning, WorkbenchColor.success, WorkbenchColor.muted, WorkbenchColor.hairline])
        .chartLegend(showBreakdown ? .visible : .hidden)
        .chartXAxisLabel("Seconds")
        .frame(height: CGFloat(max(candidates.count, 1)) * 40 + (showBreakdown ? 80 : 48))
    }

    private func timings(_ candidate: AgentTaskCandidate) -> String {
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "unknown" }
        return "Total \(seconds(candidate.totalSeconds)) · inference \(seconds(candidate.inferenceSeconds)) · tools \(seconds(candidate.toolSeconds)) · queue \(seconds(candidate.queueSeconds))"
    }
}
