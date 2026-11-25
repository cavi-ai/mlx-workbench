import SwiftUI

struct ServingInferenceContext: Equatable {
    let runtime: String
    var chip: String? = nil

    static func resolve(model: LibraryModel?, override: String = "auto", profile: ServingProfile? = nil, chip: String? = nil) -> Self {
        if profile != nil { return Self(runtime: "strata", chip: chip) }
        if override != "auto" { return Self(runtime: override, chip: chip) }
        if let runtime = model?.item.servingRuntime { return Self(runtime: runtime, chip: chip) }
        switch model?.item.task?.type {
        case .visionLanguage: return Self(runtime: "mlx-vlm", chip: chip)
        case .textLLM: return Self(runtime: "mlx_lm", chip: chip)
        case .some: return Self(runtime: "tasks", chip: chip)
        case .none: return Self(runtime: "auto", chip: chip)
        }
    }

    static func supportsSavedSplashPreset(model: LibraryModel?, profile: ServingProfile?) -> Bool {
        guard let model, profile == nil else { return false }
        return model.item.servingRuntime == "strata" || model.item.splashFamily != nil
    }

    static func savedEndpointOverride(model: LibraryModel?, presetSelected: Bool, profile: ServingProfile?) -> String {
        guard presetSelected, supportsSavedSplashPreset(model: model, profile: profile) else { return "auto" }
        return "splash"
    }

    var isText: Bool { runtime == "mlx_lm" }
    var isVision: Bool { runtime == "mlx-vlm" }
    var isStrata: Bool { runtime == "strata" }
    var isSplash: Bool { runtime == "splash" }
    var hasGenerationDefaults: Bool { isText || isStrata }
    var supportsReasoningOverride: Bool { isText || isSplash }
    var supportsRequestDefaults: Bool { isText || isStrata || isVision }
    var supportsM5: Bool { chip?.range(of: #"\bM5\b"#, options: [.regularExpression, .caseInsensitive]) != nil }

    func normalized(_ options: LocalInferenceOptions) -> LocalInferenceOptions {
        var result = options
        if !isText { result.m5Prefill = false; result.promptLookup = false }
        if !supportsReasoningOverride { result.thinkingOff = false }
        if !isVision { result.visionCache = false }
        if !hasGenerationDefaults { result.maximumTokens = nil }
        if !supportsRequestDefaults { result.systemPrompt = ""; result.temperature = nil; result.topP = nil }
        return result
    }
}

struct InferenceOptionEvidence: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String

    static func rows(prefill: LabValue?, lookup: LabValue?, vision: LabValue?) -> [Self] {
        [("prefill", "M5 prompt processing", prefill), ("lookup", "Prompt text reuse", lookup), ("vision", "Image feature reuse", vision)].compactMap { id, title, value in
            guard let value else { return nil }
            let detail: String
            switch value.object?["adapter_enabled"] {
            case .boolean(true): detail = "Configured · eligible models and requests"
            case .boolean(false): detail = "Native fallback · adapter unavailable"
            default: detail = "Requested · activation not reported"
            }
            return Self(id: id, title: title, detail: detail)
        }
    }

    static func rows(plan: [String: Any]) -> [Self] {
        func value(_ key: String) -> LabValue? {
            guard let raw = plan[key], let data = try? JSONSerialization.data(withJSONObject: raw),
                  let result = try? JSONDecoder().decode(LabValue.self, from: data) else { return nil }
            return result
        }
        var result = rows(prefill: value("prefill_kernel"), lookup: value("decode_profile"), vision: value("vision_profile"))
        if let version = plan["splash_version"] as? String {
            result.append(Self(id: "splash", title: "Splash", detail: [version, plan["splash_served_model"] as? String].compactMap { $0 }.joined(separator: " · ")))
        }
        if let mode = plan["strata_decoding"] as? String {
            result.append(Self(id: "strata", title: "Strata decoding", detail: StrataComparisonOptions(decoding: mode).decodingTitle))
        }
        if ["mlx_lm", "strata"].contains(plan["runtime"] as? String ?? ""), let tokens = plan["max_tokens"] as? Int {
            result.append(Self(id: "output", title: "Default output length", detail: "\(tokens.formatted()) tokens"))
        }
        if let thinking = plan["thinking"] as? String {
            result.append(Self(id: "thinking", title: "Reasoning", detail: thinking == "off" ? "Skip reasoning requested" : "Override unsupported · model default"))
        }
        return result
    }
}

/// Inference a model can use beyond its default runtime, for the Library and its inspector.
/// The engine still checks eligibility when Run or a task previews the work.
struct ModelInferenceOption: Equatable, Identifiable {
    enum Place: Equatable {
        /// Run's Start now setup; a runtime is selected there when given.
        case run(runtime: String?)
        /// The inspector's task panel.
        case task
        /// Settings → Serving.
        case settings
    }

