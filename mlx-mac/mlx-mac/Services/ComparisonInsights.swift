import Foundation

enum ComparisonInsights {
    struct Champions: Identifiable {
        let run: ComparisonRun
        let performance: [VariantResult]
        let quality: [VariantResult]
        let latency: [VariantResult]
        var id: UUID { run.id }
    }

    /// Awards are scoped to the latest complete workload cohort on this Mac.
    /// Every entrant must still be available with the measured identity.
    static func champions(models: [LibraryModel], runs: [ComparisonRun], environment: String?) -> [Champions] {
        guard knownEnvironment(environment) else { return [] }
        var seen: Set<String> = []
        return runs.filter { $0.state == .completed }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
            .compactMap { run in
                guard seen.insert("\(run.effectiveMode.rawValue)|\(run.promptSetID)").inserted,
                      run.variants.count >= 2, Set(run.variants).count == run.variants.count,
                      run.results.count == run.variants.count,
                      Set(run.results.map(\.modelPath)) == Set(run.variants) else { return nil }
                let candidates = ComparisonViewLogic.candidates(from: models, mode: run.effectiveMode)
                guard run.results.allSatisfy({ result in
                    fullCohort(result, run: run) && candidates.contains { valid(result, model: $0, environment: environment) }
                }) else { return nil }
                let metric = run.effectiveMode.primaryMetric
                let values = run.results.compactMap { positive(run.effectiveMode == .chat ? $0.aggregateTokensPerSecond : $0.aggregateMetric) }
                let best = metric.higherIsBetter ? values.max() : values.min()
                let performance = values.count == run.results.count ? run.results.filter {
                    (run.effectiveMode == .chat ? $0.aggregateTokensPerSecond : $0.aggregateMetric) == best
                } : []
                let reviews = run.results.compactMap { run.qualityReviews?[$0.modelPath] }
                let reviewed = reviews.count == run.results.count && reviews.allSatisfy { $0.rubricID == ComparisonQualityReview.taskOutcomeRubric && (1...5).contains($0.score) }
                let quality = reviewed ? run.results.filter { run.qualityReviews?[$0.modelPath]?.score == reviews.map(\.score).max() } : []
                let latencies = run.results.compactMap { nonnegative($0.aggregateTTFTSeconds) }
                let latency = run.effectiveMode == .chat && latencies.count == run.results.count ? run.results.filter { $0.aggregateTTFTSeconds == latencies.min() } : []
                guard !performance.isEmpty || !quality.isEmpty || !latency.isEmpty else { return nil }
                return Champions(run: run, performance: performance, quality: quality, latency: latency)
            }
    }

