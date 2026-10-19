import Foundation

// MARK: - Verdict

/// The resolution's verdict as one sentence with a symbol and a tone.
struct IntakeVerdictLine: Equatable {
    enum Tone: Equatable {
        case positive, neutral, warning, failure
    }

    let symbol: String
    let tone: Tone
    let sentence: String

    static func make(_ resolution: IntakeResolution, inLibrary: Bool = false) -> IntakeVerdictLine {
        let symbol: String
        let tone: Tone
        let detail: String
        switch resolution.verdict {
        case .unknown:
            (symbol, tone, detail) = ("wifi.exclamationmark", .warning, "Check could not read this repository.")
        case .blocked:
            (symbol, tone, detail) = ("lock.fill", .failure, "This repository cannot be added.")
        case .alreadyMLX:
            if let backend = resolution.backend, !resolution.backendInstalled {
                (symbol, tone, detail) = ("checkmark.circle", .positive, "It runs without conversion once \(backend) is installed.")
            } else if inLibrary || resolution.cached == true {
                (symbol, tone, detail) = ("checkmark.circle", .positive, "It is already downloaded and runs without conversion.")
            } else {
                (symbol, tone, detail) = ("checkmark.circle", .positive, "It downloads and runs without conversion.")
            }
        case .gguf:
            (symbol, tone, detail) = ("shippingbox", .neutral, "Pick a file; it downloads and converts to MLX.")
        case .convertible:
            (symbol, tone, detail) = ("arrow.triangle.2.circlepath", .positive, resolution.cached == true
                ? "It is already downloaded and converts to MLX."
                : "It downloads, then converts to MLX.")
        case .convertibleAfterInstall:
            (symbol, tone, detail) = (
                "wrench.and.screwdriver", .neutral,
                "Install \(resolution.backend ?? "the converter backend") first, then it converts to MLX."
            )
        case .unsupported:
            (symbol, tone, detail) = ("nosign", .failure, "No installed or declared backend converts this architecture.")
        }
        return IntakeVerdictLine(symbol: symbol, tone: tone, sentence: "\(resolution.verdict.title). \(detail)")
    }
}

// MARK: - Activity

enum IntakeActivityPresentation {
    static let idleSentence = "Paste a Hugging Face link or org/name. Check reads the model card and config; nothing downloads until you confirm."

    /// The in-flight sentence; nil while idle or failed.
    static func sentence(_ activity: IntakeCoordinator.Activity) -> String? {
        switch activity {
        case .idle, .failed: return nil
        case .resolving: return "Reading the model card and config…"
        case .installing(let backend): return "Installing \(backend) into its own environment…"
        case .downloading(let repo): return "Downloading \(repo)…"
        case .analyzing: return "Analyzing the architecture…"
        case .drafting: return "Drafting a port plan with a local model…"
        }
    }
}

// MARK: - Log

enum IntakeLogPresentation {
    /// The log opens by itself only while a download or install is writing it.
    static func autoExpands(_ activity: IntakeCoordinator.Activity) -> Bool {
        switch activity {
        case .downloading, .installing: return true
        default: return false
        }
    }

    static func isVisible(activity: IntakeCoordinator.Activity, lines: [String]) -> Bool {
        !lines.isEmpty || autoExpands(activity)
    }

    /// A user's choice holds until a new check starts.
    static func override(_ current: Bool?, after activity: IntakeCoordinator.Activity) -> Bool? {
        activity == .resolving ? nil : current
    }

    /// The user's choice, else open while writing and after a failure that left output.
    static func isExpanded(override: Bool?, activity: IntakeCoordinator.Activity, lines: [String]) -> Bool {
        if let override { return override }
        if case .failed = activity { return !lines.isEmpty }
        return autoExpands(activity)
    }

    static func title(_ activity: IntakeCoordinator.Activity) -> String {
        switch activity {
        case .downloading: return "Download log"
        case .installing: return "Install log"
        default: return "Log"
        }
    }
}

// MARK: - Library

