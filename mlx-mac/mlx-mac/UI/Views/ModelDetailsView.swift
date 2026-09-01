import AppKit
import SwiftUI

struct ModelDetailsView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var verification: VerificationCoordinator

    let model: LibraryModel
    let snapshotGeneratedAt: Date
    let onRouteSelection: (String) -> Void

    init(appHost: AppHost, model: LibraryModel, snapshotGeneratedAt: Date, onRouteSelection: @escaping (String) -> Void) {
        self.appHost = appHost
        _verification = ObservedObject(wrappedValue: appHost.verification)
        self.model = model
        self.snapshotGeneratedAt = snapshotGeneratedAt
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionRow

                VStack(alignment: .leading, spacing: 10) {
                    detailRow("Path", model.item.path)
                    detailRow("Source", sourceIdentity)
                    detailRow("Architecture", known(model.item.architecture))
                    detailRow("Parameters", known(model.item.parameters))
                    detailRow("Quantization", known(model.item.quantization))
                    detailRow("Outputs", lines(model.outputPaths))
                    detailRow("Readiness", model.readiness.title)
                    detailRow("Duplicate status", duplicateStatus)
                    detailRow("Prepare destination", prepareDestination)
                    detailRow("Why", readinessExplanation)
                    detailRow("Source paths", lines(model.sourcePaths))
                    detailRow("Signature", known(model.item.signature))
                    detailRow("Size", ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file))
                }
                .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Evidence timestamps")
                    detailRow("File modified", modifiedAtText)
                    detailRow("Library scan", format(snapshotGeneratedAt))
                }
                .textSelection(.enabled)

                verificationSection

                lineageSection

                if let error = model.item.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: "Observed issue")
                        detailRow("Error", error)
                    }
                    .textSelection(.enabled)
                }

                DisclosureGroup("Raw model evidence") {
                    let evidence = LibraryPresentation.userFacingEvidence(model.evidence)
                    Group {
                        if evidence.isEmpty {
                            Text("Unknown")
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(evidence, id: \.self) { entry in
                                    Text(entry)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.displayName)
                    .font(.title2)
                StatusPill(state: model.readiness.rawValue)
                Spacer()
                if appHost.selectedModelPath == model.item.path {
                    Text("Selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("Model identity: \(known(model.item.modelKey))")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Copy Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(model.item.path, forType: .string)
            }

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.item.path)])
            }

            Spacer()

            Button("Prepare to run") {
                appHost.selectedModelPath = model.item.path
                appHost.modelWorkflow.inspect(source: model.item, snapshot: appHost.librarySnapshot)
                onRouteSelection("convert")
            }

            Button("Select for Compare") {
                selectAndRoute(to: "quant")
            }

            Button("Select for Try") {
                selectAndRoute(to: "serve")
            }
        }
        .buttonStyle(.bordered)
    }

    private var sourceIdentity: String {
        lines(model.sourcePaths)
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Verification")
            switch appHost.verification.status(for: model.item.path, signature: model.item.signature) {
            case .verified(let report):
                detailRow("Status", "Verified (canary suite v\(report.suiteVersion))")
                verificationMetrics(report)
            case .failed(let report):
                detailRow("Status", "Failed — \(report.outcome.summary)")
                verificationMetrics(report)
            case .keptAnyway(let report):
                detailRow("Status", "Kept despite a failed verification")
                verificationMetrics(report)
            case .stale(let report):
                detailRow("Status", "Stale — the file changed since verification on \(format(report.finishedAt))")
            case .inProgress:
                detailRow("Status", appHost.verification.progressMessage ?? "Verification in progress…")
            case .unverified:
                detailRow("Status", "Not verified by the canary suite.")
            }
            if model.readiness == .ready {
                Button("Verify now") {
                    appHost.verification.verifyNow(modelPath: model.item.path, signature: model.item.signature)
                }
                .disabled(appHost.verification.activeModelPath != nil)
            }
        }
    }

    private func verificationMetrics(_ report: VerificationReport) -> some View {
        Group {
            if let tps = report.tokensPerSecond {
                detailRow("Decode speed", String(format: "%.1f tok/s%@", tps, report.metricsEstimated ? " (estimated)" : ""))
            }
            if let ttft = report.timeToFirstTokenSeconds {
                detailRow("First token", String(format: "%.2fs", ttft))
            }
            ForEach(report.canaries, id: \.id) { canary in
                detailRow(canary.title, canary.passed ? "Passed" : "Failed: \(canary.failureReason ?? "unknown")")
            }
        }
    }

    // MARK: - Lineage

    private var lineageSection: some View {
        let lineage = appHost.lineage(for: model.item.path)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Lineage")
                Spacer()
                Button("Copy Markdown") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(lineage.markdown, forType: .string)
                }
                .controlSize(.small)
                Button("Export JSON…") { exportLineage(lineage) }
                    .controlSize(.small)
            }
            if lineage.events.isEmpty {
                Text("No recorded history for this model yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(lineage.events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.kind.systemImage)
                            .foregroundColor(event.kind == .verificationFailed ? .red : .accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.kind.title).font(.callout).fontWeight(.medium)
                                if event.stale {
                                    Text("predates current bytes")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                                Spacer()
                                Text(event.at, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(event.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(event.detail.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key): \(value)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .opacity(event.stale ? 0.6 : 1)
                }
            }
        }
    }

    private func exportLineage(_ lineage: ModelLineage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(model.item.name)-lineage.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(lineage) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private var readinessExplanation: String {
        switch model.readiness {
        case .ready:
            if !model.outputPaths.isEmpty {
                return "An MLX output path was detected for this local model."
            }
            return "The scan marked this local model ready."
        case .needsConversion:
            return "No local MLX output was detected, so this model still needs Prepare work."
        case .needsRuntime:
            return "The scan marked the runtime as missing for this model."
        case .incompleteCache:
            return model.item.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The scan reported incomplete local metadata for this model."
        case .unsupported:
            if model.item.readable == false {
                return "The local file was not readable during the scan."
            }
            return "The scan marked this local model unsupported."
        case .duplicate:
            return "This local variant is redundant with another copy in the same family group."
        case .quarantined:
            return "This model is quarantined and should not be used for Prepare or Try."
        }
    }

    private var duplicateStatus: String {
        guard model.readiness == .duplicate else {
            return "No duplicate status reported by the latest library scan."
        }
        return "Duplicate variant reported by the latest library scan. Review the raw model evidence before preparing it."
    }

    private var prepareDestination: String {
        switch ModelWorkflowResolver.destination(for: model.item, library: appHost.librarySnapshot) {
        case .reuseExisting(let existing):
            return "Existing equivalent MLX model: \(existing.item.path)"
        case .available(let destination):
            return destination.path
        case .blocked(let destination, let reason):
            return "\(destination.path)\nBlocked: \(reason)"
        }
    }

    private var modifiedAtText: String {
        guard let modifiedAt = model.item.modifiedAt else { return "Unknown" }
        return format(Date(timeIntervalSince1970: TimeInterval(modifiedAt)))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lines(_ values: [String]) -> String {
        if values.isEmpty {
            return "Unknown"
        }
        return values.joined(separator: "\n")
    }

    private func known(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func selectAndRoute(to route: String) {
        appHost.selectedModelPath = model.item.path
        if route == "serve", model.readiness == .ready {
            appHost.modelWorkflow.prepareServe(model: model)
        }
        onRouteSelection(route)
    }
}
