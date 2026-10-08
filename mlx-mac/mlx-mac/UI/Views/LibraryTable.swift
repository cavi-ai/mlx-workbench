import SwiftUI

// MARK: - LibraryRow

/// One row of the Library table. A family with more than one variant is a
/// disclosure row whose children are the variants; a single-variant family
/// is shown as the variant itself, so the table never repeats a name.
///
/// A row carries nothing derived from live memory: the fit cell reads the
/// monitor itself, so a reading never rebuilds the rows.
struct LibraryRow: Identifiable, Hashable {
    static let familyIDPrefix = "family:"

    let id: String
    let name: String
    let detail: String
    /// Model type for a variant; the count or bucket text otherwise.
    let subline: String
    let readiness: ModelReadiness?
    let quantization: String
    let bytes: Int64
    let modifiedAt: Date?
    let modelPath: String?
    let children: [LibraryRow]?
    let taskType: ModelTaskType
    let model: LibraryModel?
    /// Estimated need in bytes at the table's context; `Int64.max` when no
    /// fit is estimated. Independent of any memory reading.
    let fitSortKey: Int64

    var isFamily: Bool { children != nil }
    var isLeaf: Bool { model != nil }
    var isBucket: Bool { id.hasPrefix(Self.typeIDPrefix) || id.hasPrefix(Self.useCaseIDPrefix) }
    var readinessTitle: String { readiness?.title ?? "" }
    var readinessSortKey: Int {
        readiness.flatMap { ModelReadiness.allCases.firstIndex(of: $0) } ?? ModelReadiness.allCases.count
    }
    var modifiedSortKey: TimeInterval { modifiedAt?.timeIntervalSince1970 ?? 0 }

    /// The models this row stands for: itself, or every variant below it.
    var fitModels: [LibraryModel] {
        if let model { return [model] }
        return (children ?? []).flatMap(\.fitModels)
    }

    static func variant(_ model: LibraryModel, contextTokens: Int = FitAdvisor.defaultContextTokens) -> LibraryRow {
        LibraryRow(
            id: model.item.path,
            name: model.displayName.split(separator: "/").last.map(String.init) ?? model.displayName,
            detail: LibraryTablePresentation.detail(for: model),
            subline: LibraryTablePresentation.subline(for: model),
            readiness: model.readiness,
            quantization: model.item.quantization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            bytes: model.item.bytes,
            modifiedAt: model.item.modifiedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            modelPath: model.item.path,
            children: nil,
            taskType: model.item.task?.type ?? .other,
            model: model,
            fitSortKey: LibraryTablePresentation.fitSortKey(for: model, contextTokens: contextTokens)
        )
    }

    static func family(_ group: LibraryGroupViewModel, children: [LibraryRow]) -> LibraryRow {
        let quantizations = Set(children.map(\.quantization).filter { !$0.isEmpty })
        let types = Set(children.map(\.taskType))
        let count = "\(children.count) \(children.count == 1 ? "model" : "variants")"
        return LibraryRow(
            id: familyIDPrefix + group.id,
            name: group.primaryDisplayName,
            detail: count,
            subline: count,
            readiness: nil,
            quantization: quantizations.count == 1 ? quantizations.first! : "",
            bytes: group.totalBytes,
            modifiedAt: children.compactMap(\.modifiedAt).max(),
            modelPath: nil,
            children: children,
            taskType: types.count == 1 ? types.first! : .other,
            model: nil,
            fitSortKey: children.map(\.fitSortKey).min() ?? Int64.max
        )
    }
}

// MARK: - LibraryTablePresentation

enum LibraryTablePresentation {
    static let defaultSortOrder = [KeyPathComparator(\LibraryRow.name, comparator: .localizedStandard)]

    /// Flattens single-variant families and nests multi-variant ones, then
    /// applies the table's sort order at every level.
    static func rows(
        groups: [LibraryGroupViewModel],
        sortOrder: [KeyPathComparator<LibraryRow>],
        contextTokens: Int = FitAdvisor.defaultContextTokens
    ) -> [LibraryRow] {
        let order = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        let top: [LibraryRow] = groups.map { group in
            let variants = group.variants.map { LibraryRow.variant($0, contextTokens: contextTokens) }.sorted(using: order)
            if variants.count == 1 {
                return variants[0]
            }
            return LibraryRow.family(group, children: variants)
        }
        return top.sorted(using: order)
    }

