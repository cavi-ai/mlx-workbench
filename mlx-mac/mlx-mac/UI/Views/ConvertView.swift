import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PreparePrimaryAction: Equatable {
    case preview
    case confirm
    case runExisting
    case none
}

struct PrepareWorkflowPresentation: Equatable {
    let sourcePath: String
    let destinationPath: String
    let state: ConversionWorkflowState
    let message: String?
    let errorMessage: String?
    let hasPreviewHash: Bool
    let sourceRepo: String?
    let subfolder: String?
    /// The bit widths the source converts to; a port can allow fewer than 4 and 8.
    let bitWidths: [Int]

    init(workflow: ConversionWorkflow) {
        sourcePath = workflow.sourcePath
        destinationPath = workflow.outputPath
        state = workflow.state
        message = workflow.message
        errorMessage = workflow.errorMessage
        hasPreviewHash = !(workflow.previewHash?.isEmpty ?? true)
        sourceRepo = workflow.sourceRepo
        subfolder = workflow.subfolder
        bitWidths = (workflow.allowedBits?.isEmpty == false ? workflow.allowedBits! : [4, 8]).sorted()
    }

    var sourceLabel: String { sourceRepo == nil ? "Source GGUF" : "Source repo" }

    var sourceDisplay: String { sourceRepo.map { repo in subfolder.map { "\(repo)/\($0)" } ?? repo } ?? sourcePath }

    var destinationNote: String {
        sourceRepo == nil
            ? "The destination is the coordinator-approved same-directory path. It cannot be overridden in Prepare."
            : "The destination is the configured output directory, which the Library scans."
    }

    var primaryAction: PreparePrimaryAction {
        switch state {
        case .existingModelFound:
            return .runExisting
        case .readyToConfirm:
            return .confirm
        case .idle, .inspectingSource, .previewingConversion, .queued, .running, .completed, .verifying, .verified, .verificationFailed:
            return sourcePath.isEmpty ? .none : .preview
        case .failed:
            return isBlockedDestination || sourcePath.isEmpty ? .none : (canConfirm ? .confirm : .preview)
        }
    }

    var canPreview: Bool {
        !sourcePath.isEmpty && !isBlockedDestination && ![.existingModelFound, .previewingConversion, .queued, .running, .completed, .verifying, .verified].contains(state)
    }

    var canConfirm: Bool {
        state == .readyToConfirm && hasPreviewHash
    }

    var isQuantizationLocked: Bool {
        hasPreviewHash
    }

    var isBlockedDestination: Bool {
        errorMessage?.localizedCaseInsensitiveContains("destination") == true
            && errorMessage?.localizedCaseInsensitiveContains("already exists") == true
    }

    var stateTitle: String {
        switch state {
        case .idle: return "Choose a model in Library"
        case .inspectingSource: return "Inspecting source"
        case .existingModelFound: return "Equivalent MLX model found"
        case .previewingConversion: return "Preparing conversion preview"
        case .readyToConfirm: return "Preview ready"
        case .queued: return "Conversion queued"
        case .running: return "Conversion running"
        case .completed: return "Conversion completed"
        case .verifying: return "Verifying conversion output"
        case .verified: return "Conversion verified"
        case .verificationFailed: return "Verification failed"
        case .failed: return "Preparation needs attention"
        }
    }
}

struct ConvertView: View {
    @ObservedObject var appHost: AppHost
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var reclaim: ReclaimCoordinator
    private let onRouteSelection: (AppRoute) -> Void

