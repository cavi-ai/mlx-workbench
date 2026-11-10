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

    var isText: Bool { runtime == "mlx_lm" }
    var isVision: Bool { runtime == "mlx-vlm" }
    var isStrata: Bool { runtime == "strata" }
    var hasGenerationDefaults: Bool { isText || isStrata }
    var supportsM5: Bool { chip?.range(of: #"\bM5\b"#, options: [.regularExpression, .caseInsensitive]) != nil }

    func normalized(_ options: LocalInferenceOptions) -> LocalInferenceOptions {
        var result = options
        if !isText { result.m5Prefill = false; result.promptLookup = false; result.thinkingOff = false }
        if !isVision { result.visionCache = false }
        if !hasGenerationDefaults { result.maximumTokens = nil }
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

extension LocalInferenceOptions {
    var summary: String {
        var parts: [String] = []
        if promptLookup { parts.append("Prompt text reuse") }
        if m5Prefill { parts.append("M5 prompt processing") }
        if visionCache { parts.append("Image feature reuse") }
        if thinkingOff { parts.append("Skip reasoning") }
        if let maximumTokens { parts.append("\(maximumTokens.formatted()) output tokens") }
        return parts.isEmpty ? "Runtime defaults" : parts.joined(separator: " · ")
    }
}

/// Shared by a new server and a saved endpoint. Only the chosen runtime's controls appear.
struct ServingInferenceControls: View {
    @Binding var options: LocalInferenceOptions
    let context: ServingInferenceContext

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
            if context.isText {
                Picker("Decoding", selection: $options.promptLookup) {
                    Text("Standard").tag(false)
                    Text("Reuse prompt text").tag(true)
                }
                .pickerStyle(.segmented).accessibilityIdentifier("serve-text-decoding")
                Text(options.promptLookup
                     ? "For code edits that copy text from the prompt. Use temperature 0 in your client; these requests run one at a time. No draft model is needed."
                     : "Native decoding and batching for general chat and concurrent requests.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                DisclosureGroup("Hardware acceleration") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Toggle("M5 prompt processing", isOn: $options.m5Prefill).toggleStyle(.checkbox)
                            .disabled(!context.supportsM5 && !options.m5Prefill)
                            .accessibilityIdentifier("serve-m5-prefill")
                        Text(context.supportsM5
                             ? "Experimental kernel for supported M5 Q4 models. First load compiles kernels; unsupported inputs use native MLX."
                             : "Requires an M5 GPU and supported Q4 models. The engine checks runtime compatibility.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }.padding(.top, WorkbenchSpacing.xs)
                }
            } else if context.isVision {
                Toggle("Reuse image features", isOn: $options.visionCache).toggleStyle(.checkbox)
                    .accessibilityIdentifier("serve-vision-cache")
                Text("For repeated questions about the same image on supported Qwen2.5-VL and Qwen3-VL models. Keeps up to 128 MiB of features while loaded; other models use native processing.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else if context.isStrata {
                Text("A serving profile controls decoding, expert memory and context. Verify the profile before use.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                Text(context.runtime == "tasks"
                     ? "Generation settings belong to each task request. Use model residency and memory controls to manage the server's footprint."
                     : "The engine identifies this model's runtime during preview. Select a known runtime to review its inference controls.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            if context.hasGenerationDefaults {
                DisclosureGroup("Generation defaults") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        if context.isText {
                            Picker("Reasoning", selection: $options.thinkingOff) {
                                Text("Model default").tag(false)
                                Text("Skip reasoning").tag(true)
                            }.accessibilityIdentifier("serve-thinking")
                            Text("Skipping reasoning can shorten responses at the cost of deliberation. Support depends on the model's chat template.")
                                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                        Picker("Default output length", selection: $options.maximumTokens) {
                            Text("Engine default · 8,192 tokens").tag(Int?.none)
                            ForEach(Array(Set([256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536] + (options.maximumTokens.map { [$0] } ?? []))).sorted(), id: \.self) { value in
                                Text("\(value.formatted()) tokens").tag(Optional(value))
                            }
                        }.accessibilityIdentifier("serve-output-length")
                        Text("Used when a client omits its output length. Temperature, sampling and per-request token limits stay in the client.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }.padding(.top, WorkbenchSpacing.xs)
                }
            }
            if let error = options.validationError { InlineMessage(kind: .warning, text: error) }
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serve-inference-settings")
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
