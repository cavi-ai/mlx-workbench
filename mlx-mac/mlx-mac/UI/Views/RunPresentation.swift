import CoreGraphics
import Foundation

// MARK: - Eligibility

/// The one owner of what Run shows and which serve actions it offers.
struct RunPresentation: Equatable {
    enum Stage: Equatable {
        case noModel
        case nonServable
        case notEligible
        case runtimeMissing
        case eligible
        case readyToConfirm
        case starting
        case running
        case stopped
        case failed
    }

    /// Workflow states whose output Run may serve.
    static let runnableStates: Set<ConversionWorkflowState> = [.completed, .verified]

    let workflow: ConversionWorkflow
    let model: LibraryModel?
    let servers: [ServerInfo]
    let runtimeAvailable: Bool
    let runtimeMessage: String
    var serveInFlight = false

    /// The path Run and the window subtitle name: the workflow's output, else the Library selection.
    static func shownModelPath(workflow: ConversionWorkflow, selectedModelPath: String?) -> String? {
        for candidate in [workflow.completedModelPath, selectedModelPath] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    var isServable: Bool { model.map(ModelTaskPresentation.isServable) ?? false }

    var selectedCompletedModel: LibraryModel? {
        guard Self.runnableStates.contains(workflow.state),
              let completedPath = workflow.completedModelPath,
              let model,
              model.item.path == completedPath || model.outputPaths.contains(completedPath),
              model.readiness == .ready else { return nil }
        return model
    }
    var modelPath: String? {
        guard selectedCompletedModel != nil else { return nil }
        return workflow.completedModelPath
    }
    var activeServer: ServerInfo? {
        guard let modelPath else { return nil }
        return servers.first(where: {
            $0.state?.lowercased() == "running"
                && HFRepoID.matches($0.modelIdentity, modelPath)
        })
    }
    var canPreview: Bool {
        selectedCompletedModel != nil && isServable && runtimeAvailable
            && workflow.serveState != .previewing && activeServer == nil
    }
    var canConfirm: Bool {
        selectedCompletedModel != nil && isServable && runtimeAvailable && workflow.serveState == .readyToConfirm
    }
    var remediation: String? { runtimeAvailable ? nil : runtimeMessage }

    var stage: Stage {
        guard model != nil else { return .noModel }
        guard isServable else { return .nonServable }
        guard selectedCompletedModel != nil else { return .notEligible }
        if activeServer != nil { return .running }
        guard runtimeAvailable else { return .runtimeMissing }
        if serveInFlight || workflow.serveState == .previewing { return .starting }
        switch workflow.serveState {
        case .readyToConfirm: return .readyToConfirm
        case .failed: return .failed
        case .stopped: return .stopped
        case .idle, .running, .previewing: return .eligible
        }
    }

    /// The model the runway's "next" segment sizes; none for no model or a non-servable one.
    var runwayModel: LibraryModel? {
        switch stage {
        case .noModel, .nonServable: return nil
        default: return model
        }
    }

    /// The serve state in words; nil before any serve activity.
    var stateWords: String? {
        switch stage {
        case .readyToConfirm: return "Ready to confirm"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        default: return nil
        }
    }

    var selectionError: String? {
        stage == .notEligible
            ? "Run requires a ready Library model that exactly matches the completed workflow output."
            : nil
    }

    /// Conversion messages stay off Run; serve feedback shows once a serve flow has started.
    var visibleMessage: String? {
        workflow.serveState == .idle ? nil : workflow.message
    }
    var visibleError: String? { workflow.errorMessage }

    /// Whether the model shown can become an endpoint; only servable models can.
    var canAddEndpoint: Bool { model != nil && isServable }

    /// Why Add endpoint is unavailable; nil when it is available.
    var addEndpointBlockedReason: String? {
        canAddEndpoint ? nil : "Endpoints serve chat and vision models. Select one in Library."
    }
}

// MARK: - Formatting

/// Ports render as plain digits, never grouped by locale.
enum RunFormat {
    static func port(_ port: Int) -> String { ":" + String(port) }

