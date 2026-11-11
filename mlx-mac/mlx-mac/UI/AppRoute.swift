import Foundation

/// The stable navigation contract for the Workbench.
///
/// `rawValue` is intentionally the legacy tab identifier used by existing
/// deep-links, callback closures, and persisted UI state. Keep these values
/// stable when changing copy or grouping.
enum AppRoute: String, CaseIterable, Hashable, Identifiable {
    case overview = "quickstart"
    case library = "models"
    case use = "use"
    case prepare = "convert"
    case compare = "quant"
    case run = "serve"
    case activity = "jobs"
    case reclaim = "duplicates"
    case clientSetup = "wire"
    case health = "doctor"
    case discover = "scout"
    case lmStudio = "lmstudio"
    case studies = "studies"
    case training = "training-studio"
    case adopt = "adopt"
    case settings = "settings"
    case monitor = "monitor"

    enum Group: String, CaseIterable, Hashable {
        case models = "Models"
        case workspaces = "Workspaces"
        case system = "System"
        case settings = "Settings"
    }

    enum BadgeDestination: String, Hashable {
        case alerts
        case reclaim

        var route: AppRoute {
            switch self {
            case .alerts: return .overview
            case .reclaim: return .reclaim
            }
        }
    }

    var id: String { rawValue }

    /// Legacy destinations keep their identifiers while sharing the current page.
    var navigationDestination: AppRoute {
        switch self {
        case .adopt: return .discover
        case .lmStudio: return .library
        default: return self
        }
    }

    /// UserDefaults key for the persisted selection; shared by the window
    /// and the ⌘, command so both address the same destination.
    static let selectionStorageKey = "mlx-workbench.selectedRoute"

    /// Stable zero-based position in the navigation registry.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// Sidebar order within each group; independent of the enum case order,
    /// which stays fixed for `order` and mount order.
    private static let sidebarOrder: [Group: [AppRoute]] = [
        .models: [.library, .discover, .prepare, .reclaim],
        .workspaces: [.use, .compare, .run, .monitor, .training, .studies],
        .system: [.overview, .activity, .clientSetup, .health],
        .settings: [.settings],
    ]

    /// Grouped projection for sidebars and command menus. Routes come from
    /// `AppRoute.allCases` through an ordered list per group, so legacy
    /// destinations never appear.
    static var grouped: [(group: Group, routes: [AppRoute])] {
        Group.allCases.map { group in
            (group: group, routes: (sidebarOrder[group] ?? []).filter { $0.group == group && $0.navigationDestination == $0 })
        }
    }

    var group: Group {
        switch self {
        case .library, .discover, .prepare, .reclaim, .lmStudio, .adopt: return .models
        case .use, .compare, .run, .monitor, .training, .studies: return .workspaces
        case .overview, .activity, .clientSetup, .health: return .system
        case .settings: return .settings
        }
    }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .use: return "Use"
        case .library: return "Library"
        case .prepare: return "Prepare"
        case .compare: return "Compare"
        case .run: return "Serving"
        case .monitor: return "Monitor"
        case .activity: return "Activity"
        case .reclaim: return "Reclaim"
        case .clientSetup: return "Clients"
        case .health: return "Health"
        case .discover: return "Discover"
        case .lmStudio: return "LM Studio"
        case .studies: return "Studies"
        case .training: return "Training"
        case .adopt: return "Adopt"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "house"
        case .use: return "bubble.left.and.bubble.right"
        case .library: return "books.vertical"
        case .prepare: return "shippingbox"
        case .compare: return "chart.bar"
        case .run: return "server.rack"
        case .monitor: return "waveform.path.ecg"
        case .activity: return "clock.arrow.circlepath"
        case .reclaim: return "square.3.layers.3d"
        case .clientSetup: return "arrow.triangle.branch"
        case .health: return "stethoscope"
        case .discover: return "magnifyingglass"
        case .lmStudio: return "square.and.arrow.down"
        case .studies: return "square.split.2x1"
        case .training: return "sparkles"
        case .adopt: return "hand.tap"
        case .settings: return "gearshape"
        }
    }

    var pageDescription: String {
        switch self {
        case .overview: return "See the current model workspace and next safe action."
        case .use: return "Work with model servers and keep conversations and results."
        case .library: return "Browse discovered models and their readiness evidence."
        case .prepare: return "Preview and confirm model conversion jobs."
        case .compare: return "Measure ready model variants against the same prompts."
        case .run: return "Manage model APIs, inference settings, memory and connected apps."
        case .monitor: return "See live model status, token usage and response throughput."
        case .activity: return "Inspect conversion jobs and endpoint activity."
        case .reclaim: return "Review evidence-backed disk reclaim opportunities."
        case .clientSetup: return "Preview and apply configuration wiring for local clients."
        case .health: return "Inspect runtime and environment health findings."
        case .discover: return "Browse model candidates or request a recommendation for a task."
        case .lmStudio: return "See LM Studio's models: what runs here and what needs converting."
        case .studies: return "Change one variable at a time and review generated clips blind."
        case .training: return "Review local training and fine-tuning tools."
        case .adopt: return "Adopt a model role using the available evidence."
        case .settings: return "Configure Workbench paths, runtime, and feature controls."
        }
    }

    /// Optional destinations for badges emitted by coordinators or stores.
    /// The enum stays free of coordinator dependencies; callers supply the
    /// badge text and use this destination to select the associated page.
    var badgeDestination: BadgeDestination? {
        switch self {
        case .overview: return .alerts
        case .reclaim: return .reclaim
        default: return nil
        }
    }

    /// Resolve a legacy identifier; a missing or unknown identifier opens
    /// the Library instead of stranding navigation on an unavailable page.
    init(rawID: String?) {
        self = rawID.flatMap(Self.init(rawValue:)) ?? .library
    }

    init(legacyID: String?) {
        self.init(rawID: legacyID)
    }

    init(_ rawID: String?) {
        self.init(rawID: rawID)
    }
}
