import SwiftUI

// MARK: - AppSidebar

struct AppSidebar: View {
    @Binding var selectedTab: String
    @State private var showMore = false
    /// Optional badge text per tab (e.g. reclaimable bytes on Duplicates).
    var badges: [String: String] = [:]
    
    let primaryTabs = ["quickstart", "models", "scout", "convert", "serve", "jobs", "settings"]
    let secondaryTabs = ["duplicates", "lmstudio", "training-studio", "quant", "doctor", "adopt", "wire", "model-arch", "sloth"]
    
    var body: some View {
        List(selection: $selectedTab) {
            Section("Primary") {
                ForEach(primaryTabs, id: \.self) { tab in
                    sidebarRow(tab: tab)
                }
            }
            
            Section {
                Button(action: { showMore.toggle() }) {
                    Label("More", systemImage: "chevron.down")
                        .foregroundColor(showMore ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                
                if showMore {
                    ForEach(secondaryTabs, id: \.self) { tab in
                        sidebarRow(tab: tab)
                    }
                }
            } header: {
                Text("Discovery & Tools")
            }
        }
        .listStyle(.sidebar)
    }
    
    private func sidebarRow(tab: String) -> some View {
        Button(action: { selectedTab = tab }) {
            HStack {
                Label(tabTitle(for: tab), systemImage: tabIcon(for: tab))
                    .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                Spacer()
                if let badge = badges[tab] {
                    Text(badge)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    private func tabTitle(for tab: String) -> String {
        switch tab {
        case "quickstart": return "Home"
        case "models": return "Library"
        case "scout": return "Discover"
        case "convert": return "Prepare"
        case "serve": return "Run"
        case "jobs": return "Activity"
        case "settings": return "Settings"
        case "duplicates": return "Duplicates"
        case "lmstudio": return "LM Studio"
        case "training-studio": return "Training"
        case "quant": return "Compare"
        case "doctor": return "Doctor"
        case "adopt": return "Adopt"
        case "wire": return "Wire"
        case "model-arch": return "Model Arch"
        case "sloth": return "Sloth"
        default: return tab
        }
    }
    
    private func tabIcon(for tab: String) -> String {
        switch tab {
        case "quickstart": return "house"
        case "models": return "books.vertical"
        case "scout": return "magnifyingglass"
        case "convert": return "shippingbox"
        case "serve": return "play.circle"
        case "jobs": return "clock.arrow.circlepath"
        case "settings": return "gearshape"
        case "duplicates": return "square.3.layers.3d"
        case "lmstudio": return "square.and.arrow.down"
        case "training-studio": return "sparkles"
        case "quant": return "chart.bar"
        case "doctor": return "stethoscope"
        case "adopt": return "hand.tap"
        case "wire": return "wireframe"
        case "model-arch": return "cube"
        case "sloth": return "safari"
        default: return "circle"
        }
    }
}
