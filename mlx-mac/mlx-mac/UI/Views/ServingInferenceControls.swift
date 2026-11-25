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

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label("Inference settings", systemImage: "slider.horizontal.3").font(WorkbenchTypography.cardTitle)
                Spacer(minLength: WorkbenchSpacing.xs)
                if options.requested {
                    Button("Reset") { options = .init() }.buttonStyle(.borderless)
                        .accessibilityIdentifier("serve-inference-reset")
                }
            }
            ServingAccelerationRows(options: $options, context: context)
            ServingInferenceRows(options: $options, context: context, allowRequestDefaults: allowRequestDefaults)
            if let error = options.validationError { InlineMessage(kind: .warning, text: error) }
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serve-inference-settings")
    }
}

/// Acceleration controls for the chosen runtime; captions come from `ServingInspectorPresentation`.
struct ServingAccelerationRows: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext
    typealias Field = ServingInspectorPresentation.Field

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if context.isText {
                Picker("Decoding", selection: $options.promptLookup) {
                    Text("Standard").tag(false)
                    Text("Reuse prompt text").tag(true)
                }
                .pickerStyle(.segmented).accessibilityIdentifier("serve-text-decoding")
                ServingCaption(ServingInspectorPresentation.caption(Field.promptLookup))
                DisclosureGroup("Hardware acceleration") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Toggle("M5 prompt processing", isOn: $options.m5Prefill).toggleStyle(.checkbox)
                            .disabled(!context.supportsM5 && !options.m5Prefill)
                            .accessibilityIdentifier("serve-m5-prefill")
                        ServingCaption(ServingInspectorPresentation.caption(Field.m5Prefill))
                    }.padding(.top, WorkbenchSpacing.xs)
                }
            } else if context.isVision {
                Toggle("Reuse image features", isOn: $options.visionCache).toggleStyle(.checkbox)
                    .accessibilityIdentifier("serve-vision-cache")
                ServingCaption(ServingInspectorPresentation.caption(Field.visionCache))
            } else if context.isStrata {
                Text("A serving profile controls decoding, expert memory and context. Verify the profile before use.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else if context.isSplash {
                Text("Splash serves quantized MLX, GGUF and Strata profile weights in place with a DFlash2 draft. Install Splash and the family draft first; the preview checks both.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                Text(context.runtime == "tasks"
                     ? "Generation settings belong to each task request. Use model residency and memory controls to manage the server's footprint."
                     : "The engine identifies this model's runtime during preview. Select a known runtime to review its inference controls.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }
}

/// Reasoning, output length and request defaults; captions come from `ServingInspectorPresentation`.
struct ServingInferenceRows: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext
    var allowRequestDefaults = false
    typealias Field = ServingInspectorPresentation.Field

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if context.supportsReasoningOverride {
                Picker("Reasoning", selection: $options.thinkingOff) {
                    Text("Model default").tag(false)
                    Text("Skip reasoning").tag(true)
                }.accessibilityIdentifier("serve-thinking")
                ServingCaption(ServingInspectorPresentation.caption(Field.thinkingOff))
            }
            if context.hasGenerationDefaults {
                Picker("Default output length", selection: $options.maximumTokens) {
                    Text("Engine default").tag(Int?.none)
                    ForEach(LocalInferenceBounds.choices(LocalInferenceBounds.maximumTokens, including: options.maximumTokens), id: \.self) { value in
                        Text("\(value.formatted()) tokens").tag(Optional(value))
                    }
                }.accessibilityIdentifier("serve-output-length")
                ServingCaption(ServingInspectorPresentation.caption(Field.maximumTokens))
            }
            if allowRequestDefaults && context.supportsRequestDefaults {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Text("Default system prompt").font(WorkbenchTypography.label)
                    TextEditor(text: $options.systemPrompt)
                        .frame(minHeight: WorkbenchSize.Serving.promptMinimum, maxHeight: WorkbenchSize.Serving.promptMaximum)
                        .accessibilityLabel("Default system prompt").accessibilityIdentifier("serve-system-prompt")
                    ServingCaption(ServingInspectorPresentation.caption(Field.systemPrompt))
                    LabeledContent("Temperature") {
                        TextField("Model default", value: $options.temperature, format: .number)
                            .accessibilityIdentifier("serve-default-temperature")
                    }
                    ServingCaption(ServingInspectorPresentation.caption(Field.temperature))
                    LabeledContent("Top-p") {
                        TextField("Model default", value: $options.topP, format: .number)
                            .accessibilityIdentifier("serve-default-top-p")
                    }
                    ServingCaption(ServingInspectorPresentation.caption(Field.topP))
                }
            } else if context.supportsRequestDefaults {
                ServingCaption("System prompt, temperature and top-p apply to load-on-request endpoints. Turn on Load on request to set them.")
            }
        }
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
