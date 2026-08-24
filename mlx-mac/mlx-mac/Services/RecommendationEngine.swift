import Foundation

enum RecommendationFreshness: String, Equatable, Hashable {
    case localOnly = "local_only"
    case catalogCurrent = "catalog_current"
    case catalogStale = "catalog_stale"
    case catalogUnavailable = "catalog_unavailable"

    var title: String {
        switch self {
        case .localOnly:
            return "Local only"
        case .catalogCurrent:
            return "Catalog current"
        case .catalogStale:
            return "Catalog stale"
        case .catalogUnavailable:
            return "Catalog unavailable"
        }
    }
}

enum RecommendationConfidence: String, Equatable, Hashable {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }
}

struct RecommendationReason: Equatable, Hashable {
    let name: String
    let message: String
    let isHint: Bool
}

struct RecommendationEvidence: Equatable, Hashable {
    let name: String
    let value: String
    let observedAt: Date?
    let isHint: Bool
}

struct RecommendationPreferences: Equatable, Hashable {
    let speedWeight: Int
    let qualityWeight: Int
    let hiddenModelIDs: Set<String>
    let preferredModelIDs: [UseCase: String]

    static let defaults = RecommendationPreferences()

    init(
        speedWeight: Int = 1,
        qualityWeight: Int = 1,
        hiddenModelIDs: Set<String> = [],
        preferredModelIDs: [UseCase: String] = [:]
    ) {
        self.speedWeight = max(0, speedWeight)
        self.qualityWeight = max(0, qualityWeight)
        self.hiddenModelIDs = hiddenModelIDs
        self.preferredModelIDs = preferredModelIDs
    }
}

struct RecommendationBenchmarkResult: Equatable, Hashable {
    let modelID: String
    let useCase: UseCase
    let tokensPerSecond: Double?
    let timeToFirstTokenSeconds: Double?
    let measuredAt: Date
    let sampleCount: Int

    init(
        modelID: String,
        useCase: UseCase,
        tokensPerSecond: Double? = nil,
        timeToFirstTokenSeconds: Double? = nil,
        measuredAt: Date,
        sampleCount: Int = 1
    ) {
        self.modelID = modelID
        self.useCase = useCase
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.measuredAt = measuredAt
        self.sampleCount = max(1, sampleCount)
    }
}

struct Recommendation: Equatable, Hashable, Identifiable {
    let useCase: UseCase
    let modelID: String
    let score: Int
    let confidence: RecommendationConfidence
    let reasons: [RecommendationReason]
    let evidence: [RecommendationEvidence]
    let freshness: RecommendationFreshness
    let readiness: ModelReadiness

    var id: String {
        "\(useCase.rawValue)::\(modelID)"
    }

    var evidenceTimestamp: Date? {
        evidence.compactMap(\.observedAt).max()
    }
}

