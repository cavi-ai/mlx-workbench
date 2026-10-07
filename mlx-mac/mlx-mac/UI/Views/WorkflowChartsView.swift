import Charts
import SwiftUI

struct WorkflowChartsView: View {
    @ObservedObject var workflow: WorkflowEvidenceStore
    let models: [LibraryModel]
    let environment: String?
    let hardware: HardwareProfile
    let mode: ComparisonMode
    let activeRunID: UUID?
    let onCompare: (String) -> WorkflowCharts.ComparisonSelection
    @Binding var metric: WorkflowCharts.Metric
    @State private var selectedTaskID: String?
    @State private var selectionNote: String?
    @State private var selectionError: String?

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
                if let selected { compareButton(selected) }
            }
            if let selected {
                ViewThatFits(in: .horizontal) {
                    HStack { controls(available, selected: selected) }
                    VStack(alignment: .leading) { controls(available, selected: selected) }
                }
                let selection = WorkflowCharts.comparisonSelection(selected, models: models, mode: mode, activeRunID: activeRunID)
                if selection.slots == nil {
                    Text(selection.reason).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                if let selectionNote {
                    Text(selectionNote).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
                }
                if let selectionError {
                    Text(selectionError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                }
                let series = WorkflowCharts.series(selected, records: workflow.records, metric: metric)
                if series.points.isEmpty {
                    Text(series.unavailableReason ?? "No current comparable \(metric.title.lowercased()) measurements in this cohort. Review the evidence below.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                } else {
                    ScrollView(.vertical) { chart(series.points) }
                        .frame(height: min(chartHeight(series.points.count), 360))
                    Text(caption(selected))
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if metric == .breakdown {
                        ForEach(series.points.map(\.candidate).filter { !WorkflowCharts.missingTimings($0).isEmpty }) { candidate in
                            Text("\(candidate.name): \(WorkflowCharts.missingTimings(candidate).joined(separator: ", ")) unknown.")
                                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                }
                ForEach(series.missing) { candidate in
                    Text("\(candidate.name): \(metric.title.lowercased()) unknown.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
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
                                    Text("Quality: \(record.qualityScore.map { "\($0)/5" } ?? "unknown") · rubric: \(record.rubricID ?? "unknown")")
                                    Text("Recorded peak memory: \(record.peakMemoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown")")
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
        .onChange(of: selectedTaskID) { _, _ in selectionNote = nil; selectionError = nil }
    }

    private func compareButton(_ task: AgentTaskGuidance) -> some View {
        let selection = WorkflowCharts.comparisonSelection(task, models: models, mode: mode, activeRunID: activeRunID)
        return Button("Compare these models") {
            let applied = onCompare(task.id)
            if let slots = applied.slots {
                selectionNote = "\(ComparePresentation.variantPaths(slots).count) models loaded. Choose prompts for the new local comparison."
                selectionError = nil
            } else {
                selectionNote = nil; selectionError = applied.reason
            }
        }
        .buttonStyle(.bordered)
        .disabled(selection.slots == nil)
        .help(selection.reason + " Loads slots only; does not replay the harness or start a run.")
    }

    @ViewBuilder private func controls(_ tasks: [AgentTaskGuidance], selected: AgentTaskGuidance) -> some View {
        Picker("Harness / task", selection: Binding(get: { selected.id }, set: { selectedTaskID = $0 })) {
            ForEach(tasks) { task in
                Text("\(task.harness ?? "workflow") · \(task.title) · \(task.candidates.first?.sampleCount ?? 0) samples · \(task.configurationFingerprint.map { String($0.prefix(8)) } ?? "unknown config") · \(task.useCase?.title ?? "no role")").tag(task.id)
            }
        }.frame(maxWidth: 560)
        Picker("Chart", selection: $metric) {
            ForEach(WorkflowCharts.Metric.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).frame(width: 220)
    }

    private func chartHeight(_ count: Int) -> CGFloat {
        CGFloat(max(count, 1)) * (metric == .peakMemory ? 52 : 40) + (metric == .breakdown ? 80 : 48)
    }

    private func caption(_ task: AgentTaskGuidance) -> String {
        switch metric {
        case .runtime, .breakdown:
            return "Seconds for \(task.candidates.first?.sampleCount ?? 0) samples · lower total runtime is faster. Latest report per model; capture dates appear in evidence."
        case .quality:
            return "Recorded scores · higher is better within rubric \(task.rubricID ?? "unknown"). Quality for other tasks is not established."
        case .peakMemory:
            return "Recorded peak memory at each capture date. Current headroom and estimated memory fit are separate."
        }
    }

    private func chart(_ points: [WorkflowCharts.Point]) -> some View {
        let candidates = points.map(\.candidate)
        return Chart {
            ForEach(points) { point in
                let candidate = point.candidate
                if metric == .breakdown {
                    ForEach(WorkflowCharts.segments(candidate)) { segment in
                        BarMark(x: .value("Seconds", segment.seconds), y: .value("Model", candidate.modelPath))
                            .foregroundStyle(by: .value("Timing", segment.timing.rawValue))
                            .accessibilityLabel("\(candidate.name), \(segment.timing.rawValue)")
                            .accessibilityValue(String(format: "%.2f seconds", segment.seconds))
                    }
                } else {
                    BarMark(x: .value(metric.axisLabel, point.value), y: .value("Model", candidate.modelPath))
                        .foregroundStyle(metric == .quality ? WorkbenchColor.success : WorkbenchColor.accent).cornerRadius(3)
                        .annotation(position: .trailing, overflowResolution: .init(x: .fit(to: .plot))) {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                Text(metric.formattedValue(point.value)).font(WorkbenchTypography.value)
                                if metric == .peakMemory {
                                    Text("Captured \(candidate.measuredAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                                }
                            }
                            .fixedSize()
                            .padding(WorkbenchSpacing.xxs)
                            .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: 3))
                        }
                        .accessibilityLabel(candidate.name)
                        .accessibilityValue("\(metric.formattedValue(point.value)), recorded \(candidate.measuredAt.formatted())")
                }
            }
        }
        .chartXScale(domain: 0...(metric == .quality ? 5 : max((points.map(\.value).max() ?? 0) * 1.15, 0.1)))
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
        .chartLegend(metric == .breakdown ? .visible : .hidden)
        .chartXAxisLabel(metric.axisLabel)
        .frame(height: chartHeight(candidates.count))
    }

    private func timings(_ candidate: AgentTaskCandidate) -> String {
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "unknown" }
        return "Total \(seconds(candidate.totalSeconds)) · inference \(seconds(candidate.inferenceSeconds)) · tools \(seconds(candidate.toolSeconds)) · queue \(seconds(candidate.queueSeconds))"
    }
}
