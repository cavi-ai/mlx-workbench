import Foundation

// MARK: - FleetFitAdvisor
//
// Multimodal fleet memory budget (Phase 2.3): the summed fit assessment over
// enabled endpoint slots against one live memory snapshot and optional shared
// AgentMemoryBudget. Distinguishes resident LLMs, vision-language models,
// JIT-unloaded (dormant) gateways, Splash-capped slots, and typed audio/video/
// media/embedding workers. Verdicts are derived, never persisted, and unknown
// model sizes are always surfaced alongside partial known totals — the advisor
// never fabricates a number.

enum FleetFitAdvisor {
    enum Modality: String, CaseIterable, Equatable, Sendable {
        case llm
        case vision
        case audio
        case video
        case image
        case embedding
        case mesh
        case other

        var title: String {
            switch self {
            case .llm: return "LLM"
            case .vision: return "Vision"
            case .audio: return "Audio"
            case .video: return "Video"
            case .image: return "Image"
            case .embedding: return "Embedding"
            case .mesh: return "3D"
            case .other: return "Other"
            }
        }

        var usesLLMKVCache: Bool {
            self == .llm || self == .vision
        }

        /// Per-process runtime allowance in bytes for this modality.
        var runtimeOverheadBytes: Int64 {
            switch self {
            case .llm:
                return FitAdvisor.runtimeOverheadBytes
            case .vision:
                // LLM runtime + vision tower / image feature cache headroom.
                return FitAdvisor.runtimeOverheadBytes + 512 * 1024 * 1024
            case .audio:
                return 512 * 1024 * 1024
            case .video:
                return 1024 * 1024 * 1024
            case .image, .mesh:
                return 768 * 1024 * 1024
            case .embedding, .other:
                return 384 * 1024 * 1024
            }
        }

        /// Activation/workspace multiplier over on-disk weight bytes for
        /// non-KV-cache modalities.
        var weightMultiplier: Double {
            switch self {
            case .llm, .vision: return 1.0
            case .audio: return 1.15
            case .video: return 1.25
            case .image, .mesh: return 1.20
            case .embedding, .other: return 1.10
            }
        }
    }

    enum Residency: Equatable, Sendable {
        /// Actively loaded or eager-serving (counts toward live budget).
        case resident
        /// Load-on-request gateway whose weights are currently unloaded.
        /// Counts lightweight gateway overhead toward live budget and tracks
        /// full weights+KV as dormant.
        case jitUnloaded
        /// Splash-managed endpoint bounded by an explicit memory cap in GB.
        case splashCapped(maxMemoryGB: Double)
    }

    /// Lightweight Python/loopback gateway footprint when JIT weights are unloaded.
    static let jitGatewayOverheadBytes: Int64 = 128 * 1024 * 1024

    struct Estimate: Equatable, Sendable {
        /// Active memory footprint counted against the live fleet budget.
        let neededBytes: Int64
        /// Potential footprint when a JIT-unloaded slot loads its weights.
        let dormantBytes: Int64
        let sizeKnown: Bool
        let modality: Modality
        let residency: Residency

        init(
            neededBytes: Int64,
            sizeKnown: Bool,
            dormantBytes: Int64 = 0,
            modality: Modality = .llm,
            residency: Residency = .resident
        ) {
            self.neededBytes = neededBytes
            self.sizeKnown = sizeKnown
            self.dormantBytes = dormantBytes
            self.modality = modality
            self.residency = residency
        }

        /// Backward-compatible resident LLM estimate factory.
        static func known(modelBytes: Int64, contextTokens: Int, parameters: String?) -> Estimate {
            Estimate(
                neededBytes: FitAdvisor.neededBytes(
                    modelBytes: modelBytes,
                    contextTokens: contextTokens,
                    parameters: parameters
                ),
                sizeKnown: true,
                dormantBytes: 0,
                modality: .llm,
                residency: .resident
            )
        }