enum RecommendationEngine {
    static func recommend(
        useCase: UseCase,
        snapshot: LibrarySnapshot,
        catalog: CatalogState,
        benchmarkResults: [RecommendationBenchmarkResult],
        preferences: RecommendationPreferences
    ) -> [Recommendation] {
        let authority = CatalogAuthority(catalog)
        let benchmarks = benchmarkIndex(from: benchmarkResults)
        var candidates: [Candidate] = []

        for model in snapshot.models {
            guard isEligibleLocalModel(model, preferences: preferences) else { continue }

            let record = authority.record(for: model)
            guard let capability = capabilityAssessment(
                for: useCase,
                model: model,
                record: record,
                authority: authority
            ) else {
                continue
            }

            guard let memory = memoryAssessment(
                model: model,
                record: record,
                snapshot: snapshot,
                authority: authority
            ) else {
                continue
            }

            let benchmark = benchmarks[benchmarkKey(modelID: model.item.path, useCase: useCase)]
            var score = Score.readyLocalModel + capability.score + memory.score
            var reasons = [
                RecommendationReason(
                    name: "ready_local_model",
                    message: "The latest library scan found this model ready on this Mac.",
                    isHint: false
                )
            ]
            reasons.append(contentsOf: capability.reasons)
            reasons.append(contentsOf: memory.reasons)

            var evidence = [
                RecommendationEvidence(
                    name: "library_scan",
                    value: "Ready local model at \(model.item.path)",
                    observedAt: snapshot.generatedAt,
                    isHint: false
                )
            ]
            evidence.append(contentsOf: capability.evidence)
            evidence.append(contentsOf: memory.evidence)

            if preferences.preferredModelIDs[useCase] == model.item.path {
                score += Score.preferredOverride
                reasons.append(
                    RecommendationReason(
                        name: "preferred_override",
                        message: "You marked this model as preferred for \(useCase.title).",
                        isHint: false
                    )
                )
            }

            if let benchmark {
                let benchmarkBonus = benchmarkScore(for: benchmark)
                score += benchmarkBonus
                reasons.append(benchmarkReason(for: benchmark, useCase: useCase))
                evidence.append(
                    RecommendationEvidence(
                        name: "local_benchmark",
                        value: benchmarkSummary(for: benchmark),
                        observedAt: benchmark.measuredAt,
                        isHint: false
                    )
                )
            }

            candidates.append(
                Candidate(
                    model: model,
                    record: record,
                    benchmark: benchmark,
                    freshness: authority.freshness(for: record),
                    baseScore: score,
                    sizeBytes: scoreSizeBytes(for: model, record: record),
                    reasons: reasons,
                    evidence: evidence,
                    usesStructuredCapability: capability.usesStructuredMetadata,
                    usesHintedCapability: capability.usesHint,
                    usesStructuredMemoryEvidence: memory.usesStructuredMetadata
                )
            )
        }

        let speedRanks = sizeRanks(in: candidates, ascending: true)
        let qualityRanks = sizeRanks(in: candidates, ascending: false)

        let finalized = candidates.map { candidate in
            var score = candidate.baseScore
            var reasons = candidate.reasons

            let speedBonus = (speedRanks[candidate.sizeBytes] ?? 0) * preferences.speedWeight * Score.sizePreferenceUnit
            let qualityBonus = (qualityRanks[candidate.sizeBytes] ?? 0) * preferences.qualityWeight * Score.sizePreferenceUnit
            score += speedBonus + qualityBonus

            if speedBonus > qualityBonus, preferences.speedWeight > 0 {
                reasons.append(
                    RecommendationReason(
                        name: "speed_preference",
                        message: "The current preference weights favor a smaller ready model for faster local starts.",
                        isHint: true
                    )
                )
            } else if qualityBonus > speedBonus, preferences.qualityWeight > 0 {
                reasons.append(
                    RecommendationReason(
                        name: "quality_preference",
                        message: "The current preference weights favor a larger ready model for more local headroom.",
                        isHint: true
                    )
                )
            }

            return Recommendation(
                useCase: useCase,
                modelID: candidate.model.item.path,
                score: score,
                confidence: confidence(for: candidate),
                reasons: reasons,
                evidence: candidate.evidence,
                freshness: candidate.freshness,
                readiness: candidate.model.readiness
            )
        }

        return finalized.sorted(by: recommendationSort)
    }
}

private extension RecommendationEngine {
    enum Score {
        static let readyLocalModel = 1_000
        static let currentStructuredCapability = 350
        static let staleStructuredCapability = 200
        static let hintedCapability = 120
        static let currentStructuredMemoryFit = 220
        static let staleStructuredMemoryFit = 140
        static let localReadyOutput = 180
        static let preferredOverride = 1_500
        static let sizePreferenceUnit = 20
        static let benchmarkSingleRun = 80
        static let benchmarkRepeatedRuns = 140
        static let benchmarkSampleCap = 80
    }

    struct Candidate {
        let model: LibraryModel
        let record: CatalogRecord?
        let benchmark: RecommendationBenchmarkResult?
        let freshness: RecommendationFreshness
        let baseScore: Int
        let sizeBytes: Int64
        let reasons: [RecommendationReason]
        let evidence: [RecommendationEvidence]
        let usesStructuredCapability: Bool
        let usesHintedCapability: Bool
        let usesStructuredMemoryEvidence: Bool
    }

