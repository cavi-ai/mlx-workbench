import AppKit
import SwiftUI

/// Plain-English hover text for the Splash and Strata controls; each sentence names the engine range.
enum ServingRuntimeHelp {
    static let splash = "Splash guesses several tokens ahead with a small draft model and checks them with the full model, so answers arrive faster without changing what the model would write."
    static let draftModel = "A small helper model that guesses the next few tokens for Splash to check. Leave it unset to use this family's draft from the Hugging Face cache, or choose a local DFlash2 draft folder with config.json and safetensors weights."
    static let chatTemplate = "The template that turns a conversation into the exact text the model reads. Leave it unset to use the model's own, or choose a local UTF-8 Jinja file of at most 1 MiB to replace it."
    static let verifyRows = "How many of the draft's guesses Splash checks each step. Adaptive is faster; Every row makes the same prompt and seed give the same answer every time."
    static let cachedStates = "How Splash stores its memory of earlier text. int8 is compact; Exact keeps full precision and uses about three times the memory."
    static let kvFormat = "How Splash stores attention memory for the conversation so far. int8 uses half the memory; bf16 keeps full precision and uses about twice as much."
    static let reasoningEffort = "How hard the model thinks before it answers, applied to every request whatever the client asks. None turns thinking off; Each request leaves the choice to the client."
    static let thinkingBudget = "The most tokens the model may spend thinking when a request sets no limit, from 0 to 1,010,000 tokens."
    static let persistentCache = "Keeps Splash's on-disk prompt cache after a restart, so prompts it has seen before start answering sooner."
    static let cacheQuota = "The most disk space Splash's prompt cache may use, from 0 to 4,096 GB; 0 turns the cache off."
    static let projectCache = "A named on-disk prompt cache that every launch with the same name reuses, such as one per code project. Use a lowercase letter, then up to 63 lowercase letters, digits, - or _. It needs Load on request, an API key, an SSD cache size and a write cap."
    static let writeCap = "The most data the project cache may write to disk, which limits SSD wear, above 0 and up to 4,096 GB."
    static let memoryCeiling = "The most unified memory Splash may plan for, from 1 to 1,024 GB. It can only lower Splash's own plan."
    static let contextLimit = "The longest conversation Splash accepts, from 512 to 1,010,000 tokens. Lower limits use less memory."
    static let strata = "Strata serves large mixture-of-experts models by keeping the most used experts in memory and reading the rest from disk."
    static let strataDecoding = "How Strata writes each answer. Standard writes one token at a time. Lookup copies matching text from the prompt and checks it, which helps edits and summaries. MTP lets the model's own draft head guess ahead, then checks the guesses."
    static let expertMemory = "How much memory Strata keeps for the model's experts, from 0.5 to 64 GB. Experts that do not fit stay on disk and load when needed, which is slower."
    static let strataContext = "The longest conversation Strata accepts, from 512 to 131,072 tokens. Larger values reserve more memory."
}

enum ServingRuntimeText {
    static func range(_ range: ClosedRange<Double>, unit: String) -> String {
        "\(range.lowerBound.formatted()) to \(range.upperBound.formatted()) \(unit)"
    }
    static func range(_ range: ClosedRange<Int>, unit: String) -> String {
        "\(range.lowerBound.formatted()) to \(range.upperBound.formatted()) \(unit)"
    }
    /// A whole-number setting edited through the shared decimal row; out-of-range values stay visible for validation.
    static func decimal(_ value: Binding<Int?>) -> Binding<Double?> {
        Binding(get: { value.wrappedValue.map(Double.init) },
                set: { value.wrappedValue = $0.flatMap { $0.isFinite ? Int(min(max($0.rounded(), -1e12), 1e12)) : nil } })
    }
}

/// The Splash runtime's experimental launch settings: the draft model and chat template files.
struct ServingSplashExperimentalControls: View {
    @Binding var options: LocalInferenceOptions

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ServingFeatureCard(title: "Splash DFlash2", detail: "Speculative decoding with the family's cached draft; serves MLX, GGUF and Strata weights in place. The preview checks Splash and the draft.",
                               availability: "Splash 1.4+, Apple M3 or newer, macOS 26.4") { EmptyView() }
                .help(ServingRuntimeHelp.splash)
            ServingPathChoiceRow(title: "Draft model", help: ServingRuntimeHelp.draftModel, unsetText: "Family's cached draft",
                                 choosesFolder: true, path: $options.splashDraftModel, identifier: "serve-splash-draft-model")
            ServingPathChoiceRow(title: "Chat template", help: ServingRuntimeHelp.chatTemplate, unsetText: "Model's own template",
                                 choosesFolder: false, path: $options.splashChatTemplate, identifier: "serve-splash-chat-template")
            ServingCaption("Decoding, reasoning, SSD cache and memory limits are saved in the Splash preset.")
        }
    }
}

