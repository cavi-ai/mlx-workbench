import SwiftUI

// MARK: - Layout

/// Overview layout modes, derived from the measured content width (detail
/// column width minus the page gutters). Thresholds live in `WorkbenchSize`.
enum OverviewLayoutMode: Equatable {
    case compact
    case regular
    case wide

    init(contentWidth: CGFloat) {
        if contentWidth >= WorkbenchSize.twoColumnMinimum {
            self = .wide
        } else if contentWidth >= WorkbenchSize.heroRowMinimum {
            self = .regular
        } else {
            self = .compact
        }
    }

    /// The instrument and the Next Step panel share a row.
    var heroIsSideBySide: Bool { self != .compact }

    /// Watch alerts and recommendations sit in two columns.
    var usesTwoColumnLowerRow: Bool { self == .wide }

    static func showsTileCaptions(contentWidth: CGFloat) -> Bool {
        contentWidth >= WorkbenchSize.tileCaptionsMinimum
    }

    static func showsStageState(contentWidth: CGFloat) -> Bool {
        contentWidth >= WorkbenchSize.stageStateMinimum
    }

    static func showsBarLabels(instrumentWidth: CGFloat) -> Bool {
        instrumentWidth >= WorkbenchSize.barLabelsMinimum
    }

    static func foldsAlertActions(rowWidth: CGFloat) -> Bool {
        rowWidth < WorkbenchSize.alertRowMinimum
    }
}

struct OverviewContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = WorkbenchSize.assumedContentWidth

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Model budget

/// Pure math behind the Model Budget instrument. Budget is the available
/// memory estimate minus the configured reserve, clamped at zero; the fit
/// verdict comes from `ComparisonInsights.fitEstimate` with the same reserve
/// and context the Run tab uses. All sizes are decimal GB.
struct ModelBudgetPresentation: Equatable {
    enum Tone: Equatable {
        case neutral, fits, tight, wontFit
    }

    enum Fit: Equatable {
        case noModel
        case notEstimated(String)
        case estimated(FitVerdict)
    }

    struct Segments: Equatable {
        let inUse: Double
        let reserve: Double
        let budget: Double
    }

    let totalBytes: Int64?
    let availableBytes: Int64?
    let budgetBytes: Int64?
    let reserveGB: Double
    let contextTokens: Int
    let segments: Segments?
    let markerFraction: Double?
    let fit: Fit
    let reading: Reading

    /// What the lead region shows: a placeholder before the first probe,
    /// the unavailable state after a failed probe, or the live budget.
    enum Reading: Equatable {
        case loading, unavailable, live
    }

    init(memory: MemorySnapshot?, reserveGB: Double, contextTokens: Int, model: LibraryModel?, hardware: HardwareProfile, hasProbed: Bool = true) {
        let reserve = max(0, reserveGB)
        if memory != nil {
            reading = .live
        } else {
            reading = hasProbed ? .unavailable : .loading
        }
        let reserveBytes = Int64(reserve * 1e9)
        self.reserveGB = reserve
        self.contextTokens = contextTokens

        if let memory, memory.totalBytes > 0 {
            let total = Double(memory.totalBytes)
            let budget = max(0, memory.availableBytes - reserveBytes)
            let reserved = min(reserveBytes, memory.availableBytes)
            totalBytes = memory.totalBytes
            availableBytes = memory.availableBytes
            budgetBytes = budget
            segments = Segments(
                inUse: Double(memory.unavailableBytes) / total,
                reserve: Double(reserved) / total,
                budget: Double(budget) / total
            )
        } else {
            totalBytes = hardware.memoryBytes
            availableBytes = nil
            budgetBytes = nil
            segments = nil
        }

        guard let model else {
            fit = .noModel
            markerFraction = nil
            return
        }
        guard ComparisonInsights.supportsFitEstimate(model) else {
            let type = model.item.task?.type.title.lowercased() ?? "these"
            fit = .notEstimated("Fit not estimated for \(type) models")
            markerFraction = nil
            return
        }
        guard model.item.bytes > 0 else {
            fit = .notEstimated("Fit not estimated: model size unavailable")
            markerFraction = nil
            return
        }
        let verdict = ComparisonInsights.fitEstimate(
            model: model,
            hardware: hardware,
            memory: memory,
            contextTokens: contextTokens,
            reserveGB: reserve
        )
        if case .unknown(let reason) = verdict {
            fit = .notEstimated("Fit not estimated: \(reason)")
            markerFraction = nil
            return
        }
        fit = .estimated(verdict)
        if let segments, let budgetBytes, let totalBytes {
            let needed = FitAdvisor.neededBytes(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters)
            let used = Double(min(needed, budgetBytes)) / Double(totalBytes)
            markerFraction = min(1, max(0, segments.inUse + segments.reserve + used))
        } else {
            markerFraction = nil
        }
    }

