import SwiftUI

// Run's memory-observing subviews. Each takes the shared monitor and reads
// `memory` and `contextTokens` from it; no other Run view observes it.

extension FitVerdict {
    var runTone: ModelBudgetPresentation.Tone {
        switch self {
        case .fits: return .fits
        case .tight: return .tight
        case .wontFit: return .wontFit
        case .unknown: return .neutral
        }
    }

    var runWord: String {
        switch self {
        case .fits: return "Fits"
        case .tight: return "Tight"
        case .wontFit: return "Won't fit"
        case .unknown: return "Unknown"
        }
    }

    var runSymbol: String {
        switch self {
        case .fits: return "checkmark.circle"
        case .tight: return "exclamationmark.triangle"
        case .wontFit: return "xmark.octagon"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension AppHost {
    /// Fleet verdict for the enabled, not-yet-resident slots plus an optional candidate,
    /// read from the shared monitor at the moment of an action.
    func runFleetVerdict(adding: String?) -> FitVerdict? {
        RunFleet.verdict(
            slots: endpoint.fleet.slots,
            servers: modelWorkflow.servers,
            models: librarySnapshot?.models ?? [],
            adding: adding,
            memory: resources.memory,
            contextTokens: resources.contextTokens,
            reserveGB: config.fitReserveGB
        )
    }
}

// MARK: - Runway

struct RunRunwayView: View {
    @ObservedObject var resources: SystemResourceMonitor
    let servers: [ServerInfo]
    let models: [LibraryModel]
    let hardware: HardwareProfile
    let reserveGB: Double
    let nextModel: LibraryModel?
    let isCompact: Bool
    /// Read only to choose labels-under versus legend; no frame uses it.
    @State private var measuredBarWidth = WorkbenchSize.assumedContentWidth

    private var runway: RunRunway {
        RunRunway(
            memory: resources.memory,
            hasProbed: resources.hasProbed,
            reserveGB: reserveGB,
            contextTokens: resources.contextTokens,
            hardware: hardware,
            residents: RunRunway.residents(servers: servers, models: models, contextTokens: resources.contextTokens),
            next: nextModel.map { ModelBudgetPresentation.Subject(bytes: $0.item.bytes, parameters: $0.item.parameters, task: $0.item.task?.type) },
            nextName: nextModel?.displayName
        )
    }

    var body: some View {
        let runway = runway
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            header(runway)
            if runway.isLive {
                bar(runway)
                if let sentence = verdictSentence(runway) {
                    Text(sentence)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                ForEach(runway.unknownResidents) { resident in
                    Label("\(resident.name): size unknown (\(resident.unknownReason ?? "unavailable"))", systemImage: "questionmark.circle")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                Text(runway.caption)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                unavailable(runway)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(runway.budget.accessibilityLabel)
    }

    private func verdictSentence(_ runway: RunRunway) -> String? {
        guard case .estimated = runway.budget.fit else {
            if case .notEstimated(let sentence) = runway.budget.fit { return sentence }
            return nil
        }
        return runway.budget.verdictText
    }

    private func header(_ runway: RunRunway) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Memory runway")
            Spacer(minLength: WorkbenchSpacing.xs)
            if isCompact, runway.isLive { verdictCluster(runway) }
        }
    }

    private func verdictLabel(_ runway: RunRunway) -> some View {
        Group {
            if let word = runway.budget.verdictWord {
                Label(word, systemImage: runway.budget.verdictSymbol)
                    .font(WorkbenchTypography.emphasis)
                    .foregroundStyle(runway.budget.tone.color)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }

    /// Narrow layouts: verdict and one-line budget in the header.
    private func verdictCluster(_ runway: RunRunway) -> some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            verdictLabel(runway)
            if let lead = runway.budget.leadText {
                Text(verbatim: "\(lead) \(RunRunway.budgetCaption)")
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }

    /// Wide layouts: the budget as the page's display numeral at the bar's end.
    private func budgetFigure(_ runway: RunRunway) -> some View {
        VStack(alignment: .trailing, spacing: WorkbenchSpacing.xxxs) {
            verdictLabel(runway)
            if let lead = runway.budget.leadText {
                Text(verbatim: lead)
                    .font(WorkbenchTypography.display)
                    .foregroundStyle(WorkbenchColor.ink)
                Text(verbatim: RunRunway.budgetCaption)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private func unavailable(_ runway: RunRunway) -> some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Image(systemName: "memorychip").foregroundStyle(WorkbenchColor.muted)
            Text(runway.budget.reading == .loading
                 ? "Reading memory…"
                 : "Memory reading unavailable. Fit is not estimated until it returns.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    private func color(_ segment: RunRunway.Segment, runway: RunRunway) -> Color {
        switch segment.kind {
        case .resident: return WorkbenchColor.accent
        case .otherInUse: return WorkbenchColor.muted.opacity(.stroke)
        case .reserve: return WorkbenchColor.muted.opacity(.fill)
        case .next: return runway.budget.tone.color.opacity(.fill)
        case .free: return Color.clear
        }
    }

    private func bar(_ runway: RunRunway) -> some View {
        let widths: (CGFloat) -> [CGFloat] = { runway.widths(barWidth: $0, minimum: WorkbenchSize.Run.segmentMinimum) }
        let under = runway.labelsFitUnderSegments(
            widths: widths(measuredBarWidth), minimum: WorkbenchSize.Run.labelMinimum
        )
        let steps = runway.segments.map { Int($0.bytes / WorkbenchSize.Run.animationStepBytes) }
        return HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                RunSegmentsLayout(widths: widths) {
                    ForEach(Array(runway.segments.enumerated()), id: \.element.id) { _, segment in
                        Rectangle()
                            .fill(color(segment, runway: runway))
                            .overlay {
                                if segment.kind == .next {
                                    Rectangle().strokeBorder(runway.budget.tone.color, lineWidth: WorkbenchSize.Run.nextOutline)
                                }
                            }
                            .help([runway.legendName(segment), runway.legendSize(segment)].compactMap { $0 }.joined(separator: " "))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: WorkbenchSize.Run.heroBarHeight)
                .background(WorkbenchColor.well)
                .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous))
                .workbenchAnimation(value: steps)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: RunBarWidthKey.self, value: proxy.size.width)
                })
                if under {
                    RunSegmentsLayout(widths: widths) {
                        ForEach(Array(runway.segments.enumerated()), id: \.element.id) { _, segment in
                            Text(segmentLabel(segment))
                                .font(WorkbenchTypography.metadata)
                                .foregroundStyle(WorkbenchColor.muted)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    legend(runway)
                }
            }
            .onPreferenceChange(RunBarWidthKey.self) { if $0 > 0 { measuredBarWidth = $0 } }
            if !isCompact { budgetFigure(runway) }
        }
    }

    private func segmentLabel(_ segment: RunRunway.Segment) -> String {
        [.resident, .next].contains(segment.kind) ? "\(segment.name) \(ModelBudgetPresentation.gb(segment.bytes)) GB" : ""
    }

    private func legend(_ runway: RunRunway) -> some View {
        let items = runway.segments.filter { $0.kind != .free }
        return RunFlowLayout(spacing: WorkbenchSize.Run.legendSpacing, lineSpacing: WorkbenchSpacing.xxs) {
            ForEach(items) { segment in
                HStack(spacing: WorkbenchSpacing.xxs) {
                    Circle().fill(color(segment, runway: runway))
                        .frame(width: WorkbenchSize.Run.swatch, height: WorkbenchSize.Run.swatch)
                        .overlay { Circle().strokeBorder(WorkbenchColor.hairline, lineWidth: WorkbenchSpacing.hairline) }
                    Text(verbatim: runway.legendName(segment))
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(runway.legendName(segment))
                    if let size = runway.legendSize(segment) {
                        Text(verbatim: size)
                            .font(WorkbenchTypography.metadata)
                            .foregroundStyle(WorkbenchColor.muted)
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// Places its children side by side at the widths computed for the proposed width,
/// so the row always fits the space it is given and shrinks with it.
struct RunSegmentsLayout: Layout {
    let widths: (CGFloat) -> [CGFloat]

    /// Child spans for a total width; they tile the width and never exceed it.
    static func spans(width: CGFloat, widths: (CGFloat) -> [CGFloat]) -> [(x: CGFloat, width: CGFloat)] {
        let total = max(width, 0)
        let raw = widths(total).map { max($0, 0) }
        let sum = raw.reduce(0, +)
        let scale = sum > total && sum > 0 ? total / sum : 1
        var x: CGFloat = 0
        return raw.map { value in
            defer { x += value * scale }
            return (x, value * scale)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spans = Self.spans(width: bounds.width, widths: widths)
        for (subview, span) in zip(subviews, spans) {
            subview.place(
                at: CGPoint(x: bounds.minX + span.x, y: bounds.minY),
                proposal: ProposedViewSize(width: span.width, height: bounds.height)
            )
        }
    }
}

/// Wraps its children into rows sized to their content.
private struct RunFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    private struct Arrangement {
        var size = CGSize.zero
        var frames: [CGRect] = []
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        var result = Arrangement()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if width.isFinite, size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            result.frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            result.size.width = max(result.size.width, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        result.size.height = y + rowHeight
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// The bar column's measured width; 0 until measured, so siblings that report nothing never win.
private struct RunBarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Context

/// Fit-only context, bound to the toolbar's shared value; it is never passed to serve.
struct RunContextControl: View {
    @ObservedObject var resources: SystemResourceMonitor
    let model: LibraryModel?
    let hardware: HardwareProfile
    let reserveGB: Double

    private var verdict: FitVerdict? {
        guard let model, ModelTaskPresentation.isServable(model) else { return nil }
        return ComparisonInsights.fitEstimate(
            model: model, hardware: hardware, memory: resources.memory,
            contextTokens: resources.contextTokens, reserveGB: reserveGB
        )
    }

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Picker("Context for fit", selection: $resources.contextTokens) {
                ForEach(SystemResourceMonitor.contextOptions, id: \.self) { tokens in
                    Text(RunContext.title(tokens)).tag(tokens)
                }
            }
            .frame(width: WorkbenchSize.Run.contextWidth)
            .help("Fit estimates only; the server's own context limit is not changed.")
            if let suggestion = RunContext.suggestion(from: verdict) {
                Button("Use \(RunContext.title(suggestion)) instead") {
                    resources.contextTokens = suggestion
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Slot chips

struct RunSlotFitChip: View {
    @ObservedObject var resources: SystemResourceMonitor
    let slot: EndpointSlot
    let servers: [ServerInfo]
    let models: [LibraryModel]
    let hardware: HardwareProfile
    let reserveGB: Double

    var body: some View {
        switch RunFleet.slotFit(
            slot, servers: servers, models: models, memory: resources.memory,
            hardware: hardware, contextTokens: resources.contextTokens, reserveGB: reserveGB
        ) {
        case .resident?:
            Label("In memory", systemImage: "memorychip")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .help("Already counted in the memory in use.")
        case .verdict(let verdict)?:
            Label(verdict.runWord, systemImage: verdict.runSymbol)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(verdict.runTone.color)
                .help(verdict.summary)
        case nil:
            EmptyView()
        }
    }
}

struct RunFleetVerdictLine: View {
    @ObservedObject var resources: SystemResourceMonitor
    let slots: [EndpointSlot]
    let servers: [ServerInfo]
    let models: [LibraryModel]
    let reserveGB: Double

    var body: some View {
        if let verdict = RunFleet.verdict(
            slots: slots, servers: servers, models: models, adding: nil,
            memory: resources.memory, contextTokens: resources.contextTokens, reserveGB: reserveGB
        ) {
            Label("Fleet memory: \(verdict.summary)", systemImage: verdict.runSymbol)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(verdict.runTone.color)
        }
    }
}
