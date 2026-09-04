import Foundation

/// The stable navigation contract for the Workbench.
///
/// `rawValue` is intentionally the legacy tab identifier used by existing
/// deep-links, callback closures, and persisted UI state. Keep these values
/// stable when changing copy or grouping.
enum AppRoute: String, CaseIterable, Hashable, Identifiable {
    case overview = "quickstart"
    case library = "models"
    case prepare = "convert"
    case compare = "quant"
    case run = "serve"
    case activity = "jobs"
    case reclaim = "duplicates"
    case clientSetup = "wire"
    case health = "doctor"
    case discover = "scout"
    case lmStudio = "lmstudio"
    case training = "training-studio"
    case adopt = "adopt"
    case settings = "settings"

    enum Group: String, CaseIterable, Hashable {
        case workbench = "Workbench"
        case lifecycle = "Lifecycle"
        case operations = "Operations"
        case lab = "Lab"
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

    /// Stable zero-based position in the navigation registry.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// Grouped projection for sidebars and command menus. The source of truth
    /// remains `AppRoute.allCases`; this projection cannot introduce routes.
    static var grouped: [(group: Group, routes: [AppRoute])] {
        Group.allCases.map { group in
            (group: group, routes: allCases.filter { $0.group == group })
        }
    }

    var group: Group {
        switch self {
        case .overview, .library: return .workbench
        case .prepare, .compare, .run: return .lifecycle
        case .activity, .reclaim, .clientSetup, .health: return .operations
        case .discover, .lmStudio, .training, .adopt: return .lab
        case .settings: return .settings
        }
    }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .library: return "Library"
        case .prepare: return "Prepare"
        case .compare: return "Compare"
        case .run: return "Run"
        case .activity: return "Activity"
        case .reclaim: return "Reclaim"
        case .clientSetup: return "Client Setup"
        case .health: return "Health"
        case .discover: return "Discover"
        case .lmStudio: return "LM Studio"
        case .training: return "Training"
        case .adopt: return "Adopt"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "house"
        case .library: return "books.vertical"
        case .prepare: return "shippingbox"
        case .compare: return "chart.bar"
        case .run: return "play.circle"
        case .activity: return "clock.arrow.circlepath"
        case .reclaim: return "square.3.layers.3d"
        case .clientSetup: return "arrow.triangle.branch"
        case .health: return "stethoscope"
        case .discover: return "magnifyingglass"
        case .lmStudio: return "square.and.arrow.down"
        case .training: return "sparkles"
        case .adopt: return "hand.tap"
        case .settings: return "gearshape"
        }
    }

    var pageDescription: String {
        switch self {
        case .overview: return "See the current model workspace and next safe action."
        case .library: return "Browse discovered models and their readiness evidence."
        case .prepare: return "Preview and confirm model conversion jobs."
        case .compare: return "Measure ready model variants against the same prompts."
        case .run: return "Serve a verified model on the loopback endpoint."
        case .activity: return "Inspect conversion jobs and endpoint activity."
        case .reclaim: return "Review evidence-backed disk reclaim opportunities."
        case .clientSetup: return "Preview and apply configuration wiring for local clients."
        case .health: return "Inspect runtime and environment health findings."
        case .discover: return "Explore catalog metadata and model candidates."
        case .lmStudio: return "Inspect LM Studio-compatible local model files."
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

    /// Resolve a legacy identifier without allowing malformed persisted state
    /// to strand navigation on an unavailable page.
    init(rawID: String?) {
        self = rawID.flatMap(Self.init(rawValue:)) ?? .overview
    }

    init(legacyID: String?) {
        self.init(rawID: legacyID)
    }

    init(_ rawID: String?) {
        self.init(rawID: rawID)
    }
}
