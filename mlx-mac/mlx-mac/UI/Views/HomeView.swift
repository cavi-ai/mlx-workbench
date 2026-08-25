import SwiftUI

enum HomeNextActionKind: Equatable {
    case configure
    case scan
    case activity
    case prepare(String)
    case run(String)
    case library
}

struct HomeNextAction: Equatable {
    let kind: HomeNextActionKind
    let title: String
    let reason: String
    let route: String

    static func derive(
        workflow: ConversionWorkflow,
        snapshot: LibrarySnapshot?,
        rootsConfigured: Bool,
        isScanning: Bool,
        lastError: String?,
        agentReady: Bool,
        convertRuntimeReady: Bool,
        serveRuntimeReady: Bool
    ) -> HomeNextAction {
        if workflow.state == .queued || workflow.state == .running {
            return HomeNextAction(kind: .activity, title: "Monitor conversion", reason: "A conversion is \(workflow.state.rawValue); Activity has the authoritative receipt and live status.", route: "jobs")
        }
        if workflow.state == .failed {
            return HomeNextAction(kind: .activity, title: "Resolve conversion failure", reason: workflow.errorMessage ?? workflow.message ?? "The current conversion needs attention in Activity.", route: "jobs")
        }
        if let path = workflow.completedModelPath, !path.isEmpty {
            guard agentReady && serveRuntimeReady else {
                return HomeNextAction(kind: .configure, title: "Repair the Run runtime", reason: "The model is complete, but the agent or serving runtime is unavailable.", route: "settings")
            }
            return HomeNextAction(kind: .run(path), title: "Run completed model", reason: "Conversion completed and the selected MLX output is ready for a serve preview.", route: "serve")
        }
        guard rootsConfigured else {
            return HomeNextAction(kind: .configure, title: "Configure model roots", reason: "No GGUF or MLX roots are configured, so the library has nowhere to scan.", route: "settings")
        }
        guard agentReady else {
            return HomeNextAction(kind: .configure, title: "Configure mlx-agent", reason: "The local agent is unavailable; Settings contains the path needed for scan, prepare, and run.", route: "settings")
        }
        if let error = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return HomeNextAction(kind: .scan, title: "Resolve the library scan", reason: error, route: "models")
        }
        guard let snapshot else {
            return HomeNextAction(
                kind: .scan,
                title: isScanning ? "View library scan" : "Scan the model library",
                reason: isScanning ? "The first authoritative library scan is in progress." : "No successful library snapshot exists yet.",
                route: "models"
            )
        }
        if let ready = snapshot.models.first(where: { $0.readiness == .ready }) {
            guard serveRuntimeReady else {
                return HomeNextAction(kind: .configure, title: "Repair the Run runtime", reason: "A ready model exists, but the serving runtime is unavailable.", route: "settings")
            }
            return HomeNextAction(kind: .run(ready.item.path), title: "Run a ready model", reason: "The latest Library snapshot contains a model ready for serve preview.", route: "serve")
        }
        if let source = snapshot.models.first(where: { $0.readiness == .needsConversion }) {
            guard convertRuntimeReady else {
                return HomeNextAction(kind: .configure, title: "Repair the Prepare runtime", reason: "A GGUF source needs conversion, but the conversion runtime is unavailable.", route: "settings")
            }
            return HomeNextAction(kind: .prepare(source.item.path), title: "Prepare a GGUF model", reason: "The latest Library snapshot contains a GGUF source that needs MLX conversion.", route: "convert")
        }
        return HomeNextAction(
            kind: .library,
            title: "Review the model library",
            reason: snapshot.models.isEmpty ? "The latest scan found no local models." : "The latest scan found models, but none are currently ready to run or prepare.",
            route: "models"
        )
    }
}

struct HomeView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (String) -> Void

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    private var ggufRoots: [String] {
        if let roots = appHost.scanResult?.roots?.gguf, !roots.isEmpty { return roots }
        return appHost.config.ggufRoots.isEmpty ? appHost.discoveredRoots : appHost.config.ggufRoots
    }
    private var mlxRoots: [String] {
        if let roots = appHost.scanResult?.roots?.mlx, !roots.isEmpty { return roots }
        return appHost.config.mlxRoots
    }
    private var agentReady: Bool {
        if case .ready = appHost.agentHealth { return true }
        return false
    }
    private var nextAction: HomeNextAction {
        HomeNextAction.derive(
            workflow: appHost.modelWorkflow.workflow,
            snapshot: appHost.librarySnapshot,
            rootsConfigured: !ggufRoots.isEmpty || !mlxRoots.isEmpty,
            isScanning: appHost.isScanning,
            lastError: appHost.lastError,
            agentReady: agentReady,
            convertRuntimeReady: appHost.runtimeReport.convert.ok,
            serveRuntimeReady: appHost.runtimeReport.serve.ok
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home").font(.system(size: 28, weight: .semibold))
                    Text("One concrete next step from the shared model workflow and latest Library evidence.")
                        .font(.callout).foregroundColor(.secondary)
                }
                nextActionCard
                statusSection
                recommendationEvidence
            }
            .padding(24)
        }
    }

    private var nextActionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Next action").font(.caption).foregroundColor(.secondary)
            Text(nextAction.title).font(.title2).fontWeight(.semibold)
            Text(nextAction.reason).font(.callout).foregroundColor(.secondary)
            Button(nextAction.title) { perform(nextAction) }.buttonStyle(.borderedProminent)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.09)).cornerRadius(14)
    }

    private var statusSection: some View {
        HStack(alignment: .top, spacing: 16) {
            statusCard(title: "Workflow", value: appHost.modelWorkflow.workflow.state.rawValue, detail: appHost.modelWorkflow.workflow.message ?? "No active conversion message.")
            statusCard(title: "Library", value: appHost.librarySnapshot.map { "\($0.models.count) models" } ?? "No snapshot", detail: appHost.lastError ?? "The latest successful scan remains authoritative.")
            statusCard(title: "Runtime", value: appHost.runtimeReport.ok ? "Ready" : "Needs attention", detail: appHost.runtimeReport.ok ? "Prepare and Run checks passed." : appHost.runtimeReport.install)
        }
    }

    @ViewBuilder
    private var recommendationEvidence: some View {
        if let snapshot = appHost.librarySnapshot {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Recommendation evidence")
                Text("Current Library snapshot: \(timestamp(snapshot.generatedAt))").font(.caption).foregroundColor(.secondary)
                ForEach(UseCase.allCases) { useCase in
                    if let recommendation = appHost.recommendations(for: useCase).first,
                       let model = appHost.model(for: recommendation) {
                        HStack(alignment: .top) {
                            Text(useCase.title).frame(width: 150, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName).font(.headline)
                                Text(recommendation.reasons.first?.message ?? "Ranked from the current local snapshot.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(recommendation.confidence.title).font(.caption).foregroundColor(.green)
                        }
                        .padding(12).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
                    }
                }
            }
        }
    }

    private func statusCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline)
            Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(3)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
    }

    private func perform(_ action: HomeNextAction) {
        switch action.kind {
        case .run(let path):
            appHost.selectedModelPath = path
            if let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path }) {
                appHost.modelWorkflow.prepareServe(model: model)
            }
        case .prepare(let path):
            appHost.selectedModelPath = path
        case .configure, .scan, .activity, .library:
            break
        }
        onRouteSelection(action.route)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
