import Foundation

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
            case .runtime: return "Install the Python runtime"
            case .roots: return "Choose model roots"
            case .done: return "Ready"
            }
        }
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

    /// Complete the assistant: persist and close.
    func finish() {
        defaults.set(true, forKey: Self.completionKey)
        isPresented = false
    }

    /// Dismiss without completing; the assistant returns next launch.
    func dismiss() {
        isPresented = false
    }

    /// Re-open from Health ("Run setup assistant again").
    func presentAgain() {
        step = .agent
        isPresented = true
    }
}
