import SwiftUI

// MARK: - AppSidebar

/// The navigation registry is rendered from `AppRoute` rather than a second
/// list of string identifiers, so labels, symbols, grouping, and keyboard
/// selection share one typed contract. Rows are plain buttons inside a
/// selectable sidebar list: the system paints selection and handles arrow
/// keys, and the buttons keep the rows addressable by label in UI tests.
struct AppSidebar: View {
    @Binding var selectedRoute: AppRoute
    @State private var labExpanded = false

    var badges: [AppRoute: String] = [:]

    var body: some View {
        List(selection: $selectedRoute) {
            ForEach(AppRoute.grouped.filter { $0.group != .settings }, id: \.group) { projection in
                if projection.group == .lab {
                    Section {
                        DisclosureGroup(isExpanded: labDisclosureBinding) {
                            routeRows(projection.routes)
                        } label: {
                            Text(projection.group.rawValue)
                        }
                    }
                } else {
                    Section(projection.group.rawValue) {
                        routeRows(projection.routes)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                routeRow(.settings)
                    .padding(.horizontal, WorkbenchSpacing.xs)
                    .padding(.vertical, WorkbenchSpacing.xxs)
            }
        }
        .onChange(of: selectedRoute) { _, route in
            if route.group == .lab {
                labExpanded = true
            }
        }
        .accessibilityLabel("Workbench navigation")
    }

    private var labDisclosureBinding: Binding<Bool> {
        Binding(
            get: { labExpanded || selectedRoute.group == .lab },
            set: { labExpanded = $0 }
        )
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
