import SwiftUI

/// The Models and Go menus: model intake and rescan, and one item per sidebar page.
struct WorkbenchCommands: Commands {
    let appHost: AppHost
    @Binding var selectedRouteID: String

    private static let shortcutKeys: [KeyEquivalent] = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
    ]

    /// ⌘1…⌘9 and ⌘0 keys by route, from `ContentView.shortcutRoutes`.
    private static func shortcutKey(for route: AppRoute) -> KeyEquivalent? {
        ContentView.shortcutRoutes.firstIndex(of: route).map { shortcutKeys[$0] }
    }

    var body: some Commands {
        CommandMenu("Models") {
            IntakeMenuCommand(intake: appHost.intake)
            Button("Rescan Models") {
                appHost.requestRescan()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        CommandMenu("Go") {
            ForEach(AppRoute.grouped, id: \.group) { entry in
                ForEach(entry.routes) { route in
                    if let key = Self.shortcutKey(for: route) {
                        Button(route.label) { selectedRouteID = route.rawValue }
                            .keyboardShortcut(key, modifiers: .command)
                    } else {
                        Button(route.label) { selectedRouteID = route.rawValue }
                    }
                }
                if entry.group != AppRoute.grouped.last?.group {
                    Divider()
                }
            }
        }
    }
}
