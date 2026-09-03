import SwiftUI

// MARK: - AppSidebar

/// The navigation registry is intentionally rendered from `AppRoute` rather
/// than maintained as a second list of string identifiers. This keeps labels,
/// symbols, grouping, and keyboard selection on the same typed contract.
struct AppSidebar: View {
    @Binding var selectedRoute: AppRoute
    @State private var labExpanded = false

    var badges: [AppRoute: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(AppRoute.grouped.filter { $0.group != .settings }, id: \.group) { projection in
                    if projection.group == .lab {
                        Section {
                            DisclosureGroup(isExpanded: labDisclosureBinding) {
                                routeRows(projection.routes)
                            } label: {
                                Text(projection.group.rawValue)
                                    .font(WorkbenchTypography.navigation)
                                    .foregroundColor(WorkbenchColor.graphiteMuted)
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

            Divider()

            // Keep Settings reachable without expanding the navigation list.
            List {
                routeRow(.settings)
            }
            .listStyle(.sidebar)
            .frame(height: 54)
        }
        .frame(minWidth: 176, idealWidth: 208, maxWidth: 220)
        .background(WorkbenchColor.alloyCanvas)
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
        }
    }

    private func routeRow(_ route: AppRoute) -> some View {
        let isSelected = selectedRoute == route

        return Button {
            selectedRoute = route
        } label: {
            HStack(spacing: WorkbenchSpacing.sm) {
                Label(route.label, systemImage: route.symbolName)
                    .font(WorkbenchTypography.navigation)
                    .foregroundColor(isSelected ? WorkbenchColor.fluxTeal : WorkbenchColor.graphiteInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: WorkbenchSpacing.xs)

                if let badge = badges[route] {
                    Text(badge)
                        .font(WorkbenchTypography.monoUtility)
                        .foregroundColor(WorkbenchColor.thermalAmber)
                        .lineLimit(1)
                        .accessibilityLabel("\(badge) for \(route.label)")
                }
            }
            .padding(.horizontal, WorkbenchSpacing.xs)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous)
                    .fill(isSelected ? WorkbenchColor.fluxTeal.opacity(0.18) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous)
                    .stroke(isSelected ? WorkbenchColor.fluxTeal.opacity(0.35) : Color.clear, lineWidth: WorkbenchSpacing.hairline)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .help(route.label)
        .accessibilityLabel(route.label)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
