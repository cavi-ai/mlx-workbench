import Foundation

// MARK: - Classification comparisons
//
// A classification prompt is a state (the prompt text) and typed questions with
// the answer that counts as correct. Every lane receives the same System One
// request: native models through `convert decide`, System One servers through
// `POST /v1/systemone`. Grading compares each returned answer with the expected one.

/// One typed question about a classification prompt's state.
struct DecisionQuestion: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case choice, score, noul
        var id: String { rawValue }
        var title: String {
            switch self {
            case .choice: "Choice"
            case .score: "Score"
            case .noul: "True or false"
            }
        }
    }

    /// A choice option (label and optional description) or a score level (its description, lowest first).
    struct Option: Codable, Equatable, Sendable {
        var label: String
        var detail: String? = nil
    }

    var name: String
    var kind: Kind
    var instructions: String
    /// Choice: options in request order. Score: levels, lowest first. Unused for true or false.
    var options: [Option] = []
    /// True or false: optional descriptions of each outcome.
    var trueText: String? = nil
    var falseText: String? = nil
    /// Choice: an option label. Score: a level index. True or false: "true" or "false". Nil leaves the question unscored.
    var expected: String? = nil

    var id: String { name }

    static let maximumQuestions = 32
    static let maximumOptions = 255

    /// The expected answer as a reader sees it.
    var expectedTitle: String? {
        guard let expected else { return nil }
        return answerTitle(expected)
    }

    func answerTitle(_ answer: String) -> String {
        switch kind {
        case .choice: return answer
        case .score:
            guard let index = Int(answer), options.indices.contains(index) else { return "level \(answer)" }
            return "\(index) · \(options[index].label)"
        case .noul: return answer == "true" ? "True" : "False"
        }
    }

    var validationError: String? {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label == name, name.count <= 64, !Self.hasControlCharacters(name) else {
            return "Question names need 1–64 characters without surrounding spaces or control characters."
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.hasControlCharacters(instructions) else {
            return "Question \(name) needs instructions."
        }
        switch kind {
        case .choice, .score:
            let minimum = kind == .choice ? "two option labels" : "two level descriptions"
            guard (2...Self.maximumOptions).contains(options.count),
                  options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !Self.hasControlCharacters($0.label)
                      && !Self.hasControlCharacters($0.detail ?? "") }) else {
                return "Question \(name) needs at least \(minimum)."
            }
            if kind == .choice, Set(options.map(\.label)).count != options.count { return "Question \(name) repeats an option label." }
            if kind == .score, options.contains(where: { $0.detail != nil }) { return "Score question \(name) takes level descriptions only." }
        case .noul:
            guard options.isEmpty else { return "True-or-false question \(name) takes no option labels." }
            guard !Self.hasControlCharacters(trueText ?? ""), !Self.hasControlCharacters(falseText ?? "") else {
                return "Question \(name) has control characters in an outcome description."
            }
        }
        if let expected {
            switch kind {
            case .choice where !options.map(\.label).contains(expected):
                return "Question \(name) expects an answer that is not one of its options."
            case .score where Int(expected).map({ !options.indices.contains($0) }) ?? true:
                return "Question \(name) expects a level outside 0–\(options.count - 1)."
            case .noul where expected != "true" && expected != "false":
                return "Question \(name) expects true or false."
            default: break
            }
        }
        return nil
    }

    static func validationError(_ questions: [DecisionQuestion]) -> String? {
        guard (1...maximumQuestions).contains(questions.count) else { return "Add 1–\(maximumQuestions) questions." }
        guard Set(questions.map(\.name)).count == questions.count else { return "Question names must be unique." }
        return questions.lazy.compactMap(\.validationError).first
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" }
    }
}

/// The System One request body, written in question and option order so every lane sees the same options in the same order.
enum DecisionRequest {
    /// `model` names the served model for System One servers; `convert decide` takes none.
    static func body(state: String, questions: [DecisionQuestion], model: String? = nil) throws -> Data {
        guard DecisionQuestion.validationError(questions) == nil else {
            throw HostedIntegrationError.invalid("This prompt's classification questions are invalid.")
        }
        var fields: [(String, OrderedJSON)] = []
        if let model { fields.append(("model", .string(model))) }
        fields.append(("state", .string(state)))
        fields.append(("questions", .object(questions.map { ($0.name, definition($0)) })))
        return Data(OrderedJSON.object(fields).encoded().utf8)
    }

