import SwiftUI

/// The valid loopback port range for an endpoint.
enum ServingPortBounds {
    static let range = 1...65535
}

/// Section list and one-line captions for the Serving inspector. Ranges come from `LocalInferenceBounds`.
enum ServingInspectorPresentation {
    enum Section: String, CaseIterable, Identifiable {
        case status, load, inference, acceleration, access, tasks
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// One case per `LocalInferenceOptions` field.
    enum Field: String, CaseIterable {
        case m5Prefill, promptLookup, visionCache, thinkingOff, maximumTokens, systemPrompt, temperature, topP, sharedPrefixCacheMiB
    }

    enum Control: String, CaseIterable {
        case runtime, splashPreset, loadOnRequest, memoryPolicy, idleUnload, keepLoaded, releaseAfterRequest, port, requireKey
    }

    /// Chat roles (and an unassigned endpoint) tune inference; typed roles run tasks.
    static func sections(for role: ServingRole?, typedTasks: Bool = false) -> [Section] {
        let chat = !typedTasks && (role?.isChat ?? true)
        return chat ? [.status, .load, .inference, .acceleration, .access] : [.status, .load, .access, .tasks]
    }

    static func caption(_ field: Field) -> String {
        typealias Bounds = LocalInferenceBounds
        switch field {
        case .m5Prefill: return "Faster prompt processing on supported M5 Q4 models; other inputs use native MLX."
        case .promptLookup: return "Reuses text from the prompt while decoding, for code edits; requests run one at a time."
        case .visionCache: return "Reuses image features for repeated questions about one image on supported vision models."
        case .thinkingOff: return "Skips reasoning when the model's chat template supports it."
        case .maximumTokens: return "Output length used when a client omits it: \(Bounds.text(Bounds.maximumTokens)) tokens."
        case .systemPrompt: return "Used when a client sends no system prompt: up to \(Bounds.systemPromptBytesText) UTF-8 bytes."
        case .temperature: return "Sampling default when a client omits it: \(Bounds.text(Bounds.temperature))."
        case .topP: return "Nucleus sampling default when a client omits it: \(Bounds.text(Bounds.topP))."
        case .sharedPrefixCacheMiB: return "Reuses identical system-prompt prefixes on keyed MLX-LM endpoints: \(Bounds.text(Bounds.sharedPrefixCacheMiB)) MiB."
        }
    }

    static func caption(_ control: Control) -> String {
        switch control {
        case .runtime: return "Engine that serves this model; set when the endpoint is created."
        case .splashPreset: return "Splash launch and memory settings; review a preset to change them."
        case .loadOnRequest: return "Keeps the endpoint reachable without resident weights; changing it restarts the endpoint."
        case .memoryPolicy: return "Checks free memory before loading; estimates can differ from actual use."
        case .idleUnload: return "Unloads the weights after this long without requests."
        case .keepLoaded: return "Prevents the automatic unload after the first request; manual unload stays available."
        case .releaseAfterRequest: return "Unloads the weights after every request."
        case .port: return "Loopback port from \(ServingPortBounds.range.lowerBound) to \(ServingPortBounds.range.upperBound); stop the server to change it."
        case .requireKey: return "Requires an API key on every request; stop the server to change it."
        }
    }
}

struct ServingCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The selected row's settings as grouped sections. Inference edits keep the preview, recheck and confirm path.
struct ServingInspector<Content: View>: View {
    typealias Section = ServingInspectorPresentation.Section
    typealias Field = ServingInspectorPresentation.Field

    let sections: [Section]
    @ObservedObject var endpoint: EndpointSupervisor
    let slot: EndpointSlot?
    let context: ServingInferenceContext
    var onManageProfile: ((ServingProfile) -> Void)? = nil
    @ViewBuilder let content: (Section) -> Content

    @State private var options: LocalInferenceOptions
    @State private var preview: EndpointInferencePreview?
    @State private var busy = false
    @State private var error: String?

    init(sections: [Section], endpoint: EndpointSupervisor, slot: EndpointSlot?, context: ServingInferenceContext,
         onManageProfile: ((ServingProfile) -> Void)? = nil, @ViewBuilder content: @escaping (Section) -> Content) {
        self.sections = sections
        self.endpoint = endpoint
        self.slot = slot
        self.context = context
        self.onManageProfile = onManageProfile
        self.content = content
        _options = State(initialValue: slot?.inferenceOptions ?? .init())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Text(section.title).font(WorkbenchTypography.cardTitle)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.md) { rows(section) }
                        .padding(WorkbenchSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                }.id(section)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .onChange(of: options) { _, _ in preview = nil; error = nil }
        .onChange(of: slot) { _, value in options = value?.inferenceOptions ?? .init(); preview = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serving-inspector")
    }

