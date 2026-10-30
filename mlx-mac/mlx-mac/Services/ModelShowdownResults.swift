import Foundation

/// One recorded task cohort. Rankings never combine different runs or workloads.
struct ModelShowdownResults: Identifiable {
    enum ReviewState: Equatable {
        case reviewed
        case needsQualityReview
        case unavailable(String)
    }
    struct Row: Identifiable {
        let id: String
        let path: String
        let name: String
        let qualityScore: Int?
        let tokensPerSecond: Double?
        let speedEstimated: Bool
        let firstTokenSeconds: Double?
        let diskBytes: Int64?
    }

    let run: ComparisonRun
    let rows: [Row]
    let reviewState: ReviewState
    var id: UUID { run.id }
    var isReviewed: Bool { reviewState == .reviewed }
    var supportsReplacement: Bool {
        isReviewed && rows.allSatisfy { $0.tokensPerSecond != nil && $0.firstTokenSeconds != nil }
    }

    var qualityLeaders: Set<String> {
        guard isReviewed, let highest = rows.compactMap(\.qualityScore).max() else { return [] }
        return Set(rows.filter { $0.qualityScore == highest }.map(\.path))
    }
    var speedLeaders: Set<String> {
        guard isReviewed, rows.allSatisfy({ $0.tokensPerSecond != nil }),
              let fastest = rows.compactMap(\.tokensPerSecond).max() else { return [] }
        return Set(rows.filter { $0.tokensPerSecond == fastest }.map(\.path))
    }
    var hasQualitySpeedTradeoff: Bool {
        !qualityLeaders.isEmpty && !speedLeaders.isEmpty && qualityLeaders.isDisjoint(with: speedLeaders)
    }
    var explanation: String {
        switch reviewState {
        case .unavailable(let reason): return reason
        case .needsQualityReview: return "Rate every variant’s task quality in Compare before deciding what to retain."
        case .reviewed:
            if hasQualitySpeedTradeoff { return "Different variants lead on reviewed quality and recorded speed. Keeping separate variants can preserve those strengths for this task." }
            if speedLeaders.isEmpty { return "Quality is reviewed. Timing is incomplete, so no speed winner is shown." }
            if qualityLeaders.count == rows.count && speedLeaders.count == rows.count { return "All entrants tie on reviewed quality and decode speed in this run." }
            return "Compare the reviewed quality, recorded speed and disk size for this task."
        }
    }

    init(run: ComparisonRun, models: [LibraryModel], environment: String?, promptSets: [PromptSet]? = nil) {
        self.run = run
        reviewState = Self.assess(run: run, models: models, environment: environment, promptSets: promptSets)
        if case .unavailable = reviewState { rows = []; return }
        rows = run.results.map { result in
            let model = models.first { $0.item.path == result.modelPath }
            let review = run.qualityReviews?[result.id]
            let score = review.flatMap { $0.rubricID == ComparisonQualityReview.taskOutcomeRubric && (1...5).contains($0.score) ? $0.score : nil }
            return Row(id: result.id, path: result.modelPath, name: model?.displayName ?? result.modelPath,
                qualityScore: score, tokensPerSecond: result.samples.allSatisfy { ComparisonInsights.positive($0.tokensPerSecond) != nil }
                    ? ComparisonInsights.positive(result.aggregateTokensPerSecond) : nil,
                speedEstimated: result.samples.contains { $0.metricsEstimated == true },
                firstTokenSeconds: result.samples.allSatisfy { ComparisonInsights.nonnegative($0.timeToFirstTokenSeconds) != nil }
                    ? ComparisonInsights.nonnegative(result.aggregateTTFTSeconds) : nil,
                diskBytes: model.flatMap { $0.item.bytes > 0 ? $0.item.bytes : nil })
        }
    }

    /// Assess the latest completed default-configuration run for each task before
    /// filtering eligibility, so missing reviews never revive an older winner.
    static func latest(runs: [ComparisonRun], models: [LibraryModel], environment: String?, promptSets: [PromptSet]) -> [Self] {
        var seen = Set<String>()
        return runs.filter { $0.state == .completed && $0.effectiveMode == .chat && !$0.hasCustomServingConfiguration }
            .sorted {
                let left = $0.finishedAt ?? $0.startedAt, right = $1.finishedAt ?? $1.startedAt
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            }.filter { seen.insert($0.promptSetID).inserted }
            .map { Self(run: $0, models: models, environment: environment, promptSets: promptSets) }
    }

    private static func assess(run: ComparisonRun, models: [LibraryModel], environment: String?, promptSets: [PromptSet]?) -> ReviewState {
        guard run.state == .completed, run.effectiveMode == .chat, !run.hasCustomServingConfiguration else {
            return .unavailable("A completed chat comparison with standard serving settings is required.")
        }
        guard run.variants.count >= 2, Set(run.variants).count == run.variants.count,
              run.hasValidLaneIdentities, run.results.count == run.variants.count,
              Set(run.results.map(\.modelPath)) == Set(run.variants),
              Set(run.results.map(\.id)).count == run.results.count,
              Set(run.results.map(\.id)) == Set(run.variantIdentities),
              (run.laneConfigurations ?? []).allSatisfy({ lane in
                  run.results.contains { $0.id == lane.id && $0.modelPath == lane.modelPath && $0.modelSignature == lane.modelSignature }
              }),
              run.results.allSatisfy({ result in models.contains { model in
                  model.readiness == .ready && ComparisonMode.chat.supports(model.item)
                    && ComparisonInsights.valid(result, model: model, environment: environment)
              } && ComparisonInsights.fullCohort(result, run: run) }) else {
            return .unavailable("Model identity, environment or recorded prompt coverage changed or is unavailable. Run a fresh comparison.")
        }
        if let promptSets {
            guard let current = promptSets.first(where: { $0.id == run.promptSetID && $0.effectiveMode == .chat }),
                  current.prompts == run.promptEntries else {
                return .unavailable("The prompt set changed or is unavailable. Open the saved outputs or run a fresh comparison.")
            }
        }
        guard run.results.allSatisfy({ ChatComparisonPresentation.completion($0, in: run).isComplete }) else {
            return .unavailable("Some prompts did not finish with a usable answer or valid tool calls. Review the saved outputs before running again.")
        }
        guard run.results.allSatisfy({ result in
            guard let review = run.qualityReviews?[result.id] else { return false }
            return review.rubricID == ComparisonQualityReview.taskOutcomeRubric && (1...5).contains(review.score)
        }) else { return .needsQualityReview }
        return .reviewed
    }
}
