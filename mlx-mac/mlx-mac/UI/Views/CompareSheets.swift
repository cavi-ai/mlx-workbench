import SwiftUI

struct ComparisonProgressControls: View {
    let message: String
    let isCancelling: Bool
    let cleanupPending: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            if !cleanupPending || isCancelling { ProgressView().controlSize(.small).accessibilityHidden(true) }
            Text(message).font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WorkbenchSpacing.sm)
            if cleanupPending {
                Button("Retry cleanup", action: onRetry).disabled(isCancelling)
                    .help("Retry stopping this comparison's owned server before starting another run.")
                    .accessibilityIdentifier("comparison-retry-cleanup")
            } else {
                Button(isCancelling ? "Cancelling…" : "Cancel comparison", action: onCancel).disabled(isCancelling)
                    .help("Stop this comparison's owned work and retain recorded samples. Server startup may need to finish before cleanup.")
                    .accessibilityIdentifier("comparison-cancel")
            }
        }
    }
}

struct StrataSettingsSearchSheet: View {
    let models: [LibraryModel]
    let onUse: (LibraryModel, StrataSettingsSearchSetup) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var modelPath: String
    @State private var lowerBudget = "2"
    @State private var upperBudget = "4"
    @State private var headroom = "8"
    @State private var context = 8192
    @State private var objective = StrataSettingsSearchObjective.firstAnswer
    @State private var warmEachPrompt = false
    @State private var error: String?

    init(models: [LibraryModel], onUse: @escaping (LibraryModel, StrataSettingsSearchSetup) -> String?) {
        self.models = models; self.onUse = onUse
        _modelPath = State(initialValue: models.first?.item.path ?? "")
    }
    private var setup: StrataSettingsSearchSetup? {
        guard let lower = Double(lowerBudget.trimmingCharacters(in: .whitespaces)),
              let upper = Double(upperBudget.trimmingCharacters(in: .whitespaces)),
              let target = Double(headroom.trimmingCharacters(in: .whitespaces)) else { return nil }
        return StrataSettingsSearchSetup(lowerExpertMemoryGB: lower, upperExpertMemoryGB: upper, contextTokens: context,
            headroomGB: target, objective: objective, warmEachPrompt: warmEachPrompt)
    }
    private var validation: String? { setup?.validationError ?? (setup == nil ? "Enter numeric expert budgets and a headroom target." : nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Find best Strata settings").font(WorkbenchTypography.cardTitle)
            Picker("Model", selection: $modelPath) {
                ForEach(models, id: \.item.path) { model in Text(model.item.name).tag(model.item.path) }
            }
            Picker("Fixed context", selection: $context) {
                ForEach([2048, 4096, 8192, 16384, 32768, 65536, 131072], id: \.self) { value in Text("\(value) tokens").tag(value) }
            }
            Picker("Minimize latency to", selection: $objective) {
                ForEach(StrataSettingsSearchObjective.allCases) { Text($0.title).tag($0) }
            }
            Text(objective.explanation)
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("Warm each prompt before measuring", isOn: $warmEachPrompt)
            Text("Adds a one-token request immediately before each measured prompt. Warm-up responses are excluded from samples; total run time increases. Recorded cache counts still determine comparability.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Expert budgets (GB)")
                TextField("Lower", text: $lowerBudget).frame(width: 80)
                TextField("Upper", text: $upperBudget).frame(width: 80)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Text("Observed headroom target (GB)")
                TextField("Headroom", text: $headroom).frame(width: 80).textFieldStyle(.roundedBorder)
            }
            Text("Four lanes test each budget with speculation off and on, using the same prompt set and context. Use setup prepares the lanes; Run comparison starts them sequentially. Existing memory admission guards still apply.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            Text("Rate every lane's task quality after the run. A suggested configuration needs a score of 4 or 5, complete answers, matching fingerprints and sufficient observed headroom. Verify its serving profile before use.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            ErrorBanner(text: validation ?? error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use setup") {
                    guard let setup, let model = models.first(where: { $0.item.path == modelPath }) else { return }
                    error = onUse(model, setup)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(validation != nil || !models.contains(where: { $0.item.path == modelPath }))
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 540)
    }
}

// MARK: - Promote winner

/// One reviewed action that chains the comparison verdict into the rest of
/// the lifecycle: mark the winner preferred for the run's use case and,
/// optionally, keep it serving on the always-on endpoint. Client wiring and
/// loser reclaim stay in their own tabs, so every mutating step keeps its
/// own preview/confirm discipline.
struct PromoteWinnerSheet: View {
    let appHost: AppHost
    let context: QuantView.PromoteContext
    let onPromoted: (String) -> Void
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var verification: VerificationCoordinator