    static func agentEvidence(models: [LibraryModel], runs: [ComparisonRun], workflow: [WorkflowEvidence], environment: String?, hardware: HardwareProfile, memory: MemorySnapshot?, capturedAt: Date?, contextTokens: Int, reserveGB: Double, protected: Set<String>, exportedAt: Date = Date()) -> AgentEvidenceExport {
        let facts = runs.filter { $0.state == .completed }.flatMap { run in
            run.results.map { result in
                let current = fullCohort(result, run: run) && models.contains { valid(result, model: $0, environment: environment) }
                return AgentComparisonFact(runID: run.id, workloadID: run.promptSetID, promptSetName: run.promptSetName,
                    useCase: run.useCase, mode: run.effectiveMode.rawValue, measuredAt: run.finishedAt ?? run.startedAt,
                    modelPath: result.modelPath, modelSignature: result.modelSignature, environmentFingerprint: result.environmentFingerprint,
                    sampleCount: result.samples.count, successfulSamples: result.samples.filter { $0.error == nil }.count,
                    tokensPerSecond: positive(result.aggregateTokensPerSecond), timeToFirstTokenSeconds: nonnegative(result.aggregateTTFTSeconds),
                    quality: run.qualityReviews?[result.modelPath], limitedValidation: limitedValidation(result), current: current,
                    aggregateMetric: positive(result.aggregateMetric), primaryMetric: run.effectiveMode.primaryMetric.rawValue,
                    evidenceStatus: current ? "Current identity/environment and full prompt cohort" : "Historical, incomplete cohort, missing identity or changed environment; exclude from current comparisons",
                    samplePeakMemoryGB: result.samples.compactMap(\.peakMemoryGB).compactMap { nonnegative($0) }.max())
            }
        }
        let modelFacts = models.map { model in
            let estimate = fitEstimate(model: model, hardware: hardware, memory: memory, contextTokens: contextTokens, reserveGB: reserveGB)
            return AgentModelFact(path: model.item.path, signature: model.item.signature, name: model.displayName, tasks: model.capabilities,
                diskBytes: model.item.bytes, readiness: model.readiness.rawValue, fitEstimate: estimate.summary,
                estimatedRequiredBytes: supportsFitEstimate(model) && model.item.bytes > 0 ? FitAdvisor.neededBytes(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters) : nil,
                protected: protected.contains(model.item.path))
        }
        let replacements = superseded(models: models, runs: runs, workflow: workflow, environment: environment, protected: protected, contextTokens: contextTokens)
        let tradeoffs = taskTradeoffs(models: models, runs: runs, environment: environment)
        return AgentEvidenceExport(schemaVersion: 1, exportedAt: exportedAt, hardware: hardware, environmentFingerprint: environment,
            memoryCapturedAt: capturedAt, availableMemoryBytes: memory?.availableBytes, contextTokens: contextTokens, reserveGB: reserveGB,
            models: modelFacts, comparisons: facts, workflowReports: workflow, replacementReviews: replacements.map(\.evidence),
            limitations: ["Compare only the same complete run or matched harness/workload/configuration/rubric cohort.", "Quality is unknown unless explicitly reviewed; no universal best model.", "Fit uses heuristic weights/KV/runtime estimates at captured available memory, not peak measurement.", "GPU utilization, disk I/O, CPU load and network attribution: unavailable.", "Task-scoped replacement reviews do not establish global redundancy."], taskTradeoffs: tradeoffs)
    }

    static func supportsFitEstimate(_ model: LibraryModel) -> Bool {
        model.item.task?.type.isServable ?? true
    }

    static func fitEstimate(model: LibraryModel, hardware: HardwareProfile, memory: MemorySnapshot?, contextTokens: Int, reserveGB: Double) -> FitVerdict {
        guard supportsFitEstimate(model) else { return .unknown(reason: "media pipeline memory not modeled") }
        guard let memory else { return .unknown(reason: "live memory unavailable") }
        return FitAdvisor.verdict(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters, hardware: hardware, memory: memory, reserveBytes: Int64(reserveGB * 1_000_000_000))
    }

    static func limitedValidation(_ result: VariantResult) -> String {
        var facts: [String] = []
        if let calls = result.totalToolCalls, let valid = result.totalToolCallsValid { facts.append("\(valid)/\(calls) tool calls with usable arguments") }
        let keywords = result.samples.compactMap(\.keywordsMatched)
        if !keywords.isEmpty { facts.append("\(keywords.filter { $0 }.count)/\(keywords.count) keyword checks passed") }
        let wer = result.samples.compactMap(\.wordErrorRate).filter(\.isFinite)
        if !wer.isEmpty { facts.append(String(format: "%.1f%% mean word error", wer.reduce(0, +) / Double(wer.count) * 100)) }
        return facts.isEmpty ? "Task validation unknown; inspect outputs and review task outcome." : "Limited validation: " + facts.joined(separator: " · ")
    }