    struct Assessment {
        let score: Int
        let reasons: [RecommendationReason]
        let evidence: [RecommendationEvidence]
        let usesStructuredMetadata: Bool
        let usesHint: Bool
    }

    struct CatalogAuthority {
        let state: CatalogState
        let recordsByFamily: [String: CatalogRecord]
        let currentMetadata: Bool
        let baseFreshness: RecommendationFreshness

        init(_ state: CatalogState) {
            self.state = state
            switch state {
            case .current(let snapshot), .currentFailure(let snapshot, _):
                self.recordsByFamily = Self.index(records: snapshot.records)
                self.currentMetadata = true
                self.baseFreshness = .catalogCurrent
            case .stale(let snapshot), .staleFailure(let snapshot, _):
                self.recordsByFamily = Self.index(records: snapshot.records)
                self.currentMetadata = false
                self.baseFreshness = .catalogStale
            case .refreshFailed(let snapshot, _):
                self.recordsByFamily = Self.index(records: snapshot?.records ?? [])
                self.currentMetadata = false
                self.baseFreshness = snapshot == nil ? .catalogUnavailable : .catalogStale
            case .missing, .unavailable, .corrupt:
                self.recordsByFamily = [:]
                self.currentMetadata = false
                self.baseFreshness = .catalogUnavailable
            }
        }

        func record(for model: LibraryModel) -> CatalogRecord? {
            let keys = [
                normalizedCatalogKey(model.normalizedFamilyKey),
                normalizedCatalogKey(model.item.modelKey),
                normalizedCatalogKey(model.displayName)
            ]
            for key in keys where !key.isEmpty {
                if let record = recordsByFamily[key] {
                    return record
                }
            }
            return nil
        }

        func freshness(for record: CatalogRecord?) -> RecommendationFreshness {
            record == nil ? .localOnly : baseFreshness
        }

        private static func index(records: [CatalogRecord]) -> [String: CatalogRecord] {
            let ordered = records.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                if lhs.revision != rhs.revision {
                    return lhs.revision > rhs.revision
                }
                return lhs.repoIdentity < rhs.repoIdentity
            }

