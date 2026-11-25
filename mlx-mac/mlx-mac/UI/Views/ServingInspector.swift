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
        var title: String {
            switch self {
            case .acceleration: return "Experimental"
            case .access: return "Server"
            default: return rawValue.capitalized
            }
        }
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

    /// Plain-English explanation shown on hover; it ends with the accepted range.
    static func caption(_ field: Field) -> String {
        typealias Bounds = LocalInferenceBounds
        switch field {
        case .m5Prefill: return "M5 prompt processing: reads long prompts faster on an Apple M5 with Q4 models. Other models use the standard path."
        case .promptLookup: return "Prompt lookup decoding: copies matching text from the prompt instead of writing it word by word, which speeds up code edits and rewrites. Requests run one at a time."
        case .visionCache: return "Image feature reuse: remembers what the model saw in an image, so follow-up questions about the same image answer faster."
        case .thinkingOff: return "Reasoning: whether the model thinks step by step before it answers. Off answers sooner and shorter, on models whose chat template supports it."
        case .maximumTokens: return "Max response tokens: how long an answer can get when a client sets no limit. A token is about three quarters of a word. Range \(Bounds.text(Bounds.maximumTokens))."
        case .systemPrompt: return "System prompt: standing instructions the model reads before every conversation, used when a client sends none. Up to \(Bounds.systemPromptBytesText) UTF-8 bytes."
        case .temperature: return "Temperature: how adventurous word choice is. Lower gives focused, repeatable answers; higher gives more varied ones. Used when a client sends none; range \(Bounds.text(Bounds.temperature))."
        case .topP: return "Top-p: keeps only the most likely next words whose chances add up to this share. Lower is safer; 1 keeps every option. Used when a client sends none; range \(Bounds.text(Bounds.topP))."
        case .sharedPrefixCacheMiB: return "Shared prefix cache: remembers the start of prompts that repeat, such as one long system prompt, so keyed MLX-LM endpoints answer sooner. Budget \(Bounds.text(Bounds.sharedPrefixCacheMiB)) MiB."
        }
    }

    /// Inference edits differ from what the endpoint serves with (its options resolved against the model default).
    static func hasUnsavedEdits(_ options: LocalInferenceOptions, effective slot: EndpointSlot) -> Bool {
        options != slot.inferenceOptions
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

/// How long a load-on-request endpoint keeps its weights, as one choice over `EndpointMemoryPolicy`.
enum EndpointResidency: Hashable {
    case releaseAfterRequest, keepLoaded, unloadAfterIdle(seconds: Int)

    enum Kind: String, CaseIterable, Identifiable {
        case releaseAfterRequest, keepLoaded, unloadAfterIdle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .releaseAfterRequest: return "Release weights after each request"
            case .keepLoaded: return "Keep loaded"
            case .unloadAfterIdle: return "Unload after idle"
            }
        }
    }

    static let idleChoices = [0, 60, 120, 300, 600, 1800, 3600]
    static let defaultIdleSeconds = 600

    init(_ policy: EndpointMemoryPolicy) {
        if policy.releaseAfterRequest == true { self = .releaseAfterRequest }
        else if policy.keepLoaded { self = .keepLoaded }
        else { self = .unloadAfterIdle(seconds: policy.idleTimeoutSeconds) }
    }

    /// Switching to idle unload from a policy without an idle time starts at ten minutes.
    init(_ kind: Kind, from policy: EndpointMemoryPolicy) {
        switch kind {
        case .releaseAfterRequest: self = .releaseAfterRequest
        case .keepLoaded: self = .keepLoaded
        case .unloadAfterIdle: self = .unloadAfterIdle(seconds: policy.idleTimeoutSeconds > 0 ? policy.idleTimeoutSeconds : Self.defaultIdleSeconds)
        }
    }

    var kind: Kind {
        switch self {
        case .releaseAfterRequest: return .releaseAfterRequest
        case .keepLoaded: return .keepLoaded
        case .unloadAfterIdle: return .unloadAfterIdle
        }
    }

    /// The policy with this residency; headroom, budget, context and execution wait are kept.
    func applied(to policy: EndpointMemoryPolicy) -> EndpointMemoryPolicy {
        var result = policy
        switch self {
        case .releaseAfterRequest:
            result.releaseAfterRequest = true; result.keepLoaded = false; result.idleTimeoutSeconds = 0
        case .keepLoaded:
            result.keepLoaded = true; result.unloadUnderPressure = nil
            if result.releaseAfterRequest == true { result.releaseAfterRequest = false }
        case .unloadAfterIdle(let seconds):
            result.keepLoaded = false; result.idleTimeoutSeconds = seconds
            if result.releaseAfterRequest == true { result.releaseAfterRequest = false }
        }
        return result
    }

    var title: String {
        switch self {
        case .unloadAfterIdle(let seconds): return seconds == 0 ? "Never unload when idle" : "Unload after \(Self.duration(seconds)) idle"
        default: return kind.title
        }
    }

    static func duration(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Never"
        case 3600: return "1 hour"
        case 60: return "1 minute"
        case let value where value % 3600 == 0: return "\(value / 3600) hours"
        case let value where value % 60 == 0: return "\(value / 60) minutes"
        default: return "\(seconds) seconds"
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
    @State private var defaultsPreview: ModelDefaultsChangePreview?
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
        _options = State(initialValue: slot.map { endpoint.effectiveSlot($0).inferenceOptions } ?? .init())
    }

    /// Wide: endpoint, load and server on the left; inference, experimental and presets on the right.
    /// Narrow: one column with presets after Status.
    var body: some View {
        Group {
            if let slot {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                        sectionStack(configuration: nil, only: [.status, .load, .access, .tasks])
                            .frame(minWidth: 480, idealWidth: 560, maxWidth: 640, alignment: .leading)
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                            sectionStack(configuration: nil, only: [.inference, .acceleration])
                            ServingConfigurationPanel(endpoint: endpoint, slot: slot)
                        }
                        .frame(minWidth: 420, idealWidth: 520, maxWidth: 640, alignment: .topLeading)
                    }
                    sectionStack(configuration: slot).frame(maxWidth: 640, alignment: .leading)
                }
            } else {
                sectionStack(configuration: nil).frame(maxWidth: 640, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: options) { _, _ in preview = nil; error = nil }
        .onChange(of: slot) { _, value in options = value.map { endpoint.effectiveSlot($0).inferenceOptions } ?? .init(); preview = nil; defaultsPreview = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serving-inspector")
    }

    private func sectionStack(configuration slot: EndpointSlot?, only: [Section]? = nil) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            ForEach(sections.filter { only?.contains($0) ?? true }) { section in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Text(section.title).font(WorkbenchTypography.cardTitle)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.md) { rows(section) }
                        .padding(WorkbenchSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                }.id(section)
                if section == .status, let slot { ServingConfigurationPanel(endpoint: endpoint, slot: slot) }
            }
        }
        .labeledContentStyle(ServingRowStyle())
    }

    @ViewBuilder
    private func rows(_ section: Section) -> some View {
        switch (section, slot) {
        case (.inference, let slot?): inferenceRows(slot)
        case (.acceleration, let slot?): accelerationRows(slot)
        case (.load, let slot?) where slot.overrides != nil:
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                content(section)
                marker(.loadOnRequest, label: ServingInspectorPresentation.label(.loadOnRequest))
                marker(.memoryPolicy, label: ServingInspectorPresentation.label(.memoryPolicy))
                marker(.splashPreset, label: ServingInspectorPresentation.label(.splashPreset))
                marker(.servingProfile, label: ServingInspectorPresentation.label(.servingProfile))
                resetConfirm
            }
        default: content(section)
        }
    }

    /// "Model default" / "This endpoint" under a field; Reset previews returning it to the model default.
    @ViewBuilder
    private func marker(_ key: ServingSettingKey, label: String? = nil) -> some View {
        if let slot, slot.overrides != nil {
            HStack {
                if let label { Text(label).font(WorkbenchTypography.label) }
                Text(ServingInspectorPresentation.sourceLabel(key, slot: slot))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Spacer()
                if slot.overrides?.contains(key) == true {
                    Button("Reset") {
                        busy = true; error = nil
                        Task {
                            do { preview = try await endpoint.previewResettingOverrides(id: slot.id, keys: [key]) }
                            catch { self.error = AppHost.render(error) }
                            busy = false
                        }
                    }.buttonStyle(.borderless).disabled(slot.enabled || busy)
                }
            }
        }
    }

    @ViewBuilder
    private var resetConfirm: some View {
        if let preview, preview.overrides != slot?.overrides {
            HStack {
                Text("Reset reviewed: launch plan \(preview.hash)").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Spacer()
                Button("Confirm and save") {
                    busy = true
                    Task {
                        if await endpoint.confirmSlotInference(preview) { self.preview = nil } else { error = endpoint.lastError; self.preview = nil }
                        busy = false
                    }
                }.buttonStyle(.workbenchPrimary).disabled(busy || endpoint.isChanging)
            }
        }
    }

    private func inferenceRows(_ slot: EndpointSlot) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if slot.enabled { InlineMessage(kind: .info, text: "Stop this endpoint to change its inference settings.") }
            ServingInferenceRows(options: $options, context: context, allowRequestDefaults: slot.usesJIT,
                                 accessory: { marker($0.settingKey) })
                .disabled(slot.enabled)
            resetConfirm
            if let defaultsPreview {
                ModelDefaultsConfirmation(endpoint: endpoint, preview: defaultsPreview, confirmTitle: "Confirm model default") { failure in
                    error = failure
                    self.defaultsPreview = nil
                }
            } else {
                Button("Save as model default") {
                    busy = true; error = nil
                    Task {
                        do { defaultsPreview = try await endpoint.previewSavingAsModelDefault(id: slot.id) }
                        catch { self.error = AppHost.render(error) }
                        busy = false
                    }
                }.accessibilityIdentifier("serve-save-model-default")
            }
            if let error { InlineMessage(kind: .error, text: error) }
        }.disabled(busy)
    }

    private func accelerationRows(_ slot: EndpointSlot) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Group {
                ServingAccelerationRows(options: $options, context: context, accessory: { marker($0.settingKey) })
                if slot.usesJIT && slot.apiKeySHA256 != nil && slot.splashPresetName == nil && slot.servingProfile == nil && !slot.isTrainedAdapter {
                    sharedPrefixCache
                    marker(.sharedPrefixCacheMiB)
                }
            }.disabled(slot.enabled)
            if let profile = slot.servingProfile {
                LabeledContent("Strata profile", value: "\(profile.name) · \(profile.options.decodingTitle)")
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
                .help("After saving, start the endpoint. Reinstall an existing login item to capture the changed settings.")
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
                LabeledContent("Budget") {
                    Picker("Budget", selection: Binding(get: { mib }, set: { options.sharedPrefixCacheMiB = $0 })) {
                        ForEach(LocalInferenceBounds.choices(LocalInferenceBounds.sharedPrefixCacheMiB, including: mib), id: \.self) {
                            Text("\($0) MiB").tag($0)
                        }
                    }.labelsHidden().fixedSize()
                }
            }
        }
        .help(ServingInspectorPresentation.caption(Field.sharedPrefixCacheMiB))
    }

    /// Preview and Discard are enabled only while the edits differ from the endpoint's effective options.
    private func actions(_ slot: EndpointSlot) -> some View {
        let edited = ServingInspectorPresentation.hasUnsavedEdits(options, effective: endpoint.effectiveSlot(slot))
        return HStack {
            if options.requested {
                Button("Reset") { options = .init() }.buttonStyle(.borderless).disabled(slot.enabled)
                    .accessibilityIdentifier("serve-inference-reset")
            }
            Button("Discard changes") { options = endpoint.effectiveSlot(slot).inferenceOptions; preview = nil; error = nil }
                .disabled(!edited && preview == nil)
                .accessibilityIdentifier("serve-inference-discard")
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
                }.buttonStyle(.workbenchPrimary).disabled(!edited || slot.enabled || busy || endpoint.isChanging || options.validationError != nil)
                    .accessibilityIdentifier("serve-inference-preview")
            }
        }
    }
}