    static func taskTradeoffs(models: [LibraryModel], runs: [ComparisonRun], environment: String?) -> [String] {
        runs.filter { $0.state == .completed }.compactMap { run in
            let results = run.results.filter { result in fullCohort(result, run: run) && models.contains { valid(result, model: $0, environment: environment) } }
            guard results.count >= 2 else { return nil }
            let reviewed = results.compactMap { result -> (String, Int)? in
                guard let review = run.qualityReviews?[result.modelPath], review.rubricID == ComparisonQualityReview.taskOutcomeRubric else { return nil }
                return (result.modelPath, review.score)
            }
            guard reviewed.count == results.count, let quality = reviewed.max(by: { $0.1 < $1.1 }) else {
                return "\(run.promptSetName), run \(run.id): quality ranking unavailable; review every variant before preferring speed over task outcome. Check fit at intended context."
            }
            let metric = run.effectiveMode.primaryMetric
            let measured = results.compactMap { result -> (String, Double)? in
                positive(run.effectiveMode == .chat ? result.aggregateTokensPerSecond : result.aggregateMetric).map { (result.modelPath, $0) }
            }
            let fastest = measured.sorted { metric.higherIsBetter ? $0.1 > $1.1 : $0.1 < $1.1 }.first
            return "\(run.promptSetName), run \(run.id): highest reviewed task outcome \(quality.0) (\(quality.1)/5); best measured \(metric.title) \(fastest?.0 ?? "unknown"). Choose the quality/speed tradeoff after checking context fit and disk. Review ties; this is task-scoped evidence."
        }
    }
    static func reconcile(slots: [String?], available: Set<String>) -> [String?] {
        slots.map { path in path.flatMap { available.contains($0) ? $0 : nil } }
    }

    static func knownEnvironment(_ environment: String?) -> Bool {
        guard let environment, !environment.isEmpty else { return false }
        return !environment.lowercased().split(separator: "|").contains { $0.contains("unknown") }
    }
    struct Selection: Equatable {
        let paths: [String?]
        let reason: String
    }

    static func valid(_ result: VariantResult, model: LibraryModel, environment: String?) -> Bool {
        guard let signature = model.item.signature, !signature.isEmpty,
              let environment, knownEnvironment(environment) else { return false }
        return result.modelPath == model.item.path && result.modelSignature == signature
            && result.environmentFingerprint == environment && result.error == nil
            && !result.samples.isEmpty && result.samples.allSatisfy { $0.error == nil }
    }

    static func fullCohort(_ result: VariantResult, run: ComparisonRun) -> Bool {
        guard let prompts = run.promptEntries, !prompts.isEmpty,
              Set(prompts.map(\.id)).count == prompts.count else { return false }
        return result.samples.count == prompts.count && Set(result.samples.map(\.promptID)) == Set(prompts.map(\.id))
    }

