import SwiftUI

// MARK: - AppSidebar

struct AppSidebar: View {
    @Binding var selectedTab: String
    @State private var showMore = false
    
    let primaryTabs = ["quickstart", "models", "convert", "duplicates", "serve"]
    let secondaryTabs = ["scout", "lmstudio", "training-studio", "quant", "doctor", "adopt", "wire", "model-arch", "sloth", "jobs", "settings"]
    
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
            Label(tabTitle(for: tab), systemImage: tabIcon(for: tab))
                .foregroundColor(selectedTab == tab ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
    
    private func tabTitle(for tab: String) -> String {
        switch tab {
        case "quickstart": return "Quick Start"
        case "models": return "Models"
        case "convert": return "Convert"
        case "duplicates": return "Duplicates"
        case "serve": return "Serve"
        case "scout": return "Scout"
        case "lmstudio": return "LM Studio"
        case "training-studio": return "Training"
        case "quant": return "Compare"
        case "doctor": return "Doctor"
        case "adopt": return "Adopt"
        case "wire": return "Wire"
        case "model-arch": return "Model Arch"
        case "sloth": return "Sloth"
        case "jobs": return "Jobs"
        case "settings": return "Settings"
        default: return tab
        }
    }
    
    private func tabIcon(for tab: String) -> String {
        switch tab {
        case "quickstart": return "star.circle"
        case "models": return "cube.box"
        case "convert": return "arrow.trianglehead.counterclockwise"
        case "duplicates": return "square.3.layers.3d"
        case "serve": return "server.rack"
        case "scout": return "magnifyingglass"
        case "lmstudio": return "square.and.arrow.down"
        case "training-studio": return "sparkles"
        case "quant": return "chart.bar"
        case "doctor": return "stethoscope"
        case "adopt": return "hand.tap"
        case "wire": return "wireframe"
        case "model-arch": return "cube"
        case "sloth": return "safari"
        case "jobs": return "clock"
        case "settings": return "gearshape"
        default: return "circle"
        }
    }
}
