import Foundation

/// Charts consume the same identity and cohort checks as agent guidance.
/// They show recorded durations, never a synthetic hardware bottleneck.
enum WorkflowCharts {
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