    @State private var qBits: Int
    @State private var progress: ConversionProgressSnapshot?
    @State private var isLogExpanded = false
    @State private var reclaimSource = true

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
        self.onRouteSelection = onRouteSelection
        _qBits = State(initialValue: appHost.config.qBits)
    }

    private var presentation: PrepareWorkflowPresentation {
        PrepareWorkflowPresentation(workflow: modelWorkflow.workflow)
    }

    private var existingModel: LibraryModel? {
        guard presentation.state == .existingModelFound else { return nil }
        return appHost.librarySnapshot?.models.first { $0.item.path == presentation.destinationPath }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                IntakeField(intake: appHost.intake)
                workflowCard
                sourceAndDestinationCard
                conversionActions
                if modelWorkflow.workflow.state == .verified {
                    sourceCleanupActions
                }
                if let progress, modelWorkflow.workflow.state.isInFlight {
                    ConversionProgressCard(snapshot: progress, startedAt: ConversionProgressReader.date(fromAgentTimestamp: currentJob?.startedAt))
                        .formSection {}
                }
                if currentJob?.logPath != nil {
                    ConversionLogAccordion(lines: progress?.logLines ?? [], isExpanded: $isLogExpanded)
                        .formSection {}
                }

                if let error = presentation.errorMessage {
                    ErrorBanner(text: error)
                }

                if let message = presentation.message, !message.isEmpty {
                    Text(message)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
            .padding(WorkbenchSpacing.pageInset)
            .onPasteCommand(of: [.plainText, .url]) { _ in pasteIntake() }
        }
        .onChange(of: qBits) { _, bits in
            modelWorkflow.selectRepoBits(bits)
        }
        .onChange(of: presentation.bitWidths, initial: true) { _, widths in
            if !widths.contains(qBits), let widest = widths.last { qBits = widest }
        }
        // A new workflow (intake, Library) names its destination's width; the picker follows it.
        .onChange(of: modelWorkflow.workflow.id, initial: true) { _, _ in
            if let bits = modelWorkflow.workflow.destinationBits, presentation.bitWidths.contains(bits) { qBits = bits }
        }
        .task(id: modelWorkflow.workflow.jobReceipt) {
            await sampleProgress()
            while !Task.isCancelled && modelWorkflow.workflow.state.isInFlight {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await sampleProgress()
            }
            await sampleProgress()
        }
        .task(id: modelWorkflow.workflow.state) {
            while !Task.isCancelled && modelWorkflow.workflow.state.isInFlight {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await appHost.refreshWorkflowStatus()
            }
        }
    }

    private var currentJob: Job? {
        guard let receipt = modelWorkflow.workflow.jobReceipt else { return nil }
        return modelWorkflow.jobs.first { $0.receipt == receipt }
    }

    /// Reads the destination size and log tail off the main thread.
    private func sampleProgress() async {
        guard modelWorkflow.workflow.jobReceipt != nil else {
            progress = nil
            return
        }
        let output = modelWorkflow.workflow.outputPath
        let logPath = currentJob?.logPath
        let estimate = ConversionProgressSnapshot.estimate(for: modelWorkflow.workflow)
        progress = await Task.detached(priority: .utility) {
            ConversionProgressSnapshot(
                writtenBytes: ConversionProgressReader.writtenBytes(at: output),
                estimatedBytes: estimate,
                logLines: ConversionProgressReader.logTail(at: logPath)
            )
        }.value
    }

    private func pasteIntake() {
        let text = NSPasteboard.general.string(forType: .string)
        guard IntakeCoordinator.looksLikeHFLink(text) else { return }
        appHost.intake.open(with: text)
        openWindow(id: IntakeWindow.id)
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Workflow status")
            HStack(spacing: WorkbenchSpacing.xs) {
                StatusPill(state: modelWorkflow.workflow.state.rawValue)
                Text(presentation.stateTitle)
                    .font(WorkbenchTypography.body)
                    .foregroundStyle(WorkbenchColor.ink)
            }
        }
        .formSection {}
    }

    private var sourceAndDestinationCard: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Source and destination")
            detailRow(presentation.sourceLabel, presentation.sourcePath.isEmpty ? "Choose Prepare to run from a Library model." : presentation.sourceDisplay)
            detailRow("Destination", presentation.destinationPath.isEmpty ? "Destination will be calculated from the selected source." : presentation.destinationPath)
            if !presentation.destinationPath.isEmpty {
                Text(presentation.destinationNote)
                    .font(WorkbenchTypography.body)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
        .formSection {}
    }

    private var conversionActions: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Conversion")
            if presentation.canPreview || presentation.canConfirm {
                Toggle("Move original source to Trash after verification", isOn: $reclaimSource)
                Text("Keeps failed or unverified sources, active models, other cache revisions and shared weights.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            Picker("Quantization", selection: $qBits) {
                ForEach(presentation.bitWidths, id: \.self) { bits in
                    Text("\(bits)-bit").tag(bits)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220, alignment: .leading)
            .disabled(presentation.isQuantizationLocked)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    actionButtons
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    actionButtons
                }
            }
        }
        .formSection {}
    }

    private func previewAction() {
        Task { await modelWorkflow.preview(qBits: qBits, out: nil) }
    }

    private func confirmAction() {
        Task { await modelWorkflow.confirm(qBits: qBits, reclaimSourceAfterVerification: reclaimSource) }
    }

    private var sourceCleanupActions: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Original source")
            if let plan = reclaim.sourcePlan, plan.workflow.id == modelWorkflow.workflow.id {
                Text("\(plan.paths.count) source items · \(LibraryTablePresentation.byteCount(plan.bytes)) to Trash")
                DisclosureGroup("Review source paths") {
                    ForEach(plan.paths, id: \.self) { Text($0).font(WorkbenchTypography.secondary).textSelection(.enabled) }
                }
                HStack {
                    Button("Move originals to Trash") {
                        Task { await reclaim.confirmSource(modelWorkflow.workflow); await appHost.rescan() }
                    }.buttonStyle(.borderedProminent)
                    Button("Cancel") { reclaim.cancelSource() }
                }.disabled(reclaim.isApplying)
            } else {
                Button("Preview source cleanup") { Task { await reclaim.previewSource(modelWorkflow.workflow) } }
                    .disabled(reclaim.isApplying)
            }
            if let note = reclaim.sourceCleanupNote { Text(note).font(WorkbenchTypography.secondary) }
            if let error = reclaim.lastError { ErrorBanner(text: error) }
        }.formSection {}
    }

    @ViewBuilder
    private var actionButtons: some View {
        // The primary action for the current workflow state is prominent.
        if presentation.primaryAction == .preview {
            Button("Preview conversion", action: previewAction)
                .buttonStyle(.borderedProminent)
                .disabled(!presentation.canPreview || modelWorkflow.isConversionSubmissionInFlight)
        } else {
            Button("Preview conversion", action: previewAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canPreview || modelWorkflow.isConversionSubmissionInFlight)
        }

        if presentation.primaryAction == .confirm {
            Button("Confirm conversion", action: confirmAction)
                .buttonStyle(.borderedProminent)
                .disabled(!presentation.canConfirm || modelWorkflow.isConversionSubmissionInFlight)
        } else {
            Button("Confirm conversion", action: confirmAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canConfirm || modelWorkflow.isConversionSubmissionInFlight)
        }

        if let existingModel, ModelTaskPresentation.isServable(existingModel) {
            Button("Run existing") {
                modelWorkflow.useExisting(existingModel)
                modelWorkflow.prepareServe(model: existingModel)
                onRouteSelection(.run)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(WorkbenchTypography.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