    let id: String
    let title: String
    let detail: String
    let experimental: Bool
    let place: Place
}

enum ModelInferencePresentation {
    static func options(for model: LibraryModel, chip: String?) -> [ModelInferenceOption] {
        let task = model.item.task?.type
        let runtime = model.item.servingRuntime
        let splashFamily = model.item.splashFamily
        var result: [ModelInferenceOption] = []
        if runtime == "strata" {
            result.append(.init(id: "strata", title: "Strata", detail: "Prepared profile with its own decoding, expert memory and context. Verify the profile before use.",
                                experimental: false, place: .run(runtime: nil)))
        }
        if runtime == "strata" || (runtime == nil && splashFamily != nil) {
            let draft = splashFamily.map { "the \($0) family's cached draft" } ?? "this family's cached draft"
            result.append(.init(id: "splash", title: "Splash", detail: "DFlash2 speculative decoding with \(draft). Needs Splash 1.4 or later, Apple M3 or newer and macOS 26.4.",
                                experimental: true, place: .run(runtime: "splash")))
        }
        if task == .textLLM, runtime == nil {
            result.append(.init(id: "lookup", title: "Prompt text reuse", detail: "Copies text from the prompt while decoding, for code edits. Choose it in Run's inference settings.",
                                experimental: false, place: .run(runtime: nil)))
            if model.item.quantization == "q4", ServingInferenceContext(runtime: "mlx_lm", chip: chip).supportsM5 {
                result.append(.init(id: "m5", title: "M5 prompt processing", detail: "Experimental prefill kernel for Q4 models on the M5 GPU. Choose it under Run's hardware acceleration.",
                                    experimental: true, place: .run(runtime: nil)))
            }
        }
        if task == .visionLanguage, runtime == nil {
            result.append(.init(id: "vision", title: "Image feature reuse", detail: "Keeps image features for repeated questions on supported Qwen2.5-VL and Qwen3-VL models. Choose it in Run's inference settings.",
                                experimental: false, place: .run(runtime: nil)))
        }
        if task == .videoGeneration || task == .meshGeneration {
            result.append(.init(id: "reuse", title: "Experimental reuse", detail: "Reuses computation between generation steps within a cache budget. Choose it in this model's task panel.",
                                experimental: true, place: .task))
        }
        if task == .musicGeneration {
            result.append(.init(id: "fx", title: "Sound effects from music", detail: "FX and ambience from this music model may still contain music. Choose it in Settings → Serving.",
                                experimental: true, place: .settings))
        }
        return result
    }
}

extension LocalInferenceOptions {
    var summary: String {
        var parts: [String] = []
        if promptLookup { parts.append("Prompt text reuse") }
        if m5Prefill { parts.append("M5 prompt processing") }
        if visionCache { parts.append("Image feature reuse") }
        if thinkingOff { parts.append("Skip reasoning") }
        if let maximumTokens { parts.append("\(maximumTokens.formatted()) output tokens") }
        if !systemPrompt.isEmpty { parts.append("System prompt") }
        if let temperature { parts.append("Temperature \(temperature.formatted())") }
        if let topP { parts.append("Top-p \(topP.formatted())") }
        return parts.isEmpty ? "Runtime defaults" : parts.joined(separator: " · ")
    }
}

/// Shared by a new server and a saved endpoint. Only the chosen runtime's controls appear.
struct ServingInferenceControls: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext
    var allowRequestDefaults = false
    /// False when `ServingExperimentalCard` shows the runtime's features beside this card.
    var showsAcceleration = true

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label("Inference", systemImage: "slider.horizontal.3").font(WorkbenchTypography.cardTitle)
                Spacer(minLength: WorkbenchSpacing.xs)
                if options.requested {
                    Button("Reset") { options = .init() }.buttonStyle(.borderless)
                        .accessibilityIdentifier("serve-inference-reset")
                }
            }
            if showsAcceleration { ServingAccelerationRows(options: $options, context: context) }
            ServingInferenceRows(options: $options, context: context, allowRequestDefaults: allowRequestDefaults)
            if let error = options.validationError { InlineMessage(kind: .warning, text: error) }
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serve-inference-settings")
    }
}

