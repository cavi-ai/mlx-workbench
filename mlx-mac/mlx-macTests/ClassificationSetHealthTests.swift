import XCTest
@testable import mlx_workbench

final class ClassificationSetHealthTests: XCTestCase {
    private func question(_ name: String, kind: DecisionQuestion.Kind = .choice, options: [String] = ["a", "b", "c"],
                          expected: String?) -> DecisionQuestion {
        DecisionQuestion(name: name, kind: kind, instructions: "Pick one.", options: options.map { .init(label: $0) }, expected: expected)
    }

    private func set(_ entries: [[DecisionQuestion]], id: String = "set-1") -> PromptSet {
        PromptSet(id: id, name: "Set", useCase: nil,
                  prompts: entries.enumerated().map { PromptEntry(id: "p\($0.offset)", text: "state", decisionQuestions: $0.element) },
                  origin: .userCreated, mode: .classification)
    }

    private func lane(_ path: String, grades: [Bool?]) -> VariantResult {
        var sample = ComparisonSample(promptID: "p0", outputExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil)
        sample.decision = DecisionEvidence(grades: grades.map {
            DecisionGrade(question: "q", kind: .choice, answer: "a", probability: nil, score: nil, expected: $0 == nil ? nil : "a",
                          expectedProbability: nil, correct: $0)
        })
        return VariantResult(modelPath: path, modelSignature: nil, samples: [sample], aggregateTokensPerSecond: nil,
                             aggregateTTFTSeconds: nil, error: nil, aggregateMetric: DecisionScoring.pooledAccuracy([sample]))
    }

    private func run(_ results: [VariantResult], at seconds: TimeInterval, setID: String = "set-1",
                     state: ComparisonRunState = .completed) -> ComparisonRun {
        ComparisonRun(id: UUID(), promptSetID: setID, promptSetName: "Set", useCase: nil, variants: results.map(\.modelPath),
                      results: results, startedAt: Date(timeIntervalSince1970: seconds), finishedAt: Date(timeIntervalSince1970: seconds + 60),
                      state: state, mode: .classification, promptEntries: nil)
    }

    func testBuiltInSupportRoutingCounts() {
        let health = ClassificationSetHealth(set: ComparisonMediaFixtures.supportRoutingSet, runs: [])
        XCTAssertEqual(health.entries, 6)
        XCTAssertEqual(health.questions, 18)
        XCTAssertEqual(health.scoredQuestions, 14, "urgency is expected on 2 of 6 tickets")
        XCTAssertEqual(try XCTUnwrap(health.scoredShare), 14.0 / 18.0, accuracy: 1e-9)
        XCTAssertEqual(health.unusedOptions, [.init(question: "urgency", option: "somewhat urgent")])
        XCTAssertEqual(health.warnings, ["4 questions have no expected answer",
                                         "Option somewhat urgent of question urgency is never the expected answer"])
        XCTAssertTrue(health.models.isEmpty)
    }

    func testUnusedChoiceOptionsAndScoreLevelsArePerQuestion() {
        let health = ClassificationSetHealth(set: set([
            [question("team", expected: "a"), question("level", kind: .score, expected: "0")],
            [question("team", expected: "b"), question("level", kind: .score, expected: "2")],
        ]), runs: [])
        XCTAssertEqual(health.unusedOptions, [.init(question: "team", option: "c"), .init(question: "level", option: "b")])
        XCTAssertEqual(health.scoredQuestions, 4)
        XCTAssertEqual(health.scoredShare, 1)
    }

    func testModelAccuracyUsesOnlyCompletedRunsOfThisSetNewestFirst() {
        let health = ClassificationSetHealth(
            set: set([[question("team", expected: "a")]]),
            runs: [run([lane("/m/x", grades: [true, false])], at: 100),
                   run([lane("/m/x", grades: [true, true]), lane("/m/y", grades: [false, true, nil])], at: 200),
                   run([lane("/m/x", grades: [false])], at: 300, setID: "other"),
                   run([lane("/m/x", grades: [false])], at: 400, state: .cancelled)],
            laneName: { $0.split(separator: "/").last.map(String.init) ?? $0 })
        XCTAssertEqual(health.models.map(\.name), ["x", "y"])
        XCTAssertEqual(health.models[0].runs, 2)
        XCTAssertEqual(health.models[0].accuracy, 1, "latest run of x matched 2 of 2")
        XCTAssertEqual(health.models[1].runs, 1)
        XCTAssertEqual(health.models[1].accuracy, 0.5)
        XCTAssertEqual(health.models[1].correct, 1)
        XCTAssertEqual(health.models[1].scored, 2)
        XCTAssertFalse(health.warnings.contains { $0.contains("does not separate") })
    }

    func testWarnsWhenEveryModelMatchesEveryExpectedAnswer() {
        let health = ClassificationSetHealth(
            set: set([[question("team", expected: "a"), question("team2", expected: "b")]]),
            runs: [run([lane("/m/x", grades: [true, true]), lane("/m/y", grades: [true, true])], at: 100)])
        XCTAssertTrue(health.warnings.contains("Every model that ran this set matched all expected answers"))

        let single = ClassificationSetHealth(set: set([[question("team", expected: "a")]]),
                                             runs: [run([lane("/m/x", grades: [true])], at: 100)])
        XCTAssertFalse(single.warnings.contains { $0.hasPrefix("Every model") }, "one model cannot show separation")
    }
}
