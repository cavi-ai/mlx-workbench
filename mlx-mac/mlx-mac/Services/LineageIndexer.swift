import Foundation

// MARK: - LineageIndexer
//
// Pure, read-only assembly of a model's provenance timeline (premium spec
// 07). All inputs are supplied by the caller; nothing touches disk, network,
// or process state. Matching is by canonical path (and exact output paths),
// with signature-based staleness dimming.

enum LineageIndexer {
    static func assemble(
        modelPath: String,
        item: ModelItem?,
        workflows: [ConversionWorkflow],
        reports: [VerificationReport],
        runs: [ComparisonRun],
        lastUsedByPath: [String: Date],
        transactions: [WiringTransaction],
        quarantineRecords: [QuarantineRecord]
    ) -> ModelLineage {
        let target = canonical(modelPath)
        let currentSignature = item?.signature
        var events: [LineageEvent] = []

        if let item {
            events.append(sourceEvent(item))
        }
        events.append(contentsOf: conversionEvents(workflows: workflows, target: target))
        events.append(contentsOf: verificationEvents(reports: reports, target: target, currentSignature: currentSignature))
        events.append(contentsOf: benchmarkEvents(runs: runs, target: target, currentSignature: currentSignature))
        if let used = lastUsedByPath[target] ?? lastUsedByPath[modelPath] {
            events.append(LineageEvent(
                kind: .served,
                at: used,
                summary: "Last served, verified, or measured.",
                detail: ["path": target]
            ))
        }
        events.append(contentsOf: wiringEvents(transactions: transactions, target: target))
        events.append(contentsOf: quarantineEvents(records: quarantineRecords, target: target))

        return ModelLineage(
            modelPath: target,
            currentSignature: currentSignature,
            events: events.sorted { $0.at > $1.at }
        )
    }

    // MARK: - Event builders

    private static func sourceEvent(_ item: ModelItem) -> LineageEvent {
        var detail: [String: String] = ["path": item.path]
        if let architecture = item.architecture { detail["architecture"] = architecture }
        if let quantization = item.quantization { detail["quantization"] = quantization }
        if let parameters = item.parameters { detail["parameters"] = parameters }
        detail["size"] = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        let at = item.modifiedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantPast
        return LineageEvent(
            kind: .source,
            at: at,
            summary: "\(item.name) on disk (\(detail["size"] ?? "unknown size")).",
            detail: detail
        )
    }

    private static func conversionEvents(workflows: [ConversionWorkflow], target: String) -> [LineageEvent] {
        workflows.compactMap { workflow in
            let paths = [workflow.completedModelPath, workflow.outputPath].compactMap { $0 }.map(canonical)
            guard paths.contains(target), !workflow.sourcePath.isEmpty else { return nil }
            let terminalStates: Set<ConversionWorkflowState> = [.completed, .verified, .verificationFailed]
            guard terminalStates.contains(workflow.state) else { return nil }
            var detail: [String: String] = ["source": workflow.sourcePath]
            if let receipt = workflow.jobReceipt { detail["receipt"] = receipt }
            return LineageEvent(
                kind: .converted,
                at: workflow.updatedAt,
                summary: "Converted from \(URL(fileURLWithPath: workflow.sourcePath).lastPathComponent).",
                detail: detail
            )
        }
    }

    private static func verificationEvents(
        reports: [VerificationReport],
        target: String,
        currentSignature: String?
    ) -> [LineageEvent] {
        reports.compactMap { report in
            guard canonical(report.modelPath) == target else { return nil }
            let stale = report.modelSignature != nil
                && currentSignature != nil
                && report.modelSignature != currentSignature
            var detail: [String: String] = ["suite": "v\(report.suiteVersion)"]
            if let tps = report.tokensPerSecond {
                detail["tok/s"] = String(format: "%.1f%@", tps, report.metricsEstimated ? " (estimated)" : "")
            }
            if let ttft = report.timeToFirstTokenSeconds {
                detail["TTFT"] = String(format: "%.2fs", ttft)
            }
            let kind: LineageEventKind = report.outcome == .passed ? .verified : .verificationFailed
            return LineageEvent(
                kind: kind,
                at: report.finishedAt,
                summary: report.outcome.summary,
                detail: detail,
                stale: stale
            )
        }
    }

    private static func benchmarkEvents(
        runs: [ComparisonRun],
        target: String,
        currentSignature: String?
    ) -> [LineageEvent] {
        runs.compactMap { run in
            guard run.state == .completed,
                  let finishedAt = run.finishedAt,
                  let result = run.results.first(where: { canonical($0.modelPath) == target }) else { return nil }
            let stale = result.modelSignature != nil
                && currentSignature != nil
                && result.modelSignature != currentSignature
            var detail: [String: String] = ["prompt set": run.promptSetName]
            if let tps = result.aggregateTokensPerSecond {
                detail["tok/s"] = String(format: "%.1f", tps)
            }
            if let ttft = result.aggregateTTFTSeconds {
                detail["TTFT"] = String(format: "%.2fs", ttft)
            }
            detail["prompts"] = String(result.samples.count)
            return LineageEvent(
                kind: .benchmarked,
                at: finishedAt,
                summary: "Measured against \"\(run.promptSetName)\".",
                detail: detail,
                stale: stale
            )
        }
    }

    private static func wiringEvents(transactions: [WiringTransaction], target: String) -> [LineageEvent] {
        let modelName = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
        return transactions
            .filter { $0.modelName == modelName }
            .map { transaction in
                let rolledBack = transaction.rolledBackAt != nil
                return LineageEvent(
                    kind: .wired,
                    at: transaction.appliedAt,
                    summary: "Wired to \(transaction.receipts.count) client(s) at \(transaction.endpointBaseURL)\(rolledBack ? " (rolled back)" : "").",
                    detail: [
                        "clients": transaction.receipts.map(\.clientID).sorted().joined(separator: ", "),
                        "endpoint": transaction.endpointBaseURL,
                    ]
                )
            }
    }

    private static func quarantineEvents(records: [QuarantineRecord], target: String) -> [LineageEvent] {
        records.compactMap { record in
            guard canonical(record.from) == target else { return nil }
            return LineageEvent(
                kind: .quarantined,
                at: ISO8601DateFormatter().date(from: record.movedAt) ?? .distantPast,
                summary: "Moved to quarantine.",
                detail: ["destination": record.to, "bytes": String(record.bytes)]
            )
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
