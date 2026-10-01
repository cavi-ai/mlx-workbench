import SwiftUI
import AppKit

struct PortAnalysisPanel: View {
    @ObservedObject var intake: IntakeCoordinator
    let analysis: PortAnalysis

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Porting analysis")
                DetailGrid(rows: PortAnalysisPresentation.rows(analysis))
                ForEach(analysis.components) { component in
                    HStack(alignment: .firstTextBaseline) {
                        Text(component.role).font(WorkbenchTypography.label).frame(width: 80, alignment: .leading)
                        Text(component.modelType).font(WorkbenchTypography.value)
                        Spacer()
                        Text(component.status == "exists" ? (component.matches.first?.module ?? "exists") : "missing")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(component.status == "exists" ? WorkbenchColor.success : WorkbenchColor.warning)
                    }
                }
                if !analysis.missing.isEmpty {
                    Text("To write: " + analysis.missing.map(\.name).joined(separator: ", "))
                        .font(WorkbenchTypography.body)
                }
                draftRow
            }
        }
    }

    @ViewBuilder
    private var draftRow: some View {
        if let draft = intake.draft {
            HStack(spacing: WorkbenchSpacing.sm) {
                InlineMessage(kind: .success, text: "Draft written: \(draft.path)")
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: draft.path)])
                }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.path, forType: .string)
                }
            }
        } else if let server = intake.draftServer {
            Button("Draft port plan with \(server.modelIdentity)") { Task { await intake.draftPlan() } }
                .disabled(intake.isBusy)
        } else {
            Text("Start a model in Run to draft a plan with it; the analysis above needs no model.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }
}

enum PortAnalysisPresentation {
    static func rows(_ analysis: PortAnalysis) -> [DetailRow] {
        var rows = [DetailRow("Architecture", analysis.modelType ?? "Unknown")]
        if let processor = analysis.processorClass { rows.append(DetailRow("Processor", processor)) }
        if let version = analysis.transformersVersion { rows.append(DetailRow("transformers", version)) }
        let tensors = analysis.weights.prefixes.reduce(0) { $0 + $1.tensors }
        rows.append(DetailRow("Weights", "\(tensors) tensors in \(analysis.weights.prefixes.count) prefixes"))
        let classes = analysis.code.files.reduce(0) { $0 + $1.classes.count }
        rows.append(DetailRow("Custom code", "\(analysis.code.files.count) files, \(classes) classes\(analysis.code.truncated ? " (truncated)" : "")"))
        return rows
    }
}