    /// The model path a table selection stands for; family rows stand for none.
    static func modelPath(forSelection id: String?) -> String? {
        guard let id else { return nil }
        let bucketPrefixes = [LibraryRow.familyIDPrefix, LibraryRow.typeIDPrefix, LibraryRow.useCaseIDPrefix]
        return bucketPrefixes.contains(where: id.hasPrefix) ? nil : id
    }

    /// A second line that locates the variant: the Hugging Face repo id for
    /// cache entries, otherwise the containing directory.
    static func detail(for model: LibraryModel) -> String {
        if let repoID = HFRepoID.forPath(model.item.path) {
            return repoID
        }
        return URL(fileURLWithPath: model.item.path).deletingLastPathComponent().path
    }

    /// Location stays in the inspector; rows carry only model type.
    static func subline(for model: LibraryModel) -> String {
        model.item.task?.type.title ?? ""
    }

    /// Browsing families are visible series headings, including single-model
    /// families. This projection never changes identity or evidence grouping.
    static func familyRows(groups: [LibraryGroupViewModel], sortOrder: [KeyPathComparator<LibraryRow>], contextTokens: Int = FitAdvisor.defaultContextTokens) -> [LibraryRow] {
        let order = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        return Dictionary(grouping: groups.flatMap(\.variants), by: ComparePresentation.familyLabel).map { name, models in
            let children = models.map { LibraryRow.variant($0, contextTokens: contextTokens) }.sorted(using: order)
            let group = ModelGroup(variants: models, normalizedModelKey: name, primaryDisplayName: name)
            return LibraryRow.family(LibraryGroupViewModel(sourceGroup: group, variants: models), children: children)
        }.sorted(using: order)
    }

    /// Sort key for the Fits now column: the estimated need at `contextTokens`,
    /// or `Int64.max` when the model has no estimate. It reads no memory
    /// snapshot, so the order never moves with a probe.
    static func fitSortKey(for model: LibraryModel, contextTokens: Int) -> Int64 {
        guard ComparisonInsights.supportsFitEstimate(model), model.item.bytes > 0 else { return Int64.max }
        return FitAdvisor.neededBytes(modelBytes: model.item.bytes, contextTokens: contextTokens, parameters: model.item.parameters)
    }

    /// Relative date such as "2d ago"; "—" when the scan reported none.
    static func modifiedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// The largest single model in `rows`; family and bucket totals are not
    /// models and never set the scale.
    static func largestLeafBytes(in rows: [LibraryRow]) -> Int64 {
        rows.reduce(Int64(0)) { largest, row in
            if row.isLeaf { return max(largest, row.bytes) }
            return max(largest, largestLeafBytes(in: row.children ?? []))
        }
    }
}

// MARK: - Grouping

enum LibraryGroupMode: String, CaseIterable, Identifiable {
    case family
    case type

    var id: String { rawValue }
    var title: String { self == .family ? "Family" : "Type" }
}

extension LibraryRow {
    static let typeIDPrefix = "type:"
    static let useCaseIDPrefix = "usecase:"

    static func bucket(id: String, name: String, detail: String, taskType: ModelTaskType = .other, children: [LibraryRow]) -> LibraryRow {
        LibraryRow(
            id: id, name: name, detail: detail, subline: detail, readiness: nil, quantization: "",
            bytes: children.reduce(Int64(0)) { $0 + $1.bytes },
            modifiedAt: children.compactMap(\.modifiedAt).max(),
            modelPath: nil, children: children,
            taskType: taskType, model: nil,
            fitSortKey: Int64.max
        )
    }
}

