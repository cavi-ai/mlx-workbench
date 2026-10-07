import Foundation

/// Charts consume the same identity and cohort checks as agent guidance.
/// Recorded measurements stay distinct from current memory-fit estimates.
enum WorkflowCharts {
    enum Metric: String, CaseIterable, Identifiable {
        case runtime, breakdown, quality, peakMemory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .runtime: return "Total runtime"
            case .breakdown: return "Time breakdown"
            case .quality: return "Task quality"
            case .peakMemory: return "Peak memory"
            }
        }
        var axisLabel: String {
            switch self {
            case .runtime, .breakdown: return "Seconds"
            case .quality: return "Recorded score (1–5)"
            case .peakMemory: return "Recorded peak memory (GB)"
            }
        }
        func formattedValue(_ value: Double) -> String {
            switch self {
            case .runtime, .breakdown: return String(format: "%.2f s", value)
            case .quality: return String(format: "%.0f/5", value)
            case .peakMemory: return String(format: "%.2f GB", value)
            }
        }
    }

    struct Point: Identifiable {
        let candidate: AgentTaskCandidate
        let value: Double
        var id: String { candidate.modelPath }
    }
    struct Series {
        let points: [Point]
        let missing: [AgentTaskCandidate]
        let unavailableReason: String?
    }

    static func series(_ task: AgentTaskGuidance, records: [WorkflowEvidence], metric: Metric) -> Series {
        let candidates = task.candidates.filter(\.comparable)
        if metric == .quality, task.rubricID == nil {
            return Series(points: [], missing: candidates.filter { $0.qualityScore == nil },
                unavailableReason: "No shared quality rubric. Missing or different rubrics prevent a quality comparison.")
        }
        let recordsByID = Dictionary(grouping: records, by: { $0.id.uuidString })
        var points: [Point] = []
        var missing: [AgentTaskCandidate] = []
        for candidate in candidates {
            // Bind to the exact report selected by guidance, never an older observation.
            guard task.source == "workflow", let matches = recordsByID[candidate.evidenceID], matches.count == 1,
                  let record = matches.first, record.modelPath == candidate.modelPath,
                  record.measuredAt == candidate.measuredAt, record.sampleCount == candidate.sampleCount,
                  record.harness == task.harness, record.workloadID == task.workloadID, record.useCase == task.useCase,
                  record.configurationFingerprint == task.configurationFingerprint,
                  record.totalSeconds == candidate.totalSeconds, record.qualityScore == candidate.qualityScore,
                  (try? record.validate()) != nil else { missing.append(candidate); continue }
            let value: Double?
            switch metric {
            case .runtime, .breakdown: value = record.totalSeconds
            case .quality:
                value = record.rubricID == task.rubricID ? record.qualityScore.map(Double.init) : nil
            case .peakMemory:
                value = record.peakMemoryBytes.map { Double($0) / 1_000_000_000 }
            }
            if let value { points.append(Point(candidate: candidate, value: value)) }
            else { missing.append(candidate) }
        }
        points.sort {
            if $0.value == $1.value { return $0.id < $1.id }
            return metric == .quality ? $0.value > $1.value : $0.value < $1.value
        }
        return Series(points: points, missing: missing.sorted { $0.modelPath < $1.modelPath }, unavailableReason: nil)
    }

    struct ComparisonSelection {
        let slots: [String?]?
        let reason: String
    }

    static func comparisonSelection(_ task: AgentTaskGuidance, models: [LibraryModel], mode: ComparisonMode, activeRunID: UUID?) -> ComparisonSelection {
        guard activeRunID == nil else {
            return ComparisonSelection(slots: nil, reason: "Wait for the current comparison to finish.")
        }
        let eligible = Set(ComparisonViewLogic.candidates(from: models, mode: mode).map { $0.item.path })
        var seen = Set<String>()
        let paths = chartCandidates(task).map(\.modelPath).filter { eligible.contains($0) && seen.insert($0).inserted }
        guard !paths.isEmpty else {
            return ComparisonSelection(slots: nil, reason: "No current, ready models in this cohort match \(mode.title).")
        }
        guard paths.count <= ComparePresentation.maxSlots else {
            return ComparisonSelection(slots: nil, reason: "\(paths.count) eligible models; Compare supports \(ComparePresentation.maxSlots). Select models manually below.")
        }
        var slots = paths.map(Optional.some)
        if slots.count == 1 { slots.append(nil) }
        let excluded = task.candidates.count - paths.count
        let suffix = excluded > 0 ? " \(excluded) unavailable, incompatible or stale observations excluded." : ""
        return ComparisonSelection(slots: slots, reason: "\(paths.count) models from \(task.harness ?? "workflow") · \(task.title). Prompt set unchanged.\(suffix)")
    }

    enum Timing: String, CaseIterable {
        case inference = "Inference", tools = "Tools", queue = "Queue"
        case unattributed = "Unattributed", unknown = "Breakdown unknown"
    }

    struct Segment: Identifiable {
        let timing: Timing
        let seconds: Double
        var id: Timing { timing }
    }

    static func segments(_ candidate: AgentTaskCandidate) -> [Segment] {
        guard candidate.comparable, let total = candidate.totalSeconds, total.isFinite, total > 0 else { return [] }
        guard let inference = candidate.inferenceSeconds, let tools = candidate.toolSeconds, let queue = candidate.queueSeconds,
              [inference, tools, queue].allSatisfy({ $0.isFinite && $0 >= 0 }),
              inference + tools + queue <= total + 0.000001 else {
            return [Segment(timing: .unknown, seconds: total)]
        }
        return [Segment(timing: .inference, seconds: inference), Segment(timing: .tools, seconds: tools),
                Segment(timing: .queue, seconds: queue),
                Segment(timing: .unattributed, seconds: max(0, total - inference - tools - queue))]
    }

    static func missingTimings(_ candidate: AgentTaskCandidate) -> [String] {
        [(Timing.inference.rawValue, candidate.inferenceSeconds), (Timing.tools.rawValue, candidate.toolSeconds),
         (Timing.queue.rawValue, candidate.queueSeconds)].compactMap { $0.1 == nil ? $0.0 : nil }
    }

    static func chartCandidates(_ task: AgentTaskGuidance) -> [AgentTaskCandidate] {
        task.candidates.filter { !segments($0).isEmpty }.sorted {
            if $0.totalSeconds == $1.totalSeconds { return $0.modelPath < $1.modelPath }
            return ($0.totalSeconds ?? .infinity) < ($1.totalSeconds ?? .infinity)
        }
    }
}