            var indexed: [String: CatalogRecord] = [:]
            for record in ordered {
                let key = normalizedCatalogKey(record.repoIdentity)
                guard !key.isEmpty, indexed[key] == nil else { continue }
                indexed[key] = record
            }
            return indexed
        }
    }

    static func benchmarkIndex(
        from results: [RecommendationBenchmarkResult]
    ) -> [String: RecommendationBenchmarkResult] {
        let ordered = results.sorted { lhs, rhs in
            if lhs.measuredAt != rhs.measuredAt {
                return lhs.measuredAt > rhs.measuredAt
            }
            if lhs.sampleCount != rhs.sampleCount {
                return lhs.sampleCount > rhs.sampleCount
            }
            return lhs.modelID < rhs.modelID
        }

        var indexed: [String: RecommendationBenchmarkResult] = [:]
        for result in ordered {
            let key = benchmarkKey(modelID: result.modelID, useCase: result.useCase)
            if indexed[key] == nil {
                indexed[key] = result
            }
        }
        return indexed
    }

    static func benchmarkKey(modelID: String, useCase: UseCase) -> String {
        "\(useCase.rawValue)::\(modelID)"
    }

    static func isEligibleLocalModel(
        _ model: LibraryModel,
        preferences: RecommendationPreferences
    ) -> Bool {
        guard !preferences.hiddenModelIDs.contains(model.item.path) else { return false }
        guard model.readiness == .ready else { return false }
        guard model.item.readable != false else { return false }
        let error = model.item.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard error.isEmpty else { return false }
        return true
    }

    static func capabilityAssessment(
        for useCase: UseCase,
        model: LibraryModel,
        record: CatalogRecord?,
        authority: CatalogAuthority
    ) -> Assessment? {
        if let record, let roles = record.roles {
            if authority.currentMetadata {
                guard roles.contains(useCase) else { return nil }
                return Assessment(
                    score: Score.currentStructuredCapability,
                    reasons: [
                        RecommendationReason(
                            name: "catalog_role",
                            message: "Current catalog metadata lists this family for \(useCase.title).",
                            isHint: false
                        )
                    ],
                    evidence: [
                        RecommendationEvidence(
                            name: "catalog_role",
                            value: "roles=\(roles.map(\.rawValue).joined(separator: ","))",
                            observedAt: record.updatedAt,
                            isHint: false
                        )
                    ],
                    usesStructuredMetadata: true,
                    usesHint: false
                )
            }

            if roles.contains(useCase) {
                return Assessment(
                    score: Score.staleStructuredCapability,
                    reasons: [
                        RecommendationReason(
                            name: "stale_catalog_role",
                            message: "Stale catalog metadata last listed this family for \(useCase.title).",
                            isHint: false
                        )
                    ],
                    evidence: [
                        RecommendationEvidence(
                            name: "stale_catalog_role",
                            value: "roles=\(roles.map(\.rawValue).joined(separator: ","))",
                            observedAt: record.updatedAt,
                            isHint: false
                        )
                    ],
                    usesStructuredMetadata: true,
                    usesHint: false
                )
            }
        }

        if useCase == .generalChat {
            return Assessment(
                score: Score.hintedCapability,
                reasons: [
                    RecommendationReason(
                        name: "general_chat_baseline",
                        message: "No structured role metadata was available, so this stays a conservative local general chat candidate only.",
                        isHint: true
                    )
                ],
                evidence: [
                    RecommendationEvidence(
                        name: "local_identity",
                        value: model.displayName,
                        observedAt: nil,
                        isHint: true
                    )
                ],
                usesStructuredMetadata: false,
                usesHint: true
            )
        }

        guard model.capabilities.contains(useCase) else { return nil }
        return Assessment(
            score: Score.hintedCapability,
            reasons: [
                RecommendationReason(
                    name: "name_hint",
                    message: "The local model name hints at \(useCase.title), but the scan did not observe that capability directly.",
                    isHint: true
                )
            ],
            evidence: [
                RecommendationEvidence(
                    name: "local_name_hint",
                    value: model.displayName,
                    observedAt: nil,
                    isHint: true
                )
            ],
            usesStructuredMetadata: false,
            usesHint: true
        )
    }

    static func memoryAssessment(
        model: LibraryModel,
        record: CatalogRecord?,
        snapshot: LibrarySnapshot,
        authority: CatalogAuthority
    ) -> Assessment? {
        if let record,
           let estimatedBytes = record.estimatedMemoryBytes,
           let hardwareBytes = snapshot.hardware.memoryBytes {
            guard estimatedBytes <= hardwareBytes else { return nil }
            let label = authority.currentMetadata ? "catalog_memory_fit" : "stale_catalog_memory_fit"
            let messagePrefix = authority.currentMetadata ? "Current" : "Stale"
            return Assessment(
                score: authority.currentMetadata ? Score.currentStructuredMemoryFit : Score.staleStructuredMemoryFit,
                reasons: [
                    RecommendationReason(
                        name: label,
                        message: "\(messagePrefix) catalog memory metadata still fits within this Mac's memory.",
                        isHint: false
                    )
                ],
                evidence: [
                    RecommendationEvidence(
                        name: label,
                        value: "estimated_memory_bytes=\(estimatedBytes)",
                        observedAt: record.updatedAt,
                        isHint: false
                    )
                ],
                usesStructuredMetadata: true,
                usesHint: false
            )
        }

        guard !model.outputPaths.isEmpty else { return nil }
        return Assessment(
            score: Score.localReadyOutput,
            reasons: [
                RecommendationReason(
                    name: "local_output_detected",
                    message: "A ready local MLX output is already present for this model on this Mac.",
                    isHint: false
                )
            ],
            evidence: [
                RecommendationEvidence(
                    name: "local_output_paths",
                    value: model.outputPaths.joined(separator: ", "),
                    observedAt: snapshot.generatedAt,
                    isHint: false
                )
            ],
            usesStructuredMetadata: false,
            usesHint: false
        )
    }

    static func scoreSizeBytes(for model: LibraryModel, record: CatalogRecord?) -> Int64 {
        max(record?.estimatedMemoryBytes ?? model.item.bytes, 1)
    }

    static func benchmarkScore(for benchmark: RecommendationBenchmarkResult) -> Int {
        let base = benchmark.sampleCount > 1 ? Score.benchmarkRepeatedRuns : Score.benchmarkSingleRun
        let throughput = min(Int((benchmark.tokensPerSecond ?? 0) / 4), Score.benchmarkSampleCap / 2)
        let latency = benchmark.timeToFirstTokenSeconds.map { max(0, min(Int((5 - $0) * 10), Score.benchmarkSampleCap / 2)) } ?? 0
        return base + throughput + latency
    }

    static func benchmarkReason(
        for benchmark: RecommendationBenchmarkResult,
        useCase: UseCase
    ) -> RecommendationReason {
        let sampleLabel = benchmark.sampleCount == 1 ? "one local sample" : "\(benchmark.sampleCount) local samples"
        return RecommendationReason(
            name: "local_benchmark",
            message: "A \(useCase.title) benchmark is available from \(sampleLabel), so this ranking uses measured local speed conservatively.",
            isHint: false
        )
    }

    static func benchmarkSummary(for benchmark: RecommendationBenchmarkResult) -> String {
        var parts: [String] = []
        if let tokensPerSecond = benchmark.tokensPerSecond {
            parts.append(String(format: "tok/s=%.1f", tokensPerSecond))
        }
        if let ttft = benchmark.timeToFirstTokenSeconds {
            parts.append(String(format: "ttft=%.2fs", ttft))
        }
        parts.append("samples=\(benchmark.sampleCount)")
        return parts.joined(separator: ", ")
    }

    static func sizeRanks(in candidates: [Candidate], ascending: Bool) -> [Int64: Int] {
        let uniqueSizes = Array(Set(candidates.map(\.sizeBytes))).sorted(by: ascending ? (<) : (>))
        var ranks: [Int64: Int] = [:]
        for (index, size) in uniqueSizes.enumerated() {
            ranks[size] = uniqueSizes.count - index
        }
        return ranks
    }

    static func confidence(for candidate: Candidate) -> RecommendationConfidence {
        if candidate.usesStructuredCapability && candidate.usesStructuredMemoryEvidence && !candidate.usesHintedCapability {
            return candidate.benchmark == nil ? .medium : .high
        }
        if candidate.usesStructuredCapability || candidate.benchmark != nil {
            return .medium
        }
        return .low
    }

    static func recommendationSort(lhs: Recommendation, rhs: Recommendation) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if confidenceRank(lhs.confidence) != confidenceRank(rhs.confidence) {
            return confidenceRank(lhs.confidence) > confidenceRank(rhs.confidence)
        }
        if freshnessRank(lhs.freshness) != freshnessRank(rhs.freshness) {
            return freshnessRank(lhs.freshness) > freshnessRank(rhs.freshness)
        }
        return lhs.modelID < rhs.modelID
    }

    static func confidenceRank(_ confidence: RecommendationConfidence) -> Int {
        switch confidence {
        case .high:
            return 3
        case .medium:
            return 2
        case .low:
            return 1
        }
    }

    static func freshnessRank(_ freshness: RecommendationFreshness) -> Int {
        switch freshness {
        case .catalogCurrent:
            return 4
        case .localOnly:
            return 3
        case .catalogStale:
            return 2
        case .catalogUnavailable:
            return 1
        }
    }

    static func normalizedCatalogKey(_ value: String?) -> String {
        let raw = value?.lowercased() ?? ""
        return raw.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
