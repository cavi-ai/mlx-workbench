import Foundation

// MARK: - VerificationCoordinator
//
// Owns the Conversion Quality Gate. When the model workflow confirms a fresh
// MLX output via rescan, the coordinator serves it on an ephemeral loopback
// port, runs the canary suite, persists a VerificationReport, and resolves
// the workflow record (verified / verificationFailed / completed-unverified).
// Reports vouch for exact bytes: a signature match is required for the
// "verified" status to hold.

@MainActor
protocol ConversionCompletionVerifying: AnyObject {
    func beginVerification(recordID: UUID, modelPath: String, signature: String?)
}

@MainActor
final class VerificationCoordinator: ObservableObject {
    @Published private(set) var reports: [VerificationReport] = []
    @Published private(set) var activeModelPath: String?
    @Published private(set) var progressMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?

    private let probe: ServeProbe
    private let store: VerificationStore
    private let now: () -> Date

    /// Resolution callback into the model workflow. Set by `attach(to:)`.
    var onResolution: ((UUID, VerificationResolution) -> Void)?
    /// Called after every completed probe run — stamps usage evidence for the
    /// Disk Pressure Advisor.
    var onReport: ((VerificationReport) -> Void)?
    /// Environment fingerprint provider (spec 08): recorded on every report
    /// so macOS/MLX drift can mark old evidence stale. Default: none.
    var environmentFingerprint: () -> String? = { nil }
    /// The library's model type for a path; speech-to-text and classification models take their own canary.
    var taskType: (String) -> ModelTaskType? = { _ in nil }
    /// Speech canary dependencies; without them speech models are reported unverifiable.
    var speech: SpeechCanaryRunner?
    /// Answers the decision canary (model path, request file); without it classification models are unverifiable.
    var decide: (@Sendable (String, URL) async throws -> DecisionResult)?

    init(probe: ServeProbe, store: VerificationStore, now: @escaping () -> Date = Date.init) {
        self.probe = probe
        self.store = store
        self.now = now
        do {
            reports = try store.load().sorted { $0.finishedAt > $1.finishedAt }
        } catch {
            persistenceError = "Saved verification reports are unavailable: \(AppHost.render(error))"
        }
    }

    /// Link this coordinator to the model workflow so completed conversions
    /// route through verification and outcomes resolve the workflow record.
    func attach(to workflow: ModelWorkflowCoordinator) {
        workflow.completionVerifier = self
        onResolution = { [weak workflow] recordID, resolution in
            workflow?.resolveVerification(recordID: recordID, resolution: resolution)
        }
    }

    /// Unlink (Settings toggle off). In-flight verification still completes
    /// and persists its report; the workflow record resolves to completed.
    func detach(from workflow: ModelWorkflowCoordinator) {
        if workflow.completionVerifier === self {
            workflow.completionVerifier = nil
        }
        onResolution = nil
    }

    /// Manual re-verification for any model (no workflow record attached).
    func verifyNow(modelPath: String, signature: String?) {
        guard activeModelPath == nil else {
            lastError = "Another verification is already in progress."
            return
        }
        run(modelPath: modelPath, signature: signature, recordID: nil)
    }

    func status(for path: String, signature: String?) -> VerificationStatus {
        if activeModelPath == canonical(path) { return .inProgress }
        guard let report = latestReport(for: path) else { return .unverified }
        if let signature, let reportSignature = report.modelSignature, signature != reportSignature {
            return .stale(report)
        }
        switch report.outcome {
        case .passed: return .verified(report)
        case .failed, .error: return .failed(report)
        case .keptDespiteFailure: return .keptAnyway(report)
        }
    }

    /// Explicit user override: keep a model whose verification failed.
    /// Resolves the linked workflow record back to plain `.completed`.
    func keepAnyway(recordID: UUID) {
        guard let report = reports.first(where: {
            $0.workflowRecordID == recordID && $0.outcome != .passed && $0.outcome != .keptDespiteFailure
        }) else { return }
        var updated = report
        updated.outcome = .keptDespiteFailure
        persist(updated)
        onResolution?(recordID, .keptAnyway)
    }

    private func latestReport(for path: String) -> VerificationReport? {
        let target = canonical(path)
        return reports.first(where: { canonical($0.modelPath) == target })
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func persist(_ report: VerificationReport) {
        if let index = reports.firstIndex(where: { $0.id == report.id }) {
            reports[index] = report
        } else {
            reports.insert(report, at: 0)
        }
        do {
            try store.upsert(report)
        } catch {
            persistenceError = "Verification report could not be saved: \(AppHost.render(error))"
        }
    }
}

extension VerificationCoordinator: ConversionCompletionVerifying {
    func beginVerification(recordID: UUID, modelPath: String, signature: String?) {
        guard activeModelPath == nil else {
            onResolution?(recordID, .unavailable(reason: "Another verification is already in progress."))
            return
        }
        run(modelPath: modelPath, signature: signature, recordID: recordID)
    }