    var hasReading: Bool { segments != nil }

    /// "~12.4": the lead numeral, estimate-marked.
    var leadText: String? {
        budgetBytes.map { "~" + Self.gb($0) }
    }

    var unitText: String { "GB" }

    var contextText: String { "\(Self.tokens(contextTokens))-token context" }

    var reserveText: String { String(format: "%g", reserveGB) }

    var caption: String {
        if let totalBytes, hasReading {
            return "of \(Self.gb(totalBytes)) GB unified memory · \(reserveText) GB reserve · \(contextText)"
        }
        if let totalBytes {
            return "\(Self.gb(totalBytes)) GB unified memory · \(reserveText) GB reserve"
        }
        return "Unified memory size unknown · \(reserveText) GB reserve"
    }

    /// Caption when the instrument is narrow: the context clause drops.
    var compactCaption: String {
        if let totalBytes {
            return "of \(Self.gb(totalBytes)) GB · \(reserveText) GB reserve"
        }
        return "\(reserveText) GB reserve"
    }

    var unavailableText: String { "Memory reading unavailable" }

    var inUseLabel: String { availableBytes != nil ? "In use \(Self.gb(inUseBytes)) GB" : "In use" }
    var reserveLabel: String { "Reserve \(reserveText) GB" }
    var budgetLabel: String { budgetBytes.map { "Budget \(Self.gb($0)) GB" } ?? "Budget" }

    struct SegmentLabel: Equatable {
        let text: String
        let leadingFraction: Double
    }

    static let placeholderLead = "~00.0"

    static let placeholderLabels: [SegmentLabel] = [
        SegmentLabel(text: "In use 00.0 GB", leadingFraction: 0),
        SegmentLabel(text: "Reserve 0 GB", leadingFraction: 0.4),
        SegmentLabel(text: "Budget 00.0 GB", leadingFraction: 0.5),
    ]

    /// Value labels, each anchored at its own segment's leading edge.
    var segmentLabels: [SegmentLabel] {
        guard let segments else { return [] }
        return [
            SegmentLabel(text: inUseLabel, leadingFraction: 0),
            SegmentLabel(text: reserveLabel, leadingFraction: segments.inUse),
            SegmentLabel(text: budgetLabel, leadingFraction: segments.inUse + segments.reserve),
        ]
    }

    private var inUseBytes: Int64 {
        guard let totalBytes, let availableBytes else { return 0 }
        return max(0, totalBytes - availableBytes)
    }

    var verdictText: String {
        switch fit {
        case .noModel:
            return "Select a model in Library to check fit."
        case .notEstimated(let sentence):
            return sentence
        case .estimated(let verdict):
            switch verdict {
            case .fits(let headroom):
                return "Fits with \(Self.gb(headroom)) GB to spare"
            case .tight(let headroom):
                return "Tight: \(Self.gb(headroom)) GB to spare"
            case .wontFit(let deficit, let suggestion):
                var text = "Won't fit: \(Self.gb(deficit)) GB short"
                if let suggestion { text += "; \(Self.tokens(suggestion)) tokens would fit" }
                return text
            case .unknown(let reason):
                return "Fit not estimated: \(reason)"
            }
        }
    }

    var tone: Tone {
        guard case .estimated(let verdict) = fit else { return .neutral }
        switch verdict {
        case .fits: return .fits
        case .tight: return .tight
        case .wontFit: return .wontFit
        case .unknown: return .neutral
        }
    }

    var verdictSymbol: String {
        switch tone {
        case .fits: return "checkmark.circle"
        case .tight: return "exclamationmark.triangle"
        case .wontFit: return "xmark.octagon"
        case .neutral: return "questionmark.circle"
        }
    }