/// The chosen runtime's experimental features as one card.
struct ServingExperimentalCard: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Label("Experimental", systemImage: "flask").font(WorkbenchTypography.cardTitle)
            ServingAccelerationRows(options: $options, context: context)
        }
        .padding(WorkbenchSpacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serve-experimental")
    }
}

/// Acceleration controls for the chosen runtime; captions come from `ServingInspectorPresentation`.
struct ServingAccelerationRows<Accessory: View>: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext
    @ViewBuilder var accessory: (ServingInspectorPresentation.Field) -> Accessory
    typealias Field = ServingInspectorPresentation.Field

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if context.isText {
                ServingFeatureCard(title: "Prompt lookup decoding", detail: ServingInspectorPresentation.caption(Field.promptLookup),
                                   availability: "MLX-LM text models") {
                    Toggle("Prompt lookup decoding", isOn: $options.promptLookup).accessibilityIdentifier("serve-text-decoding")
                }
                accessory(.promptLookup)
                ServingFeatureCard(title: "M5 prompt processing", detail: ServingInspectorPresentation.caption(Field.m5Prefill),
                                   availability: context.supportsM5 ? "Q4 models on this M5" : "Needs an Apple M5 chip",
                                   unavailable: !context.supportsM5) {
                    Toggle("M5 prompt processing", isOn: $options.m5Prefill)
                        .disabled(!context.supportsM5 && !options.m5Prefill)
                        .accessibilityIdentifier("serve-m5-prefill")
                }
                accessory(.m5Prefill)
            } else if context.isVision {
                ServingFeatureCard(title: "Image feature reuse", detail: ServingInspectorPresentation.caption(Field.visionCache),
                                   availability: "Qwen2.5-VL and Qwen3-VL") {
                    Toggle("Image feature reuse", isOn: $options.visionCache).accessibilityIdentifier("serve-vision-cache")
                }
                accessory(.visionCache)
            } else if context.isStrata {
                ServingStrataExperimentalControls()
            } else if context.isSplash {
                ServingSplashExperimentalControls(options: $options)
            } else {
                Text(context.runtime == "tasks"
                     ? "Generation settings belong to each task request. Use model residency and memory controls to manage the server's footprint."
                     : "The engine identifies this model's runtime during preview. Select a known runtime to review its inference controls.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }
}

extension ServingAccelerationRows where Accessory == EmptyView {
    init(options: Binding<LocalInferenceOptions>, context: ServingInferenceContext) {
        self.init(options: options, context: context, accessory: { _ in EmptyView() })
    }
}

/// Reasoning, output length and request defaults; captions come from `ServingInspectorPresentation`.
struct ServingInferenceRows<Accessory: View>: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext
    var allowRequestDefaults = false
    /// Per-field accessory (source marker) shown under each field's caption.
    @ViewBuilder var accessory: (ServingInspectorPresentation.Field) -> Accessory
    typealias Field = ServingInspectorPresentation.Field

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if context.hasGenerationDefaults {
                LabeledContent("Max response tokens") {
                    Picker("Max response tokens", selection: $options.maximumTokens) {
                        Text("Engine default").tag(Int?.none)
                        ForEach(LocalInferenceBounds.choices(LocalInferenceBounds.maximumTokens, including: options.maximumTokens), id: \.self) { value in
                            Text(value.formatted()).tag(Optional(value))
                        }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("serve-output-length")
                }
                .help(ServingInspectorPresentation.caption(Field.maximumTokens))
                accessory(.maximumTokens)
            }
            if context.supportsReasoningOverride {
                LabeledContent("Reasoning") {
                    Picker("Reasoning", selection: $options.thinkingOff) {
                        Text("Model default").tag(false)
                        Text("Off").tag(true)
                    }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("serve-thinking")
                }
                .help(ServingInspectorPresentation.caption(Field.thinkingOff))
                accessory(.thinkingOff)
            }
            if allowRequestDefaults && context.supportsRequestDefaults {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    ServingSamplingRow(title: "Temperature", value: $options.temperature, range: LocalInferenceBounds.temperature,
                                       step: 0.05, start: 0.8, identifier: "serve-default-temperature",
                                       help: ServingInspectorPresentation.caption(Field.temperature))
                    accessory(.temperature)
                    ServingSamplingRow(title: "Top-p", value: $options.topP, range: LocalInferenceBounds.topP,
                                       step: 0.01, start: 0.95, identifier: "serve-default-top-p",
                                       help: ServingInspectorPresentation.caption(Field.topP))
                    accessory(.topP)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        HStack {
                            Text("System prompt").font(WorkbenchTypography.label)
                            Spacer(minLength: WorkbenchSpacing.xs)
                            Text("\(options.systemPrompt.utf8.count.formatted()) / \(LocalInferenceBounds.systemPromptBytesText) bytes")
                                .font(WorkbenchTypography.metadata).monospacedDigit()
                                .foregroundStyle(options.systemPrompt.utf8.count > LocalInferenceBounds.systemPromptBytes ? WorkbenchColor.failure : WorkbenchColor.muted)
                        }
                        TextEditor(text: $options.systemPrompt)
                            .font(WorkbenchTypography.secondary)
                            .scrollContentBackground(.hidden)
                            .padding(WorkbenchSpacing.xs)
                            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                            .frame(minHeight: WorkbenchSize.Serving.promptMinimum, maxHeight: WorkbenchSize.Serving.promptMaximum)
                            .accessibilityLabel("Default system prompt").accessibilityIdentifier("serve-system-prompt")
                    }
                    .contentShape(Rectangle())
                    .help(ServingInspectorPresentation.caption(Field.systemPrompt))
                    accessory(.systemPrompt)
                }
            } else if context.supportsRequestDefaults {
                ServingCaption("System prompt, temperature and top-p apply to load-on-request endpoints. Turn on Load on request to set them.")
            }
        }
    }
}

