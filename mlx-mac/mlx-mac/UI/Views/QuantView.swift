import SwiftUI

// MARK: - QuantView
// Compare tab. Top: measured comparison of ready variants via prompt-set
// replay (premium spec 03). Bottom: conversion plan preview across q-bits.

struct QuantView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var comparison: ComparisonCoordinator

    @State private var selectedModel: ModelItem?
    @State private var profiles: [Profile] = []
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var showingPicker = false

    @State private var selectedVariants: Set<String> = []
    @State private var selectedPromptSetID: String = BuiltinPromptSets.coding.id
    @State private var diffLeftPath: String?
    @State private var diffRightPath: String?

    init(appHost: AppHost) {
        self.appHost = appHost
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
    }

    struct Profile: Identifiable {
        let id: String
        let bits: Int
        let plan: [String: Any]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                measuredComparisonSection
                planPreviewSection
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingPicker) {
            ModelPickerSheet(appHost: appHost, selected: $selectedModel)
        }
        .onAppear(perform: preselectVariantFamily)
    }

    // MARK: - Measured comparison

    private var readyModels: [LibraryModel] {
        appHost.librarySnapshot?.models.filter { $0.readiness == .ready } ?? []
    }

    private var selectedPromptSet: PromptSet? {
        comparison.promptSets.first { $0.id == selectedPromptSetID } ?? comparison.promptSets.first
    }

    private var measuredComparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Measured comparison")
            Text("Replay a prompt set against ready variants and measure real decode speed and first-token latency. One variant at a time.")
                .font(.caption)
                .foregroundColor(.secondary)

            if readyModels.isEmpty {
                Text("No ready models in the latest Library snapshot.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(readyModels, id: \.item.path) { model in
                    Toggle(isOn: variantBinding(model.item.path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.callout)
                            Text(model.item.quantization ?? model.item.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 10) {
                Picker("Prompt set", selection: $selectedPromptSetID) {
                    ForEach(comparison.promptSets) { set in
                        Text(set.name).tag(set.id)
                    }
                }
                .frame(width: 240)

                Button("Import my prompts") {
                    if let imported = comparison.importHistory() {
                        selectedPromptSetID = imported.id
                    }
                }
                .help("Read-only import of your opencode user prompts as a prompt set.")

                Button("Run comparison") { startRun() }
                    .disabled(selectedVariants.isEmpty || comparison.activeRunID != nil)
            }

            if comparison.activeRunID != nil {
                ProgressView(comparison.progressMessage ?? "Measuring…")
            }
            ErrorBanner(text: comparison.lastError)
            ErrorBanner(text: comparison.persistenceError)

            if let run = comparison.runs.first {
                runResults(run)
            }
        }
        .formSection {}
    }

    private func runResults(_ run: ComparisonRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Latest run — \(run.promptSetName)")
            ForEach(run.results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(URL(fileURLWithPath: result.modelPath).lastPathComponent)
                            .font(.headline)
                        Spacer()
                        if let tps = result.aggregateTokensPerSecond {
                            Text(String(format: "%.1f tok/s", tps)).font(.caption)
                        }
                        if let ttft = result.aggregateTTFTSeconds {
                            Text(String(format: "TTFT %.2fs", ttft))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let error = result.error {
                        Text(error).font(.caption).foregroundColor(.red)
                    } else {
                        DisclosureGroup("Per-prompt outputs (\(result.samples.count))") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(result.samples, id: \.promptID) { sample in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sample.promptID).font(.caption).foregroundColor(.secondary)
                                        Text(sample.outputExcerpt)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        if let useCase = run.useCase {
                            Button("Set as preferred for \(useCase.title)") {
                                setPreferred(result.modelPath, for: useCase)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(appHost.recommendationPreferences.preferredModelIDs[useCase] == result.modelPath)
                        }
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            if let winner = run.winner, run.state == .completed {
                Text("Fastest: \(URL(fileURLWithPath: winner.modelPath).lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if run.state == .completed, run.results.filter({ $0.error == nil }).count >= 2 {
                diffSection(run)
            }
        }
    }

    // MARK: - Output diff (phase 2)

    private func diffSection(_ run: ComparisonRun) -> some View {
        let candidates = run.results.filter { $0.error == nil }
        let left = candidates.first { $0.modelPath == diffLeftPath }
        let right = candidates.first { $0.modelPath == diffRightPath }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Output diff")
            HStack(spacing: 10) {
                Picker("Left", selection: $diffLeftPath) {
                    Text("Choose…").tag(String?.none)
                    ForEach(candidates) { result in
                        Text(URL(fileURLWithPath: result.modelPath).lastPathComponent).tag(String?.some(result.modelPath))
                    }
                }
                Picker("Right", selection: $diffRightPath) {
                    Text("Choose…").tag(String?.none)
                    ForEach(candidates) { result in
                        Text(URL(fileURLWithPath: result.modelPath).lastPathComponent).tag(String?.some(result.modelPath))
                    }
                }
            }
            .frame(maxWidth: 520)

            if let left, let right, left.modelPath != right.modelPath {
                ForEach(ComparisonDiff.pairs(left, right)) { pair in
                    DisclosureGroup(pair.promptID) {
                        let lines = LineDiff.diff(before: pair.left, after: pair.right)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(diffText(line))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(diffColor(line.kind))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func diffText(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: return "  \(line.text)"
        case .added: return "+ \(line.text)"
        case .removed: return "- \(line.text)"
        }
    }

    private func diffColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return .primary
        case .added: return .green
        case .removed: return .red
        }
    }

    private func variantBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { selectedVariants.contains(path) },
            set: { isOn in
                if isOn { selectedVariants.insert(path) } else { selectedVariants.remove(path) }
            }
        )
    }

    private func preselectVariantFamily() {
        guard selectedVariants.isEmpty,
              let selectedPath = appHost.selectedModelPath,
              let model = readyModels.first(where: {
                  $0.item.path == selectedPath || $0.outputPaths.contains(selectedPath)
              }) else { return }
        selectedVariants = Set(
            readyModels.filter { $0.item.modelKey == model.item.modelKey }.map(\.item.path)
        )
    }

    private func startRun() {
        guard let promptSet = selectedPromptSet else { return }
        let variants = readyModels
            .filter { selectedVariants.contains($0.item.path) }
            .map { (path: $0.item.path, signature: $0.item.signature) }
        comparison.start(variants: variants, promptSet: promptSet)
    }

    private func setPreferred(_ path: String, for useCase: UseCase) {
        let current = appHost.recommendationPreferences
        var preferred = current.preferredModelIDs
        preferred[useCase] = path
        appHost.recommendationPreferences = RecommendationPreferences(
            speedWeight: current.speedWeight,
            qualityWeight: current.qualityWeight,
            hiddenModelIDs: current.hiddenModelIDs,
            preferredModelIDs: preferred
        )
    }

    // MARK: - Conversion plan preview (existing)

    private var planPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Conversion plan preview")
            HStack(spacing: 10) {
                Button("Choose GGUF…") { showingPicker = true }
                Text(selectedModel?.name ?? "No model selected")
                    .foregroundColor(selectedModel == nil ? .secondary : .primary)
                Spacer()
                Button("Compare 4/8-bit") { compare() }
                    .disabled(selectedModel == nil || isRunning)
            }
            if isRunning {
                ProgressView("Profiling…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            ErrorBanner(text: errorMessage)
            if !profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(profile.bits)-bit")
                                .font(.headline)
                            PreviewDictView(value: planSummary(profile.plan))
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .formSection {}
    }

    private func planSummary(_ plan: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["preview_hash", "out", "size", "source", "q_bits"] {
            if let value = plan[key] {
                out[key] = "\(value)"
            }
        }
        if out.isEmpty {
            out["note"] = "Preview returned no structured plan. See Jobs for details."
        }
        return out
    }

    private func compare() {
        guard let model = selectedModel else { return }
        errorMessage = nil
        profiles = []
        isRunning = true
        let path = model.path
        Task {
            for bits in [4, 8] {
                do {
                    let plan = try await appHost.api.convertPreview(ggufPath: path, qBits: bits, out: nil)
                    profiles.append(Profile(id: "\(path)-\(bits)", bits: bits, plan: plan))
                } catch let error as BridgeError {
                    profiles.append(Profile(id: "\(path)-\(bits)", bits: bits,
                                            plan: ["error": error.message]))
                } catch {
                    profiles.append(Profile(id: "\(path)-\(bits)", bits: bits,
                                            plan: ["error": error.localizedDescription]))
                }
            }
            isRunning = false
        }
    }
}