    private var spokenVerdict: String {
        var text = verdictText.lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    var accessibilityLabel: String {
        switch reading {
        case .loading:
            return "Model budget: reading memory, \(reserveText) GB reserve"
        case .unavailable:
            return "Model budget: memory reading unavailable, \(reserveText) GB reserve, \(spokenVerdict)"
        case .live:
            guard let budgetBytes, let totalBytes, let availableBytes else { return "Model budget" }
            return "Model budget about \(Self.gb(budgetBytes)) GB: \(Self.gb(availableBytes)) GB available minus \(reserveText) GB reserve of \(Self.gb(totalBytes)) GB unified memory at \(contextText), \(spokenVerdict)."
        }
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }
    static func gb(_ value: Double) -> String { String(format: "%.1f", value) }

    static func tokens(_ count: Int) -> String {
        count > 0 && count % 1024 == 0 ? "\(count / 1024)K" : "\(count)"
    }
}

private struct SegmentLeadingKey: LayoutValueKey {
    static let defaultValue: Double = 0
}

private extension View {
    func segmentLeading(_ fraction: Double) -> some View {
        layoutValue(key: SegmentLeadingKey.self, value: fraction)
    }
}

/// Places each label at its segment's leading edge; a label never overlaps
/// the one before it and never leaves the row.
struct SegmentLabelsLayout: Layout {
    /// Left edges for labels wanting `desired` positions, in order.
    static func origins(desired: [CGFloat], widths: [CGFloat], total: CGFloat, gap: CGFloat) -> [CGFloat] {
        var cursor: CGFloat = 0
        var result: [CGFloat] = []
        for (want, width) in zip(desired, widths) {
            let x = min(max(want, cursor), max(0, total - width))
            result.append(x)
            cursor = x + width + gap
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let desired = subviews.map { bounds.width * CGFloat($0[SegmentLeadingKey.self]) }
        let xs = Self.origins(desired: desired, widths: sizes.map(\.width), total: bounds.width, gap: WorkbenchSpacing.sm)
        for (subview, x) in zip(subviews, xs) {
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        }
    }
}

/// Capacity bar: in use, reserve and budget on a recessed track, with the
/// selected model's footprint marked from the start of the budget segment.
struct CapacityBar: View {
    let presentation: ModelBudgetPresentation

    private var markerColor: Color { WorkbenchColor.ink }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous)
                        .fill(WorkbenchColor.well)
                    if let segments = presentation.segments {
                        let parts: [(fraction: Double, color: Color)] = [
                            (segments.inUse, WorkbenchColor.muted.opacity(.stroke)),
                            (segments.reserve, WorkbenchColor.muted.opacity(.fill)),
                            (segments.budget, WorkbenchColor.accent),
                        ].filter { $0.fraction > 0 }
                        let usable = max(0, width - WorkbenchSize.barGap * CGFloat(max(0, parts.count - 1)))
                        HStack(spacing: WorkbenchSize.barGap) {
                            ForEach(parts.indices, id: \.self) { index in
                                RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous)
                                    .fill(parts[index].color)
                                    .frame(width: usable * parts[index].fraction)
                            }
                        }
                    }
                }
                .frame(height: WorkbenchSize.barHeight)
                if let marker = presentation.markerFraction {
                    RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous)
                        .fill(markerColor)
                        .frame(width: WorkbenchSize.markerWidth, height: WorkbenchSize.barHeight + WorkbenchSize.markerOverhang * 2)
                        .offset(x: max(0, min(width - WorkbenchSize.markerWidth, width * marker - WorkbenchSize.markerWidth / 2)))
                }
            }
            .workbenchAnimation(WorkbenchMotion.standard, value: presentation.segments)
            .workbenchAnimation(WorkbenchMotion.standard, value: presentation.markerFraction)
        }
        .frame(height: WorkbenchSize.barHeight + WorkbenchSize.markerOverhang * 2)
        .accessibilityHidden(true)
    }
}

/// The one view that observes the live memory monitor; the page around it
/// does not re-evaluate on each reading.
struct ModelBudgetInstrument: View {
    @ObservedObject var resources: SystemResourceMonitor
    let reserveGB: Double
    let model: LibraryModel?
    let hardware: HardwareProfile

    private var presentation: ModelBudgetPresentation {
        ModelBudgetPresentation(
            memory: resources.memory,
            reserveGB: reserveGB,
            contextTokens: resources.contextTokens,
            model: model,
            hardware: hardware,
            hasProbed: resources.hasProbed
        )
    }

    var body: some View {
        let budget = presentation
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Label("Model budget", systemImage: "memorychip")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                    .symbolRenderingMode(.hierarchical)
                lead(budget)
                ViewThatFits(in: .horizontal) {
                    Text(budget.caption)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(budget.compactCaption)
                }
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                CapacityBar(presentation: budget)
                if budget.reading != .unavailable {
                    ViewThatFits(in: .horizontal) {
                        segmentValues(budget)
                            .frame(minWidth: WorkbenchSize.barLabelsMinimum - WorkbenchSpacing.surfaceInset * 2, alignment: .leading)
                        EmptyView()
                    }
                }
                verdictLine(budget)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(budget.accessibilityLabel)
    }

