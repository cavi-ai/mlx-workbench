import Foundation

/// A summary of existing probes, independent of whether the assistant was reviewed.
struct SetupReadiness: Equatable {
    let agentReady: Bool
    let convertReady: Bool
    let serveReady: Bool

    var isReady: Bool { agentReady && convertReady && serveReady }
    var needsEngine: Bool { !agentReady }
    var needsRuntime: Bool { !convertReady || !serveReady }
    var title: String { isReady ? "Base checks passed" : "Setup needs attention" }
    var finishTitle: String { isReady ? "Scan my library" : "Finish for now" }
    var summary: String {
        isReady
            ? "The engine and base tools passed their checks. Scan the library to review model-specific readiness."
            : "Some base prerequisites still need attention. You can finish this review now and return through Health."
    }
    var runtimeMessage: String {
        switch (convertReady, serveReady) {
        case (true, true): return "Conversion and base serving tools passed their checks."
        case (false, true): return "Conversion tools need setup; base serving tools passed their checks."
        case (true, false): return "Base serving tools need setup; conversion tools passed their checks."
        case (false, false): return "Conversion and base serving tools need setup."
        }
    }
}

// MARK: - SetupCoordinator
//
// First-launch setup assistant state: a short ordered walk through the
// prerequisites the app already probes (agent, Python runtime, model roots),
// persisted once completed so it never nags again. Re-openable from Health.
// Read-only over AppHost's probes; the one mutation it drives (guided
// install) goes through the existing RuntimeInstaller.

@MainActor
final class SetupCoordinator: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case agent, runtime, roots, done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .agent: return "Connect mlx-agent"
            case .runtime: return "Python runtime"
            case .roots: return "Choose model roots"
            case .done: return "Review setup"
            }
        }

        var progressLabel: String { "Step \(rawValue + 1) of \(Self.allCases.count)" }
    }

    /// Persistence key for "the assistant has been completed once".
    static let completionKey = "mlx-workbench.setupCompleted.v1"

    @Published private(set) var step: Step = .agent
    @Published var isPresented: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPresented = !defaults.bool(forKey: Self.completionKey)
    }

    var isFirst: Bool { step == .agent }
    var isLast: Bool { step == .done }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func retreat() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Record that the assistant was reviewed; readiness remains owned by live probes.
    func finish() {
        defaults.set(true, forKey: Self.completionKey)
        isPresented = false
    }

    /// Dismiss without completing; the assistant returns next launch.
    func dismiss() {
        isPresented = false
    }

    func revisit(_ earlier: Step) {
        guard earlier.rawValue < step.rawValue else { return }
        step = earlier
    }

    /// Re-open from Health ("Run setup assistant again").
    func presentAgain() {
        step = .agent
        isPresented = true
    }
}