    static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    static func nonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    static func suggestion(candidates: [LibraryModel], lastServed: [String: Date], selectedPath: String?, runs: [ComparisonRun], mode: ComparisonMode, environment: String?, promptSetID: String? = nil) -> Selection {
        let ordered = candidates.sorted { $0.item.path < $1.item.path }
        guard !ordered.isEmpty else { return Selection(paths: [nil, nil], reason: "Waiting for eligible Library models.") }
        func match(_ path: String?) -> LibraryModel? {
            ordered.first { $0.item.path == path || $0.outputPaths.contains(path ?? "") }
        }
        let served = lastServed.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.compactMap { match($0.key) }.first
        let prior = runs.filter { $0.effectiveMode == mode }.sorted { $0.startedAt > $1.startedAt }.flatMap(\.variants).compactMap { match($0) }.first
        let anchor = served ?? match(selectedPath) ?? prior ?? ordered[0]
        let source = served != nil ? "Last intentionally served model" : match(selectedPath) != nil ? "Library selection" : prior != nil ? "Last comparison model" : "First eligible model"
        // Distance is evaluated only within one completed run, never across prompt cohorts.
        let cohort = runs.filter { $0.state == .completed && $0.effectiveMode == mode && (promptSetID == nil || $0.promptSetID == promptSetID) }.sorted { $0.startedAt > $1.startedAt }.first { run in
            run.results.contains { fullCohort($0, run: run) && valid($0, model: anchor, environment: environment) && positive(mode == .chat ? $0.aggregateTokensPerSecond : $0.aggregateMetric) != nil && (mode != .chat || nonnegative($0.aggregateTTFTSeconds) != nil) }
        }
        var ranked: [(LibraryModel, Double)] = []
        if let cohort, let baseline = cohort.results.first(where: { valid($0, model: anchor, environment: environment) }),
           let speed = positive(mode == .chat ? baseline.aggregateTokensPerSecond : baseline.aggregateMetric) {
            for model in ordered where model.item.path != anchor.item.path {
                guard let result = cohort.results.first(where: { valid($0, model: model, environment: environment) }),
                      fullCohort(result, run: cohort),
                      Set(result.samples.map(\.promptID)) == Set(baseline.samples.map(\.promptID)),
                      let otherSpeed = positive(mode == .chat ? result.aggregateTokensPerSecond : result.aggregateMetric) else { continue }
                var distance = abs(log(otherSpeed / speed))
                if mode == .chat {
                    guard let ttft = nonnegative(baseline.aggregateTTFTSeconds), let otherTTFT = nonnegative(result.aggregateTTFTSeconds) else { continue }
                    distance += abs(log((otherTTFT + 0.001) / (ttft + 0.001)))
                }
                ranked.append((model, distance))
            }
        }
        let measured = ranked.sorted { $0.1 == $1.1 ? $0.0.item.path < $1.0.item.path : $0.1 < $1.1 }.map { $0.0 }
        let measuredPaths = Set(measured.map { $0.item.path })
        let fallback = ordered.filter { $0.item.path != anchor.item.path && !measuredPaths.contains($0.item.path) }.sorted {
            let leftSibling = $0.normalizedFamilyKey == anchor.normalizedFamilyKey
            let rightSibling = $1.normalizedFamilyKey == anchor.normalizedFamilyKey
            if leftSibling != rightSibling { return leftSibling }
            let left = abs(Double($0.item.bytes) - Double(anchor.item.bytes))
            let right = abs(Double($1.item.bytes) - Double(anchor.item.bytes))
            return left == right ? $0.item.path < $1.item.path : left < right
        }
        var paths: [String?] = [anchor.item.path] + (measured + fallback).prefix(3).map { Optional($0.item.path) }
        if paths.count == 1 { paths.append(nil) }
        let explanation = measured.isEmpty ? "Alternatives are unmeasured suggestions by family and disk size." : "Nearest speed/first-token alternatives use the same local run; any remaining slots are unmeasured suggestions."
        return Selection(paths: paths, reason: "\(source). \(explanation)")
    }

    static func currentResult(model: LibraryModel, runs: [ComparisonRun], environment: String?, promptSetID: String) -> (ComparisonRun, VariantResult)? {
        for run in runs.sorted(by: { $0.startedAt > $1.startedAt }) where run.state == .completed && run.promptSetID == promptSetID {
            if let result = run.results.first(where: { fullCohort($0, run: run) && valid($0, model: model, environment: environment) }) { return (run, result) }
        }
        return nil
    }