/// The Strata runtime's experimental settings, owned by the verified serving profile.
struct ServingStrataExperimentalControls: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ServingFeatureCard(title: "Strata decoding", detail: "Standard, lookup or MTP decoding, expert memory and context come from the verified serving profile.",
                               availability: "Strata profiles") { EmptyView() }
                .help(ServingRuntimeHelp.strata)
            ServingCaption("Expert memory \(ServingRuntimeText.range(ServingRuntimeBounds.strataExpertMemoryGB, unit: "GB")); context \(ServingRuntimeText.range(ServingRuntimeBounds.strataContextTokens, unit: "tokens")). A changed profile is verified again before serving.")
        }
    }
}

/// Every Splash setting a saved preset carries; values left unset keep Splash's own defaults.
struct SplashPresetTuningControls: View {
    @Binding var tuning: SplashTuning
    @Binding var memoryGB: Double?
    @Binding var contextTokens: Int?
    typealias Bounds = ServingRuntimeBounds

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Text("Decoding").font(WorkbenchTypography.label)
                ServingOptionalChoiceRow(title: "Draft checking", help: ServingRuntimeHelp.verifyRows, selection: $tuning.verifyRows,
                                         choices: [("auto", "Adaptive"), ("all", "Every row")], identifier: "splash-verify-rows")
                LabeledContent("Reasoning effort") {
                    Picker("Reasoning effort", selection: $tuning.reasoningEffort) {
                        Text("Each request").tag(String?.none)
                        ForEach(SplashTuning.efforts, id: \.self) { effort in
                            Text(effort == "none" ? "None" : effort.capitalized).tag(String?.some(effort))
                        }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("splash-reasoning-effort")
                }.help(ServingRuntimeHelp.reasoningEffort)
                ServingOptionalValueRow(title: "Thinking budget", help: ServingRuntimeHelp.thinkingBudget,
                                        value: ServingRuntimeText.decimal($tuning.thinkingBudget),
                                        range: Double(Bounds.splashThinkingTokens.lowerBound)...Double(Bounds.splashThinkingTokens.upperBound),
                                        step: 1024, start: 4096, unit: "tokens", identifier: "splash-thinking-budget")
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Text("Cache").font(WorkbenchTypography.label)
                ServingOptionalChoiceRow(title: "KV cache", help: ServingRuntimeHelp.kvFormat, selection: $tuning.kvFormat,
                                         choices: [("int8", "int8"), ("bf16", "bf16")], identifier: "splash-kv-format")
                ServingOptionalChoiceRow(title: "Saved states", help: ServingRuntimeHelp.cachedStates, selection: $tuning.cachedStates,
                                         choices: [("int8", "int8"), ("exact", "Exact")], identifier: "splash-cached-states")
                LabeledContent("Keep SSD cache") {
                    Picker("Keep SSD cache", selection: $tuning.persistentCache) {
                        Text("Default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("splash-persistent-cache")
                }.help(ServingRuntimeHelp.persistentCache)
                ServingOptionalValueRow(title: "SSD cache size", help: ServingRuntimeHelp.cacheQuota, value: $tuning.maxCacheDiskGB,
                                        range: Bounds.splashCacheDiskGB, step: 8, start: 32, unit: "GB", fractionDigits: 1,
                                        identifier: "splash-cache-disk")
                LabeledContent("Project cache") {
                    TextField("Project cache", text: Binding(
                        get: { tuning.projectCache ?? "" },
                        set: { let name = $0.trimmingCharacters(in: .whitespacesAndNewlines); tuning.projectCache = name.isEmpty ? nil : name }),
                        prompt: Text("None"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 160)
                        .accessibilityIdentifier("splash-project-cache")
                }.help(ServingRuntimeHelp.projectCache)
                ServingOptionalValueRow(title: "Cache write cap", help: ServingRuntimeHelp.writeCap, value: $tuning.maxCacheDiskWritesGB,
                                        range: Bounds.splashCacheDiskGB, step: 8, start: 64, unit: "GB", fractionDigits: 1,
                                        identifier: "splash-cache-writes")
                    .disabled(tuning.projectCache == nil && tuning.maxCacheDiskWritesGB == nil)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Text("Limits").font(WorkbenchTypography.label)
                ServingOptionalValueRow(title: "Memory ceiling", help: ServingRuntimeHelp.memoryCeiling, value: $memoryGB,
                                        range: Bounds.splashMemoryGB, step: 1, start: 32, unit: "GB", fractionDigits: 1,
                                        identifier: "splash-max-memory")
                ServingOptionalValueRow(title: "Context limit", help: ServingRuntimeHelp.contextLimit,
                                        value: ServingRuntimeText.decimal($contextTokens),
                                        range: Double(Bounds.splashContextTokens.lowerBound)...Double(Bounds.splashContextTokens.upperBound),
                                        step: 4096, start: 32768, unit: "tokens", identifier: "splash-max-context")
            }
            if let problem = tuning.problem { InlineMessage(kind: .warning, text: problem) }
        }
    }
}

/// A Strata serving profile's decoding, expert memory and context; a changed profile needs verification.
struct StrataProfileOptionControls: View {
    @Binding var options: StrataComparisonOptions
    typealias Bounds = ServingRuntimeBounds

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            LabeledContent("Decoding") {
                Picker("Decoding", selection: $options.decodingSelection) {
                    Text("Standard").tag("plain")
                    Text("Lookup").tag("lookup")
                    Text("MTP").tag("mtp")
                    if options.speculation && options.decoding == nil { Text("Automatic").tag("automatic") }
                }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("strata-profile-decoding")
            }.help(ServingRuntimeHelp.strataDecoding)
            ServingOptionalValueRow(title: "Expert memory", help: ServingRuntimeHelp.expertMemory, value: $options.expertMemoryGB,
                                    range: Bounds.strataExpertMemoryGB, step: 0.5, start: 8, unit: "GB", fractionDigits: 1,
                                    unsetText: "Automatic", identifier: "strata-profile-expert-memory")
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                LabeledContent("Context") {
                    Picker("Context", selection: $options.contextTokens) {
                        ForEach(LocalInferenceBounds.choices(Bounds.strataContextTokens, including: options.contextTokens), id: \.self) { count in
                            Text("\(count.formatted()) tokens").tag(count)
                        }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("strata-profile-context")
                }
                Text(ServingRuntimeText.range(Bounds.strataContextTokens, unit: "tokens"))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }.help(ServingRuntimeHelp.strataContext)
            if let error = options.validationError { InlineMessage(kind: .warning, text: error) }
        }
    }
}

