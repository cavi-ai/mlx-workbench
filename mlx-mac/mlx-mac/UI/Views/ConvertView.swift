import SwiftUI

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

    init(workflow: ConversionWorkflow) {
        sourcePath = workflow.sourcePath
        destinationPath = workflow.outputPath
        state = workflow.state
        message = workflow.message
        errorMessage = workflow.errorMessage
        hasPreviewHash = !(workflow.previewHash?.isEmpty ?? true)
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
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    private let onRouteSelection: (String) -> Void

    @State private var qBits: Int

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
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
                workflowCard
                sourceAndDestinationCard
                conversionActions

                if let error = presentation.errorMessage {
                    ErrorBanner(text: error)
                }

                if let message = presentation.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Workflow status")
            HStack(spacing: WorkbenchSpacing.xs) {
                StatusPill(state: modelWorkflow.workflow.state.rawValue)
                Text(presentation.stateTitle)
                    .font(WorkbenchTypography.body)
                    .foregroundColor(WorkbenchColor.graphiteInk)
            }
        }
        .formSection {}
    }

    private var sourceAndDestinationCard: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Source and destination")
            detailRow("Source GGUF", presentation.sourcePath.isEmpty ? "Choose Prepare to run from a Library model." : presentation.sourcePath)
            detailRow("Destination", presentation.destinationPath.isEmpty ? "Destination will be calculated from the selected source." : presentation.destinationPath)
            if !presentation.destinationPath.isEmpty {
                Text("The destination is the coordinator-approved same-directory path. It cannot be overridden in Prepare.")
                    .font(WorkbenchTypography.body)
                    .foregroundColor(WorkbenchColor.graphiteMuted)
            }
        }
        .formSection {}
    }

    private var conversionActions: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Conversion")
            Picker("Quantization", selection: $qBits) {
                Text("4-bit").tag(4)
                Text("8-bit").tag(8)
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
        Task { await modelWorkflow.confirm(qBits: qBits) }
    }

    @ViewBuilder
    private var actionButtons: some View {
        // The primary action for the current workflow state is prominent.
        if presentation.primaryAction == .preview {
            Button("Preview conversion", action: previewAction)
                .buttonStyle(.borderedProminent)
                .tint(WorkbenchColor.fluxTeal)
                .disabled(!presentation.canPreview || modelWorkflow.isConversionSubmissionInFlight)
        } else {
            Button("Preview conversion", action: previewAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canPreview || modelWorkflow.isConversionSubmissionInFlight)
        }

        if presentation.primaryAction == .confirm {
            Button("Confirm conversion", action: confirmAction)
                .buttonStyle(.borderedProminent)
                .tint(WorkbenchColor.fluxTeal)
                .disabled(!presentation.canConfirm || modelWorkflow.isConversionSubmissionInFlight)
        } else {
            Button("Confirm conversion", action: confirmAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canConfirm || modelWorkflow.isConversionSubmissionInFlight)
        }

        if let existingModel {
            Button("Run existing") {
                modelWorkflow.useExisting(existingModel)
                modelWorkflow.prepareServe(model: existingModel)
                onRouteSelection("serve")
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
