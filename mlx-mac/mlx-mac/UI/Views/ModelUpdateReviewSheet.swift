import SwiftUI

struct ModelUpdateReviewSheet: View {
    @ObservedObject var coordinator: ModelUpdateCoordinator
    let addFromHuggingFace: (String) -> Void
    @State private var quarantinePrevious = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Review model update").font(WorkbenchTypography.title)
            Text(coordinator.repo).font(WorkbenchTypography.cardTitle).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Text("Choose the local version to replace. The new revision downloads to a separate folder and must pass verification before managed endpoints switch.")
                        .foregroundStyle(WorkbenchColor.muted)
                    if coordinator.isLoading {
                        ProgressView("Finding local versions…")
                    } else if !coordinator.candidates.isEmpty {
                        Picker("Previous version", selection: Binding(get: {
                            coordinator.selectedPreviousPath ?? ""
                        }, set: { path in
                            quarantinePrevious = false
                            Task { await coordinator.selectPrevious(path: path.isEmpty ? nil : path) }
                        })) {
                            Text("Choose a local model").tag("")
                            ForEach(coordinator.candidates) { candidate in
                                Text("\(candidate.displayName) — \(candidate.path)").tag(candidate.path)
                            }
                        }
                        .disabled(coordinator.isRunning)
                    }
                    if coordinator.isPreparing { ProgressView("Preparing update review…") }
                    if let review = coordinator.review { reviewDetails(review) }
                    if let record = coordinator.activeRecord {
                        HStack(spacing: WorkbenchSpacing.xs) {
                            if coordinator.isRunning { ProgressView().controlSize(.small) }
                            Text(record.stage.title).font(WorkbenchTypography.label)
                            if record.state == .failed || record.state == .interrupted {
                                Text("Needs review").foregroundStyle(WorkbenchColor.warning)
                            }
                        }
                        if record.state == .completed {
                            Text(record.quarantinePrevious
                                 ? "The new revision is verified. The previous version is in Quarantine."
                                 : "The new revision is verified. The previous version remains in its folder.")
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                    if let interrupted = coordinator.interruptedRecords.first(where: { $0.review.repo == coordinator.repo }) {
                        Text(interrupted.error ?? "A previous update was interrupted. Review the current library and endpoints before starting another update.")
                            .foregroundStyle(WorkbenchColor.warning)
                    }
                    ErrorBanner(text: coordinator.persistenceError)
                    if coordinator.error != coordinator.persistenceError { ErrorBanner(text: coordinator.error) }
                    if !coordinator.isRunning && coordinator.review == nil && !coordinator.isPreparing && !coordinator.isLoading {
                        Button("Review in Add from Hugging Face") {
                            let repo = coordinator.repo
                            coordinator.close()
                            addFromHuggingFace(repo)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(coordinator.isRunning || coordinator.activeRecord?.state == .completed ? "Close" : "Cancel") { coordinator.close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if coordinator.activeRecord?.state != .completed {
                    Button("Download and verify update") {
                        Task { await coordinator.confirm(quarantinePrevious: quarantinePrevious) }
                    }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(coordinator.review == nil || coordinator.isRunning || coordinator.isPreparing || coordinator.activeRecord != nil)
                }
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(width: 680, height: 620)
        .onChange(of: coordinator.repo) { _, _ in quarantinePrevious = false }
        .interactiveDismissDisabled(coordinator.isRunning)
    }

    private func reviewDetails(_ review: ModelUpdateReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            GroupBox("Previous version") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(review.previous.path).textSelection(.enabled)
                    if let revision = review.previous.revision { Text("Revision \(revision)").font(WorkbenchTypography.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("New version") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Revision \(review.targetRevision)").textSelection(.enabled)
                    Text(review.destinationPath).font(WorkbenchTypography.secondary).textSelection(.enabled)
                    if let bytes = review.downloadBytes {
                        Text("Download: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if review.endpointSummary.isEmpty {
                Text("No managed endpoint currently uses the previous version.").foregroundStyle(WorkbenchColor.muted)
            } else {
                Text("Endpoints to switch after verification").font(WorkbenchTypography.cardTitle)
                ForEach(review.endpointSummary, id: \.self) { Text($0).font(WorkbenchTypography.secondary) }
            }
            Toggle("Move the previous version to Quarantine after the update", isOn: $quarantinePrevious)
                .disabled(!review.previous.canQuarantine || coordinator.isRunning)
            if let reason = review.previous.retentionReason { Text(reason).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
            Text("Quarantine keeps a recoverable copy. Shared Hugging Face caches and models owned by other apps stay in place.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
    }
}
