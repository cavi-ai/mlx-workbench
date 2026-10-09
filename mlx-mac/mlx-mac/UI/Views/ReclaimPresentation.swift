import CoreGraphics
import Foundation

// MARK: - Layout

/// Reclaim's width thresholds, derived from the width the page is offered and
/// built on the Run content width, never from measured children.
struct ReclaimLayout: Equatable {
    /// The page content width, including the surface chrome.
    private(set) var contentWidth: CGFloat
    /// The width inside a surface.
    private(set) var innerWidth: CGFloat
    private(set) var stacksStages = false
    private(set) var compactSuggestions = false
    private(set) var wrapsHeader = false
    private(set) var compactQuarantine = false
    private(set) var compactHistory = false

    static let assumedViewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2

    /// A compact layout flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(width: CGFloat, threshold: CGFloat, wasCompact: Bool) -> Bool {
        width < (wasCompact ? threshold + WorkbenchSize.Reclaim.hysteresis : threshold)
    }

    init(viewportWidth: CGFloat = Self.assumedViewportWidth, previous: ReclaimLayout? = nil) {
        let inner = RunLayout(viewportWidth: viewportWidth).innerWidth
        innerWidth = inner
        contentWidth = inner + WorkbenchSize.Reclaim.surfaceChrome
        stacksStages = Self.isCompact(width: contentWidth, threshold: WorkbenchSize.Reclaim.stageThreshold, wasCompact: previous?.stacksStages ?? false)
        compactSuggestions = Self.isCompact(width: inner, threshold: WorkbenchSize.Reclaim.suggestionThreshold, wasCompact: previous?.compactSuggestions ?? false)
        wrapsHeader = Self.isCompact(width: inner, threshold: WorkbenchSize.Reclaim.headerThreshold, wasCompact: previous?.wrapsHeader ?? false)
        compactQuarantine = Self.isCompact(width: inner, threshold: WorkbenchSize.Reclaim.quarantineThreshold, wasCompact: previous?.compactQuarantine ?? false)
        compactHistory = Self.isCompact(width: inner - WorkbenchSize.Reclaim.historyIndent, threshold: WorkbenchSize.Reclaim.historyThreshold, wasCompact: previous?.compactHistory ?? false)
    }
}

// MARK: - Formatting