extension ServingInspectorPresentation.Field {
    var settingKey: ServingSettingKey { ServingSettingKey(rawValue: rawValue)! }
}

extension ServingInspectorPresentation {
    /// "Model default" or "This endpoint" for one setting of a slot.
    static func sourceLabel(_ key: ServingSettingKey, slot: EndpointSlot) -> String {
        ServingSettings.source(of: key, slot: slot) == .modelDefault ? "Model default" : "This endpoint"
    }

    /// Human label for a setting.
    static func label(_ key: ServingSettingKey) -> String {
        switch key {
        case .loadOnRequest: return "Load on request"
        case .memoryPolicy: return "Memory policy"
        case .splashPreset: return "Splash preset"
        case .servingProfile: return "Serving profile"
        case .m5Prefill: return "M5 prompt processing"
        case .promptLookup: return "Prompt text reuse"
        case .visionCache: return "Image feature reuse"
        case .thinkingOff: return "Reasoning"
        case .maximumTokens: return "Default output length"
        case .systemPrompt: return "Default system prompt"
        case .temperature: return "Temperature"
        case .topP: return "Top-p"
        case .sharedPrefixCacheMiB: return "Shared prefix cache"
        }
    }

    /// One setting's value on a slot as display text; the one formatter for per-setting values.
    static func value(_ key: ServingSettingKey, slot: EndpointSlot) -> String {
        let options = slot.inferenceOptions
        func onOff(_ value: Bool) -> String { value ? "On" : "Off" }
        func sampling(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "Model default" }
        switch key {
        case .loadOnRequest: return onOff(slot.usesJIT)
        case .memoryPolicy:
            guard let policy = slot.memoryPolicy else { return "Engine default" }
            let reserve = policy.minimumHeadroomGB.map { " · reserve \(String(format: "%g", $0)) GB" } ?? ""
            return EndpointResidency(policy).title + reserve
        case .splashPreset: return slot.splashPresetName ?? "None"
        case .servingProfile: return slot.servingProfile?.name ?? "None"
        case .m5Prefill: return onOff(options.m5Prefill)
        case .promptLookup: return onOff(options.promptLookup)
        case .visionCache: return onOff(options.visionCache)
        case .thinkingOff: return options.thinkingOff ? "Off" : "Model default"
        case .maximumTokens: return options.maximumTokens.map { "\($0.formatted()) tokens" } ?? "Engine default"
        case .systemPrompt:
            let line = options.systemPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if line.isEmpty { return "None" }
            return line.count > 40 ? String(line.prefix(40)) + "…" : line
        case .temperature: return sampling(options.temperature)
        case .topP: return sampling(options.topP)
        case .sharedPrefixCacheMiB: return options.sharedPrefixCacheMiB.map { "\($0) MiB" } ?? "Off"
        }
    }

