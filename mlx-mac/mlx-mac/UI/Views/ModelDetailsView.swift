import AppKit
import SwiftUI

struct ModelDetailsView: View {
    @ObservedObject var appHost: AppHost

    let model: LibraryModel
    let snapshotGeneratedAt: Date
    let onRouteSelection: (String) -> Void

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