enum ReclaimFormat {
    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// The ledger's ISO timestamp as a date and time; the raw text when it does not parse.
    static func movedAt(_ raw: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Names

struct ReclaimName: Equatable {
    let title: String
    /// What the title leaves out, such as a cache file's hash; shown in help only.
    let detail: String?
    let isCacheFile: Bool
}

enum ReclaimNames {
    static let cacheFileTitle = "Cache file"

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    /// A content hash used as a file name: 32 or more hex digits, optionally with an ".incomplete" suffix.
    static func isHashName(_ name: String) -> Bool {
        let stem = name.hasSuffix(".incomplete") ? String(name.dropLast(".incomplete".count)) : name
        return stem.count >= 32 && stem.allSatisfy(\.isHexDigit)
    }

    private static func resolveOne(_ path: String, models: [LibraryModel]) -> ReclaimName {
        let target = normalized(path)
        if let model = models.first(where: { normalized($0.item.path) == target }), !model.displayName.isEmpty {
            return ReclaimName(title: model.displayName, detail: nil, isCacheFile: false)
        }
        if let repo = HFRepoID.forPath(path) {
            return ReclaimName(title: repo, detail: nil, isCacheFile: false)
        }
        let last = URL(fileURLWithPath: path).lastPathComponent
        if isHashName(last) {
            return ReclaimName(title: cacheFileTitle, detail: last, isCacheFile: true)
        }
        return ReclaimName(title: last.isEmpty ? path : last, detail: nil, isCacheFile: false)
    }

    /// Library display name, then the Hugging Face repo id, then the file or folder name.
    /// The first path that yields a real name wins; a hash is never a title.
    static func resolve(paths: [String], models: [LibraryModel]) -> ReclaimName {
        let names = paths.filter { !$0.isEmpty }.map { resolveOne($0, models: models) }
        return names.first(where: { !$0.isCacheFile }) ?? names.first ?? ReclaimName(title: "Original source", detail: nil, isCacheFile: false)
    }
}

// MARK: - Ledger

/// Where the bytes are: reviewable, held in quarantine, or in Trash. Each stage
/// has one declared population, computed from published coordinator state only.
struct ReclaimLedger: Equatable {
    enum StageID: String { case ready, quarantine, trash }

    enum Figure: Equatable {
        case bytes(Int64)
        /// Sizes are not recorded: the count of items stands in, never a zero.
        case items(Int)
        case pending
    }

    struct Stage: Equatable, Identifiable {
        let id: StageID
        let title: String
        let figure: Figure
        let detail: String
        /// Empty when the stage holds nothing.
        let caption: String
        /// The largest member's name and evidence class; nil when the stage is empty.
        var subject: String? = nil
        /// How old the analysis is; set on the Ready stage only.
        var asOf: String? = nil

        var numeral: String {
            switch figure {
            case .bytes(let bytes): return ReclaimFormat.byteCount(bytes)
            case .items(let count): return "\(count)"
            case .pending: return "—"
            }
        }

        var changeKey: String { "\(id.rawValue)|\(numeral)" }
    }

    let stages: [Stage]
    let originalsLine: String

    let readyBytes: Int64
    let readyCount: Int
    let quarantineBytes: Int64
    let quarantineCount: Int
    let trashKnownBytes: Int64
    let trashItemCount: Int
    let trashUnknownCount: Int
    let originalsCount: Int
    let originalsBytes: Int64

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    init(
        opportunities: [ReclaimOpportunity],
        quarantined: [QuarantineRecord],
        candidates: [SourceCleanupCandidate],
        sourcesChecked: Bool,
        history: [SourceCleanupBatch],
        hasLibrary: Bool,
        models: [LibraryModel] = [],
        generatedAt: Date? = nil,
        now: Date = Date()
    ) {
        let actionable = opportunities.filter(\.actionable)
        readyBytes = actionable.reduce(0) { $0 + $1.bytes }
        readyCount = actionable.count

        quarantineBytes = quarantined.reduce(0) { $0 + $1.bytes }
        quarantineCount = quarantined.count

        let inTrash = history.flatMap(\.items).filter(\.canReveal)
        let known = inTrash.compactMap(\.record.bytes)
        trashKnownBytes = known.reduce(0, +)
        trashItemCount = inTrash.count
        trashUnknownCount = inTrash.count - known.count

        let claimed = Set(opportunities.flatMap(\.paths).map(Self.normalized))
        let eligible = candidates.filter { $0.bytes != nil && !claimed.contains(Self.normalized($0.workflow.sourcePath)) }
        originalsCount = eligible.count
        originalsBytes = eligible.reduce(0) { $0 + ($1.bytes ?? 0) }

        if !sourcesChecked {
            originalsLine = "Originals not checked"
        } else if eligible.isEmpty {
            originalsLine = "No eligible originals"
        } else {
            originalsLine = "\(ReclaimFormat.count(eligible.count, "original")) · \(ReclaimFormat.byteCount(originalsBytes))"
        }

        let trashFigure: Figure
        if known.isEmpty && !inTrash.isEmpty { trashFigure = .items(inTrash.count) } else { trashFigure = .bytes(trashKnownBytes) }
        var trashDetail = ReclaimFormat.count(inTrash.count, "item")
        if trashUnknownCount > 0 {
            trashDetail += trashUnknownCount == inTrash.count ? " · size not recorded" : " · \(trashUnknownCount) size not recorded"
        }

        let largestReady = actionable.max { $0.bytes < $1.bytes }
        let largestQuarantined = quarantined.max { $0.bytes < $1.bytes }
        let largestTrashed = inTrash.max { ($0.record.bytes ?? -1) < ($1.record.bytes ?? -1) }

        stages = [
            Stage(
                id: .ready, title: "Ready to review",
                figure: hasLibrary ? .bytes(readyBytes) : .pending,
                detail: !hasLibrary ? "Waiting for the library scan" : readyCount == 0 ? "No suggestions" : ReclaimFormat.count(readyCount, "suggestion"),
                caption: hasLibrary && readyCount > 0 ? "can move to quarantine now" : "",
                subject: largestReady.map { "\(ReclaimNames.resolve(paths: $0.paths, models: models).title) · \($0.kind.title)" },
                asOf: generatedAt.map { "as of " + WorkbenchRelativeTime.text(for: $0, style: .full, now: now) }
            ),
            Stage(
                id: .quarantine, title: "In quarantine", figure: .bytes(quarantineBytes),
                detail: quarantineCount == 0 ? "Empty" : ReclaimFormat.count(quarantineCount, "file"),
                caption: quarantineCount == 0 ? "" : "restorable · still on disk",
                subject: largestQuarantined.map {
                    "\(ReclaimNames.resolve(paths: [$0.from], models: models).title) · \($0.kind == .mlxDirectory ? "Local MLX folder" : "GGUF file")"
                }
            ),
            Stage(
                id: .trash, title: "Originals in Trash", figure: trashFigure,
                detail: inTrash.isEmpty ? "Nothing in Trash" : trashDetail,
                caption: inTrash.isEmpty ? "" : "still on disk until Trash is emptied",
                subject: largestTrashed.map { item in
                    let source = ReclaimNames.resolve(paths: [item.record.from], models: models).title
                    guard let output = item.record.outputPath else { return "\(source) · original source" }
                    return "\(source) · original of verified \(ReclaimNames.resolve(paths: [output], models: models).title)"
                }
            ),
        ]
    }
}

// MARK: - Freshness and triggers

enum ReclaimFreshness {
    /// A preview, plan or apply is open: re-analysis would discard it.
    @MainActor
    static func hasOpenPreview(_ reclaim: ReclaimCoordinator) -> Bool {
        reclaim.plan != nil || reclaim.trashPlan != nil || reclaim.folderPlan != nil || reclaim.libraryTrashPlan != nil
            || reclaim.sourcePlan != nil || reclaim.sourceRestorePlan != nil || reclaim.cachePruneHash != nil || reclaim.isApplying
    }

    /// A new library snapshot is re-analyzed once, unless a preview is open or move results are still on screen.
    static func shouldReanalyze(analyzed: Date?, current: Date?, hasOpenPreview: Bool, hasUnreadMoves: Bool) -> Bool {
        guard let current, current != analyzed else { return false }
        return !hasOpenPreview && !hasUnreadMoves
    }
}

enum ReclaimTrigger: Equatable {
    case analyze
    case refreshQuarantined
    case rescan
}

enum ReclaimTriggers {
    /// First mount only: route activation, disclosures and hover start nothing.
    static func onMount(hasScan: Bool, isScanning: Bool) -> [ReclaimTrigger] {
        var triggers: [ReclaimTrigger] = [.analyze, .refreshQuarantined]
        if !hasScan && !isScanning { triggers.append(.rescan) }
        return triggers
    }
}

// MARK: - Sheets

enum ReclaimSheet: Hashable {
    case moveToTrash
    case quarantineFolder
    case moveOriginals
    case restoreOriginals
}

enum ReclaimSheets {
    /// The originals sheet opens only for a plan the user asked to review on this route.
    static func showsMoveOriginals(planWorkflowID: UUID?, reviewedSourceID: UUID?, isRouteActive: Bool) -> Bool {
        isRouteActive && reviewedSourceID != nil && planWorkflowID == reviewedSourceID
    }

    static func showsRestoreOriginals(hasPlan: Bool, isRouteActive: Bool) -> Bool {
        isRouteActive && hasPlan
    }

    static func presented(
        hasTrashPlan: Bool,
        hasFolderPlan: Bool,
        sourcePlanWorkflowID: UUID?,
        reviewedSourceID: UUID?,
        hasRestorePlan: Bool,
        isRouteActive: Bool
    ) -> Set<ReclaimSheet> {
        var sheets: Set<ReclaimSheet> = []
        if hasTrashPlan { sheets.insert(.moveToTrash) }
        if hasFolderPlan { sheets.insert(.quarantineFolder) }
        if showsMoveOriginals(planWorkflowID: sourcePlanWorkflowID, reviewedSourceID: reviewedSourceID, isRouteActive: isRouteActive) { sheets.insert(.moveOriginals) }
        if showsRestoreOriginals(hasPlan: hasRestorePlan, isRouteActive: isRouteActive) { sheets.insert(.restoreOriginals) }
        return sheets
    }
}

// MARK: - Prominence

enum ReclaimAction: Hashable, CaseIterable {
    case previewReclaim
    case confirmQuarantine
    case confirmPrune
}

enum ReclaimProminence {
    /// The one prominent action in the suggestions region: confirm a frozen plan first,
    /// then preview a selection, then confirm a previewed prune.
    static func primary(hasPlan: Bool, hasSelection: Bool, hasPrunePreview: Bool) -> ReclaimAction? {
        if hasPlan { return .confirmQuarantine }
        if hasSelection { return .previewReclaim }
        if hasPrunePreview { return .confirmPrune }
        return nil
    }
}

// MARK: - Originals

/// What the originals block shows; "Check originals" sits beside the unchecked state.
enum ReclaimOriginalsState: Equatable {
    case checking
    case unchecked
    case none
    case listed

    init(isChecking: Bool, isChecked: Bool, eligibleCount: Int) {
        if isChecking { self = .checking }
        else if !isChecked { self = .unchecked }
        else if eligibleCount == 0 { self = .none }
        else { self = .listed }
    }

    static let uncheckedText = "Check originals to find sources that can be removed safely."
}

// MARK: - Suggestions

/// What the suggestions region shows. Move results and the cache check do not depend on there being opportunities.
struct ReclaimSuggestionsState: Equatable {
    let showsEmpty: Bool
    let showsMoveResults: Bool
    let showsCacheControls: Bool

    init(opportunityCount: Int, candidateCount: Int, lastMoveCount: Int, cacheAvailable: Bool, cacheFindingCount: Int) {
        showsEmpty = opportunityCount == 0 && candidateCount == 0 && cacheFindingCount == 0
        showsMoveResults = lastMoveCount > 0
        showsCacheControls = cacheAvailable
    }
}

struct ReclaimSuggestionRow: Identifiable, Equatable {
    let id: String
    let kind: ReclaimKind
    let name: ReclaimName
    let symbol: String
    let bytes: String
    let evidence: String
    let reason: String?
    let paths: [String]
    let isActionable: Bool

    static func confidenceWord(_ confidence: ReclaimConfidence) -> String {
        switch confidence {
        case .high: return "High confidence"
        case .review: return "Review before moving"
        }
    }

    static func symbol(for kind: ReclaimKind) -> String {
        switch kind {
        case .stale: return "clock"
        case .supersededVariant: return "arrow.triangle.swap"
        case .crossRootDuplicate: return "square.on.square"
        }
    }

    init(_ opportunity: ReclaimOpportunity, models: [LibraryModel]) {
        id = opportunity.id
        kind = opportunity.kind
        name = ReclaimNames.resolve(paths: opportunity.paths, models: models)
        symbol = Self.symbol(for: opportunity.kind)
        bytes = ReclaimFormat.byteCount(opportunity.bytes)
        evidence = "\(opportunity.evidence) · \(Self.confidenceWord(opportunity.confidence))"
        reason = opportunity.actionable ? nil : "Review only: not selectable here. Quarantine a local MLX folder with Review model folder…; shared Hugging Face cache snapshots are protected."
        paths = opportunity.paths
        isActionable = opportunity.actionable
    }
}

struct ReclaimSuggestionGroup: Identifiable, Equatable {
    let kind: ReclaimKind
    let opportunities: [ReclaimOpportunity]
    var id: String { kind.rawValue }

    /// Groups in a fixed kind order; rows keep the advisor's ranking inside a group.
    static func groups(_ opportunities: [ReclaimOpportunity]) -> [ReclaimSuggestionGroup] {
        [ReclaimKind.stale, .supersededVariant, .crossRootDuplicate].compactMap { kind in
            let items = opportunities.filter { $0.kind == kind }
            return items.isEmpty ? nil : ReclaimSuggestionGroup(kind: kind, opportunities: items)
        }
    }
}

struct ReclaimCacheSummary: Equatable {
    let count: Int
    let knownBytes: Int64
    let unsizedCount: Int

    init(findings: [DoctorFinding]) {
        count = findings.count
        knownBytes = findings.compactMap(\.size).reduce(0, +)
        unsizedCount = findings.filter { $0.size == nil }.count
    }

    var text: String {
        let head = "\(ReclaimFormat.count(count, "incomplete cache item"))"
        if unsizedCount == count { return "\(head) · size not recorded" }
        let size = "\(ReclaimFormat.byteCount(knownBytes)) reclaimable"
        return unsizedCount == 0 ? "\(head) · \(size)" : "\(head) · \(size) · \(unsizedCount) size not recorded"
    }
}

// MARK: - Quarantine and history rows

struct ReclaimQuarantineRow: Identifiable, Equatable {
    let record: QuarantineRecord
    let name: ReclaimName
    let bytes: String
    let date: String
    var id: String { record.to }

    init(_ record: QuarantineRecord, models: [LibraryModel]) {
        self.record = record
        name = ReclaimNames.resolve(paths: [record.from], models: models)
        bytes = ReclaimFormat.byteCount(record.bytes)
        date = ReclaimFormat.movedAt(record.movedAt)
    }
}

struct ReclaimHistoryRow: Identifiable {
    let batch: SourceCleanupBatch
    let name: ReclaimName
    let date: String
    let bytes: String?
    let itemsLabel: String
    var id: String { batch.id }

    /// The kept output the originals belong to, and the shared item state when every item has the same one.
    let context: String?

    /// The date when recorded, else "Earlier cleanup"; bytes only when every item recorded them.
    var subtitle: String {
        [date, bytes, context].compactMap { $0 }.joined(separator: " · ")
    }

    init(_ batch: SourceCleanupBatch, models: [LibraryModel]) {
        self.batch = batch
        let first = batch.items.first?.record
        name = ReclaimNames.resolve(paths: [first?.from].compactMap { $0 }, models: models)
        date = batch.movedAt.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "Earlier cleanup"
        bytes = batch.bytes.map { ReclaimFormat.byteCount($0) }
        itemsLabel = "\(batch.items.count) source \(batch.items.count == 1 ? "item" : "items")"
        let original = first?.outputPath.map { "Original of \(ReclaimNames.resolve(paths: [$0], models: models).title)" }
        let states = Set(batch.items.map(\.state.rawValue))
        let state = states.count == 1 ? states.first : nil
        let parts = [original, state].compactMap { $0 }
        context = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
