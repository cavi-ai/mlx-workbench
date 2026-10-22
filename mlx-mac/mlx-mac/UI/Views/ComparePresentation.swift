import SwiftUI

enum ComparePresentation {
    /// Measured comparisons replay chat prompts; only chat-servable types qualify.
    static func candidates(from models: [LibraryModel]) -> [LibraryModel] {
        ComparisonViewLogic.candidates(from: models, mode: .chat)
    }

    static let maxSlots = 4

    enum ParameterSize: String, CaseIterable, Identifiable {
        case all, under3, from3To8, from8To20, over20, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All sizes"
            case .under3: return "Under 3B"
            case .from3To8: return "3–<8B"
            case .from8To20: return "8–<20B"
            case .over20: return "20B+"
            case .unknown: return "Unknown size"
            }
        }
        static func bucket(_ model: LibraryModel) -> Self {
            guard let size = FitAdvisor.parameterBillions(model.item.parameters), size.isFinite else { return .unknown }
            if size < 3 { return .under3 }
            if size < 8 { return .from3To8 }
            if size < 20 { return .from8To20 }
            return .over20
        }
    }

    /// Disk footprint is available even when the scan has no parameter count.
    enum SizeFilter: String, CaseIterable, Identifiable {
        case all, under2, from2To5, from5To10, over10, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All sizes"
            case .under2: return "Under 2 GB"
            case .from2To5: return "2–<5 GB"
            case .from5To10: return "5–<10 GB"
            case .over10: return "10 GB+"
            case .unknown: return "Unknown disk size"
            }
        }
        static func bucket(_ model: LibraryModel) -> Self {
            let bytes = model.item.bytes
            if bytes <= 0 { return .unknown }
            if bytes < 2_000_000_000 { return .under2 }
            if bytes < 5_000_000_000 { return .from2To5 }
            if bytes < 10_000_000_000 { return .from5To10 }
            return .over10
        }
    }

    /// A name-based series label for browsing, never an architecture claim.
    /// Snapshot hashes from older scan results are not useful menu labels.
    static func familyLabel(_ model: LibraryModel) -> String {
        let identity = HFRepoID.forPath(model.item.path) ?? model.displayName
        let name = identity.split(separator: "/").last.map(String.init) ?? identity
        var stem = name
        if let size = stem.range(of: #"(?i)[-_\s]+e?\d+(?:\.\d+)?[bm](?=[-_\s]|$)"#, options: .regularExpression) {
            stem = String(stem[..<size.lowerBound])
        }
        stem = stem.replacingOccurrences(of: #"(?i)(?:[-_\s]+(?:mlx|gguf|instruct|chat|\d+bit))+$"#, with: "", options: .regularExpression)
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty || stem.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil {
            return "Unknown family"
        }
        return stem
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case family, parameters, disk, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .family: return "Family"
            case .parameters: return "Parameter size"
            case .disk: return "Disk size"
            case .none: return "Name"
            }
        }
    }

    struct OptionGroup: Identifiable {
        let title: String
        let models: [LibraryModel]
        var id: String { title }
    }

    static func filtered(_ models: [LibraryModel], family: String?, size: SizeFilter, query: String) -> [LibraryModel] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter {
            (family == nil || familyLabel($0) == family) && (size == .all || SizeFilter.bucket($0) == size)
                && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || familyLabel($0).localizedCaseInsensitiveContains(search))
        }
    }

    static func groups(_ models: [LibraryModel], by grouping: Grouping) -> [OptionGroup] {
        func key(_ model: LibraryModel) -> String {
            switch grouping {
            case .family: return familyLabel(model)
            case .parameters: return ParameterSize.bucket(model).title
            case .disk: return SizeFilter.bucket(model).title
            case .none: return "Models"
            }
        }
        let grouped = Dictionary(grouping: models, by: key)
        let order: [String]
        switch grouping {
        case .parameters: order = ParameterSize.allCases.filter { $0 != .all }.map(\.title)
        case .disk: order = SizeFilter.allCases.filter { $0 != .all }.map(\.title)
        default: order = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return order.compactMap { title in
            grouped[title].map { OptionGroup(title: title, models: $0.sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.item.path < $1.item.path : comparison == .orderedAscending
            }) }
        }
    }

    static func selectedOutsideFilter(forSlot index: Int, slots: [String?], candidates: [LibraryModel], filtered: [LibraryModel]) -> LibraryModel? {
        guard slots.indices.contains(index), let path = slots[index], !filtered.contains(where: { $0.item.path == path }) else { return nil }
        return candidates.first { $0.item.path == path }
    }

    /// Chosen paths in slot order, without empty slots or repeats.
    static func variantPaths(_ slots: [String?]) -> [String] {
        var seen = Set<String>()
        return slots.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// Models a slot's menu offers: everything except what the other slots
    /// already hold. The slot's own choice stays selectable.
    static func options(forSlot index: Int, slots: [String?], candidates: [LibraryModel], repeatedPaths: Set<String> = []) -> [LibraryModel] {
        let taken = Set(slots.enumerated().compactMap { $0.offset == index ? nil : $0.element })
        return candidates.filter { !taken.contains($0.item.path) || repeatedPaths.contains($0.item.path) }
    }

    /// The model the operator is looking at plus one sibling of the same
    /// model key, so the first comparison needs no picking.
    static func preselectedSlots(selectedPath: String?, candidates: [LibraryModel]) -> [String?] {
        guard let selectedPath,
              let model = candidates.first(where: {
                  $0.item.path == selectedPath || $0.outputPaths.contains(selectedPath)
              }) else { return [nil, nil] }
        let sibling = model.item.modelKey.flatMap { key in
            candidates.first { $0.item.path != model.item.path && $0.item.modelKey == key }
        }
        return [model.item.path, sibling?.item.path]
    }

    static func canRun(slots: [String?], activeRunID: UUID?, availablePaths: Set<String>? = nil) -> Bool {
        runUnavailableReason(slots: slots, activeRunID: activeRunID, availablePaths: availablePaths) == nil
    }

    static func runUnavailableReason(slots: [String?], activeRunID: UUID?,
                                     availablePaths: Set<String>? = nil, hasPromptSet: Bool = true,
                                     savingPromptSet: Bool = false, hasPrompts: Bool = true) -> String? {
        if activeRunID != nil { return "Wait for the current comparison to finish." }
        if savingPromptSet { return "Wait for the prompt set save to finish." }
        if !hasPromptSet { return "Choose a prompt set." }
        if !hasPrompts { return "Choose a prompt set with at least one prompt." }
        if variantPaths(slots).isEmpty { return "Choose at least one model." }
        if let availablePaths, let index = slots.firstIndex(where: { path in
            path.map { !availablePaths.contains($0) } ?? false
        }) {
            return "Model \(letter(index)) is unavailable. Replace it or choose None."
        }
        return nil
    }

    /// A readable label for a model path recorded in a run: the Library's
    /// name, else the HF repo id (snapshot folders are commit hashes), else
    /// the folder name.
    static func displayName(for path: String, models: [LibraryModel]) -> String {
        if let model = models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) {
            return model.displayName
        }
        if let repoID = HFRepoID.forPath(path) {
            return repoID
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ComparisonRunButton: View {
    let unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button {
            guard unavailableReason == nil else { return }
            action()
        } label: { Label("Run comparison", systemImage: "play.fill") }
        .tint(WorkbenchColor.accent)
        .font(WorkbenchTypography.emphasis).controlSize(.large)
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? "Run the selected prompt set against these models.")
        .accessibilityHint(unavailableReason ?? "Run the selected prompt set against these models.")
    }
}