    private func run(modelPath: String, signature: String?, recordID: UUID?) {
        let target = canonical(modelPath)
        let kind = taskType(modelPath)
        let speech = self.speech
        let decide = self.decide
        activeModelPath = target
        switch kind {
        case .speechToText: progressMessage = "Transcribing a spoken canary sentence."
        case .classification: progressMessage = "Routing a canary support ticket."
        default: progressMessage = "Starting verification server."
        }
        lastError = nil

        Task { [probe, now] in
            let startedAt = now()
            do {
                let canaries: [CanaryResult]
                let metricsEstimated: Bool
                if kind == .speechToText {
                    guard let speech else { throw SpeechCanaryError.unavailable }
                    let clip = try await speech.synthesize(SpeechCanary.phrase)
                    defer { try? FileManager.default.removeItem(at: clip) }
                    canaries = [SpeechCanary.evaluate(try await speech.transcribe(modelPath, clip, SpeechCanary.language))]
                    metricsEstimated = false
                } else if kind == .classification {
                    guard let decide else { throw DecisionCanaryError.unavailable }
                    let request = FileManager.default.temporaryDirectory
                        .appendingPathComponent("decision-canary-\(UUID().uuidString).json")
                    try Data(DecisionCanary.request.utf8).write(to: request)
                    defer { try? FileManager.default.removeItem(at: request) }
                    canaries = [DecisionCanary.evaluate(try await decide(modelPath, request))]
                    metricsEstimated = false
                } else {
                    let result = try await probe.run(modelPath: modelPath)
                    canaries = CanarySuite.cases.compactMap { kase -> CanaryResult? in
                        result.samples[kase.id].map { CanarySuite.evaluate(kase, sample: $0) }
                    }
                    metricsEstimated = result.samples.values.contains(where: \.metricsEstimated)
                }
                let finishedAt = now()
                let failedIDs = canaries.filter { !$0.passed }.map(\.id)
                let outcome: VerificationOutcome = failedIDs.isEmpty ? .passed : .failed(canaryIDs: failedIDs)
                let report = VerificationReport(
                    id: UUID(),
                    modelPath: target,
                    modelSignature: signature,
                    workflowRecordID: recordID,
                    suiteVersion: CanarySuite.version,
                    canaries: canaries,
                    tokensPerSecond: CanarySuite.aggregateTokensPerSecond(canaries),
                    timeToFirstTokenSeconds: CanarySuite.aggregateTTFT(canaries),
                    metricsEstimated: metricsEstimated,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    outcome: outcome,
                    environmentFingerprint: self.environmentFingerprint()
                )
                persist(report)
                onReport?(report)
                activeModelPath = nil
                progressMessage = nil
                if let recordID {
                    switch outcome {
                    case .passed:
                        onResolution?(recordID, .passed(summary: reportSummary(report)))
                    case .failed:
                        onResolution?(recordID, .failed(summary: reportSummary(report)))
                    case .error, .keptDespiteFailure:
                        break
                    }
                }
            } catch {
                activeModelPath = nil
                progressMessage = nil
                let rendered = AppHost.render(error)
                lastError = rendered
                if let recordID {
                    onResolution?(recordID, .unavailable(reason: rendered))
                }
            }
        }
    }

    private func reportSummary(_ report: VerificationReport) -> String {
        var parts = [report.outcome.summary]
        if let tps = report.tokensPerSecond {
            parts.append(String(format: "%.1f tok/s", tps) + (report.metricsEstimated ? " (estimated)" : ""))
        }
        if let ttft = report.timeToFirstTokenSeconds {
            parts.append(String(format: "TTFT %.2fs", ttft))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Speech canary

struct SpeechCanaryRunner: Sendable {
    /// Speaks a sentence into an audio file.
    let synthesize: @Sendable (String) async throws -> URL
    /// Transcribes (model path, audio file, language).
    let transcribe: @Sendable (String, URL, String) async throws -> TranscriptionResult
}

enum SpeechCanaryError: LocalizedError {
    case unavailable
    case toolFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech verification is not available in this build."
        case let .toolFailed(tool, status): return "\(tool) exited with status \(status) while making the canary clip."
        }
    }
}

enum DecisionCanaryError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Decision verification is not available in this build." }
}

/// Makes the canary clip with the system voice: `say` to AIFF, `afconvert` to 16 kHz mono WAV.
enum SpeechClipSynthesizer {
    static func make(phrase: String, directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        let stem = directory.appendingPathComponent("speech-canary-\(UUID().uuidString)")
        let aiff = stem.appendingPathExtension("aiff")
        let wav = stem.appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: aiff) }
        try await run("/usr/bin/say", ["-o", aiff.path, phrase])
        try await run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        return wav
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SpeechCanaryError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus)
            }
        }.value
    }
}