    private static func definition(_ question: DecisionQuestion) -> OrderedJSON {
        var fields: [(String, OrderedJSON)] = [("type", .string(question.kind.rawValue)), ("instructions", .string(question.instructions))]
        switch question.kind {
        case .choice:
            // Object criteria are accepted by every System One implementation; list criteria are not.
            fields.append(("criteria", .object(question.options.map { option in
                let detail = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (option.label, detail.isEmpty ? .null : .string(detail))
            })))
        case .score:
            fields.append(("criteria", .array(question.options.map { .string($0.label) })))
        case .noul:
            var criteria: [(String, OrderedJSON)] = []
            if let text = question.trueText, !text.isEmpty { criteria.append(("true", .string(text))) }
            if let text = question.falseText, !text.isEmpty { criteria.append(("false", .string(text))) }
            if !criteria.isEmpty { fields.append(("criteria", .object(criteria))) }
        }
        return .object(fields)
    }
}

/// JSON with caller-defined key order; Foundation's serializers do not preserve it.
indirect enum OrderedJSON {
    case string(String), null, array([OrderedJSON]), object([(String, OrderedJSON)])

    func encoded() -> String {
        switch self {
        case .string(let value): return Self.quoted(value)
        case .null: return "null"
        case .array(let values): return "[" + values.map { $0.encoded() }.joined(separator: ",") + "]"
        case .object(let fields): return "{" + fields.map { Self.quoted($0.0) + ":" + $0.1.encoded() }.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// One graded answer. Probabilities are the model's reported values; nothing is recalibrated.
struct DecisionGrade: Codable, Equatable, Sendable {
    let question: String
    let kind: DecisionQuestion.Kind
    /// Choice: the chosen label. Score: the most likely level index. True or false: "true" or "false". Nil when unanswered.
    let answer: String?
    /// Probability of `answer`: the chosen option, the most likely level, or the reported reading.
    let probability: Double?
    /// Score questions: the reported expected level.
    let score: Double?
    let expected: String?
    /// Probability the model assigned to the expected answer.
    let expectedProbability: Double?
    /// Nil for unscored questions.
    let correct: Bool?
}

struct DecisionEvidence: Codable, Equatable, Sendable {
    let grades: [DecisionGrade]

    var scoredCount: Int { grades.filter { $0.correct != nil }.count }
    var correctCount: Int { grades.filter { $0.correct == true }.count }
    var accuracy: Double? { scoredCount > 0 ? Double(correctCount) / Double(scoredCount) : nil }
    var meanExpectedProbability: Double? {
        let values = grades.filter { $0.correct != nil }.compactMap(\.expectedProbability)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func summary(questions: [DecisionQuestion]) -> String {
        grades.map { grade in
            let question = questions.first { $0.name == grade.question }
            let answer = grade.answer.map { question?.answerTitle($0) ?? $0 } ?? "no answer"
            let mark = grade.correct.map { $0 ? " ✓" : " ✗" } ?? ""
            return "\(grade.question): \(answer)\(mark)"
        }.joined(separator: " · ")
    }
}

/// One completed classification run a model answered in: its accuracy beside every other lane's.
struct ClassificationResultRecord: Equatable, Identifiable {
    struct Lane: Equatable {
        let name: String
        let accuracy: Double?
        let correct: Int
        let scored: Int
    }

    let runID: UUID
    let promptSetName: String
    let measuredAt: Date
    /// The run came from Hosted & mixed; its lanes may include System One hosts.
    let hosted: Bool
    let model: Lane
    let others: [Lane]
    var id: UUID { runID }

    /// Newest first. Lanes match the model's paths, and its signature when both sides recorded one.
    static func records(modelPaths: [String], signature: String?, localRuns: [ComparisonRun],
                        hostedRecords: [HostedComparisonRecord]) -> [ClassificationResultRecord] {
        let paths = Set(modelPaths)
        func matches(_ path: String?, _ recorded: String?) -> Bool {
            guard let path, paths.contains(path) else { return false }
            return signature == nil || recorded == nil || recorded == signature
        }
        func lane(_ result: VariantResult, name: String) -> Lane {
            let evidence = result.samples.filter { $0.error == nil }.compactMap(\.decision)
            return Lane(name: name, accuracy: result.aggregateMetric.flatMap { (0...1).contains($0) ? $0 : nil },
                        correct: evidence.map(\.correctCount).reduce(0, +), scored: evidence.map(\.scoredCount).reduce(0, +))
        }
        func completed(_ run: ComparisonRun) -> Bool { run.state == .completed && run.effectiveMode == .classification }

        var records: [ClassificationResultRecord] = []
        for run in localRuns where completed(run) {
            guard let own = run.results.first(where: { $0.error == nil && matches($0.modelPath, $0.modelSignature) }) else { continue }
            records.append(ClassificationResultRecord(
                runID: run.id, promptSetName: run.promptSetName, measuredAt: run.finishedAt ?? run.startedAt, hosted: false,
                model: lane(own, name: URL(fileURLWithPath: own.modelPath).lastPathComponent),
                others: run.results.filter { $0.id != own.id }.map { lane($0, name: URL(fileURLWithPath: $0.modelPath).lastPathComponent) }))
        }
        for record in hostedRecords where completed(record.run) {
            guard let target = record.targets.first(where: { matches($0.localPath, $0.localSignature) }),
                  let own = record.run.results.first(where: { $0.id == target.id && $0.error == nil }) else { continue }
            let name: (String) -> String = { id in record.targets.first { $0.id == id }?.displayName ?? id }
            records.append(ClassificationResultRecord(
                runID: record.id, promptSetName: record.run.promptSetName, measuredAt: record.run.finishedAt ?? record.run.startedAt,
                hosted: true, model: lane(own, name: target.displayName),
                others: record.run.results.filter { $0.id != own.id }.map { lane($0, name: name($0.id)) }))
        }
        return records.sorted { $0.measuredAt > $1.measuredAt }
    }
}

enum DecisionScoring {
    static func grade(_ questions: [DecisionQuestion], answers: [String: DecisionAnswer]) -> DecisionEvidence {
        DecisionEvidence(grades: questions.map { grade($0, answer: answers[$0.name]) })
    }

    static func grade(_ question: DecisionQuestion, answer: DecisionAnswer?) -> DecisionGrade {
        let probabilities = answer?.probabilities ?? [:]
        var chosen: String?, probability: Double?, expectedProbability: Double?
        switch question.kind {
        case .choice:
            let labels = question.options.map(\.label)
            chosen = answer?.choice.flatMap { labels.contains($0) ? $0 : nil } ?? mostLikely(labels, probabilities)
            probability = chosen.flatMap { probabilities[$0] }
            expectedProbability = question.expected.flatMap { probabilities[$0] }
        case .score:
            let levels = question.options.indices.map(String.init)
            chosen = mostLikely(levels, probabilities) ?? answer?.score.flatMap { value in
                let level = Int(value.rounded())
                return question.options.indices.contains(level) ? String(level) : nil
            }
            probability = chosen.flatMap { probabilities[$0] }
            expectedProbability = question.expected.flatMap { probabilities[$0] }
        case .noul:
            if let reading = answer?.noul, reading.isFinite, (0...1).contains(reading) {
                chosen = reading >= 0.5 ? "true" : "false"
                probability = reading
                expectedProbability = question.expected.map { $0 == "true" ? reading : 1 - reading }
            }
        }
        return DecisionGrade(question: question.name, kind: question.kind, answer: chosen, probability: probability,
                             score: question.kind == .score ? answer?.score : nil, expected: question.expected,
                             expectedProbability: expectedProbability,
                             correct: question.expected.map { chosen == $0 })
    }

    /// The first key with the highest finite probability, in option order.
    private static func mostLikely(_ keys: [String], _ probabilities: [String: Double]) -> String? {
        var best: (key: String, value: Double)?
        for key in keys {
            guard let value = probabilities[key], value.isFinite else { continue }
            if best == nil || value > best!.value { best = (key, value) }
        }
        return best?.key
    }

    /// Median recorded time of the prompts a lane answered.
    static func medianSeconds(_ samples: [ComparisonSample]) -> Double? {
        let values = samples.filter { $0.error == nil }.compactMap(\.seconds).filter(\.isFinite).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    /// Correct answers over scored questions, pooled across every prompt a lane answered.
    static func pooledAccuracy(_ samples: [ComparisonSample]) -> Double? {
        let evidence = samples.filter { $0.error == nil }.compactMap(\.decision)
        let scored = evidence.map(\.scoredCount).reduce(0, +)
        guard scored > 0 else { return nil }
        return Double(evidence.map(\.correctCount).reduce(0, +)) / Double(scored)
    }
}
