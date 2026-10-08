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
    /// The width the destination names (`-MLX-<bits>bit`); nil when it names none.
    let destinationBits: Int?
    let estimatedOutputBytes: [String: Int64]?
    let completedModelPath: String?
    let hasJobReceipt: Bool

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
        destinationBits = workflow.destinationBits
        estimatedOutputBytes = workflow.estimatedOutputBytes
        completedModelPath = workflow.completedModelPath
        hasJobReceipt = workflow.jobReceipt != nil
    }

    static let repoScheme = "hf://"

    /// A Hugging Face source: converted from a repo, or restored as `hf://<repo>`.
    var isRepoSource: Bool { sourceRepo != nil || sourcePath.hasPrefix(Self.repoScheme) }

    /// The conversion finished; the status line alone states the outcome.
    var isFinished: Bool { state == .verified || state == .completed }

    var repoID: String? {
        sourceRepo ?? (sourcePath.hasPrefix(Self.repoScheme) ? String(sourcePath.dropFirst(Self.repoScheme.count)) : nil)
    }

    /// The source's name: its repo id, else the GGUF file name; empty without a source.
    var displayName: String {
        guard !sourcePath.isEmpty else { return "" }
        return repoID ?? URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    var sourceLabel: String { isRepoSource ? "Source repo" : "Source GGUF" }

    var sourceDisplay: String { repoID.map { repo in subfolder.map { "\(repo)/\($0)" } ?? repo } ?? sourcePath }

    var destinationNote: String {
        isRepoSource
            ? "The destination is the configured output directory, which the Library scans."
            : "The destination is the coordinator-approved same-directory path. It cannot be overridden in Prepare."
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

// MARK: - Library lookups

extension PrepareWorkflowPresentation {
    /// The Library model for a GGUF source; repo sources have none before conversion.
    func sourceModel(in snapshot: LibrarySnapshot?) -> LibraryModel? {
        guard !sourcePath.isEmpty else { return nil }
        return snapshot?.models.first { $0.item.path == sourcePath }
    }

    /// The Library model for the converted output, once the Library lists it.
    func outputModel(in snapshot: LibrarySnapshot?) -> LibraryModel? {
        let path = completedModelPath ?? destinationPath
        guard !path.isEmpty else { return nil }
        return snapshot?.models.first { $0.item.path == path || $0.outputPaths.contains(path) }
    }

    var hasConvertedOutput: Bool { state == .completed || state == .verified }

    /// Actual bytes of the converted output; nil until the Library lists it.
    func actualBytes(outputModel: LibraryModel?) -> Int64? {
        guard hasConvertedOutput, let bytes = outputModel?.item.bytes, bytes > 0 else { return nil }
        return bytes
    }
}

// MARK: - Quantization tiles

struct PrepareTile: Equatable, Identifiable {
    enum Size: Equatable {
        case estimated(Int64)
        case actual(Int64)
        case unknown

        var bytes: Int64? {
            switch self {
            case .estimated(let bytes), .actual(let bytes): return bytes
            case .unknown: return nil
            }
        }

        var text: String {
            switch self {
            case .estimated(let bytes): return "~" + LibraryTablePresentation.byteCount(bytes)
            case .actual(let bytes): return LibraryTablePresentation.byteCount(bytes) + " actual"
            case .unknown: return "Size unknown"
            }
        }

        var spokenText: String {
            switch self {
            case .estimated(let bytes): return "about " + LibraryTablePresentation.byteCount(bytes) + " estimated"
            case .actual(let bytes): return LibraryTablePresentation.byteCount(bytes) + " actual"
            case .unknown: return "size unknown"
            }
        }
    }

    let bits: Int
    let size: Size
    var id: Int { bits }
    var widthLabel: String { "\(bits)-bit" }
}

extension PrepareWorkflowPresentation {
    /// Per-state honest size: the converted output's actual bytes on the width
    /// it was converted at, else the intake estimate for that width, else unknown.
    func size(forBits bits: Int, actualBytes: Int64?) -> PrepareTile.Size {
        if hasConvertedOutput, let actualBytes, actualBytes > 0, bits == destinationBits {
            return .actual(actualBytes)
        }
        if let estimate = estimatedOutputBytes?[String(bits)], estimate > 0 {
            return .estimated(estimate)
        }
        return .unknown
    }

    func tiles(actualBytes: Int64?) -> [PrepareTile] {
        bitWidths.map { PrepareTile(bits: $0, size: size(forBits: $0, actualBytes: actualBytes)) }
    }

    /// The tile drawn as chosen. Once a preview exists the width is the one
    /// previewed or converted, which is known only when the destination names
    /// it; never the configured default.
    func highlightedBits(selected: Int) -> Int? {
        guard isQuantizationLocked else { return selected }
        guard let destinationBits, bitWidths.contains(destinationBits) else { return nil }
        return destinationBits
    }
}

/// A tile's fit verdict, from the one fit owner (`ModelBudgetPresentation`).
struct PrepareTileFit: Equatable {
    enum State: Equatable {
        case redacted, unavailable, notEstimated, estimated
    }

    let state: State
    let tone: ModelBudgetPresentation.Tone
    let word: String
    let help: String
    let symbol: String

    var spokenVerdict: String {
        switch state {
        case .redacted: return "reading memory"
        case .unavailable: return "memory reading unavailable"
        case .notEstimated: return "fit not estimated"
        case .estimated: return word.lowercased()
        }
    }

    static func make(
        size: PrepareTile.Size,
        parameters: String?,
        task: ModelTaskType?,
        taskIsLabelled: Bool,
        memory: MemorySnapshot?,
        hasProbed: Bool,
        contextTokens: Int,
        reserveGB: Double,
        hardware: HardwareProfile
    ) -> PrepareTileFit {
        let subject = ModelBudgetPresentation.Subject(bytes: size.bytes ?? 0, parameters: parameters, task: task, requiresKnownTask: !taskIsLabelled)
        let budget = ModelBudgetPresentation(
            memory: memory, reserveGB: reserveGB, contextTokens: contextTokens,
            subject: subject, hardware: hardware, hasProbed: hasProbed
        )
        func plain(_ state: State, word: String, help: String) -> PrepareTileFit {
            PrepareTileFit(state: state, tone: .neutral, word: word, help: help, symbol: budget.verdictSymbol)
        }
        guard subject.supportsEstimate, subject.bytes > 0 else {
            return plain(.notEstimated, word: budget.verdictText, help: budget.verdictText)
        }
        switch budget.reading {
        case .loading:
            return plain(.redacted, word: "Won't fit", help: "Reading memory")
        case .unavailable:
            return plain(.unavailable, word: budget.unavailableText, help: budget.unavailableText)
        case .live:
            guard let word = budget.verdictWord else {
                return plain(.notEstimated, word: budget.verdictText, help: budget.verdictText)
            }
            var help = budget.verdictText
            if FitAdvisor.parameterBillions(parameters) == nil {
                help += ". The KV cache uses the default 8B-class assumption because the parameter count is unknown."
            }
            return PrepareTileFit(state: .estimated, tone: budget.tone, word: word, help: help, symbol: budget.verdictSymbol)
        }
    }
}

// MARK: - Pipeline track

extension PrepareWorkflowPresentation {
    static let stageTitles = ["Source", "Preview", "Convert", "Verify", "Ready"]
    static let stageSymbols = ["tray.and.arrow.down", "doc.text.magnifyingglass", "gearshape.2", "checkmark.shield", "checkmark.circle"]

    /// Verify and Ready complete only on evidence: the workflow reached
    /// `.verified`, or the verification store holds a passing report for the output.
    static func hasVerificationEvidence(state: ConversionWorkflowState, status: VerificationStatus?) -> Bool {
        if state == .verified { return true }
        if case .verified = status ?? .unverified { return true }
        return false
    }

    /// Source, Preview, Convert, Verify, Ready. A failed run is placed at the
    /// stage its persisted fields prove it reached: a job receipt means Convert,
    /// a preview hash means Preview, otherwise Source.
    func stageStates(hasVerificationEvidence evidence: Bool) -> [ModelFlightStageState] {
        let pending = ModelFlightStageState.pending, complete = ModelFlightStageState.complete
        let active = ModelFlightStageState.active, failed = ModelFlightStageState.failed
        switch state {
        case .idle:
            return [pending, pending, pending, pending, pending]
        case .inspectingSource:
            return [active, pending, pending, pending, pending]
        case .existingModelFound:
            return [complete, pending, pending, pending, pending]
        case .previewingConversion:
            return [complete, active, pending, pending, pending]
        case .readyToConfirm:
            return [complete, complete, pending, pending, pending]
        case .queued, .running:
            return [complete, complete, active, pending, pending]
        case .verifying:
            return [complete, complete, complete, active, pending]
        case .completed:
            return evidence ? [complete, complete, complete, complete, complete] : [complete, complete, complete, pending, pending]
        case .verified:
            return [complete, complete, complete, complete, complete]
        case .verificationFailed:
            return [complete, complete, complete, failed, pending]
        case .failed:
            if hasJobReceipt { return [complete, complete, failed, pending, pending] }
            if hasPreviewHash { return [complete, failed, pending, pending, pending] }
            return [failed, pending, pending, pending, pending]
        }
    }

    /// The active node pulses only while work is in flight.
    var pulsesActiveStage: Bool {
        [.previewingConversion, .queued, .running, .verifying].contains(state)
    }

    func stageNodes(hasVerificationEvidence evidence: Bool) -> [FlightTrackNode] {
        let states = stageStates(hasVerificationEvidence: evidence)
        return states.indices.map { index in
            FlightTrackNode(
                id: Self.stageTitles[index],
                title: Self.stageTitles[index],
                symbol: Self.stageSymbols[index],
                state: states[index],
                detail: "",
                pulses: states[index] == .active && pulsesActiveStage
            )
        }
    }
}

// MARK: - Actions

struct PrepareExistingModel: Equatable {
    let path: String
    let isServable: Bool
}

/// The buttons Prepare shows for a state: exactly one prominent at most, never
/// a disabled prominent one. Onward actions after a conversion come from
/// `ActivityWorkflowCardPresentation.actions`.
struct PrepareActionPlan: Equatable {
    enum Action: Equatable {
        case preview
        case confirm
        case runExisting
        case openExistingInLibrary(String)
        case openActivity
        case rescan
        case onward(ActivityWorkflowAction)
    }

    struct Item: Equatable {
        let action: Action
        let isProminent: Bool
        let isEnabled: Bool
    }

    let items: [Item]

    var prominentCount: Int { items.filter(\.isProminent).count }

    static func make(
        presentation: PrepareWorkflowPresentation,
        onward: [ActivityWorkflowAction],
        existing: PrepareExistingModel?,
        isSubmitting: Bool
    ) -> PrepareActionPlan {
        guard !presentation.sourcePath.isEmpty else { return PrepareActionPlan(items: []) }
        switch presentation.state {
        case .queued, .running, .verifying:
            return PrepareActionPlan(items: [Item(action: .openActivity, isProminent: false, isEnabled: true)])
        case .completed, .verified:
            let run = onward.first { if case .runModel = $0 { return true } else { return false } }
            let library = onward.first { if case .openInLibrary = $0 { return true } else { return false } }
            if let run {
                var items = [Item(action: .onward(run), isProminent: true, isEnabled: true)]
                if let library { items.append(Item(action: .onward(library), isProminent: false, isEnabled: true)) }
                return PrepareActionPlan(items: items)
            }
            if let library {
                return PrepareActionPlan(items: [Item(action: .onward(library), isProminent: true, isEnabled: true)])
            }
            return PrepareActionPlan(items: [Item(action: .rescan, isProminent: true, isEnabled: true)])
        case .existingModelFound:
            guard let existing else {
                return PrepareActionPlan(items: [Item(action: .rescan, isProminent: true, isEnabled: true)])
            }
            let action: Action = existing.isServable ? .runExisting : .openExistingInLibrary(existing.path)
            return PrepareActionPlan(items: [Item(action: action, isProminent: true, isEnabled: true)])
        case .idle, .inspectingSource, .previewingConversion, .readyToConfirm, .verificationFailed, .failed:
            let previewEnabled = presentation.canPreview && !isSubmitting
            let confirmEnabled = presentation.canConfirm && !isSubmitting
            let primary = presentation.primaryAction
            let preview = Item(action: .preview, isProminent: primary == .preview && previewEnabled, isEnabled: previewEnabled)
            let confirm = Item(action: .confirm, isProminent: primary == .confirm && confirmEnabled, isEnabled: confirmEnabled)
            return PrepareActionPlan(items: primary == .confirm ? [confirm, preview] : [preview, confirm])
        }
    }
}

// MARK: - ConvertView

struct ConvertView: View {
    @ObservedObject var appHost: AppHost
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var reclaim: ReclaimCoordinator
    @ObservedObject private var verification: VerificationCoordinator
    private let onRouteSelection: (AppRoute) -> Void

    @State private var qBits: Int
    @State private var progress: ConversionProgressSnapshot?
    @State private var isLogExpanded = false
    @State private var reclaimSource = true

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
        _verification = ObservedObject(wrappedValue: appHost.verification)
        self.onRouteSelection = onRouteSelection
        _qBits = State(initialValue: appHost.config.qBits)
    }

    private var presentation: PrepareWorkflowPresentation {
        PrepareWorkflowPresentation(workflow: modelWorkflow.workflow)
    }

    private var sourceModel: LibraryModel? { presentation.sourceModel(in: appHost.librarySnapshot) }

    private var outputModel: LibraryModel? { presentation.outputModel(in: appHost.librarySnapshot) }

    private var existingModel: LibraryModel? {
        guard presentation.state == .existingModelFound else { return nil }
        return appHost.librarySnapshot?.models.first { $0.item.path == presentation.destinationPath }
    }

    private var hasVerificationEvidence: Bool {
        let status = presentation.completedModelPath.map { verification.status(for: $0, signature: outputModel?.item.signature) }
        return PrepareWorkflowPresentation.hasVerificationEvidence(state: presentation.state, status: status)
    }

    private var actionPlan: PrepareActionPlan {
        let onward = ActivityWorkflowCardPresentation(workflow: modelWorkflow.workflow, job: currentJob, snapshot: appHost.librarySnapshot).actions
        let existing = existingModel.map { PrepareExistingModel(path: $0.item.path, isServable: ModelTaskPresentation.isServable($0)) }
        return PrepareActionPlan.make(presentation: presentation, onward: onward, existing: existing, isSubmitting: modelWorkflow.isConversionSubmissionInFlight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                IntakeField(intake: appHost.intake)
                if presentation.sourcePath.isEmpty {
                    idleState
                    notices
                } else {
                    transformSurface
                    actionRow
                    pipeline
                    if modelWorkflow.workflow.state == .verified {
                        sourceCleanupActions
                    }
                    if currentJob?.logPath != nil {
                        ConversionLogAccordion(lines: progress?.logLines ?? [], isExpanded: $isLogExpanded)
                    }
                }
            }
            .frame(maxWidth: WorkbenchSize.contentMaxWidth)
            .padding(WorkbenchSpacing.pageInset)
            .frame(maxWidth: .infinity)
            .onPasteCommand(of: [.plainText, .url]) { _ in pasteIntake() }
        }
        .onChange(of: qBits) { _, bits in
            modelWorkflow.selectRepoBits(bits)
        }
        .onChange(of: presentation.bitWidths, initial: true) { _, widths in
            if !widths.contains(qBits), let widest = widths.last { qBits = widest }
        }
        // A new workflow (intake, Library) names its destination's width; the tiles follow it.
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

    // MARK: Idle

    private var idleState: some View {
        WorkbenchSurface {
            HStack(spacing: WorkbenchSpacing.md) {
                Image(systemName: "books.vertical")
                    .font(WorkbenchTypography.display)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WorkbenchColor.muted)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text("Choose a model to prepare")
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.ink)
                    Text("Pick a GGUF or Hugging Face model in Library, or paste a link above.")
                        .font(WorkbenchTypography.body)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                Spacer(minLength: WorkbenchSpacing.md)
                Button("Choose in Library") { onRouteSelection(.library) }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Transform header and tiles

    private var transformSurface: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                transformHeader
                if !presentation.destinationPath.isEmpty {
                    Text(presentation.destinationNote)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(presentation.destinationNote)
                }
                Text("Quantization")
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(WorkbenchColor.muted)
                tiles
                if presentation.canPreview || presentation.canConfirm {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Toggle("Move original source to Trash after verification", isOn: $reclaimSource)
                        Text("Keeps failed or unverified sources, active models, other cache revisions and shared weights.")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("Keeps failed or unverified sources, active models, other cache revisions and shared weights.")
                    }
                }
            }
        }
    }

    private var transformHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                sourceEndpoint.frame(minWidth: WorkbenchSize.Prepare.endpointMinimum, idealWidth: WorkbenchSize.Prepare.endpointMinimum, maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.muted)
                    .frame(width: WorkbenchSize.Prepare.arrow)
                    .accessibilityHidden(true)
                destinationEndpoint.frame(minWidth: WorkbenchSize.Prepare.endpointMinimum, idealWidth: WorkbenchSize.Prepare.endpointMinimum, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                sourceEndpoint
                Image(systemName: "arrow.down")
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.muted)
                    .accessibilityHidden(true)
                destinationEndpoint
            }
        }
    }

    private var sourceEndpoint: some View {
        let symbol = (outputModel ?? sourceModel)?.item.task?.type.symbolName ?? ModelTaskType.other.symbolName
        let size = sourceModel.map(\.item.bytes).flatMap { $0 > 0 ? LibraryTablePresentation.byteCount($0) : nil }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Label {
                Text(presentation.displayName)
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if presentation.isRepoSource {
                if presentation.sourceDisplay == presentation.displayName {
                    Text("Hugging Face repo")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                } else {
                    pathLine(presentation.sourceDisplay)
                }
            } else {
                pathLine(presentation.sourcePath)
            }
            if let size {
                Text(size)
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private var destinationEndpoint: some View {
        let path = presentation.destinationPath
        let bits = presentation.destinationBits ?? qBits
        let size = presentation.size(forBits: bits, actualBytes: presentation.actualBytes(outputModel: outputModel))
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            if path.isEmpty {
                Text("Destination will be calculated from the selected source.")
                    .font(WorkbenchTypography.body)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                Label {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "folder")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                pathLine(path)
                Text(size.text)
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    /// One selectable path line, middle-truncated; the full path is its accessibility label and help.
    private func pathLine(_ path: String) -> some View {
        Text(path)
            .font(WorkbenchTypography.compactValue)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
            .accessibilityLabel(path)
    }

    private var tiles: some View {
        let actual = presentation.actualBytes(outputModel: outputModel)
        let highlighted = presentation.highlightedBits(selected: qBits)
        let taskModel = outputModel ?? sourceModel
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: WorkbenchSize.Prepare.tileMinimum, maximum: WorkbenchSize.Prepare.tileMaximum), spacing: WorkbenchSpacing.sm, alignment: .top)],
            alignment: .leading,
            spacing: WorkbenchSpacing.sm
        ) {
            ForEach(presentation.tiles(actualBytes: actual)) { tile in
                PrepareQuantTileView(
                    resources: appHost.resources,
                    tile: tile,
                    parameters: taskModel?.item.parameters,
                    task: taskModel?.item.task?.type,
                    taskIsLabelled: taskModel != nil,
                    reserveGB: appHost.config.fitReserveGB,
                    hardware: appHost.hardwareProfile,
                    isHighlighted: highlighted == tile.bits,
                    isLocked: presentation.isQuantizationLocked
                ) { qBits = tile.bits }
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        let items = actionPlan.items
        return Group {
            if !items.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.sm) {
                        actionButtons(items)
                    }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        actionButtons(items)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ items: [PrepareActionPlan.Item]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button(title(for: item.action)) { perform(item.action) }
                .prepareButtonStyle(prominent: item.isProminent)
                .disabled(!item.isEnabled)
        }
    }

    private func title(for action: PrepareActionPlan.Action) -> String {
        switch action {
        case .preview: return "Preview conversion"
        case .confirm: return "Confirm conversion"
        case .runExisting: return "Run existing"
        case .openExistingInLibrary: return "Open in Library"
        case .openActivity: return "Open Activity"
        case .rescan: return "Rescan Library"
        case .onward(let onward):
            switch onward {
            case .openInLibrary: return "Open in Library"
            case .runModel: return "Run model"
            case .retryPreview: return "Retry preview"
            case .keepAnyway: return "Keep anyway (unverified)"
            }
        }
    }

    private func perform(_ action: PrepareActionPlan.Action) {
        switch action {
        case .preview:
            Task { await modelWorkflow.preview(qBits: qBits, out: nil) }
        case .confirm:
            Task { await modelWorkflow.confirm(qBits: qBits, reclaimSourceAfterVerification: reclaimSource) }
        case .runExisting:
            guard let existingModel else { return }
            modelWorkflow.useExisting(existingModel)
            modelWorkflow.prepareServe(model: existingModel)
            onRouteSelection(.run)
        case .openExistingInLibrary(let path):
            appHost.selectedModelPath = path
            onRouteSelection(.library)
        case .openActivity:
            onRouteSelection(.activity)
        case .rescan:
            Task { await appHost.rescan() }
        case .onward(let onward):
            performOnward(onward)
        }
    }

    /// Repeats the Activity card's behavior for the same onward actions.
    private func performOnward(_ action: ActivityWorkflowAction) {
        switch action {
        case .openInLibrary(let path):
            appHost.selectedModelPath = path
            onRouteSelection(.library)
        case .runModel(let record):
            guard let path = record.completedModelPath else { return }
            guard let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) else { return }
            guard record.state == .completed || record.state == .verified, model.readiness == .ready else { return }
            appHost.modelWorkflow.restore(record)
            appHost.modelWorkflow.prepareServe(model: model, exactPath: path)
            appHost.selectedModelPath = path
            onRouteSelection(.run)
        case .keepAnyway, .retryPreview:
            return
        }
    }

    // MARK: Pipeline

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            FlightTrackView(
                nodes: presentation.stageNodes(hasVerificationEvidence: hasVerificationEvidence),
                showsStateText: false,
                accessibilityTitle: "Conversion pipeline",
                columnMinimum: WorkbenchSize.Prepare.trackColumnMinimum
            )
            Text(presentation.stateTitle)
                .font(WorkbenchTypography.emphasis)
                .foregroundStyle(WorkbenchColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .help(presentation.message ?? "")
                .accessibilityValue(presentation.message ?? "")
            if let error = presentation.errorMessage {
                ErrorBanner(text: error)
            }
            // A finished conversion's message restates the status line and the
            // all-complete track; it stays in the help tag. In-flight and failed
            // messages carry new information and stay visible.
            if let message = presentation.message, !message.isEmpty, !presentation.isFinished {
                Text(message)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .textSelection(.enabled)
            }
            if let progress, modelWorkflow.workflow.state.isInFlight {
                let card = ConversionProgressCard(snapshot: progress, startedAt: ConversionProgressReader.date(fromAgentTimestamp: currentJob?.startedAt))
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Spacer(minLength: 0)
                        card.fixedSize()
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: WorkbenchSize.Prepare.ringCenteredMinimum)
                    card
                }
            }
        }
    }

    /// The workflow's message and error, once each, under the track.
    @ViewBuilder
    private var notices: some View {
        if let error = presentation.errorMessage {
            ErrorBanner(text: error)
        }
        if let message = presentation.message, !message.isEmpty {
            Text(message)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .textSelection(.enabled)
        }
    }

    // MARK: Source cleanup

    private var sourceCleanupActions: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Original source")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            if let plan = reclaim.sourcePlan, plan.workflow.id == modelWorkflow.workflow.id {
                Text("\(plan.paths.count) source items · \(LibraryTablePresentation.byteCount(plan.bytes)) to Trash")
                DisclosureGroup("Review source paths") {
                    ForEach(plan.paths, id: \.self) { Text($0).font(WorkbenchTypography.secondary).textSelection(.enabled) }
                }
                HStack {
                    Button("Move originals to Trash") {
                        Task { await reclaim.confirmSource(modelWorkflow.workflow); await appHost.rescan() }
                    }
                    Button("Cancel") { reclaim.cancelSource() }
                }
                .buttonStyle(.bordered)
                .disabled(reclaim.isApplying)
            } else {
                Button("Preview source cleanup") { Task { await reclaim.previewSource(modelWorkflow.workflow) } }
                    .buttonStyle(.bordered)
                    .disabled(reclaim.isApplying)
            }
            if let note = reclaim.sourceCleanupNote { Text(note).font(WorkbenchTypography.secondary) }
            if let error = reclaim.lastError { ErrorBanner(text: error) }
        }
    }
}

