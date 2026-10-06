import Foundation

/// Read-only decisions within one measured task cohort. Never joins workloads,
/// invents a combined score, or turns task evidence into removal authority.
enum AgentTaskAdvisor {
    static func guidance(models: [LibraryModel], runs: [ComparisonRun], workflow: [WorkflowEvidence], environment: String?, hardware: HardwareProfile, memory: MemorySnapshot?, contextTokens: Int, reserveGB: Double) -> [AgentTaskGuidance] {
        func candidate(path: String, id: String, date: Date, quality: Int?, performance: Double?, latency: Double?, samples: Int, reasons: [String]) -> AgentTaskCandidate {
            let model = models.first { $0.item.path == path }
            let fit = model.map { ComparisonInsights.fitEstimate(model: $0, hardware: hardware, memory: memory, contextTokens: contextTokens, reserveGB: reserveGB) } ?? .unknown(reason: "model unavailable")
            let status: String
            let headroom: Double?
            switch fit {
            case .fits(let value): status = "fits"; headroom = value
            case .tight(let value): status = "tight"; headroom = value
            case .wontFit: status = "wontFit"; headroom = nil
            case .unknown: status = "unknown"; headroom = nil
            }
            let required = model.flatMap { model -> Int64? in
                guard ComparisonInsights.supportsFitEstimate(model), model.item.bytes > 0 else { return nil }
                return FitAdvisor.neededBytes(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters)
            }
            return AgentTaskCandidate(modelPath: path, name: model?.displayName ?? URL(fileURLWithPath: path).lastPathComponent,
                evidenceID: id, measuredAt: date, comparable: reasons.isEmpty, exclusionReasons: reasons,
                qualityScore: quality, performanceValue: performance, firstTokenSeconds: latency, fitStatus: status,
                fitSummary: fit.summary, estimatedRequiredBytes: required, headroomGB: headroom,
                diskBytes: model.flatMap { $0.item.bytes > 0 ? $0.item.bytes : nil }, sampleCount: samples)
        }
        func identityReasons(path: String, signature: String?, measuredEnvironment: String?) -> [String] {
            guard let model = models.first(where: { $0.item.path == path }) else { return ["Model unavailable"] }
            var reasons: [String] = []
            if model.readiness != .ready { reasons.append("Model is not ready") }
            if model.item.signature == nil || model.item.signature?.isEmpty == true { reasons.append("Model signature unavailable") }
            else if model.item.signature != signature { reasons.append("Model signature changed or missing") }
            if !ComparisonInsights.knownEnvironment(environment) || !ComparisonInsights.knownEnvironment(measuredEnvironment) { reasons.append("Environment unavailable") }
            else if measuredEnvironment != environment { reasons.append("Environment changed") }
            return reasons
        }
        var output: [AgentTaskGuidance] = []
        var seen = Set<String>()
        let orderedRuns = runs.filter { $0.state == .completed }.sorted {
            let left = $0.finishedAt ?? $0.startedAt, right = $1.finishedAt ?? $1.startedAt
            return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
        }
        for run in orderedRuns {
            guard seen.insert("\(run.effectiveMode.rawValue)|\(run.promptSetID)").inserted else { continue }
            let date = run.finishedAt ?? run.startedAt
            let topologyValid = !run.variants.isEmpty && Set(run.variants).count == run.variants.count
                && run.results.count == run.variants.count && Set(run.results.map(\.modelPath)) == Set(run.variants)
            var resultPaths = Set<String>()
            let candidates = run.results.filter { resultPaths.insert($0.modelPath).inserted }.sorted { $0.modelPath < $1.modelPath }.map { result in
                var reasons = identityReasons(path: result.modelPath, signature: result.modelSignature, measuredEnvironment: result.environmentFingerprint)
                if !topologyValid || !ComparisonInsights.fullCohort(result, run: run) { reasons.append("Incomplete or invalid prompt cohort") }
                if result.error != nil || result.samples.contains(where: { $0.error != nil }) { reasons.append("Run contains failed samples") }
                if let model = models.first(where: { $0.item.path == result.modelPath }), !run.effectiveMode.accepts(model.item.task?.type) { reasons.append("Model task does not match this mode") }
                let review = run.qualityReviews?[result.modelPath]
                let quality = review.flatMap { $0.rubricID == ComparisonQualityReview.taskOutcomeRubric && (1...5).contains($0.score) ? $0.score : nil }
                return candidate(path: result.modelPath, id: run.id.uuidString, date: date, quality: quality,
                    performance: ComparisonInsights.positive(run.effectiveMode == .chat ? result.aggregateTokensPerSecond : result.aggregateMetric),
                    latency: run.effectiveMode == .chat ? ComparisonInsights.nonnegative(result.aggregateTTFTSeconds) : nil,
                    samples: result.samples.count, reasons: reasons)
            }
            output.append(make(id: "comparison:\(run.id)", source: "comparison", workload: run.promptSetID, title: run.promptSetName,
                useCase: run.useCase, mode: run.effectiveMode.rawValue, harness: nil, configuration: nil,
                rubric: ComparisonQualityReview.taskOutcomeRubric, date: date, metric: run.effectiveMode.primaryMetric.rawValue,
                higher: run.effectiveMode.primaryMetric.higherIsBetter, candidates: candidates,
                available: ComparisonViewLogic.candidates(from: models, mode: run.effectiveMode).map { $0.item.path }))
        }
        struct Cohort: Hashable {
            let harness: String; let workload: String; let configuration: String?; let samples: Int; let useCase: UseCase?
        }
        let groups = Dictionary(grouping: workflow) { Cohort(harness: $0.harness, workload: $0.workloadID, configuration: $0.configurationFingerprint, samples: $0.sampleCount, useCase: $0.useCase) }
        for (cohort, records) in groups {
            var paths = Set<String>()
            // Pick the newest observation before checking identity: no historical winner fallback.
            let latest = records.sorted { $0.measuredAt == $1.measuredAt ? $0.id.uuidString < $1.id.uuidString : $0.measuredAt > $1.measuredAt }
                .filter { paths.insert($0.modelPath).inserted }
            let rubrics = Set(latest.map { $0.rubricID ?? "" })
            let rubric = rubrics.count == 1 && rubrics.first != "" ? rubrics.first : nil
            let types = Set(latest.compactMap { record in models.first { $0.item.path == record.modelPath }.map { $0.item.task?.type ?? .textLLM } })
            let candidates = latest.sorted { $0.modelPath < $1.modelPath }.map { record in
                var reasons = identityReasons(path: record.modelPath, signature: record.modelSignature, measuredEnvironment: record.environmentFingerprint)
                if (try? record.validate()) == nil { reasons.append("Invalid report") }
                if cohort.configuration == nil { reasons.append("Configuration identity unavailable") }
                if types.count > 1 { reasons.append("Different model task types in this cohort") }
                var value = candidate(path: record.modelPath, id: record.id.uuidString, date: record.measuredAt,
                    quality: record.qualityScore, performance: ComparisonInsights.positive(record.totalSeconds),
                    latency: ComparisonInsights.nonnegative(record.timeToFirstTokenSeconds), samples: record.sampleCount, reasons: reasons)
                value.totalSeconds = record.totalSeconds; value.inferenceSeconds = record.inferenceSeconds
                value.toolSeconds = record.toolSeconds; value.queueSeconds = record.queueSeconds
                return value
            }
            guard let newest = latest.first else { continue }
            output.append(make(id: "workflow:\(newest.id)", source: "workflow", workload: cohort.workload, title: cohort.workload,
                useCase: cohort.useCase, mode: nil, harness: cohort.harness, configuration: cohort.configuration, rubric: rubric,
                date: newest.measuredAt, metric: "totalSeconds", higher: false, candidates: candidates,
                available: models.filter { model in model.readiness == .ready && (cohort.useCase.map { model.capabilities.contains($0) } ?? true) }.map { $0.item.path }))
        }
        return output.sorted { $0.measuredAt == $1.measuredAt ? $0.id < $1.id : $0.measuredAt > $1.measuredAt }
    }

