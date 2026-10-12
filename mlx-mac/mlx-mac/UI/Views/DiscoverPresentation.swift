import SwiftUI

// MARK: - Layout

/// Discover's width thresholds, derived from the width the page is offered and built
/// on the Run content width, never from measured children.
struct DiscoverLayout: Equatable {
    enum HeaderMode: Equatable {
        /// Role, per-role limit, Fast and Discover on one line.
        case oneLine
        /// The role control takes its own line above the rest.
        case roleOwnLine
        /// Every control on its own line.
        case stacked
    }

    private(set) var contentWidth: CGFloat
    private(set) var headerMode: HeaderMode = .oneLine
    private(set) var isWideRow = true
    private(set) var legendWraps = false

    static let assumedViewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2

    /// A compact layout flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(width: CGFloat, threshold: CGFloat, wasCompact: Bool) -> Bool {
        width < (wasCompact ? threshold + WorkbenchSize.Discover.hysteresis : threshold)
    }

    init(viewportWidth: CGFloat = Self.assumedViewportWidth, previous: DiscoverLayout? = nil) {
        let width = min(max(viewportWidth - WorkbenchSpacing.pageInset * 2, 0), WorkbenchSize.Discover.contentMaxWidth)
        contentWidth = width
        let wasStacked = previous?.headerMode == .stacked
        let wasOffLine = previous.map { $0.headerMode != .oneLine } ?? false
        if Self.isCompact(width: width, threshold: WorkbenchSize.Discover.headerStackThreshold, wasCompact: wasStacked) {
            headerMode = .stacked
        } else if Self.isCompact(width: width, threshold: WorkbenchSize.Discover.headerThreshold, wasCompact: wasOffLine) {
            headerMode = .roleOwnLine
        } else {
            headerMode = .oneLine
        }
        isWideRow = !Self.isCompact(
            width: width, threshold: WorkbenchSize.Discover.rowThreshold, wasCompact: !(previous?.isWideRow ?? true)
        )
        legendWraps = Self.isCompact(
            width: width, threshold: WorkbenchSize.Discover.legendThreshold, wasCompact: previous?.legendWraps ?? false
        )
    }
}

// MARK: - Controls

enum DiscoverRole {
    /// The empty string is Any; the rest are exactly the roles `discover --role` accepts.
    static let choices = [""] + WorkbenchAPI.discoveryRoleOrder

    static func title(_ role: String) -> String {
        switch role {
        case "": return "Any"
        case "tool-use": return "Tool use"
        default: return role.prefix(1).uppercased() + role.dropFirst()
        }
    }
}

/// The agent's limit is per role, so the request is a bounded integer.
enum DiscoverLimit {
    static let range = 1...50
    static let initial = 10

