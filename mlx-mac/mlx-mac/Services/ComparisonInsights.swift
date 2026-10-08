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
                let rubric = run.effectiveMode == .musicGeneration
                    ? ComparisonQualityReview.musicListeningRubric : ComparisonQualityReview.taskOutcomeRubric
                let reviewed = reviews.count == run.results.count && reviews.allSatisfy { $0.rubricID == rubric && (1...5).contains($0.score) }
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
            limitations: ["Compare only the same complete run or matched harness/workload/configuration/rubric cohort.", "Quality is unknown unless explicitly reviewed; no universal best model.", "Fit uses heuristic weights/KV/runtime estimates at captured available memory, not peak measurement. Recheck before serving; headroom changes with other apps and endpoints.", "GPU utilization, disk I/O, CPU load and network attribution: unavailable.", "Task-scoped replacement reviews do not establish global redundancy.", "Guidance is read-only. Quality-first choices use reviewed comparable models with estimated fits; tight or unknown fits require review. No automatic serving, rewiring or removal."], taskTradeoffs: tradeoffs, replacementChains: replacements.compactMap(\.replacement),
            taskGuidance: AgentTaskAdvisor.guidance(models: models, runs: runs, workflow: workflow, environment: environment, hardware: hardware, memory: memory, contextTokens: contextTokens, reserveGB: reserveGB))
    }

    static func supportsFitEstimate(_ model: LibraryModel) -> Bool {
        supportsFitEstimate(task: model.item.task?.type)
    }

    /// An unlabelled task is treated as servable, as Library models are.
    static func supportsFitEstimate(task: ModelTaskType?) -> Bool {
        task?.isServable ?? true
    }

    static func fitEstimate(model: LibraryModel, hardware: HardwareProfile, memory: MemorySnapshot?, contextTokens: Int, reserveGB: Double) -> FitVerdict {
        fitEstimate(bytes: model.item.bytes, parameters: model.item.parameters, task: model.item.task?.type, hardware: hardware, memory: memory, contextTokens: contextTokens, reserveGB: reserveGB)
    }

    /// The fit verdict for a size that is not (yet) a Library model, such as a
    /// conversion's estimated output. Same math and memory rules as the model entry.
    static func fitEstimate(bytes: Int64, parameters: String?, task: ModelTaskType?, hardware: HardwareProfile, memory: MemorySnapshot?, contextTokens: Int, reserveGB: Double) -> FitVerdict {
        guard supportsFitEstimate(task: task) else { return .unknown(reason: "media pipeline memory not modeled") }
        guard let memory else { return .unknown(reason: "live memory unavailable") }
        return FitAdvisor.verdict(modelBytes: bytes, contextTokens: contextTokens, parameters: parameters, hardware: hardware, memory: memory, reserveBytes: Int64(reserveGB * 1_000_000_000))
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
        struct Measurement {
            let model: LibraryModel
            let quality: Int
            let rubric: String
            let speed: Double
            let ttft: Double
            let duration: Double?
            var member: ModelReplacementMember {
                ModelReplacementMember(path: model.item.path, name: model.displayName, diskBytes: model.item.bytes,
                    qualityScore: quality, tokensPerSecond: speed, firstTokenSeconds: ttft)
            }
        }
        func dominates(_ right: Measurement, _ left: Measurement) -> Bool {
            guard right.model.item.path != left.model.item.path, right.rubric == left.rubric,
                  resourcesNoWorse(right.model, left.model), right.quality >= left.quality,
                  right.speed >= left.speed, right.ttft <= left.ttft else { return false }
            if let duration = left.duration {
                guard let other = right.duration, other <= duration else { return false }
            }
            return right.speed >= left.speed * 1.1 || right.ttft < left.ttft * 0.9
                || right.model.item.bytes < Int64(Double(left.model.item.bytes) * 0.9) || right.quality > left.quality
        }
        func addCohort(_ measurements: [Measurement], task: String, source: String) {
            // A keeper has no better replacement in this same cohort. Never stitch separate tasks together.
            let terminal = measurements.filter { candidate in !measurements.contains { dominates($0, candidate) } }.sorted {
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                if $0.speed != $1.speed { return $0.speed > $1.speed }
                if $0.ttft != $1.ttft { return $0.ttft < $1.ttft }
                if $0.model.item.bytes != $1.model.item.bytes { return $0.model.item.bytes < $1.model.item.bytes }
                return $0.model.item.path < $1.model.item.path
            }
            var grouped: [String: [Measurement]] = [:]
            for candidate in measurements where !protected.contains(candidate.model.item.path) {
                if let keeper = terminal.first(where: { dominates($0, candidate) }) {
                    grouped[keeper.model.item.path, default: []].append(candidate)
                }
            }
            for keeper in terminal {
                guard let replaced = grouped[keeper.model.item.path]?.sorted(by: { $0.model.item.path < $1.model.item.path }) else { continue }
                let chain = ModelReplacementChain(keeper: keeper.member, replaced: replaced.map(\.member), task: task, source: source)
                found.append(ReclaimOpportunity(kind: .supersededVariant, paths: replaced.map { $0.model.item.path },
                    bytes: replaced.reduce(0) { $0 + $1.model.item.bytes },
                    evidence: "Keep \(keeper.model.displayName): no worse reviewed quality, speed, first-token latency, estimated memory and disk for \(task) (\(source)). Review other tasks before removing \(replaced.count) replaced model(s).",
                    confidence: .review, actionable: false, replacement: chain))
            }
        }
        var seenRuns = Set<String>()
        for run in runs.sorted(by: { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }) where run.state == .completed && run.effectiveMode == .chat {
            // Newer results for a prompt set supersede its older advice, including incomplete reviews.
            guard seenRuns.insert(run.promptSetID).inserted else { continue }
            let measurements = models.compactMap { model -> Measurement? in
                guard let result = run.results.first(where: { valid($0, model: model, environment: environment) }), fullCohort(result, run: run),
                      let quality = run.qualityReviews?[model.item.path], (1...5).contains(quality.score), !quality.rubricID.isEmpty,
                      let speed = positive(result.aggregateTokensPerSecond), let ttft = nonnegative(result.aggregateTTFTSeconds) else { return nil }
                return Measurement(model: model, quality: quality.score, rubric: quality.rubricID, speed: speed, ttft: ttft, duration: nil)
            }
            addCohort(measurements, task: run.promptSetName, source: "run \(run.id)")
        }
        // Structured keys prevent accidentally matching delimiter-containing workload names.
        struct WorkflowCohort: Hashable {
            let harness: String
            let workload: String
            let configuration: String
            let rubric: String
            let samples: Int
            let useCase: UseCase?
        }
        var cohorts: [WorkflowCohort: [WorkflowEvidence]] = [:]
        for record in workflow where record.environmentFingerprint == environment {
            guard (try? record.validate()) != nil, let rubric = record.rubricID, let configuration = record.configurationFingerprint else { continue }
            let key = WorkflowCohort(harness: record.harness, workload: record.workloadID, configuration: configuration,
                rubric: rubric, samples: record.sampleCount, useCase: record.useCase)
            cohorts[key, default: []].append(record)
        }
        for records in cohorts.values.sorted(by: { ($0.map(\.measuredAt).max() ?? .distantPast) > ($1.map(\.measuredAt).max() ?? .distantPast) }) {
            var seenPaths = Set<String>()
            let current = records.sorted { $0.measuredAt > $1.measuredAt }.filter { seenPaths.insert($0.modelPath).inserted }
            let measurements = current.compactMap { record -> Measurement? in
                guard let model = models.first(where: { $0.item.path == record.modelPath && $0.item.signature == record.modelSignature }),
                      let quality = record.qualityScore, let rubric = record.rubricID,
                      let speed = positive(record.tokensPerSecond), let ttft = nonnegative(record.timeToFirstTokenSeconds) else { return nil }
                return Measurement(model: model, quality: quality, rubric: rubric, speed: speed, ttft: ttft, duration: record.totalSeconds)
            }
            if let first = current.first {
                addCohort(measurements, task: "\(first.harness) · \(first.workloadID)", source: current.map(\.source).sorted().joined(separator: ", "))
            }
        }
        return found
    }
}