/// One optional enum setting as a segmented control; the first segment keeps the runtime default.
struct ServingOptionalChoiceRow: View {
    let title: String
    let help: String
    @Binding var selection: String?
    let choices: [(value: String, label: String)]
    var unsetLabel = "Default"
    let identifier: String

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection) {
                Text(unsetLabel).tag(String?.none)
                ForEach(choices, id: \.value) { choice in Text(choice.label).tag(String?.some(choice.value)) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier(identifier)
        }
        .help(help)
    }
}

/// One optional number: a checkbox overrides the runtime default, then a field and stepper within the engine range.
struct ServingOptionalValueRow: View {
    let title: String
    let help: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let step: Double
    /// Value set when the override is turned on.
    let start: Double
    let unit: String
    var fractionDigits = 0
    var unsetText = "Splash default"
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? start) : nil }))
                    .toggleStyle(.checkbox).font(WorkbenchTypography.label).lineLimit(1)
                    .accessibilityIdentifier("\(identifier)-override")
                Spacer(minLength: WorkbenchSpacing.xs)
                if value != nil {
                    TextField(title, value: $value, format: .number.precision(.fractionLength(0...fractionDigits)))
                        .labelsHidden().textFieldStyle(.roundedBorder).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(width: 96)
                        .accessibilityIdentifier(identifier)
                    Stepper(title, value: Binding(get: { min(max(value ?? start, range.lowerBound), range.upperBound) },
                                                  set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                            in: range, step: step)
                        .labelsHidden()
                } else {
                    Text(unsetText).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                }
            }
            Text(ServingRuntimeText.range(range, unit: unit))
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }
        .help(help)
    }
}

/// A local file or folder the engine reads at launch; unset keeps the runtime's own choice.
struct ServingPathChoiceRow: View {
    let title: String
    let help: String
    let unsetText: String
    let choosesFolder: Bool
    @Binding var path: String?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Text(title).font(WorkbenchTypography.label).lineLimit(1)
                Spacer(minLength: WorkbenchSpacing.xs)
                if path != nil {
                    Button("Clear") { path = nil }.buttonStyle(.borderless)
                        .accessibilityIdentifier("\(identifier)-clear")
                }
                Button(choosesFolder ? "Choose folder…" : "Choose file…") { choose() }
                    .controlSize(.small).accessibilityIdentifier(identifier)
            }
            Text(path ?? unsetText)
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .help(help)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = choosesFolder
        panel.canChooseFiles = !choosesFolder
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Choose"
        panel.message = title
        if let path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
