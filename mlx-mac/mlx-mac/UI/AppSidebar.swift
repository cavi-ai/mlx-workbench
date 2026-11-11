import SwiftUI

/// Model types grouped the way people ask for them.
enum ModelCategory: String, CaseIterable, Identifiable {
    case chat, vision, speech, image, creative, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .vision: return "Vision"
        case .speech: return "Speech"
        case .image: return "Image and video"
        case .creative: return "Music and 3D"
        case .other: return "Embedding and other"
        }
    }

    var symbolName: String {
        switch self {
        case .chat: return "text.bubble"
        case .vision: return "eye"
        case .speech: return "waveform"
        case .image: return "photo"
        case .creative: return "music.note"
        case .other: return "tag"
        }
    }

    var types: Set<ModelTaskType> {
        switch self {
        case .chat: return [.textLLM, .speculativeDraft]
        case .vision: return [.visionLanguage]
        case .speech: return [.speechToText, .textToSpeech]
        case .image: return [.imageGeneration, .videoGeneration]
        case .creative: return [.musicGeneration, .meshGeneration]
        case .other: return [.embedding, .classification, .other]
        }
    }

    func contains(_ model: LibraryModel) -> Bool {
        types.contains(model.item.task?.type ?? .other)
    }
}

/// The Library filter chosen in the sidebar, shared with the Library table.
enum LibrarySidebarFilter: Hashable {
    case all
    case category(ModelCategory)
    case needsConversion

    static let storageKey = "library.sidebarFilter"
    private static let needsConversionID = "needs-conversion"

    init(rawValue: String) {
        if rawValue == Self.needsConversionID {
            self = .needsConversion
        } else if let category = ModelCategory(rawValue: rawValue) {
            self = .category(category)
        } else {
            self = .all
        }
    }

    var rawValue: String {
        switch self {
        case .all: return ""
        case .category(let category): return category.rawValue
        case .needsConversion: return Self.needsConversionID
        }
    }

    func contains(_ model: LibraryModel) -> Bool {
        switch self {
        case .all: return true
        case .category(let category): return category.contains(model)
        case .needsConversion: return model.readiness == .needsConversion
        }
    }
}

/// One selectable sidebar row: a Library filter or a page.
enum SidebarItem: Hashable {
    case models(LibrarySidebarFilter)
    case route(AppRoute)
}

// MARK: - AppSidebar

/// The sidebar leads with the model library: filters by kind, then sources,
/// then what needs attention. The remaining pages follow in collapsible
/// groups. The system paints selection and handles arrow keys.
struct AppSidebar: View {
    @Binding var selectedRoute: AppRoute

    var badges: [AppRoute: String] = [:]
    /// Local models, used for the per-filter counts.
    var models: [LibraryModel] = []
    @AppStorage(LibrarySidebarFilter.storageKey) private var filterRaw = ""
    @AppStorage("sidebar.workspacesExpanded") private var workspacesExpanded = true
    @AppStorage("sidebar.systemExpanded") private var systemExpanded = false

    private static let workspaceRoutes: [AppRoute] = [.use, .run, .monitor, .compare, .prepare, .training, .studies]
    private static let systemRoutes: [AppRoute] = [.overview, .activity, .clientSetup, .health]

    private var selection: Binding<SidebarItem> {
        Binding(
            get: {
                return selectedRoute == .library
                    ? .models(LibrarySidebarFilter(rawValue: filterRaw))
                    : .route(selectedRoute)
            },
            set: { item in
                switch item {
                case .models(let filter):
                    filterRaw = filter.rawValue
                    selectedRoute = .library
                case .route(let route):
                    selectedRoute = route
                }
            }
        )
    }

    private func count(_ filter: LibrarySidebarFilter) -> Int {
        models.reduce(0) { $0 + (filter.contains($1) ? 1 : 0) }
    }

    var body: some View {
        List(selection: selection) {
            Section("Models") {
                filterRow(.all, title: "All models", symbol: AppRoute.library.symbolName)
                    .accessibilityLabel(AppRoute.library.label)
                ForEach(ModelCategory.allCases.filter { count(.category($0)) > 0 }) { category in
                    filterRow(.category(category), title: category.title, symbol: category.symbolName)
                }
            }
            Section("Sources") {
                routeRows([.sources, .discover])
            }
            Section("Attention") {
                filterRow(.needsConversion, title: "Needs converting", symbol: "arrow.triangle.2.circlepath")
                routeRows([.reclaim])
            }
            Section("Workspaces", isExpanded: $workspacesExpanded) {
                routeRows(Self.workspaceRoutes)
            }
            Section("System", isExpanded: $systemExpanded) {
                routeRows(Self.systemRoutes)
            }
            Section {
                routeRows([.settings])
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workbench navigation")
    }

    private func filterRow(_ filter: LibrarySidebarFilter, title: String, symbol: String) -> some View {
        let total = count(filter)
        return Button {
            selection.wrappedValue = .models(filter)
        } label: {
            rowLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
        .padding(.vertical, WorkbenchSpacing.xxs)
        .badge(total > 0 ? Text(verbatim: "\(total)") : nil)
        .tag(SidebarItem.models(filter))
    }

    @ViewBuilder
    private func routeRows(_ routes: [AppRoute]) -> some View {
        ForEach(routes) { route in
            routeRow(route)
                .tag(SidebarItem.route(route))
        }
    }

    private func routeRow(_ route: AppRoute) -> some View {
        Button {
            selectedRoute = route
        } label: {
            rowLabel(title: route.label, symbol: route.symbolName)
        }
        .buttonStyle(.plain)
        .padding(.vertical, WorkbenchSpacing.xxs)
        .badge(badges[route].map { Text($0) })
        .help(route.pageDescription)
        .accessibilityLabel(route.label)
        .accessibilityValue(selectedRoute == route ? "Selected" : "")
    }

    private func rowLabel(title: String, symbol: String) -> some View {
        SidebarRowLabel(title: title, symbol: symbol)
            .font(WorkbenchTypography.body)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct SidebarRowLabel: View {
    let title: String
    let symbol: String

    @Environment(\.backgroundProminence) private var prominence

    /// The emphasized selection fill is the accent, so the selected row takes the contrast-checked selection color.
    var body: some View {
        if prominence == .increased {
            Label(title, systemImage: symbol)
                .foregroundStyle(WorkbenchColor.onSelection)
        } else {
            Label(title, systemImage: symbol)
        }
    }
}
