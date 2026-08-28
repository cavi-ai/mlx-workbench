import SwiftUI

// MARK: - ModelsView
// Compatibility wrapper for callers still referencing the legacy route type.
struct ModelsView: View {
    @ObservedObject var appHost: AppHost

    var body: some View {
        LibraryView(appHost: appHost)
    }
}