    @ViewBuilder
    private func lead(_ budget: ModelBudgetPresentation) -> some View {
        if budget.reading != .unavailable {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                Text(budget.leadText ?? ModelBudgetPresentation.placeholderLead)
                    .font(WorkbenchTypography.hero)
                    .foregroundStyle(WorkbenchColor.accent)
                    .contentTransition(.numericText())
                    .redacted(reason: budget.reading == .loading ? .placeholder : [])
                Text(budget.unitText)
                    .font(WorkbenchTypography.body)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            .workbenchAnimation(value: budget.budgetBytes)
        } else {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "memorychip")
                    .font(WorkbenchTypography.display)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WorkbenchColor.muted)
                Text(budget.unavailableText)
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.ink)
            }
        }
    }

    private func segmentValues(_ budget: ModelBudgetPresentation) -> some View {
        SegmentLabelsLayout {
            ForEach(budget.reading == .loading ? ModelBudgetPresentation.placeholderLabels : budget.segmentLabels, id: \.text) { label in
                Text(label.text)
                    .lineLimit(1)
                    .segmentLeading(label.leadingFraction)
            }
        }
        .redacted(reason: budget.reading == .loading ? .placeholder : [])
        .font(WorkbenchTypography.metadata)
        .foregroundStyle(WorkbenchColor.muted)
    }

    private func verdictLine(_ budget: ModelBudgetPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Image(systemName: budget.verdictSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(toneColor(budget.tone))
            Text(budget.verdictText)
                .font(WorkbenchTypography.body)
                .foregroundStyle(budget.tone == .neutral ? WorkbenchColor.muted : WorkbenchColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toneColor(_ tone: ModelBudgetPresentation.Tone) -> Color {
        switch tone {
        case .neutral: return WorkbenchColor.muted
        case .fits: return WorkbenchColor.accent
        case .tight: return WorkbenchColor.warning
        case .wontFit: return WorkbenchColor.failure
        }
    }
}

// MARK: - Next step

struct NextStepPanel: View {
    let action: HomeNextAction
    let perform: () -> Void

    var body: some View {
        WorkbenchSurface(.tinted) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Label("Next step", systemImage: "arrow.forward.circle")
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(WorkbenchColor.accent)
                    .symbolRenderingMode(.hierarchical)
                Text(action.title)
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(action.reason)
                    .font(WorkbenchTypography.body)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: WorkbenchSpacing.xs)
                Button(action.buttonTitle, action: perform)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(action.title)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Flight path

enum ModelFlightStageTone: Equatable {
    case neutral, accent, warning, failure
}

extension ModelFlightStageState {
    var tone: ModelFlightStageTone {
        switch self {
        case .pending: return .neutral
        case .active, .complete: return .accent
        case .attention: return .warning
        case .failed: return .failure
        }
    }

    var color: Color {
        switch tone {
        case .neutral: return WorkbenchColor.muted
        case .accent: return WorkbenchColor.accent
        case .warning: return WorkbenchColor.warning
        case .failure: return WorkbenchColor.failure
        }
    }
}

extension ModelFlightPathPresentation {
    /// Index of the last complete stage; the track fills with accent up to it.
    var lastCompleteIndex: Int? {
        stages.lastIndex { $0.state == .complete }
    }
}

struct FlightPathPanel: View {
    let model: LibraryModel?
    let flightPath: ModelFlightPathPresentation
    let showsStateText: Bool
    let chooseModel: () -> Void

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                header
                if model == nil {
                    emptyState
                } else {
                    stepper
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Flight path")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            if let model {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.md) {
                    Text(model.displayName)
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let path = flightPath.modelPath {
                        Text(path)
                            .font(WorkbenchTypography.compactValue)
                            .foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: WorkbenchSpacing.md) {
            Image(systemName: "books.vertical")
                .font(WorkbenchTypography.display)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WorkbenchColor.muted)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text("No model selected")
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.ink)
                Text("Choose a model in Library to see how far it has come.")
                    .font(WorkbenchTypography.body)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            Spacer(minLength: WorkbenchSpacing.md)
            Button("Choose in Library", action: chooseModel)
                .buttonStyle(.bordered)
        }
    }

    private var stepper: some View {
        let lastComplete = flightPath.lastCompleteIndex
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(flightPath.stages.enumerated()), id: \.element.id) { index, item in
                stageColumn(item, index: index, count: flightPath.stages.count, lastComplete: lastComplete)
            }
        }
        .workbenchAnimation(WorkbenchMotion.standard, value: lastComplete)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model flight path")
    }

    private func stageColumn(_ item: ModelFlightStagePresentation, index: Int, count: Int, lastComplete: Int?) -> some View {
        let filledLeft = lastComplete.map { index <= $0 } ?? false
        let filledRight = lastComplete.map { index < $0 } ?? false
        return VStack(spacing: WorkbenchSpacing.xs) {
            HStack(spacing: 0) {
                track(filled: filledLeft, visible: index > 0)
                node(item)
                track(filled: filledRight, visible: index < count - 1)
            }
            Text(item.stage.title)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.ink)
                .lineLimit(1)
            if showsStateText {
                Text(item.state.label)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(item.state.tone == .neutral || item.state.tone == .accent ? WorkbenchColor.muted : item.state.color)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .help(item.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.stage.title + ": " + item.state.label + ". " + item.detail)
    }

    private func track(filled: Bool, visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? (filled ? WorkbenchColor.accent : WorkbenchColor.hairline) : Color.clear)
            .frame(height: WorkbenchSize.stageTrack)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func node(_ item: ModelFlightStagePresentation) -> some View {
        let symbol = Image(systemName: item.stage.symbolName)
            .font(WorkbenchTypography.emphasis)
            .symbolRenderingMode(.hierarchical)
        switch item.state {
        case .complete:
            symbol
                .foregroundStyle(WorkbenchColor.onAccent)
                .frame(width: WorkbenchSize.stageNode, height: WorkbenchSize.stageNode)
                .background(WorkbenchColor.accent, in: Circle())
        case .active:
            symbol
                .foregroundStyle(item.state.color)
                .frame(width: WorkbenchSize.stageNode, height: WorkbenchSize.stageNode)
                .background(item.state.color.opacity(.fill), in: Circle())
                .overlay { Circle().strokeBorder(item.state.color, lineWidth: WorkbenchSize.stageTrack) }
                .livePulse(true)
        case .pending, .attention, .failed:
            symbol
                .foregroundStyle(item.state.color)
                .frame(width: WorkbenchSize.stageNode, height: WorkbenchSize.stageNode)
                .background(item.state.tone == .neutral ? Color.clear : item.state.color.opacity(.fill), in: Circle())
                .overlay { Circle().strokeBorder(item.state.color, lineWidth: WorkbenchSize.stageTrack) }
        }
    }
}

