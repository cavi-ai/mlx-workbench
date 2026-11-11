import SwiftUI

struct MediaReuseContext {
    let capabilities: MediaReuseCapabilities
    let modelPaths: [String]
}

struct MediaReuseControls: View {
    @Binding var settings: MediaReuseSettings
    @ObservedObject var capabilities: MediaReuseCapabilities
    let kind: TaskKind
    let modelPaths: [String]
    var refreshOnAppear = true
    private var supported: Bool { capabilities.allowsAdaptive(kind: kind, paths: modelPaths) }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Toggle("Experimental reuse", isOn: Binding(get: { settings.adaptive }, set: { value in
                    if !value || supported { settings.adaptive = value }
                }))
                .toggleStyle(.checkbox)
                .disabled(!supported && !settings.adaptive)
                .accessibilityIdentifier("media-adaptive-reuse")
                if let reason = capabilities.reason(kind: kind, paths: modelPaths) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                        Text(reason).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        Button("Refresh") { Task { await capabilities.refresh(paths: modelPaths) } }
                            .disabled(capabilities.isLoading).accessibilityIdentifier("media-reuse-refresh")
                    }
                }
                if settings.adaptive {
                    Text(kind == .meshGeneration ? "Reuse can change geometry. Review visual quality before keeping the result." : "Reuse can change generated frames. Review visual quality before keeping the result.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    LabeledContent("Feature-cache allowance · MiB") {
                        TextField("256", text: $settings.memoryMiB)
                            .accessibilityLabel("Feature-cache allowance in MiB").accessibilityIdentifier("media-cache-memory")
                    }
                    Text("8–4,096 MiB, separate from model weights. If the cache does not fit, the engine uses full computation.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    if let error = InferenceSettings.problem({ _ = try settings.parameters }) {
                        Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
                    }
                }
            }.padding(.top, WorkbenchSpacing.xs)
        } label: {
            HStack(spacing: WorkbenchSpacing.sm) {
                Text("Performance & memory")
                Text(settings.title).foregroundStyle(WorkbenchColor.muted)
            }.font(WorkbenchTypography.label)
        }
        .task(id: modelPaths.sorted().joined(separator: "\n")) { if refreshOnAppear { await capabilities.refresh(paths: modelPaths) } }
    }
}

struct MediaReuseReviewSheet: View {
    let review: MediaReuseReview
    let modelName: String
    var busy = false
    var onCancel: () -> Void = {}
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var requestJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(review.request.parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? "Request settings unavailable."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Review generation").font(WorkbenchTypography.title)
            LabeledContent("Model", value: modelName)
            LabeledContent("Computation", value: "Experimental reuse")
            LabeledContent("Feature-cache allowance", value: "\(review.request.parameters["cache_memory_mib"]?.integerValue ?? 256) MiB")
            Text(review.request.kind == .meshGeneration ? "Adaptive reuse can change geometry. Completion does not establish equivalent quality." : "Adaptive reuse can change generated frames. Completion does not establish equivalent quality.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            DisclosureGroup("Request settings") {
                ScrollView { Text(requestJSON).font(WorkbenchTypography.value).textSelection(.enabled) }
                    .frame(maxHeight: WorkbenchSize.MediaReuse.requestDetailsMaximum)
            }
            HStack {
                Button("Cancel") { onCancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate") { confirm() }.buttonStyle(.workbenchPrimary).keyboardShortcut(.defaultAction)
                    .disabled(busy)
                    .accessibilityIdentifier("media-reuse-confirm")
            }
        }.padding(WorkbenchSpacing.lg).frame(width: WorkbenchSize.MediaReuse.reviewWidth)
    }
}

struct MediaReuseResultView: View {
    let requested: String?
    let allowance: Int?
    let raw: JSONValue?
    var seconds: Double? = nil
    var body: some View {
        if requested != nil || raw != nil {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("Requested: \(requested.map { $0 == "adaptive" ? "experimental reuse" : "standard" } ?? "not available")\(allowance.map { " · \($0) MiB allowance" } ?? "")")
                if let seconds, seconds.isFinite, seconds >= 0 { Text("Reported time: \(seconds.formatted()) s") }
                if let report = MediaReuseReport(raw: raw) {
                    Text(report.summary).accessibilityIdentifier("media-reuse-result")
                    Text("Reported feature cache: \(report.peakCacheBytes) bytes peak · \(report.memoryLimitBytes) bytes allowance")
                    Text(report.explanation)
                } else if requested == "off", raw == nil { Text("Adaptive reuse was not requested.") }
                else { Text("Reuse telemetry was not reported or could not be read.").accessibilityIdentifier("media-reuse-result") }
            }.font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
        }
    }
}