struct ComparisonRunGuidance: View {
    let reason: String?

    var body: some View {
        if let reason {
            Label(reason, systemImage: "info.circle")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Lanes and run selection

/// One variant of the shown run, lettered in run order.
struct CompareLane: Equatable, Identifiable {
    enum State: Equatable {
        case measured
        case measuring
        case waiting
        case failed(String)
        /// Completed with no positive value for the mode's metric.
        case noMeasurement
        /// Completed without a result for this variant (an interrupted run).
        case notMeasured
    }

    let index: Int
    let path: String
    let state: State
    let value: Double?
    /// Share of the best lane (1 for leaders); set only when at least two lanes are ranked.
    let fraction: Double?
    let isLeader: Bool
    var resultID: String? = nil
    var profileName: String? = nil
    var resultKey: String { resultID ?? path }

    var letter: String { ComparePresentation.letter(index) }
    var id: String { "\(index)|\(path)" }
}

/// The mode, run pick and prompt set that Compare keeps coherent.
struct CompareSelection: Equatable {
    var mode: ComparisonMode
    var selectedRunID: UUID?
    var promptSetID: String
}

extension ComparePresentation {
    static let slotLetters = ["A", "B", "C", "D"]

    static func letter(_ index: Int) -> String {
        slotLetters[min(max(index, 0), slotLetters.count - 1)]
    }

    /// One lane per run variant in run order; results are matched by model path.
    static func lanes(for run: ComparisonRun) -> [CompareLane] {
        let values = run.results.compactMap { run.metricValue(of: $0) }
        let ranked = run.state != .cancelled && run.state != .interrupted && values.count >= 2
        let best = run.effectiveMode.primaryMetric.higherIsBetter ? values.max() : values.min()
        let leaders = Set(run.leaders.map(\.id))
        return run.variants.enumerated().map { index, path in
            let key = run.variantIdentities[index]
            let result = run.results.first { $0.id == key }
            let value = result.flatMap { run.metricValue(of: $0) }
            let state: CompareLane.State
            if let result {
                if let error = result.error { state = .failed(error) } else { state = value == nil ? .noMeasurement : .measured }
            } else if run.state == .running {
                state = index == run.results.count ? .measuring : .waiting
            } else {
                state = .notMeasured
            }
            var fraction: Double?
            if ranked, let value, let best {
                fraction = run.effectiveMode.primaryMetric.higherIsBetter ? value / best : best / value
            }
            return CompareLane(index: index, path: path, state: state, value: value, fraction: fraction,
                isLeader: ranked && leaders.contains(key), resultID: key,
                profileName: run.hasValidLaneIdentities ? run.laneConfigurations?.first(where: { $0.id == key })?.servingProfileName : nil)
        }
    }

    /// The formatted value split into its numeral and unit, in the order the format gives them.
    static func splitValue(_ formatted: String) -> (number: String, unit: String) {
        let tokens = formatted.split(separator: " ").map(String.init)
        guard let numeric = tokens.firstIndex(where: { Double($0) != nil }) else { return (formatted, "") }
        let unit = tokens.enumerated().filter { $0.offset != numeric }.map(\.element).joined(separator: " ")
        return (tokens[numeric], unit)
    }

    static func laneStatus(_ state: CompareLane.State) -> String? {
        switch state {
        case .measured: return nil
        case .measuring: return "Measuring…"
        case .waiting: return "Waiting"
        case .failed(let error): return error
        case .noMeasurement: return "No measurement"
        case .notMeasured: return "Not measured"
        }
    }

    /// The first non-empty line of an error, trimmed; the rest belongs in a details view.
    static func firstLine(of error: String) -> String {
        error.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// A variant that failed as a whole has no sample to show; its lane header carries the error.
    static func showsNotRun(sample: ComparisonSample?, result: VariantResult?) -> Bool {
        sample == nil && result?.error != nil
    }

    static func laneAccessibilityLabel(_ lane: CompareLane, name: String, metric: ComparisonMetric) -> String {
        var parts = [lane.letter, name]
        switch lane.state {
        case .measured:
            lane.value.map { parts.append(metric.format($0)) }
            if lane.isLeader { parts.append("fastest") } else if let fraction = lane.fraction {
                parts.append("\(Int((fraction * 100).rounded()))% of fastest")
            }
        case .measuring: parts.append("measuring")
        case .waiting: parts.append("waiting")
        case .failed: parts.append("failed")
        case .noMeasurement: parts.append("no measurement")
        case .notMeasured: parts.append("not measured")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Mode and run coherence

    /// The run the results area renders: the active run, else the pick when it belongs to the
    /// mode, else the mode's newest run.
    static func shownRun(runs: [ComparisonRun], mode: ComparisonMode, selectedRunID: UUID?, activeRunID: UUID?) -> ComparisonRun? {
        if let activeRunID, let active = runs.first(where: { $0.id == activeRunID }) { return active }
        if let selectedRunID, let picked = runs.first(where: { $0.id == selectedRunID }), picked.effectiveMode == mode {
            return picked
        }
        return runs.filter { $0.effectiveMode == mode }.max { $0.startedAt < $1.startedAt }
    }

    static func showsEmptyState(runs: [ComparisonRun], mode: ComparisonMode, selectedRunID: UUID?, activeRunID: UUID?) -> Bool {
        shownRun(runs: runs, mode: mode, selectedRunID: selectedRunID, activeRunID: activeRunID) == nil
    }

    static func emptyTitle(for mode: ComparisonMode) -> String {
        "No \(mode.title.lowercased()) comparisons yet"
    }

    /// The prompt set of the mode's newest run, so opening Compare resumes where the last run left off.
    static func restoredPromptSetID(runs: [ComparisonRun], mode: ComparisonMode, promptSets: [PromptSet]) -> String? {
        runs.filter { run in run.effectiveMode == mode && promptSets.contains { $0.id == run.promptSetID } }
            .max { $0.startedAt < $1.startedAt }?
            .promptSetID
    }

    /// A real mode change clears the run pick and takes the new mode's first prompt set.
    static func changeMode(_ selection: CompareSelection, to mode: ComparisonMode, promptSets: [PromptSet]) -> CompareSelection {
        guard mode != selection.mode else { return selection }
        let sets = ComparisonViewLogic.promptSets(promptSets, for: mode)
        return CompareSelection(mode: mode, selectedRunID: nil, promptSetID: sets.first?.id ?? "")
    }

    /// Picking a run from history or Champions shows exactly that run; a run of another mode
    /// switches the mode and takes that run's prompt set when it still exists.
    static func pick(_ run: ComparisonRun, from selection: CompareSelection, promptSets: [PromptSet]) -> CompareSelection {
        var next = selection
        next.selectedRunID = run.id
        guard run.effectiveMode != selection.mode else { return next }
        let sets = ComparisonViewLogic.promptSets(promptSets, for: run.effectiveMode)
        next.mode = run.effectiveMode
        next.promptSetID = sets.contains { $0.id == run.promptSetID } ? run.promptSetID : (sets.first?.id ?? "")
        return next
    }

    // MARK: Grid geometry

    struct GridLayout: Equatable {
        let promptWidth: CGFloat
        let laneWidth: CGFloat
        /// True when the lanes do not fit at their minimum width.
        let scrolls: Bool

        /// Square thumbnails and 16:9 video frames fill the column inside its cell inset.
        var mediaSide: CGFloat {
            min(laneWidth - 2 * WorkbenchSize.Compare.cellInset, WorkbenchSize.Compare.thumbnailMaximum)
        }
    }

    /// Lanes share the width up to their maximum; below the minimum they keep their ideal width and scroll.
    static func gridLayout(contentWidth: CGFloat, laneCount: Int) -> GridLayout {
        let size = WorkbenchSize.Compare.self
        let lanes = CGFloat(max(laneCount, 1))
        let prompt = contentWidth < size.compactBreakpoint ? size.promptColumnCompact : size.promptColumn
        let share = (contentWidth - prompt - lanes * size.columnSpacing) / lanes
        if share >= size.laneMinimum { return GridLayout(promptWidth: prompt, laneWidth: min(share, size.laneMaximum), scrolls: false) }
        return GridLayout(promptWidth: prompt, laneWidth: size.laneIdeal, scrolls: true)
    }

    /// The muted line under a slot's model: quantization, then parameters or disk size.
    static func tileLine(_ model: LibraryModel) -> String? {
        let parameters = model.item.parameters.flatMap { $0.isEmpty ? nil : $0 }
        let disk = model.item.bytes > 0 ? ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file) : nil
        let line = [model.item.quantization, parameters ?? disk].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}