// MARK: - Library strip

/// Values and captions for the three Library strip tiles.
struct LibraryStripPresentation: Equatable {
    struct Tile: Equatable {
        let name: String
        let symbol: String
        let value: String
        let caption: String
        let destination: String
    }

    let tiles: [Tile]

    init(snapshot: LibrarySnapshot?, rootCount: Int, reclaimableBytes: Int64, runs: [ComparisonRun], now: Date = Date()) {
        let models = snapshot.map { String($0.models.count) } ?? "None"
        let roots = rootCount == 1 ? "in 1 root" : "in \(rootCount) roots"
        let disk = snapshot.map { Self.gb($0.totalBytes) } ?? "None"
        let completed = runs.filter { $0.state == .completed }
        let last = completed.map { $0.finishedAt ?? $0.startedAt }.max()
        let lastCaption: String
        if let last {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            lastCaption = "Last " + formatter.localizedString(for: last, relativeTo: now)
        } else {
            lastCaption = "None yet"
        }
        tiles = [
            Tile(name: "Models", symbol: "books.vertical", value: models, caption: snapshot == nil ? "No scan yet" : roots, destination: "Library"),
            Tile(name: "On disk", symbol: "internaldrive", value: disk, caption: reclaimableBytes > 0 ? "\(Self.gb(reclaimableBytes)) reclaimable" : "Nothing to reclaim", destination: "Reclaim"),
            Tile(name: "Comparisons", symbol: "chart.bar", value: String(completed.count), caption: lastCaption, destination: "Compare"),
        ]
    }

    static func gb(_ bytes: Int64) -> String { ModelBudgetPresentation.gb(bytes) + " GB" }
}

