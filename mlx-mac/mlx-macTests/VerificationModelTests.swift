import Foundation
import XCTest

@testable import mlx_workbench

final class VerificationModelTests: XCTestCase {
    // MARK: - Detectors

    func testIsBlankDetectsWhitespaceOnly() {
        XCTAssertTrue(CanaryDetectors.isBlank("   \n\t  "))
        XCTAssertTrue(CanaryDetectors.isBlank(""))
        XCTAssertFalse(CanaryDetectors.isBlank("hello"))
    }

    func testRepetitionRatioFlagsDominatedText() {
        let repeated = Array(repeating: "alpha", count: 30).joined(separator: " ")
        XCTAssertEqual(CanaryDetectors.repetitionRatio(repeated), 1.0, accuracy: 0.001)
    }

    func testRepetitionRatioIgnoresNormalProse() {
        let prose = "Conversion finished successfully. The output directory now contains the quantized weights, tokenizer configuration, and a receipt that records the full parameter set used for the run."
        XCTAssertLessThan(CanaryDetectors.repetitionRatio(prose), 0.5)
    }

    func testRepetitionRatioIgnoresShortResponses() {
        XCTAssertEqual(CanaryDetectors.repetitionRatio("ok ok ok ok"), 0)
    }

    func testTokenLoopDetectsTrailingRepeat() {
        let loop = "Some normal opening words. " + Array(repeating: "alpha beta gamma delta", count: 5).joined(separator: " ")
        XCTAssertTrue(CanaryDetectors.hasTokenLoop(loop))
    }

    func testTokenLoopIgnoresNormalText() {
        let normal = "The quick brown fox jumps over the lazy dog while the wind shifts across the harbour and the ledger closes for the night."
        XCTAssertFalse(CanaryDetectors.hasTokenLoop(normal))
    }

    func testReplacementCharacterCount() {
        XCTAssertEqual(CanaryDetectors.replacementCharacterCount("abc"), 0)
        XCTAssertEqual(CanaryDetectors.replacementCharacterCount("a\u{FFFD}b\u{FFFD}"), 2)
    }

    // MARK: - Suite evaluation

    private func sample(_ text: String) -> ProbeSample {
        ProbeSample(
            text: text,
            completionTokens: 50,
            timeToFirstTokenSeconds: 0.1,
            durationSeconds: 1.1,
            metricsEstimated: false
        )
    }

    private func kase(_ id: String) -> CanaryCase {
        CanarySuite.cases.first { $0.id == id }!
    }

    func testEchoCanaryPassesWithExactToken() {
        let result = CanarySuite.evaluate(kase("echo"), sample: sample("CRIMSON-OKAPI-42"))
        XCTAssertTrue(result.passed)
        XCTAssertNil(result.failureReason)
    }

    func testEchoCanaryFailsWithoutToken() {
        let result = CanarySuite.evaluate(kase("echo"), sample: sample("I cannot do that."))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReason?.contains("CRIMSON-OKAPI-42") == true)
    }

    func testCanaryFailsOnBlankResponse() {
        let result = CanarySuite.evaluate(kase("arithmetic"), sample: sample("   "))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReason?.contains("empty") == true)
    }

    func testCanaryFailsOnTokenLoop() {
        let looped = "391 " + Array(repeating: "so the answer is", count: 6).joined(separator: " ")
        let result = CanarySuite.evaluate(kase("arithmetic"), sample: sample(looped))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReason?.contains("loop") == true)
    }

    func testCanaryFailsOnReplacementCharacterFlood() {
        let flooded = String(repeating: "\u{FFFD}", count: 20)
        let result = CanarySuite.evaluate(kase("refusal-shape"), sample: sample(flooded))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.failureReason?.contains("replacement") == true)
    }

    func testArithmeticCanaryPassesWithFinalNumber() {
        let result = CanarySuite.evaluate(kase("arithmetic"), sample: sample("17 * 20 = 340, plus 17 * 3 = 51, so the total is 391."))
        XCTAssertTrue(result.passed)
    }

    // MARK: - Metrics

    func testTokensPerSecondUsesDecodeWindow() {
        let value = CanarySuite.tokensPerSecond(sample("x"))
        XCTAssertEqual(value ?? 0, 50.0, accuracy: 0.01)
    }

    func testAggregateTokensPerSecondIsMedian() {
        func result(_ tps: Double?) -> CanaryResult {
            CanaryResult(id: UUID().uuidString, title: "", passed: true, failureReason: nil, responseExcerpt: "", tokensPerSecond: tps, timeToFirstTokenSeconds: nil)
        }
        let median = CanarySuite.aggregateTokensPerSecond([result(10), result(30), result(20), result(nil)])
        XCTAssertEqual(median ?? 0, 20.0, accuracy: 0.01)
    }

    func testAggregateTTFTTakesMinimum() {
        func result(_ ttft: Double?) -> CanaryResult {
            CanaryResult(id: UUID().uuidString, title: "", passed: true, failureReason: nil, responseExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: ttft)
        }
        XCTAssertEqual(CanarySuite.aggregateTTFT([result(0.4), result(0.2), result(nil)]), 0.2)
        XCTAssertNil(CanarySuite.aggregateTTFT([result(nil)]))
    }

    // MARK: - Report coding

    func testVerificationReportRoundTripsThroughJSON() throws {
        let report = VerificationReport(
            id: UUID(),
            modelPath: "/Models/converted",
            modelSignature: "sig-1",
            workflowRecordID: UUID(),
            suiteVersion: CanarySuite.version,
            canaries: [CanaryResult(id: "echo", title: "Echo", passed: true, failureReason: nil, responseExcerpt: "CRIMSON-OKAPI-42", tokensPerSecond: 42, timeToFirstTokenSeconds: 0.1)],
            tokensPerSecond: 42,
            timeToFirstTokenSeconds: 0.1,
            metricsEstimated: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 10),
            finishedAt: Date(timeIntervalSinceReferenceDate: 20),
            outcome: .passed
        )
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(VerificationReport.self, from: data), report)
    }
}