        /// Modality- and residency-aware slot estimate. Never fabricates a
        /// model size when `modelBytes` is nil or non-positive.
        static func slot(
            modelBytes: Int64?,
            contextTokens: Int = FitAdvisor.defaultContextTokens,
            parameters: String? = nil,
            modality: Modality = .llm,
            residency: Residency = .resident
        ) -> Estimate {
            guard let modelBytes, modelBytes > 0 else {
                let gatewayOnly: Int64 = (residency == .jitUnloaded) ? jitGatewayOverheadBytes : 0
                return Estimate(
                    neededBytes: gatewayOnly,
                    sizeKnown: false,
                    dormantBytes: 0,
                    modality: modality,
                    residency: residency
                )
            }

            let fullNeeded = fullNeededBytes(
                modelBytes: modelBytes,
                contextTokens: contextTokens,
                parameters: parameters,
                modality: modality
            )

            switch residency {
            case .resident:
                return Estimate(
                    neededBytes: fullNeeded,
                    sizeKnown: true,
                    dormantBytes: 0,
                    modality: modality,
                    residency: residency
                )
            case .jitUnloaded:
                return Estimate(
                    neededBytes: jitGatewayOverheadBytes,
                    sizeKnown: true,
                    dormantBytes: fullNeeded,
                    modality: modality,
                    residency: residency
                )
            case .splashCapped(let maxMemoryGB):
                let capBytes = (maxMemoryGB.isFinite && maxMemoryGB > 0)
                    ? Int64(maxMemoryGB * 1e9)
                    : fullNeeded
                return Estimate(
                    neededBytes: min(fullNeeded, capBytes),
                    sizeKnown: true,
                    dormantBytes: 0,
                    modality: modality,
                    residency: residency
                )
            }
        }

        static var unknown: Estimate {
            Estimate(neededBytes: 0, sizeKnown: false)
        }

        static func unknown(modality: Modality, residency: Residency = .resident) -> Estimate {
            slot(modelBytes: nil, modality: modality, residency: residency)
        }
    }

    struct BudgetSummary: Equatable, Sendable {
        let verdict: FitVerdict
        let knownNeededBytes: Int64
        let dormantBytes: Int64
        let effectiveBudgetBytes: Int64
        let systemAvailableBytes: Int64
        let systemReserveBytes: Int64
        let agentLimitBytes: Int64?
        let agentReserveBytes: Int64?
        let agentAccountedBytes: Int64?
        let agentWithinBudget: Bool?
        let unknownSlotCount: Int
        let knownSlotCount: Int
        let totalSlotCount: Int
        let modalityBreakdown: [Modality: Int64]

        var isPartial: Bool { unknownSlotCount > 0 }

        var agentAdmissionBytes: Int64? {
            guard let limit = agentLimitBytes, let reserve = agentReserveBytes else { return nil }
            return max(0, limit - reserve)
        }

        /// Active fraction of the effective budget used by known slots (or
        /// accounted agent bytes when higher).
        var utilizationFraction: Double {
            guard effectiveBudgetBytes > 0 else { return knownNeededBytes > 0 ? 1.0 : 0.0 }
            let active = max(knownNeededBytes, agentAccountedBytes ?? 0)
            return Double(active) / Double(effectiveBudgetBytes)
        }

        var summaryText: String {
            let knownGB = Double(knownNeededBytes) / 1e9
            let budgetGB = Double(effectiveBudgetBytes) / 1e9
            var parts: [String] = []
            if knownSlotCount > 0 || dormantBytes > 0 {
                parts.append(String(format: "%.1f GB active", knownGB))
            }
            if dormantBytes > 0 {
                parts.append(String(format: "+%.1f GB JIT dormant", Double(dormantBytes) / 1e9))
            }
            if unknownSlotCount > 0 {
                parts.append("\(unknownSlotCount) unknown")
            }
            let usage = parts.isEmpty ? "No size data" : parts.joined(separator: " · ")
            return String(format: "%@ of %.1f GB budget", usage, budgetGB)
        }
    }

    static func fullNeededBytes(
        modelBytes: Int64,
        contextTokens: Int,
        parameters: String?,
        modality: Modality
    ) -> Int64 {
        if modality.usesLLMKVCache {
            let kv = FitAdvisor.kvBytesPerToken(parameters: parameters) * Int64(contextTokens)
            return modelBytes + kv + modality.runtimeOverheadBytes
        }
        return Int64(Double(modelBytes) * modality.weightMultiplier) + modality.runtimeOverheadBytes
    }

