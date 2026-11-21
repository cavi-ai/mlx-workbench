import Foundation

/// How useful a classification prompt set is: how much of it is scored, which options it never
/// expects, and how the models that ran it did.
struct ClassificationSetHealth: Equatable {
    struct UnusedOption: Equatable {
        let question: String
        let option: String
    }

    struct ModelAccuracy: Equatable, Identifiable {
        let id: String
        let name: String
        /// Completed runs of this set that included the model.
        let runs: Int
        /// Latest run: share of expected answers matched.
        let accuracy: Double?
        let correct: Int
        let scored: Int
        let measuredAt: Date
    }

    let entries: Int
    /// Question instances across all entries.
    let questions: Int
    let scoredQuestions: Int
    let unusedOptions: [UnusedOption]
    /// Newest latest run first.
    let models: [ModelAccuracy]

    var unscoredQuestions: Int { questions - scoredQuestions }
    var scoredShare: Double? { questions > 0 ? Double(scoredQuestions) / Double(questions) : nil }

    var warnings: [String] {
        var result: [String] = []
        if unscoredQuestions > 0 {
            result.append("\(unscoredQuestions) question\(unscoredQuestions == 1 ? " has" : "s have") no expected answer")
        }
        result += unusedOptions.map { "Option \($0.option) of question \($0.question) is never the expected answer" }
        if models.count >= 2, models.allSatisfy({ $0.accuracy == 1 }) {
            result.append("Every model that ran this set matched all expected answers")
        }
        return result
    }

    var summary: String {
        let share = scoredShare.map { " · \(Int(($0 * 100).rounded()))% scored" } ?? ""
        return "\(entries) \(entries == 1 ? "state" : "states") · \(scoredQuestions) of \(questions) questions have an expected answer\(share)"
    }

    /// `laneName` turns a recorded lane id into the name shown to the reader.
    init(set: PromptSet, runs: [ComparisonRun], laneName: (String) -> String = { $0 }) {
        let asked = set.prompts.flatMap { $0.decisionQuestions ?? [] }
        entries = set.prompts.count
        questions = asked.count
        scoredQuestions = asked.filter { $0.expected != nil }.count

        var unused: [UnusedOption] = []
        var seen: Set<String> = []
        for question in asked where question.kind != .noul && seen.insert(question.name).inserted {
            let expected = Set(asked.filter { $0.name == question.name }.compactMap(\.expected))
            for (index, option) in question.options.enumerated() {
                let key = question.kind == .score ? String(index) : option.label
                if !expected.contains(key) { unused.append(UnusedOption(question: question.name, option: option.label)) }
            }
        }
        unusedOptions = unused

        let completed = runs.filter { $0.promptSetID == set.id && $0.state == .completed && $0.effectiveMode == .classification }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        var latest: [String: ModelAccuracy] = [:]
        var counts: [String: Int] = [:]
        var order: [String] = []
        for run in completed {
            for result in run.results where result.error == nil {
                let evidence = result.samples.filter { $0.error == nil }.compactMap(\.decision)
                let scored = evidence.map(\.scoredCount).reduce(0, +)
                guard scored > 0 else { continue }
                let correct = evidence.map(\.correctCount).reduce(0, +)
                counts[result.id, default: 0] += 1
                if latest[result.id] == nil {
                    order.append(result.id)
                    latest[result.id] = ModelAccuracy(id: result.id, name: laneName(result.modelPath), runs: 0,
                                                      accuracy: Double(correct) / Double(scored), correct: correct, scored: scored,
                                                      measuredAt: run.finishedAt ?? run.startedAt)
                }
            }
        }
        models = order.compactMap { id in
            latest[id].map { ModelAccuracy(id: $0.id, name: $0.name, runs: counts[id] ?? 1, accuracy: $0.accuracy,
                                           correct: $0.correct, scored: $0.scored, measuredAt: $0.measuredAt) }
        }
    }
}

/// Classification sets and their health. Compare and the inspector both read this list.
enum ClassificationSets {
    static let builtin = (BuiltinPromptSets.all + ComparisonMediaFixtures.all)
        .filter { $0.origin == .builtin && $0.effectiveMode == .classification }

    /// Built-in classification sets first, then saved sets that are not already built in.
    static func sets(_ promptSets: [PromptSet]) -> [PromptSet] {
        let builtinIDs = Set(builtin.map(\.id))
        return builtin + promptSets.filter {
            $0.origin == .userCreated && $0.effectiveMode == .classification && !builtinIDs.contains($0.id)
        }
    }

    static func health(set: PromptSet, runs: [ComparisonRun], laneName: (String) -> String = { $0 }) -> ClassificationSetHealth {
        ClassificationSetHealth(set: set, runs: runs, laneName: laneName)
    }

    /// One line naming an entry in the entry picker.
    static func title(_ entry: PromptEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
