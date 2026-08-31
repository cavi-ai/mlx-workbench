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
            VStack(alignment: .leading, spacing: 16) {
                Text("Prepare")
                    .font(.title2)
                Text("Prepare a Library GGUF for local MLX use. Conversion plans are previewed before they are confirmed.")
                    .foregroundColor(.secondary)

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
            .padding()
        }
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Workflow status")
            HStack(spacing: 8) {
                StatusPill(state: modelWorkflow.workflow.state.rawValue)
                Text(presentation.stateTitle)
                    .font(.subheadline)
            }
        }
        .formSection {}
    }

    private var sourceAndDestinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Source and destination")
            detailRow("Source GGUF", presentation.sourcePath.isEmpty ? "Choose Prepare to run from a Library model." : presentation.sourcePath)
            detailRow("Destination", presentation.destinationPath.isEmpty ? "Destination will be calculated from the selected source." : presentation.destinationPath)
            if !presentation.destinationPath.isEmpty {
                Text("The destination is the coordinator-approved same-directory path. It cannot be overridden in Prepare.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formSection {}
    }

    private var conversionActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Conversion")
            Picker("Quantization", selection: $qBits) {
                Text("4-bit").tag(4)
                Text("8-bit").tag(8)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(presentation.isQuantizationLocked)

            HStack(spacing: 10) {
                Button("Preview conversion") {
                    Task {
                        await modelWorkflow.preview(qBits: qBits, out: nil)
                    }
                }
                .disabled(!presentation.canPreview || modelWorkflow.isConversionSubmissionInFlight)

                Button("Confirm conversion") {
                    Task {
                        await modelWorkflow.confirm(qBits: qBits)
                    }
                }
                .disabled(!presentation.canConfirm || modelWorkflow.isConversionSubmissionInFlight)

                if let existingModel {
                    Button("Run existing") {
                        modelWorkflow.useExisting(existingModel)
                        modelWorkflow.prepareServe(model: existingModel)
                        onRouteSelection("serve")
                    }
                }
            }
        }
        .formSection {}
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

struct ModelPickerSheet: View {
    @ObservedObject var appHost: AppHost
    @Binding var selected: ModelItem?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var models: [ModelItem] {
        let all = appHost.scanResult?.models ?? []
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.modelKey?.localizedCaseInsensitiveContains(search) == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a GGUF").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            List(models) { item in
                Button {
                    selected = item
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.modelKey ?? item.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let quantization = item.quantization {
                            Text(quantization)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .onAppear {
            if appHost.scanResult == nil {
                Task { await appHost.rescan() }
            }
        }
    }
}