extension LibraryTablePresentation {
    /// Type → primary use case → family/variant rows. Types follow
    /// `ModelTaskType.allCases`; use cases sort by title.
    static func typeRows(
        groups: [LibraryGroupViewModel],
        sortOrder: [KeyPathComparator<LibraryRow>],
        contextTokens: Int = FitAdvisor.defaultContextTokens
    ) -> [LibraryRow] {
        var buckets: [ModelTaskType: [String: [LibraryGroupViewModel]]] = [:]
        for group in groups {
            let split = Dictionary(grouping: group.variants) { model in
                "\((model.item.task?.type ?? .other).rawValue)|\(model.item.task?.primaryUseCase ?? ModelTaskPresentation.unclassifiedUseCase)"
            }
            for (key, variants) in split {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let type = ModelTaskType(rawValue: parts[0]) ?? .other
                buckets[type, default: [:]][parts[1], default: []].append(
                    LibraryGroupViewModel(sourceGroup: group.sourceGroup, variants: variants)
                )
            }
        }
        return ModelTaskType.allCases.compactMap { type -> LibraryRow? in
            guard let useCases = buckets[type] else { return nil }
            let useCaseRows = useCases.keys
                .sorted { ModelTaskPresentation.useCaseTitle($0) < ModelTaskPresentation.useCaseTitle($1) }
                .map { useCase -> LibraryRow in
                    let children = rows(groups: useCases[useCase] ?? [], sortOrder: sortOrder, contextTokens: contextTokens)
                    return .bucket(
                        id: LibraryRow.useCaseIDPrefix + "\(type.rawValue):\(useCase)",
                        name: ModelTaskPresentation.useCaseTitle(useCase),
                        detail: "\(children.count) \(children.count == 1 ? "entry" : "entries")",
                        taskType: type,
                        children: children
                    )
                }
            return .bucket(
                id: LibraryRow.typeIDPrefix + type.rawValue,
                name: type.title,
                detail: "\(useCaseRows.count) use \(useCaseRows.count == 1 ? "case" : "cases")",
                taskType: type,
                children: useCaseRows
            )
        }
    }

