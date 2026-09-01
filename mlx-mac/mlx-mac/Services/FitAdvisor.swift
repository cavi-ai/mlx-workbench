import Foundation

// MARK: - FitAdvisor
//
// Pure estimation for the Memory-fit Advisor (premium spec 05, free tier).
// Estimator version: 1. Model: weights (on-disk bytes, MLX maps them) + KV
// cache (context × per-token heuristic) + fixed runtime overhead, compared
// against live available memory minus a safety reserve. Conservative on
// purpose: a false "won't fit" costs a smaller context; a false "fits" costs
// a swap storm.

enum FitAdvisor {
    static let estimatorVersion = 1

    /// Safety reserve kept free for the system and other apps.
    static let reserveBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// mlx + Python + server overhead allowance.
    static let runtimeOverheadBytes: Int64 = 1536 * 1024 * 1024
    static let defaultContextTokens = 8192
    static let minimumContextTokens = 2048

    /// KV cache bytes per token, heuristic from parameter count:
    /// ~2e-5 bytes per parameter per token (8B → ~160 KB/token, so 8k
    /// context ≈ 1.3 GB; 70B → ~1.4 MB/token, so 32k ≈ 45 GB — correctly
    /// scary). Exact architecture dims beat this when scan metadata learns
    /// to report them.
    static func kvBytesPerToken(parameters: String?) -> Int64 {
        guard let billions = parameterBillions(parameters), billions > 0 else {
            return 160_000  // 8B-class default when unknown
        }
        return Int64(billions * 1e9 * 2e-5)
    }

    /// "8B" → 8.0, "70.6B" → 70.6, "3.2b" → 3.2, "350M" → 0.35.
    static func parameterBillions(_ parameters: String?) -> Double? {
        guard let parameters else { return nil }
        let trimmed = parameters.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var digits = ""
        var sawDot = false
        for character in trimmed {
            if character.isNumber { digits.append(character) }
            else if character == "." && !sawDot { digits.append(character); sawDot = true }
            else { break }
        }
        guard let value = Double(digits), value > 0 else { return nil }
        if trimmed.hasSuffix("M") { return value / 1000 }
        return value  // default: billions
    }

    static func verdict(
        modelBytes: Int64?,
        contextTokens: Int,
        parameters: String?,
        hardware: HardwareProfile,
        memory: MemorySnapshot?,
        reserveBytes: Int64 = reserveBytes
    ) -> FitVerdict {
        guard let modelBytes, modelBytes > 0 else {
            return .unknown(reason: "model size unavailable")
        }
        guard let memory else {
            // Probe failed: fall back to 60% of total memory, marked estimate.
            guard let total = hardware.memoryBytes, total > 0 else {
                return .unknown(reason: "memory probe unavailable")
            }
            return verdict(
                modelBytes: modelBytes,
                contextTokens: contextTokens,
                parameters: parameters,
                availableBytes: Int64(Double(total) * 0.6),
                reserveBytes: reserveBytes
            )
        }
        return verdict(
            modelBytes: modelBytes,
            contextTokens: contextTokens,
            parameters: parameters,
            availableBytes: memory.availableBytes,
            reserveBytes: reserveBytes
        )
    }

    static func verdict(
        modelBytes: Int64,
        contextTokens: Int,
        parameters: String?,
        availableBytes: Int64,
        reserveBytes: Int64
    ) -> FitVerdict {
        let needed = neededBytes(modelBytes: modelBytes, contextTokens: contextTokens, parameters: parameters)
        let budget = availableBytes - reserveBytes
        let headroom = Double(budget - needed) / 1e9
        if needed <= Int64(Double(budget) * 0.85) {
            return .fits(headroomGB: headroom)
        }
        if needed <= budget {
            return .tight(headroomGB: headroom)
        }
        let deficit = Double(needed - budget) / 1e9
        let suggestion = suggestedMaxContext(
            modelBytes: modelBytes,
            parameters: parameters,
            availableBytes: availableBytes,
            reserveBytes: reserveBytes,
            ceiling: contextTokens
        )
        return .wontFit(deficitGB: deficit, suggestedMaxContext: suggestion)
    }

    static func neededBytes(modelBytes: Int64, contextTokens: Int, parameters: String?) -> Int64 {
        modelBytes
            + kvBytesPerToken(parameters: parameters) * Int64(contextTokens)
            + runtimeOverheadBytes
    }

    /// Largest power-of-two context (≥ minimum, ≤ ceiling) that fits.
    static func suggestedMaxContext(
        modelBytes: Int64,
        parameters: String?,
        availableBytes: Int64,
        reserveBytes: Int64,
        ceiling: Int
    ) -> Int? {
        var best: Int?
        var candidate = minimumContextTokens
        while candidate <= max(ceiling, minimumContextTokens) {
            let needed = neededBytes(modelBytes: modelBytes, contextTokens: candidate, parameters: parameters)
            let budget = availableBytes - reserveBytes
            if needed <= Int64(Double(budget) * 0.85) {
                best = candidate
                candidate *= 2
            } else {
                break
            }
        }
        return best
    }
}