    static func endpoint(port: Int) -> String { "127.0.0.1" + Self.port(port) }
}

// MARK: - State words

enum RunStateWord {
    /// The word for a serving process: a JIT endpoint reports its model residency, others their state.
    static func word(state: String?, jit: Bool?, modelState: String?) -> String {
        let base = state?.lowercased() ?? "unknown"
        guard base == "running", jit == true else { return base }
        switch modelState {
        case "loaded", "unloaded", "loading": return modelState ?? base
        default: return base
        }
    }

    static func word(for server: ServerInfo) -> String {
        word(state: server.state, jit: server.jit, modelState: server.modelState)
    }

    static func isLoading(_ server: ServerInfo) -> Bool { word(for: server) == "loading" }
}

// MARK: - Context

/// Context for fit estimates: the toolbar's options, one owner (`SystemResourceMonitor.contextTokens`).
enum RunContext {
    static var options: [Int] { SystemResourceMonitor.contextOptions }

    /// The largest option that does not exceed `tokens`.
    static func option(atMost tokens: Int) -> Int {
        options.last(where: { $0 <= tokens }) ?? options[0]
    }

    static func title(_ tokens: Int) -> String { "\(tokens / 1024)K tokens" }

    /// The option to offer when a verdict suggests a smaller context.
    static func suggestion(from verdict: FitVerdict?) -> Int? {
        guard case .wontFit(_, let suggested?)? = verdict else { return nil }
        return option(atMost: suggested)
    }
}

// MARK: - Library lookup

enum RunModels {
    static func model(for identity: String, in models: [LibraryModel]) -> LibraryModel? {
        guard !identity.isEmpty else { return nil }
        return models.first {
            HFRepoID.matches(identity, $0.item.path) || $0.outputPaths.contains(where: { HFRepoID.matches(identity, $0) })
        }
    }

    static func name(for identity: String, model: LibraryModel?) -> String {
        if let model { return model.displayName }
        if identity.isEmpty { return "Unknown model" }
        return HFRepoID.forPath(identity) ?? URL(fileURLWithPath: identity).lastPathComponent
    }

    /// A server holds weights unless it is a JIT endpoint with its model unloaded.
    static func isResident(_ server: ServerInfo) -> Bool {
        guard server.state?.lowercased() == "running" else { return false }
        return !(server.jit == true && server.modelState == "unloaded")
    }
}

// MARK: - Runway

/// Pure math behind the memory runway. Domain is total memory; resident
/// estimates sit inside the in-use span, then the reserve, then the budget
/// with the selected model's estimate as its leading span.
struct RunRunway: Equatable {
    enum Kind: Equatable {
        case resident, otherInUse, reserve, next, free
    }

    struct Segment: Equatable, Identifiable {
        let id: String
        let kind: Kind
        let name: String
        let bytes: Int64
        let fraction: Double
    }

    struct Resident: Equatable, Identifiable {
        let id: String
        let name: String
        /// Weights, KV cache and runtime overhead at the shared context; nil when unknown.
        let neededBytes: Int64?
        let unknownReason: String?
    }

    let budget: ModelBudgetPresentation
    let segments: [Segment]
    let unknownResidents: [Resident]
    let nextName: String?

    var isLive: Bool { budget.reading == .live }

    /// Under the bar: total memory and context. The reserve is named once, in the legend.
    var caption: String {
        guard let total = budget.totalBytes else { return "Unified memory size unknown" }
        return "of \(ModelBudgetPresentation.gb(total)) GB unified memory · \(budget.contextText)"
    }

    /// The end figure's caption: what is left once the reserve is held back.
    static let budgetCaption = "GB after reserve"

    /// Legend name; the reserve uses the budget owner's label.
    func legendName(_ segment: Segment) -> String {
        segment.kind == .reserve ? budget.reserveLabel : segment.name
    }