    /// Settings whose values differ between two slots, in `ServingSettingKey` order.
    static func differences(_ slot: EndpointSlot, from base: EndpointSlot) -> [ServingSettingKey] {
        let inference = ServingSettings.changedKeys(from: base.inferenceOptions, to: slot.inferenceOptions)
        return ServingSettingKey.allCases.filter { key in
            switch key {
            case .loadOnRequest: return slot.usesJIT != base.usesJIT
            case .memoryPolicy: return slot.memoryPolicy != base.memoryPolicy
            case .splashPreset: return slot.splashPresetName != base.splashPresetName
            case .servingProfile: return slot.servingProfile?.id != base.servingProfile?.id
            default: return inference.contains(key)
            }
        }
    }
}

/// The affected endpoints with Cancel and Confirm for a reviewed defaults change or profile apply.
/// `finish` receives the failure text, or nil on success and on cancel.
struct ModelDefaultsConfirmation: View {
    @ObservedObject var endpoint: EndpointSupervisor
    let preview: ModelDefaultsChangePreview
    let confirmTitle: String
    let finish: (String?) -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ModelDefaultsRestartList(preview: preview)
            HStack {
                Button("Cancel") { finish(nil) }.disabled(busy)
                Button(confirmTitle) {
                    busy = true
                    Task {
                        let saved = await endpoint.confirmModelDefaultsChange(preview)
                        busy = false
                        finish(saved ? nil : endpoint.lastError)
                    }
                }.buttonStyle(.workbenchPrimary).disabled(busy || endpoint.isChanging)
            }
        }
    }
}