    private static func make(id: String, source: String, workload: String, title: String, useCase: UseCase?, mode: String?, harness: String?, configuration: String?, rubric: String?, date: Date, metric: String, higher: Bool, candidates: [AgentTaskCandidate], available: [String]) -> AgentTaskGuidance {
        let comparable = candidates.filter(\.comparable)
        let canRank = comparable.count >= 2
        let reviewed = canRank && rubric != nil && comparable.allSatisfy { $0.qualityScore != nil }
        func leaders(_ values: [(String, Double)], higher: Bool) -> [String] {
            guard canRank, values.count == comparable.count else { return [] }
            let best = higher ? values.map(\.1).max() : values.map(\.1).min()
            return values.filter { $0.1 == best }.map(\.0).sorted()
        }
        let quality = reviewed ? leaders(comparable.map { ($0.modelPath, Double($0.qualityScore!)) }, higher: true) : []
        let performance = leaders(comparable.compactMap { c in c.performanceValue.map { (c.modelPath, $0) } }, higher: higher)
        let latency = leaders(comparable.compactMap { c in c.firstTokenSeconds.map { (c.modelPath, $0) } }, higher: false)
        let fits = comparable.filter { $0.fitStatus == "fits" }
        let fitQuality = reviewed ? fits.compactMap(\.qualityScore).max() : nil
        let qualityFirst = fitQuality.map { score in fits.filter { $0.qualityScore == score }.map(\.modelPath).sorted() } ?? []
        var missing: [String] = []
        if !canRank { missing.append("At least two comparable models required; no ranking") }
        else {
            if !reviewed { missing.append("Shared human quality reviews required; no quality-first choice") }
            if performance.isEmpty { missing.append("Complete performance measurements required") }
        }
        if fits.isEmpty { missing.append("No comparable model has an estimated fit at captured headroom") }
        if candidates.contains(where: { !$0.comparable }) { missing.append("Excluded observations remain visible with their reasons") }
        return AgentTaskGuidance(id: id, source: source, workloadID: workload, title: title, useCase: useCase, mode: mode, harness: harness,
            configurationFingerprint: configuration, rubricID: rubric, measuredAt: date, performanceMetric: metric, higherIsBetter: higher,
            candidates: candidates, qualityLeaders: quality, performanceLeaders: performance, latencyLeaders: latency,
            qualityFirstFitPaths: qualityFirst, unmeasuredModelPaths: available.filter { path in !candidates.contains { $0.modelPath == path } }.sorted(), needsEvidence: missing)
    }
}
