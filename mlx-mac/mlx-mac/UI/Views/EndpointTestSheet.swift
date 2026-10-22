import SwiftUI

struct EndpointTestSheet: View {
    let presentation: EndpointTestPresentation
    private var server: ServerInfo { presentation.server }
    @ObservedObject var coordinator: EndpointTestCoordinator
    let configureClients: () -> Void
    @Environment(\.dismiss) private var dismiss
    private static let defaultPrompt = "In one sentence, what can you help me with?"
    @State private var prompt = Self.defaultPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Try a prompt").font(WorkbenchTypography.pageTitle)
                Spacer()
                Button("Done") { coordinator.close(presentationID: presentation.id); dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(server.modelIdentity).font(WorkbenchTypography.emphasis).lineLimit(2).truncationMode(.middle)
                Text(RunFormat.endpoint(port: server.port ?? 0))
                    .font(WorkbenchTypography.value).foregroundStyle(WorkbenchColor.muted)
                if let adapter = server.adapterSummary { Text(adapter).font(WorkbenchTypography.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    if server.jit == true {
                        Text("Loads the model on request. Sending may take longer while it loads.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    Text("Prompt").font(WorkbenchTypography.label)
                    TextEditor(text: $prompt)
                        .font(WorkbenchTypography.body).frame(height: 90)
                        .padding(WorkbenchSpacing.xs)
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                        .accessibilityLabel("Prompt").accessibilityIdentifier("endpoint-test-prompt")
                        .disabled(coordinator.isSending)
                    Text("One prompt · 256-token limit")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    if let reason = EndpointTestCoordinator.promptError(prompt) {
                        Text(reason).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    }
                    if coordinator.isSending { ProgressView("Waiting for an answer…") }
                    ErrorBanner(text: coordinator.error)
                    if let sample = coordinator.sample {
                        Divider()
                        Text(EndpointTestCoordinator.outcome(sample)).font(WorkbenchTypography.emphasis)
                        if !sample.text.isEmpty {
                            Text(sample.text).font(WorkbenchTypography.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let reasoning = sample.reasoningText, !reasoning.isEmpty {
                            DisclosureGroup("Reasoning") {
                                Text(reasoning).font(WorkbenchTypography.body).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let sample = coordinator.sample, sample.finishReason == "stop", !sample.text.isEmpty {
                    Button("Configure clients…") { coordinator.close(presentationID: presentation.id); dismiss(); configureClients() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if coordinator.isSending {
                    Button("Cancel request") { coordinator.cancel(presentationID: presentation.id) }.buttonStyle(.bordered)
                } else {
                    Button("Send prompt") { coordinator.send(to: server, prompt: prompt, presentationID: presentation.id) }
                        .buttonStyle(.workbenchPrimary)
                        .disabled(EndpointTestCoordinator.promptError(prompt) != nil)
                }
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(width: 520, height: 520)
        .onAppear { coordinator.reset(presentationID: presentation.id) }
        .onChange(of: prompt) { _, _ in coordinator.reset(presentationID: presentation.id) }
        .onDisappear { coordinator.close(presentationID: presentation.id); prompt = Self.defaultPrompt }
    }
}
