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
        .scrollContentBackground(.hidden)
        .background(WorkbenchColor.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Image("WorkbenchIcon")
                    .resizable()
                    .frame(width: WorkbenchSize.brandIcon, height: WorkbenchSize.brandIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text("MLX Workbench")
                        .font(WorkbenchTypography.brand)
                        .foregroundStyle(WorkbenchColor.ink)
                    Text("Local models. Your Mac.")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkbenchSpacing.sm)
            .padding(.vertical, WorkbenchSpacing.lg)
            .background(WorkbenchColor.sidebar)
        }
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
            SidebarRouteLabel(route: route, isSelected: selectedRoute == route)
                .font(WorkbenchTypography.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WorkbenchSpacing.xxs)
        .listRowBackground(selectedRoute == route ? WorkbenchColor.accent.opacity(.fill) : Color.clear)
        .badge(badges[route].map { Text($0) })
        .help(route.pageDescription)
        .accessibilityLabel(route.label)
        .accessibilityValue(selectedRoute == route ? "Selected" : "")
    }
}

private struct SidebarRouteLabel: View {
    let route: AppRoute
    let isSelected: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label {
            Text(route.label)
                .foregroundStyle(prominence == .increased ? WorkbenchColor.onAccent : WorkbenchColor.ink)
        } icon: {
            Image(systemName: route.symbolName)
                .foregroundStyle(prominence == .increased ? WorkbenchColor.onAccent : (isSelected ? WorkbenchColor.accent : WorkbenchColor.muted))
        }
    }
}