/// Fixed label column with the control beside it, so fields and pickers keep their own width.
struct ServingRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.md) {
            configuration.label.frame(width: 170, alignment: .leading)
            configuration.content
            Spacer(minLength: 0)
        }
    }
}

/// Endpoints listed before a defaults change is confirmed.
struct ModelDefaultsRestartList: View {
    let preview: ModelDefaultsChangePreview
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if preview.appliedSlot != nil {
                ServingCaption("Writes this profile's values into :\(preview.following.first?.port ?? 0).")
            } else if preview.following.isEmpty {
                ServingCaption("No endpoint follows this model's defaults.")
            } else {
                ServingCaption("Endpoints that follow these defaults: " + preview.following.map { ":\($0.port)" }.joined(separator: ", "))
            }
            if !preview.restarting.isEmpty {
                InlineMessage(kind: .warning, text: "Confirming restarts running endpoints: " + preview.restarting.map { ":\($0.port)" }.joined(separator: ", "))
            }
        }
    }
}

/// Edits one model's serving defaults. Used by the Library inspector; a change previews the affected endpoints before saving.
struct ServingDefaultsEditor: View {
    @ObservedObject var endpoint: EndpointSupervisor
    let model: LibraryModel
    let context: ServingInferenceContext
    /// Verified serving profiles for this model.
    var profiles: [ServingProfile] = []

