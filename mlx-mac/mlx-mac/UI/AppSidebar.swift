import SwiftUI

// MARK: - AppSidebar

/// The navigation registry is rendered from `AppRoute` rather than a second
/// list of string identifiers, so labels, symbols, grouping, and keyboard
/// selection share one typed contract. Rows are plain buttons inside a
/// selectable sidebar list: the system paints selection and handles arrow
/// keys, and the buttons keep the rows addressable by label in UI tests.
struct AppSidebar: View {
    @Binding var selectedRoute: AppRoute

    var badges: [AppRoute: String] = [:]

    var body: some View {
        List(selection: $selectedRoute) {
            ForEach(AppRoute.grouped, id: \.group) { projection in
                if projection.group == .settings {
                    Section { routeRows(projection.routes) }
                } else {
                    Section(projection.group.rawValue) {
                        routeRows(projection.routes)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workbench navigation")
    }

    @ViewBuilder
    private func routeRows(_ routes: [AppRoute]) -> some View {
        ForEach(routes) { route in
            routeRow(route)
                .tag(route)
        }
    }

    private func routeRow(_ route: AppRoute) -> some View {
        Button {
            selectedRoute = route
        } label: {
            Label(route.label, systemImage: route.symbolName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .badge(badges[route].map { Text($0) })
        .help(route.pageDescription)
        .accessibilityLabel(route.label)
        .accessibilityValue(selectedRoute == route ? "Selected" : "")
    }
}
