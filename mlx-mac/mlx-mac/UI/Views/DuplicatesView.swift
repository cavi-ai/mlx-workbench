import SwiftUI

// MARK: - DuplicatesView
// Exact vs variant duplicate groups from convert scan; quarantine keepers.

struct DuplicatesView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var reclaim: ReclaimCoordinator

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var selectedOpportunities: Set<String> = []

    init(appHost: AppHost) {
        self.appHost = appHost
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reclaimSection
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
            appHost.analyzeReclaim()
            if groups.isEmpty { scan() }
        }
    }

    // MARK: - Reclaim (Disk Pressure Advisor)

    private var reclaimSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Reclaim")
                Spacer()
                if reclaim.totalReclaimableBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: reclaim.totalReclaimableBytes, countStyle: .file)) reclaimable")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Button("Analyze") { appHost.analyzeReclaim() }
            }
            Text("Ranked opportunities with evidence. Confirming moves `.gguf` files to quarantine — nothing is ever deleted.")
                .font(.caption)
                .foregroundColor(.secondary)

            if reclaim.opportunities.isEmpty {
                Text("No reclaim opportunities from the latest snapshot.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(reclaim.opportunities) { opportunity in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: opportunityBinding(opportunity.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(opportunity.kind.title).font(.callout).fontWeight(.medium)
                                    Text(ByteCountFormatter.string(fromByteCount: opportunity.bytes, countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    if opportunity.confidence == .review {
                                        Text("review").font(.caption2).foregroundColor(.secondary)
                                    }
                                    if !opportunity.actionable {
                                        Text("manual only").font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                                Text(opportunity.evidence)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ForEach(opportunity.paths, id: \.self) { path in
                                    Text(path)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!opportunity.actionable)
                    }
                }

                HStack(spacing: 10) {
                    Button("Preview reclaim") { reclaim.preview(selected: selectedOpportunities) }
                        .disabled(selectedOpportunities.isEmpty)
                    if let plan = reclaim.plan {
                        Text("Move \(plan.items.count) file(s), reclaim \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                            .font(.caption)
                        Button("Confirm quarantine") {
                            reclaim.confirm(previewHash: plan.previewHash)
                            selectedOpportunities = []
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(reclaim.isApplying)
                    }
                }

                if !reclaim.lastMoves.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(reclaim.lastMoves, id: \.path) { move in
                            if let destination = move.destination {
                                Text("Moved \(URL(fileURLWithPath: move.path).lastPathComponent) → \(destination)")
                                    .font(.caption).foregroundColor(.green)
                            } else {
                                Text("\(URL(fileURLWithPath: move.path).lastPathComponent): \(move.error ?? "failed")")
                                    .font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            ErrorBanner(text: reclaim.lastError)
        }
        .formSection {}
    }

    private func opportunityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedOpportunities.contains(id) },
            set: { isOn in
                if isOn { selectedOpportunities.insert(id) } else { selectedOpportunities.remove(id) }
            }
        )
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