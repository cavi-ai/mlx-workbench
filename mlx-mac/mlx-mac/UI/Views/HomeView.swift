import SwiftUI

// MARK: - HomeView

struct HomeView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (String) -> Void

    private let summaryColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12, alignment: .top)
    ]
    private let taskColumns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16, alignment: .top)
    ]

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                stateBanner
                overviewSection
                inventorySection
                taskCardsSection
                rootsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var snapshot: LibrarySnapshot? {
        guard !appHost.isScanning, appHost.scanResult != nil else {
            return nil
        }
        return appHost.librarySnapshot
    }

    private var readyModels: [LibraryModel] {
        snapshot?.models.filter { $0.readiness.isAvailable } ?? []
    }

    private var readyNowCount: Int {
        readyModels.count
    }

    private var recommendationCount: Int {
        UseCase.allCases.reduce(into: 0) { partialResult, useCase in
            partialResult += appHost.recommendations(for: useCase).count
        }
    }

    private var modelCount: Int? {
        snapshot?.models.count
    }

    private var ggufRoots: [String] {
        if let roots = appHost.scanResult?.roots?.gguf, !roots.isEmpty {
            return roots
        }
        return appHost.config.ggufRoots.isEmpty ? appHost.discoveredRoots : appHost.config.ggufRoots
    }

    private var mlxRoots: [String] {
        if let roots = appHost.scanResult?.roots?.mlx, !roots.isEmpty {
            return roots
        }
        return appHost.config.mlxRoots
    }

    private var homeState: HomeState {
        if appHost.isScanning {
            return .loading
        }
        if let error = appHost.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return .scanError(error)
        }
        guard let snapshot else {
            return .loading
        }
        if ggufRoots.isEmpty && mlxRoots.isEmpty && snapshot.models.isEmpty {
            return .configurationNeeded
        }
        if snapshot.models.isEmpty {
            return .noModels
        }
        if recommendationCount == 0 {
            return .noRecommendations
        }
        return .ready
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Local model readiness for Apple Silicon, grounded in the latest library snapshot.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusBadge(title: scanTitle, tint: scanTint)
            }
            if let snapshot {
                Text("Last successful scan: \(timestamp(snapshot.generatedAt))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch homeState {
        case .ready:
            EmptyView()
        case .loading:
            bannerCard(
                title: "Scanning your local library",
                message: "Home is waiting on the first scan so it can size storage, detect ready models, and populate the task cards.",
                symbol: "arrow.triangle.2.circlepath",
                tint: .accentColor
            )
        case .scanError(let error):
            bannerCard(
                title: "Scan error",
                message: "\(error) Update roots or agent settings, then run the existing scan again.",
                symbol: "exclamationmark.triangle",
                tint: .red
            )
        case .configurationNeeded:
            bannerCard(
                title: "No model roots configured",
                message: "Add at least one GGUF or MLX root in Settings so Home can inventory local models without downloading anything.",
                symbol: "externaldrive.badge.questionmark",
                tint: .orange
            )
        case .noModels:
            bannerCard(
                title: "No local models found",
                message: "The current roots scanned successfully, but there are no GGUF files or MLX outputs to summarize yet.",
                symbol: "tray",
                tint: .orange
            )
        case .noRecommendations:
            bannerCard(
                title: "No ready-now recommendations yet",
                message: "Home is showing intent coverage only for now. Once the library has ready models, these cards will turn into actionable starting points without adding any background downloads.",
                symbol: "sparkles",
                tint: .secondary
            )
        }
    }

    private var overviewSection: some View {
        LazyVGrid(columns: taskColumns, spacing: 16) {
            runtimeCard
            hardwareCard
        }
    }

    private var runtimeCard: some View {
        formSection {
            SectionTitle(text: "Runtime status")
            VStack(alignment: .leading, spacing: 10) {
                statusRow(title: "Agent", text: agentHealthText, tint: agentHealthTint)
                statusRow(title: "Prepare", text: appHost.runtimeReport.convert.message, tint: appHost.runtimeReport.convert.ok ? .green : .orange)
                statusRow(title: "Run", text: appHost.runtimeReport.serve.message, tint: appHost.runtimeReport.serve.ok ? .green : .orange)
                statusRow(title: "Scan", text: scanDetail, tint: scanTint)
            }
        }
    }

    private var hardwareCard: some View {
        formSection {
            SectionTitle(text: "Hardware profile")
            VStack(alignment: .leading, spacing: 10) {
                Label(appHost.hardwareProfile.summary, systemImage: "cpu")
                    .font(.callout)
                Divider()
                detailLine("Host", appHost.config.host)
                detailLine("Port", String(appHost.config.port))
                detailLine("GGUF roots", String(ggufRoots.count))
                detailLine("MLX roots", String(mlxRoots.count))
            }
        }
    }

    private var inventorySection: some View {
        Group {
            SectionTitle(text: "Inventory")
            LazyVGrid(columns: summaryColumns, spacing: 12) {
                metricCard(title: "Total storage", value: snapshot.map { byteCount($0.totalBytes) } ?? "Not available", accent: .accentColor)
                metricCard(title: "Reclaimable", value: snapshot.map { byteCount($0.reclaimableBytes) } ?? "Not available", accent: .orange)
                metricCard(title: "Model count", value: modelCount.map(String.init) ?? "Not available", accent: .primary)
                metricCard(title: "Ready now", value: snapshot != nil ? String(readyNowCount) : "Not available", accent: readyNowCount > 0 ? .green : .secondary)
            }
        }
    }

    private var taskCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Start from an intent")
            LazyVGrid(columns: taskColumns, spacing: 16) {
                ForEach(UseCase.allCases) { useCase in
                    taskCard(for: useCase)
                }
            }
        }
    }

    private func taskCard(for useCase: UseCase) -> some View {
        let state = taskState(for: useCase)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(useCase.title, systemImage: useCase.symbolName)
                        .font(.headline)
                    Text(useCase.homeBlurb)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusBadge(title: state.badgeTitle, tint: state.tint)
            }

        if let metrics = state.metrics {
            HStack(spacing: 8) {
                ForEach(metrics, id: \.title) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.value)
                                .font(.headline)
                            Text(metric.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .cornerRadius(8)
                }
            }
        }

            if let recommendation = state.recommendation, let model = state.model {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.displayName)
                        .font(.title3)
                        .fontWeight(.semibold)
                    detailLine("Readiness", recommendation.readiness.title)
                    detailLine("Freshness", recommendation.freshness.title)
                    detailLine("Evidence", recommendation.evidenceTimestamp.map(timestamp) ?? "Not available")

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recommendation.reasons.prefix(3)), id: \.name) { reason in
                            Label(reason.message, systemImage: reason.isHint ? "info.circle" : "checkmark.circle")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else if let model = state.model {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.displayName)
                        .font(.title3)
                        .fontWeight(.semibold)
                    detailLine("Readiness", model.readiness.title)
                    detailLine("Freshness", RecommendationFreshness.localOnly.title)
                    detailLine("Evidence", snapshot.map { timestamp($0.generatedAt) } ?? "Not available")
                }
            }

            Text(state.message)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let model = state.model {
                actionRow(for: model)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private var rootsSection: some View {
        formSection {
            SectionTitle(text: "Where models live")
            VStack(alignment: .leading, spacing: 14) {
                rootsBlock(title: "GGUF roots", paths: ggufRoots)
                rootsBlock(title: "MLX roots", paths: mlxRoots)
            }
        }
    }

    private func rootsBlock(title: String, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if paths.isEmpty {
                Text("None configured")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func metricCard(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(accent)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func bannerCard(title: String, message: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(tint.opacity(0.08))
        .cornerRadius(12)
    }

    private func statusRow(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(text)
                .font(.callout)
                .foregroundColor(tint)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }

    private func actionRow(for model: LibraryModel) -> some View {
        HStack(spacing: 8) {
            Button("Details") {
                select(model, route: "models")
            }

            Button("Prepare") {
                select(model, route: "convert")
            }
            .disabled(!canPrepare(model))

            Button("Compare") {
                select(model, route: "quant")
            }
            .disabled(!canCompare(model))

            Button("Try") {
                select(model, route: "serve")
            }
            .disabled(model.readiness != .ready)
        }
        .buttonStyle(.bordered)
    }

    private func statusBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .foregroundColor(tint)
            .cornerRadius(999)
    }

    private var agentHealthText: String {
        switch appHost.agentHealth {
        case .notConfigured:
            return "No mlx-agent configured."
        case .notFound(_, let cli):
            return "Missing \(cli)"
        case .notUsable(_, let cli, let reason):
            return "\(reason) (\(cli))"
        case .ready(_, let cli):
            return cli
        }
    }

    private var agentHealthTint: Color {
        switch appHost.agentHealth {
        case .ready:
            return .green
        case .notFound, .notUsable:
            return .red
        case .notConfigured:
            return .orange
        }
    }

    private var scanTitle: String {
        switch homeState {
        case .ready:
            return "Ready"
        case .loading:
            return "Loading"
        case .scanError:
            return "Error"
        case .configurationNeeded:
            return "Config needed"
        case .noModels:
            return "No models"
        case .noRecommendations:
            return "Coverage only"
        }
    }

    private var scanDetail: String {
        switch homeState {
        case .ready:
            return "Library snapshot is current and task cards are populated from local state."
        case .loading:
            return "Scanning configured roots for local GGUF files and MLX outputs."
        case .scanError(let error):
            return error
        case .configurationNeeded:
            return "Add roots in Settings to enable local inventory."
        case .noModels:
            return "Scan finished, but no local models were found."
        case .noRecommendations:
            return "The library is present, but nothing is ready to serve these intents yet."
        }
    }

    private var scanTint: Color {
        switch homeState {
        case .ready:
            return .green
        case .loading:
            return .accentColor
        case .scanError:
            return .red
        case .configurationNeeded, .noModels:
            return .orange
        case .noRecommendations:
            return .secondary
        }
    }

    private func taskState(for useCase: UseCase) -> TaskState {
        switch homeState {
        case .loading:
            return TaskState(
                badgeTitle: "Loading",
                tint: .accentColor,
                message: "Home is waiting on the current scan before it can map local coverage for this task.",
                metrics: nil,
                recommendation: nil,
                model: nil
            )
        case .scanError:
            return TaskState(
                badgeTitle: "Scan error",
                tint: .red,
                message: "Fix the scan error first. Home is intentionally not guessing about this task without authoritative local inventory.",
                metrics: nil,
                recommendation: nil,
                model: nil
            )
        case .configurationNeeded:
            return TaskState(
                badgeTitle: "Needs roots",
                tint: .orange,
                message: "Configure at least one GGUF or MLX root in Settings, then rescan to populate this task with local evidence.",
                metrics: nil,
                recommendation: nil,
                model: nil
            )
        case .noModels:
            return TaskState(
                badgeTitle: "No models",
                tint: .orange,
                message: "The current roots did not produce any local models for this task yet.",
                metrics: nil,
                recommendation: nil,
                model: nil
            )
        case .noRecommendations, .ready:
            let recommendation = appHost.recommendations(for: useCase).first
            let recommendedModel = recommendation.flatMap(appHost.model(for:))
            let matching = snapshot?.models.filter { homeMatches($0, useCase: useCase) } ?? []
            let fallbackModel = recommendedModel ?? preferredFallbackModel(in: matching)
            let ready = matching.filter { $0.readiness == .ready }.count
            let prepare = matching.filter { $0.readiness == .needsConversion }.count
            let runtime = matching.filter { $0.readiness == .needsRuntime }.count
            let attention = matching.count - ready - prepare - runtime

            guard let recommendation, let model = recommendedModel else {
                let message: String
                if fallbackModel != nil {
                    message = "No ready recommendation passed the conservative gates. Review local readiness and evidence before promoting this model for \(useCase.title)."
                } else if matching.isEmpty {
                    message = "No current local matches for this intent. Home is waiting for future scans rather than inventing a recommendation."
                } else {
                    message = "Local matches exist, but none are ready now. Use Prepare or Run after addressing conversion, runtime, or health issues."
                }
                return TaskState(
                    badgeTitle: "No recommendation",
                    tint: .secondary,
                    message: message,
                    metrics: [
                        Metric(title: "Matches", value: String(matching.count)),
                        Metric(title: "Prepare", value: String(prepare)),
                        Metric(title: "Attention", value: String(max(attention, 0)))
                    ],
                    recommendation: nil,
                    model: fallbackModel
                )
            }

            return TaskState(
                badgeTitle: recommendation.confidence.title,
                tint: .green,
                message: "Recommendation ranking stayed local, deterministic, and conservative for this task. Details and route actions reuse the existing native model selection flow.",
                metrics: [
                    Metric(title: "Ready", value: String(ready)),
                    Metric(title: "Prepare", value: String(prepare)),
                    Metric(title: "Runtime", value: String(runtime))
                ],
                recommendation: recommendation,
                model: model
            )
        }
    }

    private func homeMatches(_ model: LibraryModel, useCase: UseCase) -> Bool {
        if useCase == .generalChat {
            return true
        }
        return model.capabilities.contains(useCase)
    }

    private func preferredFallbackModel(in models: [LibraryModel]) -> LibraryModel? {
        models.sorted { lhs, rhs in
            let lhsRank = fallbackReadinessRank(lhs.readiness)
            let rhsRank = fallbackReadinessRank(rhs.readiness)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsName = lhs.displayName.localizedLowercase
            let rhsName = rhs.displayName.localizedLowercase
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            return lhs.item.path < rhs.item.path
        }.first
    }

    private func fallbackReadinessRank(_ readiness: ModelReadiness) -> Int {
        switch readiness {
        case .ready:
            return 0
        case .needsConversion:
            return 1
        case .needsRuntime:
            return 2
        case .incompleteCache:
            return 3
        case .unsupported:
            return 4
        case .duplicate:
            return 5
        case .quarantined:
            return 6
        }
    }

    private func canPrepare(_ model: LibraryModel) -> Bool {
        model.readiness != .unsupported && model.readiness != .quarantined
    }

    private func canCompare(_ model: LibraryModel) -> Bool {
        model.readiness != .quarantined && model.item.readable != false
    }

    private func select(_ model: LibraryModel, route: String) {
        appHost.selectedModelPath = model.item.path
        onRouteSelection(route)
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private extension HomeView {
    enum HomeState {
        case loading
        case scanError(String)
        case configurationNeeded
        case noModels
        case noRecommendations
        case ready
    }

    struct Metric {
        let title: String
        let value: String
    }

    struct TaskState {
        let badgeTitle: String
        let tint: Color
        let message: String
        let metrics: [Metric]?
        let recommendation: Recommendation?
        let model: LibraryModel?
    }
}

private extension UseCase {
    var symbolName: String {
        switch self {
        case .coding:
            return "curlybraces.square"
        case .generalChat:
            return "bubble.left.and.bubble.right"
        case .reasoning:
            return "lightbulb.max"
        case .vision:
            return "eye"
        }
    }

    var homeBlurb: String {
        switch self {
        case .coding:
            return "Reach for local models that can help draft, refactor, and inspect code."
        case .generalChat:
            return "Start lightweight conversation, drafting, and everyday assistant work."
        case .reasoning:
            return "Hold deeper analysis and research tasks without leaving the local inventory."
        case .vision:
            return "Check whether any local multimodal models are available for image-aware work."
        }
    }
}
