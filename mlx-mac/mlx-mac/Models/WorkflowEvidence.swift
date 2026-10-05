import Foundation

/// Interchange contract: seconds, bytes and ISO-8601 dates. No prompts or transcripts.
struct WorkflowReport: Codable, Equatable {
    let schemaVersion: Int
    let records: [WorkflowEvidence]
    var guidance: String? = nil

    static let template = WorkflowReport(schemaVersion: 1, records: [], guidance: "No measurements in this template. Each record requires UUID id, harness (claude/openclaw/opencode/custom), workloadID, absolute modelPath, modelSignature, environmentFingerprint, ISO8601 measuredAt, positive sampleCount, totalSeconds and source (receipt/session identifier, no secrets). Optional configurationFingerprint (producer hash of prompts/tools/context/generation settings; required for replacement advice), useCase, inferenceSeconds, toolSeconds, queueSeconds, timeToFirstTokenSeconds, tokensPerSecond, qualityScore (1...5), rubricID, peakMemoryBytes, availableMemoryBytes. Timings are seconds; memory is bytes. Quality requires a shared rubricID. Components must be additive disjoint durations and sum to at most totalSeconds. Missing fields remain unknown. Copy exact identity/fingerprint from Export agent evidence; never replace an older fingerprint with a current one.")
}

struct WorkflowEvidence: Codable, Equatable, Identifiable {
    let id: UUID
    let harness: String
    let workloadID: String
    let useCase: UseCase?
    let modelPath: String
    let modelSignature: String
    let environmentFingerprint: String
    let measuredAt: Date
    let sampleCount: Int
    let totalSeconds: Double
    let source: String
    var inferenceSeconds: Double? = nil
    var toolSeconds: Double? = nil
    var queueSeconds: Double? = nil
    var timeToFirstTokenSeconds: Double? = nil
    var tokensPerSecond: Double? = nil
    var qualityScore: Int? = nil
    var rubricID: String? = nil
    var peakMemoryBytes: Int64? = nil
    var availableMemoryBytes: Int64? = nil
    /// Producer hash of prompt/tool/context/generation settings; nil is display-only evidence.
    var configurationFingerprint: String? = nil

    /// Unattributed time, only when all additive components were supplied.
    var unattributedSeconds: Double? {
        guard let inferenceSeconds, let toolSeconds, let queueSeconds else { return nil }
        return max(0, totalSeconds - inferenceSeconds - toolSeconds - queueSeconds)
    }

    func validate() throws {
        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw WorkflowEvidenceError.invalid(field) }
        }
        try require(["claude", "openclaw", "opencode", "custom"].contains(harness), "harness")
        for (field, value) in [("workloadID", workloadID), ("modelPath", modelPath), ("modelSignature", modelSignature), ("environmentFingerprint", environmentFingerprint), ("source", source)] {
            try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), field)
        }
        try require(modelPath.hasPrefix("/"), "absolute modelPath")
        try require((1...1_000_000).contains(sampleCount), "sampleCount")
        try require(measuredAt.timeIntervalSince1970.isFinite && measuredAt <= Date().addingTimeInterval(300), "measuredAt")
        for value in [totalSeconds, inferenceSeconds, toolSeconds, queueSeconds, timeToFirstTokenSeconds, tokensPerSecond].compactMap({ $0 }) {
            try require(value.isFinite && value >= 0, "finite nonnegative metric")
        }
        try require(totalSeconds > 0, "totalSeconds")
        let components = [inferenceSeconds, toolSeconds, queueSeconds].compactMap { $0 }
        try require(components.reduce(0, +) <= totalSeconds + 0.000001, "component durations exceed totalSeconds")
        if let timeToFirstTokenSeconds { try require(timeToFirstTokenSeconds <= totalSeconds, "TTFT exceeds totalSeconds") }
        if let qualityScore {
            try require((1...5).contains(qualityScore) && !(rubricID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), "qualityScore requires rubricID")
        }
        for (field, value) in [("rubricID", rubricID), ("configurationFingerprint", configurationFingerprint)] {
            if let value { try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), field) }
        }
        for value in [peakMemoryBytes, availableMemoryBytes].compactMap({ $0 }) { try require(value >= 0, "memory bytes") }
    }
}

enum WorkflowEvidenceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let field): return "Workflow report rejected: \(field)." }
    }
}

struct AgentEvidenceExport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let hardware: HardwareProfile
    let environmentFingerprint: String?
    let memoryCapturedAt: Date?
    let availableMemoryBytes: Int64?
    let contextTokens: Int
    let reserveGB: Double
    let models: [AgentModelFact]
    let comparisons: [AgentComparisonFact]
    let workflowReports: [WorkflowEvidence]
    let replacementReviews: [String]
    let limitations: [String]
    var taskTradeoffs: [String] = []
    var replacementChains: [ModelReplacementChain] = []
}
struct AgentModelFact: Codable {
    let path: String
    let signature: String?
    let name: String
    let tasks: [UseCase]
    let diskBytes: Int64
    let readiness: String
    let fitEstimate: String
    let estimatedRequiredBytes: Int64?
    let protected: Bool
}
struct AgentComparisonFact: Codable {
    let runID: UUID
    let workloadID: String
    let promptSetName: String
    let useCase: UseCase?
    let mode: String
    let measuredAt: Date
    let modelPath: String
    let modelSignature: String?
    let environmentFingerprint: String?
    let sampleCount: Int
    let successfulSamples: Int
    let tokensPerSecond: Double?
    let timeToFirstTokenSeconds: Double?
    let quality: ComparisonQualityReview?
    let limitedValidation: String
    let current: Bool
    var aggregateMetric: Double? = nil
    var primaryMetric: String? = nil
    var evidenceStatus: String? = nil
    /// Peak reported by a recorded sample at measuredAt, never a current fit guarantee.
    var samplePeakMemoryGB: Double? = nil
}