private extension View {
    /// Prominent only for the one primary action of the state.
    @ViewBuilder
    func prepareButtonStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - Quantization tile

/// One quantization width. This is the only view on the page that observes the
/// memory monitor, so a probe re-evaluates the tiles and nothing around them.
private struct PrepareQuantTileView: View {
    @ObservedObject var resources: SystemResourceMonitor
    let tile: PrepareTile
    let parameters: String?
    let task: ModelTaskType?
    let taskIsLabelled: Bool
    let reserveGB: Double
    let hardware: HardwareProfile
    let isHighlighted: Bool
    let isLocked: Bool
    let select: () -> Void

    private var fit: PrepareTileFit {
        PrepareTileFit.make(
            size: tile.size, parameters: parameters, task: task, taskIsLabelled: taskIsLabelled,
            memory: resources.memory, hasProbed: resources.hasProbed,
            contextTokens: resources.contextTokens, reserveGB: reserveGB, hardware: hardware
        )
    }

    var body: some View {
        let fit = fit
        Button(action: select) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(tile.widthLabel)
                    .font(WorkbenchTypography.display)
                    .foregroundStyle(isLocked && !isHighlighted ? WorkbenchColor.muted : WorkbenchColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tile.size.text)
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xxs) {
                    Image(systemName: fit.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(fit.tone.color)
                    Text(fit.word)
                        .font(WorkbenchTypography.label)
                        .foregroundStyle(fit.tone == .neutral ? WorkbenchColor.muted : WorkbenchColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .redacted(reason: fit.state == .redacted ? .placeholder : [])
                .workbenchAnimation(value: fit.tone)
            }
            .padding(WorkbenchSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? WorkbenchColor.accent.opacity(.fill) : WorkbenchColor.surface, in: shape)
            .overlay {
                shape.strokeBorder(isHighlighted ? WorkbenchColor.accent : WorkbenchColor.hairline, lineWidth: isHighlighted ? WorkbenchSize.stageTrack : WorkbenchSpacing.hairline)
            }
            .contentShape(shape)
        }
        .buttonStyle(PrepareTileButtonStyle())
        .disabled(isLocked)
        .workbenchAnimation(WorkbenchMotion.standard, value: isHighlighted)
        .help(fit.help)
        .accessibilityLabel("\(tile.bits)-bit, \(tile.size.spokenText), \(fit.spokenVerdict)")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous)
    }
}

/// Draws the tile as-is: a locked tile keeps its highlight instead of dimming.
private struct PrepareTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