enum IntakeLibraryMatch {
    /// Paths of Library models that are ready to run.
    static func readyPaths(in snapshot: LibrarySnapshot?) -> Set<String> {
        Set((snapshot?.models ?? []).filter { $0.readiness == .ready }.map { $0.item.path })
    }

    /// The ready cache path of this source's repository at its revision. A checkpoint folder inside a
    /// repository is a different model from the repository cache, so only root sources match.
    static func path(for resolution: IntakeResolution, readyPaths: Set<String>) -> String? {
        guard resolution.source.subfolder == nil else { return nil }
        return IntakeCoordinator.readyCachePath(
            repo: resolution.source.repo, revision: resolution.source.revision, readyPaths: readyPaths
        )
    }
}

// MARK: - Fit

/// The estimated output's fit against this Mac's live model budget, from the owner Overview and Library use.
struct IntakeFit: Equatable {
    enum State: Equatable {
        case estimated, redacted, unavailable, sizeUnknown, notServable
    }

    let state: State
    let tone: ModelBudgetPresentation.Tone
    let word: String
    let symbol: String
    /// Share of the model budget the output needs, 0...1; nil without an estimate.
    let fill: Double?
    let detail: String

    var showsTrack: Bool { state == .estimated || state == .redacted }

    /// One spoken reading; the placeholder word never reaches VoiceOver while memory loads.
    var accessibilityLabel: String {
        state == .redacted ? "Fit on this Mac: reading memory" : "Fit on this Mac: \(word). \(detail)"
    }

    /// Verdicts that end in a download have a size to fit.
    static func appliesTo(_ verdict: IntakeVerdict) -> Bool {
        switch verdict {
        case .alreadyMLX, .gguf, .convertible, .convertibleAfterInstall: return true
        case .unknown, .blocked, .unsupported: return false
        }
    }

    static func make(
        _ resolution: IntakeResolution,
        qBits configured: Int,
        selectedGGUF: String? = nil,
        memory: MemorySnapshot?,
        hasProbed: Bool,
        contextTokens: Int,
        reserveGB: Double,
        hardware: HardwareProfile
    ) -> IntakeFit? {
        guard appliesTo(resolution.verdict) else { return nil }
        let task = resolution.task?.type
        func plain(_ state: State, word: String, symbol: String = "questionmark.circle", detail: String) -> IntakeFit {
            IntakeFit(state: state, tone: .neutral, word: word, symbol: symbol, fill: nil, detail: detail)
        }
        if let task, !task.isServable {
            return plain(.notServable, word: "Not estimated", detail: "Fit is not estimated for \(task.title.lowercased()) models.")
        }
        let bits = ModelWorkflowCoordinator.allowedBits(configured, allowed: resolution.qBits)
        let bytes: Int64?
        let basis: String
        if let estimate = resolution.estimatedOutputBytes?[String(bits)] {
            (bytes, basis) = (estimate, "estimated \(bits)-bit output")
        } else if resolution.verdict == .alreadyMLX {
            (bytes, basis) = (resolution.downloadBytes ?? resolution.bytes, "download size")
        } else if resolution.verdict == .gguf {
            (bytes, basis) = (resolution.files.gguf.first { $0.name == selectedGGUF }?.bytes, "selected file")
        } else {
            (bytes, basis) = (nil, "")
        }
        guard let bytes, bytes > 0 else {
            let detail = resolution.verdict == .gguf
                ? "Pick a file to see its fit."
                : "There is no output size estimate for this source."
            return plain(.sizeUnknown, word: "Size unknown", detail: detail)
        }
        let budget = ModelBudgetPresentation(
            memory: memory, reserveGB: reserveGB, contextTokens: contextTokens,
            subject: ModelBudgetPresentation.Subject(bytes: bytes, parameters: nil, task: task),
            hardware: hardware, hasProbed: hasProbed
        )
        let size = LibraryTablePresentation.byteCount(bytes)
        switch budget.reading {
        case .loading:
            return IntakeFit(
                state: .redacted, tone: .neutral, word: "Won't fit", symbol: budget.verdictSymbol, fill: nil,
                detail: "Reading memory"
            )
        case .unavailable:
            return plain(.unavailable, word: "Memory unavailable", symbol: budget.verdictSymbol, detail: budget.unavailableText)
        case .live:
            guard let word = budget.verdictWord, let fill = budget.fitFraction else {
                return plain(.sizeUnknown, word: "Not estimated", symbol: budget.verdictSymbol, detail: budget.verdictText)
            }
            return IntakeFit(
                state: .estimated, tone: budget.tone, word: word, symbol: budget.verdictSymbol,
                fill: LibraryFitPresentation.quantized(fill),
                detail: "\(budget.verdictText) (\(basis), \(size))"
            )
        }
    }
}

