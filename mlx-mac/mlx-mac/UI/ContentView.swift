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
            AppSidebar(selectedTab: $selectedTab)
        } detail: {
            TabView(selection: $selectedTab) {
                QuickStartView(appHost: appHost).tag("quickstart")
                ModelsView(appHost: appHost).tag("models")
                ConvertView(appHost: appHost).tag("convert")
                DuplicatesView(appHost: appHost).tag("duplicates")
                ServeView(appHost: appHost).tag("serve")
                ScoutView(appHost: appHost).tag("scout")
                LMStudioView(appHost: appHost).tag("lmstudio")
                TrainingView(appHost: appHost).tag("training-studio")
                QuantView(appHost: appHost).tag("quant")
                DoctorView(appHost: appHost).tag("doctor")
                AdoptView(appHost: appHost).tag("adopt")
                WireView(appHost: appHost).tag("wire")
                ModelArchView(appHost: appHost).tag("model-arch")
                SlothView(appHost: appHost).tag("sloth")
                JobsView(appHost: appHost).tag("jobs")
                SettingsView(appHost: appHost).tag("settings")
            }
            .tabViewStyle(.automatic)
        }
        .onAppear {
            Task { await appHost.rescan() }
        }
    }
}