extension ServingInferenceRows where Accessory == EmptyView {
    init(options: Binding<LocalInferenceOptions>, context: ServingInferenceContext, allowRequestDefaults: Bool = false) {
        self.init(options: options, context: context, allowRequestDefaults: allowRequestDefaults, accessory: { _ in EmptyView() })
    }
}

/// One optional sampling default: a checkbox overrides the model's value, then a slider over the engine's range and the value.
struct ServingSamplingRow: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let step: Double
    /// Value set when the override is turned on.
    let start: Double
    let identifier: String
    /// Plain-English explanation shown when hovering anywhere on the row.
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? start) : nil }))
                    .toggleStyle(.checkbox).font(WorkbenchTypography.label)
                    .accessibilityIdentifier("\(identifier)-override")
                Spacer(minLength: WorkbenchSpacing.xs)
                if value != nil {
                    TextField(title, value: $value, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden().textFieldStyle(.roundedBorder).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(width: 60)
                        .accessibilityIdentifier(identifier)
                } else {
                    Text("Model default").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            Slider(value: Binding(get: { min(max(value ?? start, range.lowerBound), range.upperBound) },
                                  set: { value = (($0 / step).rounded() * step * 100).rounded() / 100 }),
                   in: range) {
                Text(title)
            } minimumValueLabel: {
                Text(Self.text(range.lowerBound)).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } maximumValueLabel: {
                Text(Self.text(range.upperBound)).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            .labelsHidden().controlSize(.small)
            .disabled(value == nil)
        }
        .contentShape(Rectangle())
        .help(help ?? "")
    }

    private static func text(_ value: Double) -> String { String(format: "%g", value) }
}

/// An optional engine feature: its name, where it works and its control. `detail` explains it on hover.
struct ServingFeatureCard<Control: View>: View {
    let title: String
    let detail: String
    let availability: String
    var unavailable = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(title).font(WorkbenchTypography.emphasis)
                Label(availability, systemImage: unavailable ? "xmark.circle" : "checkmark.circle")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(unavailable ? WorkbenchColor.warning : WorkbenchColor.muted)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            control.toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(WorkbenchSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WorkbenchRadius.control).strokeBorder(WorkbenchColor.muted.opacity(.stroke)))
        .contentShape(Rectangle())
        .help(detail)
    }
}

struct ServingInferenceEvidenceView: View {
    let rows: [InferenceOptionEvidence]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("Launch configuration").font(WorkbenchTypography.label)
                ForEach(rows) { row in
                    LabeledContent(row.title) { Text(row.detail).textSelection(.enabled) }
                        .font(WorkbenchTypography.secondary)
                }
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("serve-inference-evidence")
        }
    }
}