    /// Legend size, estimate-marked; the reserve's size is already in its label.
    func legendSize(_ segment: Segment) -> String? {
        segment.kind == .reserve ? nil : "~" + ModelBudgetPresentation.gb(segment.bytes) + " GB"
    }

    init(memory: MemorySnapshot?, hasProbed: Bool, reserveGB: Double, contextTokens: Int,
         hardware: HardwareProfile, residents: [Resident],
         next: ModelBudgetPresentation.Subject?, nextName: String?) {
        budget = ModelBudgetPresentation(
            memory: memory, reserveGB: reserveGB, contextTokens: contextTokens,
            subject: next, hardware: hardware, hasProbed: hasProbed
        )
        self.nextName = nextName
        unknownResidents = residents.filter { $0.neededBytes == nil }
        guard let memory, memory.totalBytes > 0, let budgetBytes = budget.budgetBytes else {
            segments = []
            return
        }
        let total = Double(memory.totalBytes)
        let inUse = max(0, memory.totalBytes - memory.availableBytes)
        let reserve = min(Int64(max(0, reserveGB) * 1e9), memory.availableBytes)
        var built: [Segment] = []
        var claimed: Int64 = 0
        for resident in residents {
            guard let needed = resident.neededBytes, needed > 0 else { continue }
            let shown = min(needed, inUse - claimed)
            guard shown > 0 else { continue }
            claimed += shown
            built.append(Segment(id: "resident-\(resident.id)", kind: .resident, name: resident.name,
                                 bytes: shown, fraction: Double(shown) / total))
        }
        let other = inUse - claimed
        if other > 0 {
            built.append(Segment(id: "other", kind: .otherInUse, name: "Other in use", bytes: other, fraction: Double(other) / total))
        }
        if reserve > 0 {
            built.append(Segment(id: "reserve", kind: .reserve, name: "Reserve", bytes: reserve, fraction: Double(reserve) / total))
        }
        var nextShown: Int64 = 0
        if case .estimated = budget.fit, let needed = budget.neededBytes {
            nextShown = min(needed, budgetBytes)
            if nextShown > 0 {
                built.append(Segment(id: "next", kind: .next, name: nextName ?? "Selected model",
                                     bytes: nextShown, fraction: Double(nextShown) / total))
            }
        }
        let free = budgetBytes - nextShown
        if free > 0 {
            built.append(Segment(id: "free", kind: .free, name: "Free", bytes: free, fraction: Double(free) / total))
        }
        segments = built
    }

    /// Residents from the running servers, sized from the Library through the shared estimate.
    static func residents(servers: [ServerInfo], models: [LibraryModel], contextTokens: Int) -> [Resident] {
        servers.filter(RunModels.isResident).map { server in
            let identity = server.modelIdentity
            let model = RunModels.model(for: identity, in: models)
            let name = RunModels.name(for: identity, model: model)
            let id = "\(identity)-\(server.port.map(String.init) ?? "")"
            guard let model else {
                return Resident(id: id, name: name, neededBytes: nil, unknownReason: "not in the Library")
            }
            guard model.item.bytes > 0 else {
                return Resident(id: id, name: name, neededBytes: nil, unknownReason: "size unavailable")
            }
            let needed = FitAdvisor.neededBytes(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters)
            return Resident(id: id, name: name, neededBytes: needed, unknownReason: nil)
        }
    }

    /// Segment widths for a bar `barWidth` wide. Known resident and next spans keep
    /// `minimum` points, taken from free; nothing is widened beyond its estimate otherwise.
    func widths(barWidth: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let raw = segments.map { CGFloat($0.fraction) * barWidth }
        var widths = raw
        var borrowed: CGFloat = 0
        for index in segments.indices where [.resident, .next].contains(segments[index].kind) && raw[index] < minimum {
            widths[index] = minimum
            borrowed += minimum - raw[index]
        }
        if borrowed > 0, let free = segments.firstIndex(where: { $0.kind == .free }) {
            let taken = min(borrowed, widths[free])
            widths[free] -= taken
            borrowed -= taken
        }
        let sum = widths.reduce(0, +)
        if borrowed > 0 || sum > barWidth, sum > 0 {
            let scale = barWidth / sum
            widths = widths.map { $0 * scale }
        }
        return widths
    }

