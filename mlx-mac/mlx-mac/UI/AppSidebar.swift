import SwiftUI

/// The model-type filter shared by the sidebar and the Library table.
enum LibraryTypeFilter {
    static let storageKey = "library.typeFilter"

    static func type(from raw: String) -> ModelTaskType? {
        raw.isEmpty ? nil : ModelTaskType(rawValue: raw)
    }
}

/// One selectable sidebar row: a Library model filter or a page.
enum SidebarItem: Hashable {
    case models(ModelTaskType?)
    case route(AppRoute)
}

// MARK: - AppSidebar

/// The sidebar leads with the model library, filtered by model type, and
/// lists the remaining pages from `AppRoute` below it. The system paints
/// selection and handles arrow keys; rows stay addressable by label.
struct AppSidebar: View {
    @Binding var selectedRoute: AppRoute

    var badges: [AppRoute: String] = [:]
    /// Local model counts per type; types without models are not listed.
    var modelCounts: [ModelTaskType: Int] = [:]

    @AppStorage(LibraryTypeFilter.storageKey) private var typeFilterRaw = ""

    private var selection: Binding<SidebarItem> {
        Binding(
            get: {
                selectedRoute == .library
                    ? .models(LibraryTypeFilter.type(from: typeFilterRaw))
                    : .route(selectedRoute)
            },
            set: { item in
                switch item {
                case .models(let type):
                    typeFilterRaw = type?.rawValue ?? ""
                    selectedRoute = .library
                case .route(let route):
                    selectedRoute = route
                }
            }
        )
    }

    private var listedTypes: [ModelTaskType] {
        ModelTaskType.allCases.filter { (modelCounts[$0] ?? 0) > 0 }
    }

    var body: some View {
        List(selection: selection) {
            Section("Models") {
                modelRow(nil, title: "All models", symbol: AppRoute.library.symbolName,
                         count: modelCounts.values.reduce(0, +))
                    .accessibilityLabel(AppRoute.library.label)
                ForEach(listedTypes) { type in
                    modelRow(type, title: type.title, symbol: type.symbolName, count: modelCounts[type] ?? 0)
                }
            }
            ForEach(AppRoute.grouped, id: \.group) { projection in
                let routes = projection.routes.filter { $0 != .library }
                switch projection.group {
                case .models:
                    Section("Manage") { routeRows(routes) }
                case .settings:
                    Section { routeRows(routes) }
                default:
                    Section(projection.group.rawValue) { routeRows(routes) }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workbench navigation")
    }

    private func modelRow(_ type: ModelTaskType?, title: String, symbol: String, count: Int) -> some View {
        Button {
            selection.wrappedValue = .models(type)
        } label: {
            SidebarRowLabel(title: title, symbol: symbol)
                .font(WorkbenchTypography.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WorkbenchSpacing.xxs)
        .badge(count > 0 ? Text(verbatim: "\(count)") : nil)
        .tag(SidebarItem.models(type))
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
            SidebarRowLabel(title: route.label, symbol: route.symbolName)
                .font(WorkbenchTypography.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WorkbenchSpacing.xxs)
        .badge(badges[route].map { Text($0) })
        .help(route.pageDescription)
        .accessibilityLabel(route.label)
        .accessibilityValue(selectedRoute == route ? "Selected" : "")
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