    static func row(withID id: String, in rows: [LibraryRow]) -> LibraryRow? {
        for candidate in rows {
            if candidate.id == id { return candidate }
            if let children = candidate.children, let found = Self.row(withID: id, in: children) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Column tiers

/// Which parts of the table survive at a given table width. The width is the
/// table's own (window minus sidebar and inspector), so opening the inspector
/// narrows the table the same way a smaller window does. Each part has a
/// threshold; once hidden it returns only after the width clears the
/// threshold by the hysteresis, so a width hovering at a boundary does not
/// flicker. Model and the Fits now verdict word never hide.
struct LibraryColumnTier: Equatable {
    var showsModified: Bool
    var showsSizeBar: Bool
    var showsStatus: Bool
    var showsGauge: Bool
    var showsQuant: Bool
    var showsSize: Bool

    static func resolve(width: CGFloat, previous: LibraryColumnTier? = nil) -> LibraryColumnTier {
        typealias Size = WorkbenchSize.Library
        return LibraryColumnTier(
            showsModified: visible(previous?.showsModified, width: width, threshold: Size.tierModified),
            showsSizeBar: visible(previous?.showsSizeBar, width: width, threshold: Size.tierSizeBar),
            showsStatus: visible(previous?.showsStatus, width: width, threshold: Size.tierStatus),
            showsGauge: visible(previous?.showsGauge, width: width, threshold: Size.tierGauge),
            showsQuant: visible(previous?.showsQuant, width: width, threshold: Size.tierQuant),
            showsSize: visible(previous?.showsSize, width: width, threshold: Size.tierSize)
        )
    }

    private static func visible(_ wasVisible: Bool?, width: CGFloat, threshold: CGFloat) -> Bool {
        guard let wasVisible else { return width >= threshold }
        return wasVisible ? width >= threshold : width >= threshold + WorkbenchSize.Library.tierHysteresis
    }
}

// MARK: - Fit presentation

/// What the Fits now cell shows for one row. Built from the same
/// `ModelBudgetPresentation` Overview uses, so the verdict, the fill and the
/// tone have one owner.
struct LibraryFitPresentation: Equatable {
    enum State: String, Equatable {
        case estimated, notEstimated, redacted, unavailable
    }

    let state: State
    let tone: ModelBudgetPresentation.Tone
    /// Share of the model budget this model needs, 0...1; nil without an estimate.
    let fill: Double?
    let word: String
    let help: String
    let accessibilityLabel: String
    let contextTokens: Int
    let needBytes: Int64?

    /// fits < tight < won't fit; anything without an estimate sorts after.
    var rank: Int {
        switch tone {
        case .fits: return 0
        case .tight: return 1
        case .wontFit: return 2
        case .neutral: return 3
        }
    }

    /// Gauge fills move in twelfths of the budget, so the ordinary drift of
    /// available memory between probes leaves every gauge still.
    static let fillSteps = 12.0

    static func quantized(_ fraction: Double) -> Double {
        (fraction * fillSteps).rounded() / fillSteps
    }

    /// Changes when the verdict or the context changes. A gauge step change
    /// from a probe applies without animation.
    var animationKey: String { "\(state.rawValue)|\(rank)|\(contextTokens)" }

    static func make(
        model: LibraryModel,
        memory: MemorySnapshot?,
        hasProbed: Bool,
        contextTokens: Int,
        reserveGB: Double,
        hardware: HardwareProfile
    ) -> LibraryFitPresentation {
        let budget = ModelBudgetPresentation(
            memory: memory, reserveGB: reserveGB, contextTokens: contextTokens,
            model: model, hardware: hardware, hasProbed: hasProbed
        )
        func plain(_ state: State, word: String, help: String, label: String) -> LibraryFitPresentation {
            LibraryFitPresentation(
                state: state, tone: .neutral, fill: nil, word: word, help: help,
                accessibilityLabel: "Fits now: " + label, contextTokens: contextTokens, needBytes: nil
            )
        }
        guard ComparisonInsights.supportsFitEstimate(model), model.item.bytes > 0 else {
            return plain(.notEstimated, word: "—", help: budget.verdictText, label: budget.verdictText)
        }
        switch budget.reading {
        case .loading:
            return plain(.redacted, word: "Won't fit", help: "Reading memory", label: "reading memory")
        case .unavailable:
            return plain(.unavailable, word: "Unavailable", help: "Memory reading unavailable", label: "memory reading unavailable")
        case .live:
            guard let word = budget.verdictWord, let fill = budget.fitFraction else {
                return plain(.notEstimated, word: "—", help: budget.verdictText, label: budget.verdictText)
            }
            return LibraryFitPresentation(
                state: .estimated, tone: budget.tone, fill: quantized(fill), word: word, help: budget.verdictText,
                accessibilityLabel: "Fits now: " + budget.verdictText, contextTokens: contextTokens,
                needBytes: budget.neededBytes
            )
        }
    }

    /// A family row shows its best variant: the best verdict, the smaller
    /// need on a tie. Without any estimate it shows the first variant's state.
    static func best(
        of models: [LibraryModel],
        memory: MemorySnapshot?,
        hasProbed: Bool,
        contextTokens: Int,
        reserveGB: Double,
        hardware: HardwareProfile
    ) -> LibraryFitPresentation? {
        let all = models.map {
            make(model: $0, memory: memory, hasProbed: hasProbed, contextTokens: contextTokens, reserveGB: reserveGB, hardware: hardware)
        }
        let estimated = all.filter { $0.state == .estimated }
        if let best = estimated.min(by: { ($0.rank, $0.needBytes ?? Int64.max) < ($1.rank, $1.needBytes ?? Int64.max) }) {
            return best
        }
        return all.first
    }
}

extension ModelReadiness {
    /// Status symbol for the non-ready states the Status column shows.
    var statusSymbol: String {
        switch self {
        case .ready: return "checkmark.circle"
        case .needsConversion: return "arrow.triangle.2.circlepath"
        case .needsRuntime: return "wrench.and.screwdriver"
        case .incompleteCache: return "exclamationmark.triangle"
        case .unsupported: return "nosign"
        case .duplicate: return "square.on.square"
        case .quarantined: return "archivebox"
        }
    }
}

// MARK: - Cells

struct LibraryNameCell: View {
    let row: LibraryRow
    var isSelected = false
    /// The Status column is hidden: a non-ready state replaces the subline.
    var showsInlineStatus = false
    @Environment(\.backgroundProminence) private var prominence

    private var symbolStyle: Color {
        if prominence == .increased { return WorkbenchColor.onAccent }
        return isSelected ? WorkbenchColor.accent : WorkbenchColor.muted
    }

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Image(systemName: row.taskType.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolStyle)
                .frame(width: WorkbenchSize.Library.rowSymbol)
                .accessibilityLabel(row.taskType.title)
                .accessibilityHidden(row.model?.item.task != nil)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.hairline) {
                Text(row.name)
                    .font(row.isFamily ? WorkbenchTypography.emphasis : WorkbenchTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                subline
            }
        }
        .padding(.vertical, WorkbenchSpacing.xxxs)
    }

    @ViewBuilder
    private var subline: some View {
        if showsInlineStatus, let readiness = row.readiness, readiness != .ready {
            LibraryStatusLabel(readiness: readiness)
                .font(WorkbenchTypography.secondary)
        } else if !row.subline.isEmpty {
            Text(row.subline)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Symbol plus label for a non-ready state; the symbol keeps the state
/// readable without color.
struct LibraryStatusLabel: View {
    let readiness: ModelReadiness
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let color = prominence == .increased ? WorkbenchColor.onAccent : WorkbenchStatus(rawValue: readiness.rawValue).color
        HStack(spacing: WorkbenchSpacing.xxs) {
            Image(systemName: readiness.statusSymbol)
                .symbolRenderingMode(.hierarchical)
            Text(readiness.title)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readiness.title)
    }
}

struct LibraryReadinessCell: View {
    let row: LibraryRow

    var body: some View {
        if let readiness = row.readiness, readiness != .ready {
            LibraryStatusLabel(readiness: readiness)
                .font(WorkbenchTypography.body)
        }
    }
}

struct LibraryQuantCell: View {
    let row: LibraryRow

    var body: some View {
        Text(row.quantization)
            .font(WorkbenchTypography.tabular)
            .lineLimit(1)
    }
}

struct LibrarySizeCell: View {
    let row: LibraryRow
    let largestLeafBytes: Int64
    let showsBar: Bool
    @Environment(\.backgroundProminence) private var prominence

    private var number: some View {
        Text(LibraryTablePresentation.byteCount(row.bytes))
            .font(WorkbenchTypography.tabular)
            .lineLimit(1)
    }

    private var hasBar: Bool { showsBar && row.isLeaf && largestLeafBytes > 0 }

    var body: some View {
        if hasBar {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    bar
                    Spacer(minLength: 0)
                    number
                }
                number.frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            number.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var bar: some View {
        let fraction = min(1, max(0, Double(row.bytes) / Double(largestLeafBytes)))
        let increased = prominence == .increased
        return Capsule()
            .fill(increased ? WorkbenchColor.onAccent.opacity(.stroke) : WorkbenchColor.well)
            .frame(width: WorkbenchSize.Library.sizeBarWidth, height: WorkbenchSize.Library.sizeBarHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(increased ? WorkbenchColor.onAccent : WorkbenchColor.muted)
                    .frame(width: WorkbenchSize.Library.sizeBarWidth * fraction)
            }
            .accessibilityHidden(true)
    }
}

struct LibraryModifiedCell: View {
    let row: LibraryRow

    var body: some View {
        Text(LibraryTablePresentation.modifiedText(row.modifiedAt))
            .font(WorkbenchTypography.secondaryTabular)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
    }
}

/// The Fits now cell. The only table view that observes the memory monitor:
/// a probe re-evaluates these cells and nothing else in the Library.
struct LibraryFitCell: View {
    let row: LibraryRow
    @ObservedObject var resources: SystemResourceMonitor
    let reserveGB: Double
    let hardware: HardwareProfile
    let showsGauge: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if !row.isBucket,
           let fit = LibraryFitPresentation.best(
               of: row.fitModels,
               memory: resources.memory,
               hasProbed: resources.hasProbed,
               contextTokens: resources.contextTokens,
               reserveGB: reserveGB,
               hardware: hardware
           ) {
            LibraryFitContent(fit: fit, showsGauge: showsGauge, isProminent: prominence == .increased)
        }
    }
}

struct LibraryFitContent: View {
    let fit: LibraryFitPresentation
    let showsGauge: Bool
    let isProminent: Bool

    private var wordStyle: Color {
        if isProminent { return WorkbenchColor.onAccent }
        switch fit.tone {
        case .tight, .wontFit: return fit.tone.color
        case .fits: return WorkbenchColor.ink
        case .neutral: return WorkbenchColor.muted
        }
    }

    private var word: some View {
        Text(fit.word)
            .font(WorkbenchTypography.body)
            .foregroundStyle(wordStyle)
            .lineLimit(1)
            .redacted(reason: fit.state == .redacted ? .placeholder : [])
    }

    private var hasGauge: Bool { fit.state == .estimated || fit.state == .redacted }

    var body: some View {
        Group {
            if showsGauge && hasGauge {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) {
                        gauge
                        word
                    }
                    word
                }
            } else {
                word
            }
        }
        .help(fit.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fit.accessibilityLabel)
    }

    private var gauge: some View {
        let fillColor = isProminent ? WorkbenchColor.onAccent : fit.tone.color
        return Capsule()
            .fill(isProminent ? WorkbenchColor.onAccent.opacity(.stroke) : WorkbenchColor.well)
            .frame(minWidth: WorkbenchSize.Library.fitGaugeMinimum, maxWidth: WorkbenchSize.Library.fitGaugeMaximum)
            .frame(height: WorkbenchSize.Library.fitGaugeHeight)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fillColor)
                        .frame(width: proxy.size.width * (fit.fill ?? 0))
                }
            }
            .workbenchAnimation(WorkbenchMotion.standard, value: fit.animationKey)
    }
}
