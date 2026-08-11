import SwiftUI

// MARK: - DuplicatesView
// Exact vs variant duplicate groups from convert scan; quarantine keepers.

struct DuplicatesView: View {
    @ObservedObject var appHost: AppHost

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button("Scan Duplicates") { scan() }
                        .disabled(isScanning)
                    Spacer()
                }
                if isScanning {
                    ProgressView("Scanning…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ErrorBanner(text: errorMessage)
                if groups.isEmpty && !isScanning {
                    Text("No duplicate groups found.")
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                }
                ForEach(groups) { group in
                    groupCard(group)
                }
                Spacer()
            }
            .padding()
        }
        .onAppear {
            if groups.isEmpty { scan() }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: group.modelKey ?? group.id)
                Spacer()
                if let reclaim = group.reclaimableBytes {
                    Text("Reclaims \(ByteCountFormatter.string(fromByteCount: reclaim, countStyle: .file))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            ForEach(group.sources, id: \.self) { path in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                    if group.keep == path {
                        Text("keep").font(.caption2).foregroundColor(.green)
                    }
                }
            }
            if let redundant = group.redundant, !redundant.isEmpty {
                Text("\(redundant.count) redundant")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .formSection {}
    }

    private func scan() {
        errorMessage = nil
        isScanning = true
        Task {
            defer { isScanning = false }
            do {
                let roots = appHost.config.ggufRoots.isEmpty ? Config.discoverGgufRoots() : appHost.config.ggufRoots
                let result = try await appHost.api.scan(
                    ggufRoots: roots,
                    mlxRoots: appHost.config.mlxRoots,
                    signatures: appHost.config.signatures
                )
                groups = result.duplicates
            } catch let error as BridgeError {
                groups = []
                errorMessage = error.errorDescription
            } catch {
                groups = []
                errorMessage = error.localizedDescription
            }
        }
    }
}