// MARK: - Summary

struct IntakeItem: Equatable, Identifiable {
    let figure: String
    let label: String
    /// Sizes read in tabular digits; names and types stay proportional.
    let isNumeric: Bool

    var id: String { label }
}

// MARK: - Components

struct IntakeComponentRow: Equatable, Identifiable {
    let role: String
    let type: String
    let detail: String
    let isMatched: Bool

    var id: String { role }
}

// MARK: - IntakePresentation

enum IntakePresentation {
    /// `qBits` is the configured width; a source that converts only at other widths shows the one Prepare will use.
    static func summaryRows(_ resolution: IntakeResolution, qBits configured: Int) -> [DetailRow] {
        let qBits = ModelWorkflowCoordinator.allowedBits(configured, allowed: resolution.qBits)
        var rows = [DetailRow("Download", resolution.cached == true
            ? "Already cached"
            : LibraryTablePresentation.byteCount(resolution.downloadBytes ?? resolution.bytes))]
        if let estimate = resolution.estimatedOutputBytes?[String(qBits)] {
            rows.append(DetailRow("Estimated \(qBits)-bit output", LibraryTablePresentation.byteCount(estimate)))
        }
        if let task = resolution.task {
            rows.append(DetailRow("Type", task.type.title))
            if !task.useCases.isEmpty {
                rows.append(DetailRow("Use cases", task.useCases.map(ModelTaskPresentation.useCaseTitle).joined(separator: ", ")))
            }
        }
        rows.append(DetailRow("Architecture", resolution.modelType ?? "Unknown"))
        if let backend = resolution.backend {
            rows.append(DetailRow("Backend", "\(backend)\(resolution.backendInstalled ? "" : " (not installed)")"))
        }
        if let recipe = resolution.recipe {
            rows.append(DetailRow("Built from", "\(recipe.base) + \(recipe.lora)"))
        }
        return rows
    }

    /// Each summary row as a figure over its label.
    static func items(_ resolution: IntakeResolution, qBits: Int) -> [IntakeItem] {
        summaryRows(resolution, qBits: qBits).map { row in
            IntakeItem(
                figure: row.value,
                label: row.label == "Download" ? "Download size" : row.label,
                isNumeric: (row.label == "Download" && resolution.cached != true) || row.label.hasPrefix("Estimated")
            )
        }
    }

    static func componentRows(_ resolution: IntakeResolution) -> [IntakeComponentRow] {
        resolution.components.map { component in
            IntakeComponentRow(
                role: component.role,
                type: component.modelType,
                detail: component.matches.first.map { "\($0.module) (\($0.match))" } ?? "No MLX implementation",
                isMatched: !component.matches.isEmpty
            )
        }
    }

    static func reasonTexts(_ resolution: IntakeResolution) -> [String] {
        resolution.reasons.map { reason in
            switch reason {
            case "arch_not_in_registry": return "No installed or declared MLX backend implements \(resolution.modelType ?? "this architecture")."
            case "custom_code": return "The repository ships custom modeling code; it is read, never executed."
            case "no_config": return "The repository has no readable config.json."
            case "gated": return "The repository is gated; downloads need a token, which intake does not handle."
            case "not_found_or_private": return "The repository does not exist or is private."
            case "hub_unreachable": return "Hugging Face could not be reached."
            default: return reason
            }
        } + resolution.warnings
    }
}
