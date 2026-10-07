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
    let onReview: (AgentTaskGuidance, String) async throws -> ModelGuidanceReview
    let onApply: (ModelGuidanceReview, UseCase, Bool) async throws -> String
    @Binding var metric: WorkflowCharts.Metric
    @Binding var inspectedModelPath: String?
    @State private var selectedTaskID: String?
    @State private var selectionNote: String?
    @State private var selectionError: String?
    @State private var review: ModelGuidanceReview?
    @State private var isPreparingReview = false

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
                    if metric == .qualityRuntime {
                        tradeoffChart(series.points)
                        tradeoffSelection(series.points, task: selected)
                    } else {
                        ScrollView(.vertical) { chart(series.points) }
                            .frame(height: min(chartHeight(series.points.count), 360))
                    }
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
        .onChange(of: selected?.id) { _, _ in inspectedModelPath = nil }
        .onChange(of: metric) { _, _ in inspectedModelPath = nil }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review {
                ModelGuidanceReviewView(review: review, onApply: onApply, onBack: { self.review = nil }, onApplied: {
                    selectionNote = $0; selectionError = nil; self.review = nil
                })
            }
        }
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
        case .qualityRuntime:
            return "Upper left: higher recorded quality, lower runtime for the same sample count. Shared rubric: \(task.rubricID ?? "unknown"). Select a model to inspect its capture."
        }
    }

    private func tradeoffChart(_ points: [WorkflowCharts.Point]) -> some View {
        Chart(points) { point in
            if let seconds = point.candidate.totalSeconds {
                PointMark(x: .value("Total runtime", seconds), y: .value("Recorded score", point.value))
                    .foregroundStyle(point.id == inspectedModelPath ? WorkbenchColor.success : WorkbenchColor.accent)
                    .symbolSize(point.id == inspectedModelPath ? 140 : 90)
                    .accessibilityLabel(point.candidate.name)
                    .accessibilityValue("\(point.value.formatted()) out of 5, \(seconds.formatted()) seconds")
            }
        }
        .chartXScale(domain: 0...max((points.compactMap { $0.candidate.totalSeconds }.max() ?? 0) * 1.1, 0.1), range: .plotDimension(padding: 12))
        .chartYScale(domain: 0.5...5.5)
        .chartYAxis { AxisMarks(values: [1, 2, 3, 4, 5]) }
        .chartXAxisLabel("Total runtime (seconds) · lower is faster")
        .chartYAxisLabel("Recorded quality (1–5)")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            let origin = geometry[frame].origin
                            let distances = points.compactMap { point -> (String, CGFloat)? in
                                guard let seconds = point.candidate.totalSeconds,
                                      let x = proxy.position(forX: seconds), let y = proxy.position(forY: point.value) else { return nil }
                                return (point.id, hypot(location.x - origin.x - x, location.y - origin.y - y))
                            }
                            inspectedModelPath = distances.min { $0.1 < $1.1 }.flatMap { $0.1 <= 24 ? $0.0 : nil }
                        }
                }
            }
        }
        .frame(height: 260)
    }

    @ViewBuilder private func tradeoffSelection(_ points: [WorkflowCharts.Point], task: AgentTaskGuidance) -> some View {
        Picker("Inspect model", selection: Binding(get: {
            points.contains { $0.id == inspectedModelPath } ? inspectedModelPath : nil
        }, set: { inspectedModelPath = $0 })) {
            Text("Choose a point or model").tag(String?.none)
            ForEach(points) { Text($0.candidate.name).tag(Optional($0.id)) }
        }.pickerStyle(.menu).frame(maxWidth: 420)
        if let point = points.first(where: { $0.id == inspectedModelPath }) {
            let canUse = models.contains { $0.item.path == point.id && ModelTaskPresentation.isServable($0) && !$0.capabilities.isEmpty }
            ViewThatFits(in: .horizontal) {
                HStack { selectedCapture(point); Spacer(); useButton(task, path: point.id, canUse: canUse) }
                VStack(alignment: .leading) { selectedCapture(point); useButton(task, path: point.id, canUse: canUse) }
            }
        }
    }

    private func selectedCapture(_ point: WorkflowCharts.Point) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(point.candidate.name).font(WorkbenchTypography.emphasis)
            Text("\(WorkflowCharts.Metric.quality.formattedValue(point.value)) · \(point.candidate.totalSeconds.map { WorkflowCharts.Metric.runtime.formattedValue($0) } ?? "unknown") · recorded peak \(point.peakMemoryBytes.map { WorkflowCharts.Metric.peakMemory.formattedValue(Double($0) / 1_000_000_000) } ?? "unknown")")
                .font(WorkbenchTypography.value)
            Text("Captured \(point.candidate.measuredAt.formatted()). Current memory fit is checked in Use model.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
    }

    private func useButton(_ task: AgentTaskGuidance, path: String, canUse: Bool) -> some View {
        Button(isPreparingReview ? "Checking…" : "Use model…") {
            isPreparingReview = true; selectionError = nil; selectionNote = nil
            Task { @MainActor in
                defer { isPreparingReview = false }
                do { review = try await onReview(task, path) }
                catch { selectionError = AppHost.render(error) }
            }
        }.buttonStyle(.bordered).disabled(isPreparingReview || !canUse)
            .accessibilityIdentifier("workflow-use-model")
            .help(canUse ? "Review role preference and current fit; endpoint changes remain optional." : "This model has no supported serving role. Use its task-specific panel.")
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