struct OverviewTile: View {
    let tile: LibraryStripPresentation.Tile
    let showsCaption: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            WorkbenchSurface(padding: WorkbenchSpacing.sm) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Label(tile.name, systemImage: tile.symbol)
                        .font(WorkbenchTypography.label)
                        .foregroundStyle(WorkbenchColor.muted)
                        .symbolRenderingMode(.hierarchical)
                    Text(tile.value)
                        .font(WorkbenchTypography.display)
                        .foregroundStyle(WorkbenchColor.ink)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    if showsCaption {
                        Text(tile.caption)
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous)
                    .fill(isHovering ? WorkbenchColor.accent.opacity(.fill) : Color.clear)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minWidth: WorkbenchSize.tileMinimum)
        .onHover { isHovering = $0 }
        .workbenchAnimation(value: isHovering)
        .workbenchAnimation(value: tile.value)
        .help(tile.caption)
        .accessibilityLabel("\(tile.name): \(tile.value), opens \(tile.destination)")
        .accessibilityValue(tile.caption)
    }
}

struct LibraryStrip: View {
    let presentation: LibraryStripPresentation
    let showsCaptions: Bool
    let open: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            ForEach(Array(presentation.tiles.enumerated()), id: \.offset) { index, tile in
                OverviewTile(tile: tile, showsCaption: showsCaptions) { open(index) }
            }
        }
    }
}

// MARK: - Watch alerts

struct WatchAlertsPanel: View {
    let alerts: [WatchAlert]
    let onAction: (WatchAlertPresentation.ActionKind, WatchAlert) -> Void
    let onSnooze: (WatchAlert) -> Void
    let onMute: (WatchAlert) -> Void
    @State private var showsAll = false

    private var visible: [WatchAlert] { showsAll ? alerts : Array(alerts.prefix(OverviewLimits.visibleAlerts)) }

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                    Label("Watch alerts", systemImage: "bell.badge")
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.ink)
                        .symbolRenderingMode(.hierarchical)
                    Text("\(alerts.count)")
                        .font(WorkbenchTypography.secondary.monospacedDigit())
                        .foregroundStyle(WorkbenchColor.muted)
                }
                ForEach(visible) { alert in
                    row(alert)
                }
                if alerts.count > OverviewLimits.visibleAlerts {
                    Button(showsAll ? "Show fewer" : "Show all \(alerts.count)") { showsAll.toggle() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func row(_ alert: WatchAlert) -> some View {
        let presentation = WatchAlertPresentation(alert: alert)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.sm) {
                title(presentation)
                if let primary = presentation.primary {
                    Button(primary.title) { onAction(primary.kind, alert) }
                        .buttonStyle(.borderless)
                }
                Button("Snooze") { onSnooze(alert) }
                    .buttonStyle(.borderless)
                Button(presentation.muteTitle) { onMute(alert) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            .frame(minWidth: WorkbenchSize.alertRowMinimum - WorkbenchSpacing.surfaceInset * 2)
            HStack(spacing: WorkbenchSpacing.sm) {
                title(presentation)
                if let primary = presentation.primary {
                    Button(primary.title) { onAction(primary.kind, alert) }
                        .buttonStyle(.borderless)
                }
                Menu {
                    Button("Snooze 7 days") { onSnooze(alert) }
                    Button(presentation.muteTitle) { onMute(alert) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions for \(presentation.title)")
            }
        }
    }

    private func title(_ presentation: WatchAlertPresentation) -> some View {
        Text(presentation.title)
            .font(WorkbenchTypography.body)
            .foregroundStyle(WorkbenchColor.ink)
            .lineLimit(1)
            .frame(idealWidth: WorkbenchSize.alertTitleIdeal, maxWidth: .infinity, alignment: .leading)
            .help(presentation.message)
    }
}

enum OverviewLimits {
    static let visibleAlerts = 5
}

// MARK: - Recommendations

struct OverviewRecommendationRow: Identifiable, Equatable {
    let useCase: String
    let modelName: String
    let confidence: String
    let reason: String
    var id: String { useCase }
}

struct RecommendationsPanel: View {
    let rows: [OverviewRecommendationRow]

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Recommended models")
                Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.md, verticalSpacing: WorkbenchSpacing.xs) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.useCase)
                                .font(WorkbenchTypography.label)
                                .foregroundStyle(WorkbenchColor.muted)
                            Text(row.modelName)
                                .font(WorkbenchTypography.body)
                                .foregroundStyle(WorkbenchColor.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .gridColumnAlignment(.leading)
                            StatusBadge(state: row.confidence)
                                .gridColumnAlignment(.trailing)
                        }
                        .help(row.reason)
                    }
                }
            }
        }
    }
}