    static func clamped(_ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

// MARK: - Fit

/// One candidate's fit against this Mac's live model budget. The verdict, the bar
/// and the tone come from `ModelBudgetPresentation`, the owner Overview and Library use.
struct DiscoverFit: Equatable {
    enum State: Equatable {
        case estimated, sizeUnknown, notEstimated, unavailable, redacted
    }

    let state: State
    let tone: ModelBudgetPresentation.Tone
    let word: String
    let symbol: String
    /// Share of the model budget the candidate needs, 0...1; nil without an estimate.
    let fill: Double?
    let weightsText: String?
    let help: String
    /// The agent's static weights-under-80%-of-memory check, shown only as a labelled basis.
    let agentBasis: String?
    /// The basis, when it points the opposite way from the live verdict.
    let basisNote: String?

    var showsTrack: Bool { state == .estimated || state == .redacted }

    var spokenVerdict: String {
        switch state {
        case .redacted: return "reading memory"
        case .unavailable: return "memory reading unavailable"
        case .sizeUnknown: return "size unknown"
        case .notEstimated: return "fit not estimated"
        case .estimated: return word.lowercased()
        }
    }

    static func make(
        candidate: DiscoverCandidate,
        memory: MemorySnapshot?,
        hasProbed: Bool,
        reserveGB: Double,
        contextTokens: Int,
        hardware: HardwareProfile
    ) -> DiscoverFit {
        guard let gb = candidate.estRamGb, gb.isFinite, gb > 0, gb < 1_000_000 else {
            return DiscoverFit(
                state: .sizeUnknown, tone: .neutral, word: "Size unknown", symbol: "questionmark.circle", fill: nil,
                weightsText: nil, help: "No size estimate for this repository. Discover without Fast to inspect sizes.",
                agentBasis: nil, basisNote: nil
            )
        }
        let subject = ModelBudgetPresentation.Subject(bytes: Int64(gb * 1e9), parameters: nil, task: nil)
        let budget = ModelBudgetPresentation(
            memory: memory, reserveGB: reserveGB, contextTokens: contextTokens,
            subject: subject, hardware: hardware, hasProbed: hasProbed
        )
        let weights = "~" + ModelBudgetPresentation.gb(gb) + " GB weights (est.)"
        let basis = candidate.fits.map {
            "Static check: weights \($0 ? "under" : "over") 80% of total memory"
        }
        func plain(_ state: State, word: String, help: String) -> DiscoverFit {
            DiscoverFit(
                state: state, tone: .neutral, word: word, symbol: budget.verdictSymbol, fill: nil,
                weightsText: weights, help: help, agentBasis: basis, basisNote: nil
            )
        }
        switch budget.reading {
        case .loading:
            return plain(.redacted, word: "Won't fit", help: "Reading memory")
        case .unavailable:
            return plain(.unavailable, word: "Memory unavailable", help: budget.unavailableText)
        case .live:
            guard let word = budget.verdictWord, let fill = budget.fitFraction else {
                return plain(.notEstimated, word: "Not estimated", help: budget.verdictText)
            }
            let disagrees = (candidate.fits == true && budget.tone == .wontFit) || (candidate.fits == false && budget.tone == .fits)
            var help = "Right now: " + budget.verdictText
            if let basis { help += ". " + basis }
            return DiscoverFit(
                state: .estimated, tone: budget.tone, word: word, symbol: budget.verdictSymbol,
                fill: LibraryFitPresentation.quantized(fill), weightsText: weights, help: help,
                agentBasis: basis, basisNote: disagrees ? basis : nil
            )
        }
    }
}

// MARK: - Legend

/// The budget the bars are drawn against, from the same owner as Overview's instrument.
struct DiscoverLegend: Equatable {
    static let title = "Model budget"

    let reading: ModelBudgetPresentation.Reading
    /// "~19.1 GB"; nil until a live reading exists.
    let lead: String?
    let caption: String
    let compactCaption: String
    let help: String

    static func make(memory: MemorySnapshot?, hasProbed: Bool, reserveGB: Double, contextTokens: Int, hardware: HardwareProfile) -> DiscoverLegend {
        let budget = ModelBudgetPresentation(
            memory: memory, reserveGB: reserveGB, contextTokens: contextTokens,
            subject: nil, hardware: hardware, hasProbed: hasProbed
        )
        let help = "Available memory less the reserve, right now. Each bar is the share of this budget a model needs with its context."
        switch budget.reading {
        case .loading:
            return DiscoverLegend(reading: .loading, lead: nil, caption: budget.caption, compactCaption: budget.compactCaption, help: help)
        case .unavailable:
            return DiscoverLegend(
                reading: .unavailable, lead: nil, caption: budget.unavailableText, compactCaption: budget.unavailableText, help: help
            )
        case .live:
            return DiscoverLegend(
                reading: .live, lead: budget.leadText.map { $0 + " " + budget.unitText },
                caption: budget.caption, compactCaption: budget.compactCaption, help: help
            )
        }
    }
}

// MARK: - Rows

struct DiscoverRow: Equatable, Identifiable {
    let id: String
    let repo: String
    let roles: [String]
    let license: String?
    let downloadsText: String?
    let likesText: String?
    let fit: DiscoverFit
    let isInLibrary: Bool

    /// "1.2K", "3.4M": deterministic and locale-free.
    static func compactCount(_ value: Int) -> String {
        guard value >= 1_000 else { return String(max(value, 0)) }
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let number = Double(value) / divisor
            return (number < 10 ? String(format: "%.1f", number) : String(format: "%.0f", number)) + suffix
        }
        return value >= 1_000_000 ? scaled(1_000_000, "M") : scaled(1_000, "K")
    }

    /// A redacted row that holds the final layout while a run is in flight; it implies no count.
    static func placeholder(_ index: Int) -> DiscoverRow {
        DiscoverRow(
            id: "placeholder-\(index)",
            repo: "organization/model-name-4bit",
            roles: ["coding"],
            license: "apache-2.0",
            downloadsText: "12K",
            likesText: "340",
            fit: DiscoverFit(
                state: .redacted, tone: .neutral, word: "Won't fit", symbol: "questionmark.circle", fill: nil,
                weightsText: "~00.0 GB weights (est.)", help: "", agentBasis: nil, basisNote: nil
            ),
            isInLibrary: false
        )
    }

    var accessibilityLabel: String {
        var parts = [repo]
        if !roles.isEmpty { parts.append(roles.joined(separator: ", ")) }
        if isInLibrary { parts.append("In Library") }
        parts.append(fit.state == .sizeUnknown ? "size unknown" : "\(fit.weightsText ?? ""), \(fit.spokenVerdict)")
        if let downloadsText { parts.append("\(downloadsText) downloads") }
        if let likesText { parts.append("\(likesText) likes") }
        if let license { parts.append(license) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Presentation

/// Everything the candidate list shows, derived from injected inputs: no I/O,
/// no process. Rows keep the agent's order.
struct DiscoverPresentation: Equatable {
    let legend: DiscoverLegend
    let rows: [DiscoverRow]

    /// Repo ids of Library models whose path is in the Hugging Face cache layout.
    /// Positive-only: a model stored elsewhere, a conversion or another quantization never matches.
    static func libraryRepos(in snapshot: LibrarySnapshot?) -> Set<String> {
        Set(libraryModels(in: snapshot).keys)
    }

    /// The first Library model for each cached repo id, built once per snapshot.
    static func libraryModels(in snapshot: LibrarySnapshot?) -> [String: LibraryModel] {
        var models: [String: LibraryModel] = [:]
        for model in snapshot?.models ?? [] {
            if let repo = HFRepoID.forPath(model.item.path), models[repo] == nil {
                models[repo] = model
            }
        }
        return models
    }

    /// The Library model cached under `repo`, if any.
    static func libraryModel(for repo: String, in models: [String: LibraryModel]) -> LibraryModel? {
        models[repo]
    }

    static func make(
        candidates: [DiscoverCandidate],
        memory: MemorySnapshot?,
        hasProbed: Bool,
        reserveGB: Double,
        contextTokens: Int,
        hardware: HardwareProfile,
        library: LibrarySnapshot?
    ) -> DiscoverPresentation {
        let owned = libraryRepos(in: library)
        let rows = candidates.map { candidate in
            DiscoverRow(
                id: candidate.repo,
                repo: candidate.repo,
                roles: candidate.roles ?? [],
                license: candidate.license,
                downloadsText: candidate.downloads.map(DiscoverRow.compactCount),
                likesText: candidate.likes.map(DiscoverRow.compactCount),
                fit: DiscoverFit.make(
                    candidate: candidate, memory: memory, hasProbed: hasProbed, reserveGB: reserveGB,
                    contextTokens: contextTokens, hardware: hardware
                ),
                isInLibrary: owned.contains(candidate.repo)
            )
        }
        return DiscoverPresentation(
            legend: DiscoverLegend.make(
                memory: memory, hasProbed: hasProbed, reserveGB: reserveGB, contextTokens: contextTokens, hardware: hardware
            ),
            rows: rows
        )
    }
}

// MARK: - States

struct DiscoverStatePresentation: Equatable {
    enum Kind: Equatable {
        case idle, running, empty, failed, populated
    }

    let kind: Kind
    let symbol: String
    let sentence: String

    static let runningSentence = "Discovering models. This lists and inspects Hugging Face repositories and can take a few minutes; Fast is quicker but may miss sizes."
    static let fastRunningSentence = "Discovering models. This lists Hugging Face repositories without inspecting them, so sizes may be missing."

    /// `fast` is the mode the running discovery was started with.
    static func make(_ state: DiscoveryState, fast: Bool = false) -> DiscoverStatePresentation {
        switch state {
        case .notRun:
            return DiscoverStatePresentation(kind: .idle, symbol: state.symbol, sentence: state.message)
        case .running:
            return DiscoverStatePresentation(kind: .running, symbol: state.symbol, sentence: fast ? fastRunningSentence : runningSentence)
        case .completed(let candidates):
            return candidates.isEmpty
                ? DiscoverStatePresentation(kind: .empty, symbol: state.symbol, sentence: state.message)
                : DiscoverStatePresentation(kind: .populated, symbol: state.symbol, sentence: "")
        case .failed:
            return DiscoverStatePresentation(kind: .failed, symbol: state.symbol, sentence: state.message)
        }
    }
}

// MARK: - Intake handoff

/// The row action: open the intake window prefilled with the repository. The window
/// resolves the repo and asks before it downloads; nothing is fetched from here.
enum DiscoverIntakeAction {
    static let title = "Add from Hugging Face…"
    static let busyHelp = "An intake is in progress"
    static let readyHelp = "Opens the intake window for this repository; nothing downloads until you confirm there"

    static func isEnabled(intakeIsBusy: Bool) -> Bool { !intakeIsBusy }

    static func help(intakeIsBusy: Bool) -> String { intakeIsBusy ? busyHelp : readyHelp }

    /// Returns whether the window was opened; a busy intake is left untouched.
    @MainActor
    @discardableResult
    static func perform(repo: String, intake: IntakeCoordinator, openWindow: () -> Void) -> Bool {
        guard isEnabled(intakeIsBusy: intake.isBusy) else { return false }
        intake.open(with: repo)
        openWindow()
        return true
    }
}