    @State private var options = LocalInferenceOptions()
    @State private var loadOnRequest = true
    @State private var loadTouched = false
    @State private var memoryEnabled = false
    @State private var keepLoaded = false
    @State private var idleMinutes = 10
    @State private var splashName = ""
    @State private var profileID: UUID?
    @State private var preview: ModelDefaultsChangePreview?
    @State private var error: String?
    @State private var loaded = false

    /// Load on request is written only after the user changes it; the saved values of the other fields round-trip.
    private var draft: ModelServingDefaults {
        let saved = endpoint.modelDefaults(for: model.item.path)
        var value = saved ?? ModelServingDefaults()
        value.inference = options
        value.loadOnRequest = loadTouched ? loadOnRequest : saved?.loadOnRequest
        value.memoryPolicy = memoryEnabled ? EndpointMemoryPolicy(idleTimeoutSeconds: idleMinutes * 60, keepLoaded: keepLoaded, minimumHeadroomGB: saved?.memoryPolicy?.minimumHeadroomGB ?? 2) : nil
        let name = splashName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.splashPresetName = name.isEmpty ? nil : name
        value.servingProfileID = profileID
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Toggle("Load on request", isOn: Binding(get: { loadOnRequest }, set: { loadOnRequest = $0; loadTouched = true })).toggleStyle(.checkbox)
            Toggle("Memory policy", isOn: $memoryEnabled).toggleStyle(.checkbox)
            if memoryEnabled {
                Stepper("Unload after \(idleMinutes) min idle", value: $idleMinutes, in: 0...1440)
                Toggle("Keep loaded", isOn: $keepLoaded).toggleStyle(.checkbox)
            }
            LabeledContent("Splash preset") { TextField("None", text: $splashName) }
            Picker("Serving profile", selection: $profileID) {
                Text("None").tag(UUID?.none)
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            ServingInferenceRows(options: $options, context: context, allowRequestDefaults: loadOnRequest)
            if let message = options.validationError { InlineMessage(kind: .warning, text: message) }
            if let error { InlineMessage(kind: .error, text: error) }
            if let preview { ModelDefaultsRestartList(preview: preview) }
            HStack {
                Button("Clear defaults") { review(nil) }.disabled(endpoint.modelDefaults(for: model.item.path) == nil)
                Spacer()
                if let preview {
                    Button("Cancel") { self.preview = nil }
                    Button("Confirm and save") {
                        Task {
                            if await endpoint.confirmModelDefaultsChange(preview) { self.preview = nil; error = nil }
                            else { error = endpoint.lastError; self.preview = nil }
                        }
                    }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
                } else {
                    Button("Review") { review(draft) }.buttonStyle(.workbenchPrimary).disabled(options.validationError != nil)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            guard let saved = endpoint.modelDefaults(for: model.item.path) else { return }
            options = saved.inference; loadOnRequest = saved.loadOnRequest ?? true
            if let policy = saved.memoryPolicy { memoryEnabled = true; keepLoaded = policy.keepLoaded; idleMinutes = policy.idleTimeoutSeconds / 60 }
            splashName = saved.splashPresetName ?? ""; profileID = saved.servingProfileID
        }
        .accessibilityIdentifier("serving-defaults-editor")
    }

    private func review(_ value: ModelServingDefaults?) {
        error = nil
        Task {
            do { preview = try await endpoint.previewModelDefaultsChange(modelPath: model.item.path, to: value) }
            catch { self.error = AppHost.render(error) }
        }
    }
}