    @ViewBuilder
    private func rows(_ section: Section) -> some View {
        switch (section, slot) {
        case (.inference, let slot?): inferenceRows(slot)
        case (.acceleration, let slot?): accelerationRows(slot)
        default: content(section)
        }
    }

    private func inferenceRows(_ slot: EndpointSlot) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if slot.enabled { InlineMessage(kind: .info, text: "Stop this endpoint to change its inference settings.") }
            ServingInferenceRows(options: $options, context: context, allowRequestDefaults: slot.usesJIT)
                .disabled(slot.enabled)
        }.disabled(busy)
    }

    private func accelerationRows(_ slot: EndpointSlot) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Group {
                ServingAccelerationRows(options: $options, context: context)
                if slot.usesJIT && slot.apiKeySHA256 != nil && slot.splashPresetName == nil && slot.servingProfile == nil && !slot.isTrainedAdapter {
                    sharedPrefixCache
                }
            }.disabled(slot.enabled)
            if let profile = slot.servingProfile {
                LabeledContent("Profile", value: "\(profile.name) · \(profile.options.decodingTitle)")
                if let onManageProfile {
                    Button("Manage profile in Run") { onManageProfile(profile) }.disabled(slot.enabled)
                }
            }
            if let message = options.validationError { InlineMessage(kind: .warning, text: message) }
            if let error { InlineMessage(kind: .error, text: error) }
            if busy { ProgressView("Checking launch configuration…") }
            if let preview {
                Text("Launch preview: \(preview.hash)").font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
            }
            actions(slot)
            ServingCaption("After saving, enable the endpoint. Reinstall an existing login item to capture the changed settings.")
        }.disabled(busy)
    }

    private var sharedPrefixCache: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Toggle("Shared prefix cache", isOn: Binding(
                get: { options.sharedPrefixCacheMiB != nil },
                set: { enabled in options.sharedPrefixCacheMiB = enabled ? LocalInferenceBounds.choices(LocalInferenceBounds.sharedPrefixCacheMiB)[4] : nil }))
                .toggleStyle(.checkbox)
                .disabled(options.accelerationRequested || !options.systemPrompt.isEmpty)
            if let mib = options.sharedPrefixCacheMiB {
                Picker("Budget", selection: Binding(get: { mib }, set: { options.sharedPrefixCacheMiB = $0 })) {
                    ForEach(LocalInferenceBounds.choices(LocalInferenceBounds.sharedPrefixCacheMiB, including: mib), id: \.self) {
                        Text("\($0) MiB").tag($0)
                    }
                }
            }
            ServingCaption(ServingInspectorPresentation.caption(Field.sharedPrefixCacheMiB))
        }
    }

    private func actions(_ slot: EndpointSlot) -> some View {
        HStack {
            if options.requested {
                Button("Reset") { options = .init() }.buttonStyle(.borderless).disabled(slot.enabled)
                    .accessibilityIdentifier("serve-inference-reset")
            }
            Button("Discard changes") { options = slot.inferenceOptions; preview = nil; error = nil }
            Spacer()
            if let preview {
                Button("Confirm and save") {
                    busy = true
                    Task {
                        if await endpoint.confirmSlotInference(preview) { self.preview = nil }
                        else { error = endpoint.lastError; self.preview = nil }
                        busy = false
                    }
                }.buttonStyle(.workbenchPrimary).disabled(slot.enabled || busy || endpoint.isChanging || options.validationError != nil)
            } else {
                Button("Preview settings") {
                    busy = true; error = nil
                    Task {
                        do {
                            guard endpoint.fleet.slots.contains(slot) else {
                                throw WorkflowEvidenceError.invalid("Endpoint settings changed. Select the endpoint again.")
                            }
                            preview = try await endpoint.previewSlotInference(id: slot.id, options: options)
                        } catch { self.error = AppHost.render(error) }
                        busy = false
                    }
                }.buttonStyle(.workbenchPrimary).disabled(slot.enabled || busy || endpoint.isChanging || options.validationError != nil)
            }
        }
    }
}
