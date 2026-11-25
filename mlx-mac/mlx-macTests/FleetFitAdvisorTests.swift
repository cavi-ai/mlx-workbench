import Foundation
import XCTest

@testable import mlx_workbench

/// Spec 09 P3 + Phase 2.3: multimodal co-residency budget estimation across
/// resident LLMs, Vision, Audio, Video, Embeddings, JIT-unloaded gateways,
/// Splash-capped slots, and shared AgentMemoryBudget without Mach probes.
final class FleetFitAdvisorTests: XCTestCase {
    private let reserve = FitAdvisor.reserveBytes
    private let context = FitAdvisor.defaultContextTokens

    private func available(gb: Double) -> Int64 { Int64(gb * 1e9) }

    func testMaxSlotsSupportsSixteenEndpoints() {
        XCTAssertEqual(EndpointFleetConfig.maxSlots, 16)
    }

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

    func testAnyUnknownModelSizeSurfacesPartialKnownTotalAndUnknownCount() {
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
            .unknown,
            .unknown,
        ]
        let summary = FleetFitAdvisor.assess(
            estimates: estimates,
            availableBytes: available(gb: 64),
            reserveBytes: reserve
        )
        XCTAssertTrue(summary.isPartial)
        XCTAssertEqual(summary.knownSlotCount, 1)
        XCTAssertEqual(summary.unknownSlotCount, 2)
        XCTAssertGreaterThan(summary.knownNeededBytes, Int64(4e9))
        guard case .unknown(let reason) = summary.verdict else {
            return XCTFail("expected unknown, got \(summary.verdict)")
        }
        XCTAssertTrue(reason.contains("2"))
        XCTAssertTrue(reason.contains("known"))
    }

    func testKnownSlotsExceedingBudgetReturnWontFitEvenWhenAnotherSlotIsUnknown() {
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(20e9), contextTokens: context, parameters: "70B"),
            .unknown,
        ]
        let summary = FleetFitAdvisor.assess(
            estimates: estimates,
            availableBytes: available(gb: 20),
            reserveBytes: reserve
        )
        XCTAssertEqual(summary.unknownSlotCount, 1)
        guard case .wontFit(let deficit, _) = summary.verdict else {
            return XCTFail("expected wontFit when known slots already overflow, got \(summary.verdict)")
        }
        XCTAssertGreaterThan(deficit, 0)
    }

    func testRuntimeOverheadIsCountedPerSlot() {
        let weightsAndKV = Int64(4e9) + FitAdvisor.kvBytesPerToken(parameters: "8B") * Int64(context)
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(4e9), contextTokens: context, parameters: "8B"),
        ]
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

    func testMultimodalCoResidencyAudioVisionCodingEmbeddingFitsAndTracksBreakdown() {
        let coding = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(8e9), contextTokens: context, parameters: "14B", modality: .llm, residency: .resident
        )
        let vision = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(6e9), contextTokens: context, parameters: "7B", modality: .vision, residency: .resident
        )
        let audio = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(2e9), contextTokens: context, parameters: nil, modality: .audio, residency: .resident
        )
        let embedding = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(0.6e9), contextTokens: context, parameters: nil, modality: .embedding, residency: .resident
        )
        // Audio and embedding should NOT incur LLM KV cache overhead.
        XCTAssertLessThan(audio.neededBytes, FitAdvisor.neededBytes(modelBytes: Int64(2e9), contextTokens: context, parameters: "8B"))
        XCTAssertLessThan(embedding.neededBytes, FitAdvisor.neededBytes(modelBytes: Int64(0.6e9), contextTokens: context, parameters: "8B"))

        let summary = FleetFitAdvisor.assess(
            estimates: [coding, vision, audio, embedding],
            availableBytes: available(gb: 64),
            reserveBytes: reserve
        )
        guard case .fits(let headroom) = summary.verdict else {
            return XCTFail("expected multimodal fleet to fit on 64 GB, got \(summary.verdict)")
        }
        XCTAssertGreaterThan(headroom, 20)
        XCTAssertEqual(summary.modalityBreakdown.keys.count, 4)
        XCTAssertNotNil(summary.modalityBreakdown[.llm])
        XCTAssertNotNil(summary.modalityBreakdown[.vision])
        XCTAssertNotNil(summary.modalityBreakdown[.audio])
        XCTAssertNotNil(summary.modalityBreakdown[.embedding])
    }

    func testJITUnloadedCountsGatewayOverheadAndTracksDormantFootprint() {
        let dormantLLM = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(20e9), contextTokens: context, parameters: "32B", modality: .llm, residency: .jitUnloaded
        )
        XCTAssertEqual(dormantLLM.neededBytes, FleetFitAdvisor.jitGatewayOverheadBytes)
        XCTAssertGreaterThan(dormantLLM.dormantBytes, Int64(20e9))

        let summary = FleetFitAdvisor.assess(
            estimates: [dormantLLM],
            availableBytes: available(gb: 16),
            reserveBytes: reserve
        )
        guard case .fits = summary.verdict else {
            return XCTFail("expected JIT-unloaded slot to fit while dormant, got \(summary.verdict)")
        }
        XCTAssertGreaterThan(summary.dormantBytes, Int64(20e9))
        XCTAssertTrue(summary.summaryText.contains("JIT dormant"))
    }

    func testSplashCapBoundsActiveFootprint() {
        let uncapped = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(30e9), contextTokens: 32768, parameters: "70B", modality: .llm, residency: .resident
        )
        let capped = FleetFitAdvisor.Estimate.slot(
            modelBytes: Int64(30e9), contextTokens: 32768, parameters: "70B", modality: .llm, residency: .splashCapped(maxMemoryGB: 24)
        )
        XCTAssertEqual(capped.neededBytes, Int64(24e9))
        XCTAssertLessThan(capped.neededBytes, uncapped.neededBytes)
    }

    func testAgentMemoryBudgetTightensEffectiveCeiling() {
        let estimates = [
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(10e9), contextTokens: context, parameters: "14B"),
            FleetFitAdvisor.Estimate.known(modelBytes: Int64(10e9), contextTokens: context, parameters: "14B"),
        ]
        // System has 128 GB free, but shared AgentMemoryBudget caps admission to 20 - 4 = 16 GB.
        let agentBudget = AgentMemoryBudget(
            limitBytes: Int64(20e9),
            reserveBytes: Int64(4e9),
            accountedBytes: Int64(12e9),
            withinBudget: true
        )
        let summary = FleetFitAdvisor.assess(
            estimates: estimates,
            availableBytes: available(gb: 128),
            reserveBytes: reserve,
            agentBudget: agentBudget
        )
        XCTAssertEqual(summary.effectiveBudgetBytes, Int64(16e9))
        guard case .wontFit(let deficit, _) = summary.verdict else {
            return XCTFail("expected wontFit under tighter AgentMemoryBudget, got \(summary.verdict)")
        }
        XCTAssertGreaterThan(deficit, 0)
    }
}
