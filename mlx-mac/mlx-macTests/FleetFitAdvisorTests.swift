import Foundation
import XCTest

@testable import mlx_workbench

/// Spec 09 P3: the summed fleet verdict composes FitAdvisor's per-model
/// estimate without Mach probes.
final class FleetFitAdvisorTests: XCTestCase {
    private let reserve = FitAdvisor.reserveBytes
    private let context = FitAdvisor.defaultContextTokens

    private func available(gb: Double) -> Int64 { Int64(gb * 1e9) }

    func testEmptyFleetIsUnknown() {
        let verdict = FleetFitAdvisor.verdict(estimates: [], availableBytes: available(gb: 64), reserveBytes: reserve)
        guard case .unknown(let reason) = verdict else {
            return XCTFail("expected unknown, got \(verdict)")
        }
        XCTAssertTrue(reason.contains("no enabled endpoints"))
    }

    func testTwoSmallModelsFitWithSummedHeadroom() {
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
        ]
        let verdict = FleetFitAdvisor.verdict(estimates: estimates, availableBytes: available(gb: 64), reserveBytes: reserve)
        guard case .fits(let headroom) = verdict else {
            return XCTFail("expected fits, got \(verdict)")
        }
        XCTAssertGreaterThan(headroom, 0)
    }

    func testSumPastEightyFivePercentIsTight() {
        // Budget = 20 - 4 = 16 GB. One 8B model needs ~4 + 1.3 + 1.5 ≈ 6.8 GB;
        // two need ~13.6 GB ≈ 85% of budget → tight, not fits.
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
        ]
        let verdict = FleetFitAdvisor.verdict(estimates: estimates, availableBytes: available(gb: 20), reserveBytes: reserve)
        guard case .tight = verdict else {
            return XCTFail("expected tight, got \(verdict)")
        }
    }

    func testSumPastBudgetIsWontFitWithDeficitAndNoContextSuggestion() {
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(20e9), contextTokens: context, parameters: "70B"),
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(20e9), contextTokens: context, parameters: "70B"),
        ]
        let verdict = FleetFitAdvisor.verdict(estimates: estimates, availableBytes: available(gb: 20), reserveBytes: reserve)
        guard case .wontFit(let deficit, let suggestion) = verdict else {
            return XCTFail("expected wontFit, got \(verdict)")
        }
        XCTAssertGreaterThan(deficit, 0)
        // A per-context suggestion is meaningless across a fleet.
        XCTAssertNil(suggestion)
    }

    func testAnyUnknownModelSizeMakesTheFleetVerdictUnknown() {
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
            .unknown,
            .unknown,
        ]
        let verdict = FleetFitAdvisor.verdict(estimates: estimates, availableBytes: available(gb: 64), reserveBytes: reserve)
        guard case .unknown(let reason) = verdict else {
            return XCTFail("expected unknown, got \(verdict)")
        }
        XCTAssertTrue(reason.contains("2"))
    }

    func testRuntimeOverheadIsCountedPerSlot() {
        let weightsAndKV = Int64(4e9) + FitAdvisor.kvBytesPerToken(parameters: "8B") * Int64(context)
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
        ]
        // Budget: both models' weights+KV, ONE overhead allowance, plus a
        // small margin. Counted twice (correct), the fleet is wontFit;
        // counted once it would squeak through as tight.
        let budgetNet = 2 * weightsAndKV + FitAdvisor.runtimeOverheadBytes + Int64(0.5e9)
        let verdict = FleetFitAdvisor.verdict(
            estimates: estimates,
            availableBytes: reserve + budgetNet,
            reserveBytes: reserve
        )
        guard case .wontFit = verdict else {
            return XCTFail("expected wontFit when overhead is counted per slot, got \(verdict)")
        }
    }
}