    /// Dominance is task-scoped and needs explicit reviewed quality, not quantization.
    static func superseded(models: [LibraryModel], runs: [ComparisonRun], workflow: [WorkflowEvidence], environment: String?, protected: Set<String>, contextTokens: Int = 8192) -> [ReclaimOpportunity] {
        guard let environment, knownEnvironment(environment) else { return [] }
        var found: [ReclaimOpportunity] = []
        func resourcesNoWorse(_ replacement: LibraryModel, _ candidate: LibraryModel) -> Bool {
            let candidateTask = candidate.item.task?.type ?? .textLLM
            let replacementTask = replacement.item.task?.type ?? .textLLM
            guard supportsFitEstimate(candidate), supportsFitEstimate(replacement),
                  replacement.readiness == .ready, candidateTask != .other, replacementTask == candidateTask,
                  replacement.item.bytes > 0, candidate.item.bytes > 0,
                  FitAdvisor.parameterBillions(replacement.item.parameters) != nil,
                  FitAdvisor.parameterBillions(candidate.item.parameters) != nil else { return false }
            return replacement.item.bytes <= candidate.item.bytes && FitAdvisor.neededBytes(modelBytes: replacement.item.bytes, contextTokens: contextTokens, parameters: replacement.item.parameters) <= FitAdvisor.neededBytes(modelBytes: candidate.item.bytes, contextTokens: contextTokens, parameters: candidate.item.parameters)
        }
        func add(_ candidate: LibraryModel, _ replacement: LibraryModel, task: String, source: String) {
            guard !protected.contains(candidate.item.path), !found.contains(where: { $0.paths.contains(candidate.item.path) }) else { return }
            found.append(ReclaimOpportunity(kind: .supersededVariant, paths: [candidate.item.path], bytes: candidate.item.bytes, evidence: "Task-scoped review: \(replacement.displayName) is no worse on reviewed quality, speed, first-token latency, estimated memory and disk for \(task) (\(source)). Other tasks may still need this model; review before reclaiming.", confidence: .review, actionable: false))
        }
        for run in runs where run.state == .completed && run.effectiveMode == .chat {
            guard let prompts = run.promptEntries, !prompts.isEmpty, Set(prompts.map(\.id)).count == prompts.count else { continue }
            for candidate in models {
                guard let left = run.results.first(where: { valid($0, model: candidate, environment: environment) }),
                      left.samples.count == prompts.count, Set(left.samples.map(\.promptID)) == Set(prompts.map(\.id)),
                      let quality = run.qualityReviews?[candidate.item.path], (1...5).contains(quality.score),
                      let speed = positive(left.aggregateTokensPerSecond), let ttft = nonnegative(left.aggregateTTFTSeconds) else { continue }
                for replacement in models where replacement.item.path != candidate.item.path && resourcesNoWorse(replacement, candidate) {
                    guard let right = run.results.first(where: { valid($0, model: replacement, environment: environment) }), right.samples.count == prompts.count,
                          Set(right.samples.map(\.promptID)) == Set(prompts.map(\.id)),
                          let otherQuality = run.qualityReviews?[replacement.item.path], otherQuality.rubricID == quality.rubricID, otherQuality.score >= quality.score,
                          let otherSpeed = positive(right.aggregateTokensPerSecond), otherSpeed >= speed,
                          let otherTTFT = nonnegative(right.aggregateTTFTSeconds), otherTTFT <= ttft,
                          otherSpeed >= speed * 1.1 || otherTTFT < ttft * 0.9 || replacement.item.bytes < Int64(Double(candidate.item.bytes) * 0.9) || otherQuality.score > quality.score else { continue }
                    add(candidate, replacement, task: run.promptSetName, source: "run \(run.id)")
                }
            }
        }
        for left in workflow where left.environmentFingerprint == environment {
            guard let candidate = models.first(where: { $0.item.path == left.modelPath && $0.item.signature == left.modelSignature }), let quality = left.qualityScore,
                  let speed = positive(left.tokensPerSecond), let ttft = nonnegative(left.timeToFirstTokenSeconds),
                  let rubric = left.rubricID, let configuration = left.configurationFingerprint, !configuration.isEmpty else { continue }
            for right in workflow where right.modelPath != left.modelPath && right.environmentFingerprint == environment && right.workloadID == left.workloadID && right.harness == left.harness && right.rubricID == rubric && right.configurationFingerprint == configuration && right.sampleCount == left.sampleCount && right.useCase == left.useCase {
                guard let replacement = models.first(where: { $0.item.path == right.modelPath && $0.item.signature == right.modelSignature }), resourcesNoWorse(replacement, candidate),
                      let otherQuality = right.qualityScore, otherQuality >= quality,
                      let otherSpeed = positive(right.tokensPerSecond), otherSpeed >= speed,
                      let otherTTFT = nonnegative(right.timeToFirstTokenSeconds), otherTTFT <= ttft,
                      right.totalSeconds <= left.totalSeconds,
                      otherSpeed >= speed * 1.1 || otherTTFT < ttft * 0.9 || replacement.item.bytes < Int64(Double(candidate.item.bytes) * 0.9) || otherQuality > quality else { continue }
                add(candidate, replacement, task: left.workloadID, source: "\(left.source), \(right.source)")
            }
        }
        return found
    }
}
