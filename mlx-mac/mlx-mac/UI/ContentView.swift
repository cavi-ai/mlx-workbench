import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var appHost: AppHost
    @State private var selectedTab = "quickstart"
    
    init(appHost: AppHost) {
        _appHost = StateObject(wrappedValue: appHost)
    }
    
    var body: some View {
        NavigationSplitView {
            AppSidebar(selectedTab: $selectedTab, badges: sidebarBadges)
        } detail: {
            TabView(selection: $selectedTab) {
                HomeView(appHost: appHost) { route in
                    selectedTab = route
                }
                .tag("quickstart")
                LibraryView(appHost: appHost) { route in
                    selectedTab = route
                }
                .tag("models")
                ConvertView(appHost: appHost) { route in
                    selectedTab = route
                }
                .tag("convert")
                DuplicatesView(appHost: appHost).tag("duplicates")
                ServeView(appHost: appHost) { route in
                    selectedTab = route
                }
                .tag("serve")
                ScoutView(appHost: appHost).tag("scout")
                LMStudioView(appHost: appHost).tag("lmstudio")
                TrainingView(appHost: appHost).tag("training-studio")
                QuantView(appHost: appHost).tag("quant")
                DoctorView(appHost: appHost).tag("doctor")
                AdoptView(appHost: appHost).tag("adopt")
                WireView(appHost: appHost).tag("wire")
                ModelArchView(appHost: appHost).tag("model-arch")
                SlothView(appHost: appHost).tag("sloth")
                JobsView(appHost: appHost) { route in
                    selectedTab = route
                }
                .tag("jobs")
                SettingsView(appHost: appHost).tag("settings")
            }
            .tabViewStyle(.automatic)
        }
        .onAppear {
            Task { await appHost.rescan() }
        }
    }

    private var sidebarBadges: [String: String] {
        var badges: [String: String] = [:]
        if let reclaimBadge = appHost.reclaim.badgeText {
            badges["duplicates"] = reclaimBadge
        }
        let alertCount = appHost.watch.activeAlerts.count
        if alertCount > 0 {
            badges["quickstart"] = "\(alertCount) alert\(alertCount == 1 ? "" : "s")"
        }
        return badges
    }
}
