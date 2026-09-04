import SwiftUI

// MARK: - DoctorView
// Doctor model inventory + prune preview/confirm.

struct DoctorView: View {
    @ObservedObject var appHost: AppHost

    @State private var isRunning = false
    @State private var findings: [DoctorFinding] = []
    @State private var prunePreview: [String: Any]?
    @State private var pruneHash: String?
    @State private var resultNote: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { doctorActions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { doctorActions }
                }

                if isRunning {
                    ProgressView("Working…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }

                ErrorBanner(text: errorMessage)
                if let resultNote {
                    Text(resultNote).font(.caption).foregroundColor(WorkbenchColor.verifiedGreen)
                }

                if !findings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle(text: "Findings (\(findings.count))")
                            Spacer()
                            Button("Clear") { findings = [] }
                        }
                        ForEach(findings) { finding in
                            HStack(alignment: .top) {
                                StatusPill(state: finding.kind ?? "issue")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.path).font(.caption)
                                        .textSelection(.enabled)
                                    if let message = finding.message {
                                        Text(message).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if let size = finding.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .formSection {}
                }

                if pruneHash != nil, let prunePreview {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle(text: "Prune plan")
                            Spacer()
                            Button("Confirm Prune") { confirmPrune() }
                                .disabled(isRunning)
                        }
                        RawJSONDisclosure("Raw prune plan", value: prunePreview)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    @ViewBuilder
    private var doctorActions: some View {
        Button("Doctor Models") { runDoctor() }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
            .disabled(isRunning)
        Button("Preview Prune") { previewPrune() }
            .buttonStyle(.bordered)
            .disabled(isRunning)
    }

    private func runDoctor() {
        errorMessage = nil
        resultNote = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let result = try await appHost.api.doctor(wiredRoots: [], hfCache: nil)
                findings = result.findings ?? []
                pruneHash = result.preview_hash
            } catch let error as BridgeError {
                findings = []
                errorMessage = error.errorDescription
            } catch {
                findings = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func previewPrune() {
        errorMessage = nil
        resultNote = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let result = try await appHost.api.doctorPrunePreview(hfCache: nil)
                pruneHash = result.preview_hash
                prunePreview = [
                    "preview_hash": result.preview_hash ?? "",
                    "prune_count": result.prune_count ?? 0,
                    "reclaimed_bytes": result.reclaimedBytes.map(String.init) ?? "",
                ]
            } catch let error as BridgeError {
                prunePreview = nil
                pruneHash = nil
                errorMessage = error.errorDescription
            } catch {
                prunePreview = nil
                pruneHash = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmPrune() {
        guard let pruneHash else { return }
        errorMessage = nil
        resultNote = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let result = try await appHost.api.doctorPruneConfirm(previewHash: pruneHash, hfCache: nil)
                let removedItems = result.removed ?? []
                let removed = removedItems.filter { $0.removed == true }.count
                resultNote = "Pruned \(removed) items."
                prunePreview = nil
                self.pruneHash = nil
                findings = result.findings ?? []
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
