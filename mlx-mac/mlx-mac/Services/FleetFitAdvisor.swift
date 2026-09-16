import Foundation

// MARK: - FleetFitAdvisor
//
// Fleet memory budget (spec 09 P3): the summed fit verdict over all enabled
// endpoint slots against one live memory snapshot. Composition only — the
// per-model estimate math stays in FitAdvisor; this type exists so the sum
// is unit-testable without Mach probes. Runtime overhead is per-slot: each
// endpoint is its own mlx server process. Verdicts are derived, never
// persisted, and unknown model sizes make the fleet verdict unknown rather
// than silently summed — the advisor never fabricates a number.

enum FleetFitAdvisor {
    struct Estimate: Equatable, Sendable {
        /// Weights + KV + this slot's runtime overhead, when its model size
        /// is known.
        let neededBytes: Int64
        let sizeKnown: Bool

        static func known(modelBytes: Int64, contextTokens: Int, parameters: String?) -> Estimate {
            Estimate(
                neededBytes: FitAdvisor.neededBytes(
                    modelBytes: modelBytes,
                    contextTokens: contextTokens,
                    parameters: parameters
                ),
                sizeKnown: true
            )
        }

        static var unknown: Estimate {
            Estimate(neededBytes: 0, sizeKnown: false)
        }
    }

    static func verdict(
        estimates: [Estimate],
        availableBytes: Int64,
        reserveBytes: Int64 = FitAdvisor.reserveBytes
    ) -> FitVerdict {
        guard !estimates.isEmpty else {
            return .unknown(reason: "no enabled endpoints")
        }
        let unknown = estimates.filter { !$0.sizeKnown }.count
        guard unknown == 0 else {
            return .unknown(reason: "\(unknown) endpoint model(s) lack size data")
        }
        let needed = estimates.reduce(Int64(0)) { $0 + $1.neededBytes }
        let budget = availableBytes - reserveBytes
        let headroom = Double(budget - needed) / 1e9
        if needed <= Int64(Double(budget) * 0.85) {
            return .fits(headroomGB: headroom)
        }
        if needed <= budget {
            return .tight(headroomGB: headroom)
        }
        // A per-context suggestion does not map onto a fleet (which slot's
        // context would it change?); the deficit number is the honest signal.
        let deficit = Double(needed - budget) / 1e9
        return .wontFit(deficitGB: deficit, suggestedMaxContext: nil)
    }
}