    static func modality(
        for model: LibraryModel?,
        server: ServerInfo? = nil,
        role: ServingRole? = nil
    ) -> Modality {
        if let kinds = server?.taskKinds, !kinds.isEmpty {
            let lowered = Set(kinds.map { $0.lowercased() })
            if !lowered.isDisjoint(with: ["transcribe", "speak", "music_generation", "sound_effects"]) {
                return .audio
            }
            if lowered.contains("video_generation") { return .video }
            if lowered.contains("image_generation") { return .image }
            if lowered.contains("mesh_generation") { return .mesh }
            if !lowered.isDisjoint(with: ["embedding", "classification"]) { return .embedding }
        }
        if let taskType = model?.item.task?.type {
            switch taskType {
            case .textLLM, .speculativeDraft: return .llm
            case .visionLanguage, .visionProjector: return .vision
            case .speechToText, .textToSpeech, .musicGeneration: return .audio
            case .videoGeneration: return .video
            case .imageGeneration: return .image
            case .embedding, .classification: return .embedding
            case .meshGeneration: return .mesh
            case .other: break
            }
        }
        if role == .vision { return .vision }
        return .llm
    }

    static func assess(
        estimates: [Estimate],
        availableBytes: Int64,
        reserveBytes: Int64 = FitAdvisor.reserveBytes,
        agentBudget: AgentMemoryBudget? = nil
    ) -> BudgetSummary {
        let systemBudget = max(Int64(0), availableBytes - reserveBytes)
        let agentAdmission = agentBudget.map { max(Int64(0), $0.limitBytes - $0.reserveBytes) }
        let effectiveBudget = agentAdmission.map { min(systemBudget, $0) } ?? systemBudget

        var knownNeeded: Int64 = 0
        var dormant: Int64 = 0
        var unknownCount = 0
        var knownCount = 0
        var breakdown: [Modality: Int64] = [:]

        for estimate in estimates {
            if estimate.sizeKnown {
                knownCount += 1
                knownNeeded += estimate.neededBytes
                dormant += estimate.dormantBytes
                if estimate.neededBytes > 0 {
                    breakdown[estimate.modality, default: 0] += estimate.neededBytes
                }
            } else {
                unknownCount += 1
                knownNeeded += estimate.neededBytes
            }
        }

        let verdict: FitVerdict
        if estimates.isEmpty {
            verdict = .unknown(reason: "no enabled endpoints")
        } else {
            let effectiveDemand = max(knownNeeded, agentBudget?.accountedBytes ?? 0)
            if effectiveDemand > effectiveBudget {
                let deficit = Double(effectiveDemand - effectiveBudget) / 1e9
                verdict = .wontFit(deficitGB: deficit, suggestedMaxContext: nil)
            } else if unknownCount > 0 {
                if knownCount > 0 {
                    let knownGB = Double(knownNeeded) / 1e9
                    verdict = .unknown(
                        reason: String(
                            format: "%.1f GB known across %d endpoint(s); %d endpoint model(s) lack size data",
                            knownGB, knownCount, unknownCount
                        )
                    )
                } else {
                    verdict = .unknown(reason: "\(unknownCount) endpoint model(s) lack size data")
                }
            } else {
                let headroom = Double(effectiveBudget - effectiveDemand) / 1e9
                if effectiveDemand <= Int64(Double(effectiveBudget) * 0.85) {
                    verdict = .fits(headroomGB: headroom)
                } else {
                    verdict = .tight(headroomGB: headroom)
                }
            }
        }

        return BudgetSummary(
            verdict: verdict,
            knownNeededBytes: knownNeeded,
            dormantBytes: dormant,
            effectiveBudgetBytes: effectiveBudget,
            systemAvailableBytes: availableBytes,
            systemReserveBytes: reserveBytes,
            agentLimitBytes: agentBudget?.limitBytes,
            agentReserveBytes: agentBudget?.reserveBytes,
            agentAccountedBytes: agentBudget?.accountedBytes,
            agentWithinBudget: agentBudget?.withinBudget,
            unknownSlotCount: unknownCount,
            knownSlotCount: knownCount,
            totalSlotCount: estimates.count,
            modalityBreakdown: breakdown
        )
    }

    static func verdict(
        estimates: [Estimate],
        availableBytes: Int64,
        reserveBytes: Int64 = FitAdvisor.reserveBytes,
        agentBudget: AgentMemoryBudget? = nil
    ) -> FitVerdict {
        assess(
            estimates: estimates,
            availableBytes: availableBytes,
            reserveBytes: reserveBytes,
            agentBudget: agentBudget
        ).verdict
    }
}