    /// Labels sit under their segments only when every labelled segment is at least `minimum` wide.
    func labelsFitUnderSegments(widths: [CGFloat], minimum: CGFloat) -> Bool {
        let labelled = segments.indices.filter { [.resident, .next].contains(segments[$0].kind) }
        return !labelled.isEmpty && labelled.allSatisfy { widths[$0] >= minimum }
    }
}

// MARK: - Fleet and slots

enum RunFleet {
    enum SlotFit: Equatable {
        case resident
        case verdict(FitVerdict)
    }

    /// Whether the slot's port currently holds a loaded server.
    static func isResident(_ slot: EndpointSlot, servers: [ServerInfo]) -> Bool {
        servers.contains { $0.port == slot.port && RunModels.isResident($0) }
    }

    /// Fit of one slot's model against the shared snapshot; a resident slot is already
    /// counted in the in-use span, so it reports residency instead of a verdict.
    static func slotFit(_ slot: EndpointSlot, servers: [ServerInfo], models: [LibraryModel],
                        memory: MemorySnapshot?, hardware: HardwareProfile, contextTokens: Int, reserveGB: Double) -> SlotFit? {
        guard !slot.modelPath.isEmpty else { return nil }
        if isResident(slot, servers: servers) { return .resident }
        guard let model = RunModels.model(for: slot.modelPath, in: models) else {
            return .verdict(.unknown(reason: "model not in the Library"))
        }
        return .verdict(ComparisonInsights.fitEstimate(
            model: model, hardware: hardware, memory: memory, contextTokens: contextTokens, reserveGB: reserveGB
        ))
    }

    /// Summed verdict over enabled slots that are not yet resident, plus an optional
    /// candidate; nil when nothing is left to load. Unknown memory is unknown.
    static func verdict(slots: [EndpointSlot], servers: [ServerInfo], models: [LibraryModel], adding: String?,
                        memory: MemorySnapshot?, contextTokens: Int, reserveGB: Double) -> FitVerdict? {
        var paths = slots
            .filter { $0.enabled && !$0.modelPath.isEmpty && !isResident($0, servers: servers) }
            .map(\.modelPath)
        if let adding { paths.append(adding) }
        guard !paths.isEmpty else { return nil }
        guard let memory else { return .unknown(reason: "live memory unavailable") }
        let estimates = paths.map { path -> FleetFitAdvisor.Estimate in
            guard let model = RunModels.model(for: path, in: models),
                  ComparisonInsights.supportsFitEstimate(model),
                  model.item.bytes > 0 else { return .unknown }
            return .known(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters)
        }
        return FleetFitAdvisor.verdict(
            estimates: estimates,
            availableBytes: memory.availableBytes,
            reserveBytes: Int64(max(0, reserveGB) * 1e9)
        )
    }
}

// MARK: - Layout

/// Run's width thresholds, derived from the width the page is offered, never from its content.
struct RunLayout: Equatable {
    let innerWidth: CGFloat
    let isCompact: Bool
    let isTwoLine: Bool

    /// `viewportWidth` is the scroll area's width; page insets and surface chrome come off it.
    init(viewportWidth: CGFloat, pageInset: CGFloat = WorkbenchSpacing.pageInset) {
        let page = min(max(viewportWidth - pageInset * 2, 0), WorkbenchSize.Run.contentMaxWidth)
        innerWidth = page - WorkbenchSize.Run.surfaceChrome
        isCompact = innerWidth < WorkbenchSize.Run.compactThreshold
        isTwoLine = innerWidth < WorkbenchSize.Run.rowThreshold
    }
}