    init(appHost: AppHost, context: QuantView.PromoteContext, onPromoted: @escaping (String) -> Void) {
        self.appHost = appHost
        self.context = context
        self.onPromoted = onPromoted
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _verification = ObservedObject(wrappedValue: appHost.verification)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var enableEndpoint = true
    @State private var allowUnverified = false
    @State private var isApplying = false
    @State private var errorText: String?

    private var winnerPath: String { context.winner.modelPath }
    private var winnerName: String {
        ComparePresentation.displayName(for: winnerPath, models: appHost.librarySnapshot?.models ?? [])
    }
    private var winnerVerified: Bool { appHost.isModelVerified(winnerPath) }
    private var endpointAlreadyWinner: Bool {
        endpoint.config.enabled && endpoint.config.modelPath == winnerPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Promote \(winnerName)")
                .font(WorkbenchTypography.emphasis)
            Text(statsLine)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            if let useCase = context.run.useCase {
                Label("Set as preferred for \(useCase.title)", systemImage: "star.fill")
                    .font(WorkbenchTypography.secondary)
            }

            endpointSection

            ErrorBanner(text: errorText)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isApplying ? "Promoting…" : "Promote") { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 460)
    }

    private var statsLine: String {
        var parts: [String] = []
        if let tps = context.winner.aggregateTokensPerSecond {
            parts.append(ComparisonMetric.tokensPerSecond.format(tps))
        }
        if let ttft = context.winner.aggregateTTFTSeconds {
            parts.append(ComparisonViewLogic.firstToken(ttft))
        }
        return parts.isEmpty ? "Fastest measured variant in this run." : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var endpointSection: some View {
        if endpointAlreadyWinner {
            Label("Already the always-on endpoint model (port \(endpoint.config.port)).",
                  systemImage: "checkmark.circle")
                .font(WorkbenchTypography.secondary)
        } else {
            Toggle(isOn: $enableEndpoint) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text("Keep it always-on")
                        .font(WorkbenchTypography.secondary)
                    Text(endpointCaption)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
            .disabled(!winnerVerified && !allowUnverified)

            if !winnerVerified {
                Toggle("Enable anyway (unverified)", isOn: $allowUnverified)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                Text("This model has not passed the verification canary suite.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private var endpointCaption: String {
        if endpoint.config.enabled {
            return "Swap the supervised endpoint to this model; port \(endpoint.config.port) stays stable for clients."
        }
        return "Supervise this model on the stable loopback port \(endpoint.config.port), restarting it if it crashes."
    }

    private func confirm() async {
        isApplying = true
        defer { isApplying = false }
        errorText = nil

        if let useCase = context.run.useCase {
            do { try appHost.savePreferredModel(winnerPath, for: useCase) }
            catch { errorText = AppHost.render(error); return }
        }

        if enableEndpoint, !endpointAlreadyWinner {
            if endpoint.config.enabled {
                await endpoint.swap(to: winnerPath, allowUnverified: allowUnverified)
            } else {
                await endpoint.enable(
                    modelPath: winnerPath,
                    port: endpoint.config.port,
                    allowUnverified: allowUnverified
                )
            }
            if let lastError = endpoint.lastError {
                errorText = lastError
                return
            }
        }

        onPromoted(winnerPath)
        dismiss()
    }
}

struct StrataComparisonControls: View {
    @Binding var options: StrataComparisonOptions
    var helpText = "A smaller expert budget pages more weights from disk. Custom settings are recorded with this run and excluded from default recommendations."

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Toggle("Draft-and-verify speculation", isOn: $options.speculation)
            Picker("Expert memory", selection: $options.expertMemoryGB) {
                Text("Automatic").tag(Optional<Double>.none)
                ForEach(Array(Set([0.5, 2, 4, 8, 12, 16, 24, 32, 48, 64] + (options.expertMemoryGB.map { [$0] } ?? []))).sorted(), id: \.self) { budget in
                    Text("\(budget.formatted()) GB").tag(Optional(budget))
                }
            }.fixedSize()
            Picker("Context capacity", selection: $options.contextTokens) {
                ForEach(Array(Set([2048, 8192, 32768, 131072, options.contextTokens])).sorted(), id: \.self) { count in
                    Text("\(count) tokens").tag(count)
                }
            }.fixedSize()
            if let error = options.validationError { Text(error).foregroundStyle(.red) }
            Text(helpText)
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }.padding(.top, WorkbenchSpacing.sm)
    }
}
