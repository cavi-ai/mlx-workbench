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
        activeModelPath = target
        progressMessage = "Starting verification server."
        lastError = nil

        Task { [probe, now] in
            let startedAt = now()
            do {
                let result = try await probe.run(modelPath: modelPath)
                let finishedAt = now()
                let canaries = CanarySuite.cases.compactMap { kase -> CanaryResult? in
                    result.samples[kase.id].map { CanarySuite.evaluate(kase, sample: $0) }
                }
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
                    metricsEstimated: result.samples.values.contains(where: \.metricsEstimated),
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    outcome: outcome
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
