import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowCaptureRequestView: View {
    let models: [WorkflowCaptureModel]
    let initialModelPath: String?
    let environment: String?
    @Environment(\.dismiss) private var dismiss
    @State private var harness: WorkflowHarness = .openCode
    @State private var selectedPath = ""
    @State private var note: String?
    @State private var error: String?

    private var selectedModel: WorkflowCaptureModel? { models.first { $0.path == selectedPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Capture a workflow", systemImage: "arrow.down.doc").font(WorkbenchTypography.roundedTitle)
            Text("Give your agent this request, run the task using the selected local model, then import its measured report.").font(WorkbenchTypography.secondary)
            Picker("Harness", selection: $harness) {
                ForEach(WorkflowHarness.allCases) { Text($0.title).tag($0) }
            }
            Picker("Local model", selection: $selectedPath) {
                Text("Choose a model").tag("")
                ForEach(models) { Text($0.name).tag($0.path) }
            }
            if let selectedModel {
                Text(selectedModel.path).font(WorkbenchTypography.value).textSelection(.enabled)
            }
            Text("The request includes known model and environment identities. Unknown fields stay blank for the producer to establish from the run. Older runs must keep their original identities and dates.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if models.isEmpty { Text("No ready local models available. Rescan Library first.").font(WorkbenchTypography.secondary) }
            if selectedModel?.signature == nil || !ComparisonInsights.knownEnvironment(environment) {
                Text("Some identity context is unavailable. Imported observations stay unconfirmed until Library and this Mac can match them.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            }
            if let note { Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
            ErrorBanner(text: error)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save request…") { makeRequest(saveRequest) }.disabled(selectedModel == nil)
                Button("Copy request") { makeRequest { request in
                    let text = String(decoding: try WorkflowEvidenceStore.encode(request), as: UTF8.self)
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(text, forType: .string) else { throw WorkflowEvidenceError.invalid("could not copy capture request") }
                    note = "Request copied. Ask the agent to fill reportDraft and save that object as JSON."
                } }.buttonStyle(.borderedProminent).disabled(selectedModel == nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 520)
        .onAppear { selectedPath = models.contains(where: { $0.path == initialModelPath }) ? (initialModelPath ?? "") : (models.first?.path ?? "") }
    }

    private func makeRequest(_ consume: (WorkflowCaptureRequest) throws -> Void) {
        guard let selectedModel else { return }
        do {
            try consume(WorkflowCaptureRequest.make(harness: harness, model: selectedModel, environment: environment))
            error = nil
        } catch { self.error = AppHost.render(error) }
    }

    private func saveRequest(_ request: WorkflowCaptureRequest) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "workflow-capture-request.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try JSONStore<WorkflowEvidence>.refuseSymlink(url, fileManager: .default)
                try WorkflowEvidenceStore.encode(request).write(to: url, options: .atomic)
                note = "Saved \(url.lastPathComponent). Ask the agent to fill reportDraft and save that object as JSON."
                self.error = nil
            } catch { self.error = AppHost.render(error) }
        }
    }
}

struct WorkflowImportPreviewView: View {
    let preview: WorkflowImportPreview
    let models: [WorkflowCaptureModel]
    let environment: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Review workflow report", systemImage: "doc.text.magnifyingglass").font(WorkbenchTypography.roundedTitle)
            Text("\(preview.newRecords.count) new · \(preview.duplicateCount) already imported").font(WorkbenchTypography.value)
            Text("Historical or unmatched observations can be saved for reference. They cannot establish current model replacement advice. Import preserves all recorded identities, sources and timestamps.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if preview.report.records.isEmpty { Text("No measurements in this report. Ask your agent to fill the capture request first.").font(WorkbenchTypography.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach(preview.report.records) { record in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            HStack {
                                Text("\(record.harness) · \(record.workloadID)").font(WorkbenchTypography.roundedHeading)
                                Spacer()
                                Text(preview.newRecords.contains(where: { $0.id == record.id }) ? "New" : "Already imported").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                            }
                            Text(models.first(where: { $0.path == record.modelPath })?.name ?? URL(fileURLWithPath: record.modelPath).lastPathComponent).font(WorkbenchTypography.emphasis)
                            let status = WorkflowImportIdentity.status(record, models: models, environment: environment)
                            Text(status.label).font(WorkbenchTypography.label).foregroundStyle(status == .matching ? WorkbenchColor.success : WorkbenchColor.warning)
                            Text("\(record.sampleCount) samples · \(String(format: "%.2f", record.totalSeconds)) s total · \(record.measuredAt.formatted())").font(WorkbenchTypography.secondary)
                            Text("Inference \(seconds(record.inferenceSeconds)) · tools \(seconds(record.toolSeconds)) · queue \(seconds(record.queueSeconds))").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            if record.configurationFingerprint == nil { Text("Configuration identity missing · no replacement advice").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
                            DisclosureGroup("Recorded source and identity") {
                                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                    Text("Source: \(record.source)")
                                    Text("Model: \(record.modelPath)")
                                    Text("Signature: \(record.modelSignature)")
                                    Text("Environment: \(record.environmentFingerprint)")
                                }.font(WorkbenchTypography.value).textSelection(.enabled)
                            }.font(WorkbenchTypography.secondary)
                        }.padding(WorkbenchSpacing.sm).background(WorkbenchColor.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: WorkbenchRadius.surface))
                    }
                }
            }.frame(maxHeight: 360)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(preview.newRecords.count) records", action: onConfirm).buttonStyle(.borderedProminent).disabled(preview.newRecords.isEmpty)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 600)
    }

    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "unknown" }
}
