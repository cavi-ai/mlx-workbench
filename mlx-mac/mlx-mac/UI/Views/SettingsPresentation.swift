import CoreGraphics
import Foundation

// MARK: - Directory state

/// What a path is on disk, as reported by `SettingsDirectoryProbe`.
enum SettingsDirectoryState: Equatable, Sendable {
    case exists, missing, notDirectory

    /// The non-blocking warning shown under a path field.
    var warning: String? {
        switch self {
        case .exists: return nil
        case .missing: return "Directory does not exist yet."
        case .notDirectory: return "Path exists but is not a directory."
        }
    }
}

// MARK: - Paths

/// Path comparison in the agent's spelling space: tilde expanded, standardized,
/// compared on component boundaries, never resolved through symlinks.
enum SettingsPath {
    static func trimmed(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pure string work: no file system access, no symlink resolution.
    static func normalized(_ path: String) -> String {
        let expanded = NSString(string: trimmed(path)).expandingTildeInPath
        var parts: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return (expanded.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    /// True when `path` is `root` or lies under it.
    static func contains(root: String, path: String) -> Bool {
        let root = normalized(root)
        let path = normalized(path)
        guard !root.isEmpty, !path.isEmpty else { return false }
        if path == root { return true }
        return path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func depth(_ path: String) -> Int {
        normalized(path).split(separator: "/").count
    }
}

// MARK: - Ledger

enum SettingsTone: Equatable {
    case neutral, positive, warning, negative
}

/// One folder the library is fed from, with what it contributed to the last scan.
struct SettingsLedgerRow: Equatable, Identifiable {
    enum Kind: Equatable { case gguf, mlx, output }

    enum State: Equatable {
        case counted(models: Int, bytes: Int64)
        case none
        case notInLastScan
        case draftOnly
        case missing
        case notDirectory
        case noSnapshot
        case scanning
    }

    let kind: Kind
    let path: String
    let state: State

    var id: String { "\(kind):\(path)" }

    /// The last path component, or the whole path for a root.
    var name: String {
        let last = (SettingsPath.normalized(path) as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

extension SettingsLedgerRow.State {
    var figures: String {
        switch self {
        case .counted(let models, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(models) \(models == 1 ? "model" : "models") · \(size)"
        case .none: return "No models in the last scan"
        case .notInLastScan: return "Not in the last scan"
        case .draftOnly: return "Not saved yet"
        case .missing: return "Folder missing"
        case .notDirectory: return "Not a folder"
        case .noSnapshot: return "No scan yet"
        case .scanning: return "Scanning…"
        }
    }

    var symbol: String {
        switch self {
        case .counted, .none: return "folder"
        case .notInLastScan: return "folder.badge.questionmark"
        case .draftOnly: return "folder.badge.plus"
        case .missing, .notDirectory: return "exclamationmark.triangle.fill"
        case .noSnapshot, .scanning: return "folder"
        }
    }

    var tone: SettingsTone {
        switch self {
        case .missing, .notDirectory: return .warning
        default: return .neutral
        }
    }

    /// Counted figures are data, so they read as primary text rather than a status colour.
    var isCounted: Bool {
        if case .counted = self { return true }
        return false
    }

    /// Only a saved folder the last scan did not read can be resolved by a rescan.
    var offersRescan: Bool { self == .notInLastScan }
}

/// The ledger for the model folders and the output directory. Pure: directory
/// states and the snapshot arrive as values.
struct SettingsPresentation: Equatable {
    let gguf: [SettingsLedgerRow]
    let mlx: [SettingsLedgerRow]
    let output: SettingsLedgerRow?
    /// Models under no folder the last scan read from the rows above; zero when the roots are unknown.
    let outsideModels: Int

    static let emptyGGUF = "Saving uses the detected folders"
    static let emptyMLX = "MLX models are found in the GGUF folders and the output directory"

    static func make(
        saved: Config,
        ggufRoots: [String],
        mlxRoots: [String],
        outputDir: String,
        snapshot: LibrarySnapshot?,
        scannedRoots: ScanRoots?,
        directories: [String: SettingsDirectoryState],
        isScanning: Bool
    ) -> SettingsPresentation {
        var draft: [(SettingsLedgerRow.Kind, String)] = []
        for path in ggufRoots where !SettingsPath.trimmed(path).isEmpty { draft.append((.gguf, SettingsPath.trimmed(path))) }
        for path in mlxRoots where !SettingsPath.trimmed(path).isEmpty { draft.append((.mlx, SettingsPath.trimmed(path))) }
        if !SettingsPath.trimmed(outputDir).isEmpty { draft.append((.output, SettingsPath.trimmed(outputDir))) }

        func savedPaths(_ kind: SettingsLedgerRow.Kind) -> [String] {
            switch kind {
            case .gguf: return saved.ggufRoots
            case .mlx: return saved.mlxRoots
            case .output: return [saved.outputDir]
            }
        }

        func scannedPaths(_ kind: SettingsLedgerRow.Kind) -> [String]? {
            guard snapshot != nil, let roots = scannedRoots else { return nil }
            return kind == .gguf ? roots.gguf : roots.mlx
        }

        func isSaved(_ kind: SettingsLedgerRow.Kind, _ path: String) -> Bool {
            savedPaths(kind).contains { SettingsPath.normalized($0) == SettingsPath.normalized(path) }
        }

        func isScanned(_ kind: SettingsLedgerRow.Kind, _ path: String) -> Bool {
            (scannedPaths(kind) ?? []).contains { SettingsPath.contains(root: $0, path: path) }
        }

        // Only saved folders the last scan read can own a model.
        let owners = Set(draft.filter { isSaved($0.0, $0.1) && isScanned($0.0, $0.1) }.map { SettingsPath.normalized($0.1) })
        let attribution = attribute(models: snapshot?.models ?? [], owners: owners)

        func row(_ kind: SettingsLedgerRow.Kind, _ path: String) -> SettingsLedgerRow {
            SettingsLedgerRow(kind: kind, path: path, state: state(kind, path))
        }

        func state(_ kind: SettingsLedgerRow.Kind, _ path: String) -> SettingsLedgerRow.State {
            switch directories[path] {
            case .missing: return .missing
            case .notDirectory: return .notDirectory
            case .exists, nil: break
            }
            guard isSaved(kind, path) else { return .draftOnly }
            guard snapshot != nil, scannedRoots != nil else { return isScanning ? .scanning : .noSnapshot }
            guard isScanned(kind, path) else { return isScanning ? .scanning : .notInLastScan }
            let own = attribution.counts[SettingsPath.normalized(path)] ?? (models: 0, bytes: 0)
            return own.models == 0 ? .none : .counted(models: own.models, bytes: own.bytes)
        }

        return SettingsPresentation(
            gguf: draft.filter { $0.0 == .gguf }.map { row($0.0, $0.1) },
            mlx: draft.filter { $0.0 == .mlx }.map { row($0.0, $0.1) },
            output: draft.first { $0.0 == .output }.map { row($0.0, $0.1) },
            outsideModels: snapshot == nil || scannedRoots == nil ? 0 : attribution.outside
        )
    }

    /// Each model belongs to the deepest owner containing it, and is counted once.
    static func attribute(
        models: [LibraryModel],
        owners: Set<String>
    ) -> (counts: [String: (models: Int, bytes: Int64)], outside: Int) {
        let ordered = owners.sorted {
            SettingsPath.depth($0) != SettingsPath.depth($1) ? SettingsPath.depth($0) > SettingsPath.depth($1) : $0 < $1
        }
        var counts: [String: (models: Int, bytes: Int64)] = [:]
        var seen = Set<String>()
        var outside = 0
        for model in models {
            let path = SettingsPath.normalized(model.item.path)
            guard seen.insert(path).inserted else { continue }
            if let owner = ordered.first(where: { SettingsPath.contains(root: $0, path: path) }) {
                let current = counts[owner] ?? (models: 0, bytes: 0)
                counts[owner] = (current.models + 1, current.bytes + model.item.bytes)
            } else {
                outside += 1
            }
        }
        return (counts, outside)
    }

    static func footer(snapshot: LibrarySnapshot?, now: Date) -> String {
        guard let snapshot else { return "No scan yet; figures appear after the first scan." }
        let age = WorkbenchRelativeTime.text(for: snapshot.generatedAt, style: .full, now: now)
        return "Model sizes from the last scan, as of \(age); models that share cache files are each counted in full."
    }

    static func outsideText(_ count: Int) -> String? {
        count > 0 ? "\(count) \(count == 1 ? "model" : "models") outside these folders" : nil
    }
}

// MARK: - Engine

/// What the inline Engine status row says about the saved checkout.
struct SettingsEngineStatus: Equatable {
    let word: String
    let detail: String?
    let symbol: String
    let tone: SettingsTone

    static func make(health: AgentHealth, savedPath: String, draftPath: String) -> SettingsEngineStatus {
        if SettingsPath.trimmed(draftPath) != SettingsPath.trimmed(savedPath) {
            return SettingsEngineStatus(word: "Checked when you save", detail: nil, symbol: "questionmark.circle", tone: .neutral)
        }
        switch health {
        case .ready:
            return SettingsEngineStatus(word: "Found", detail: nil, symbol: "checkmark.circle.fill", tone: .positive)
        case .notFound:
            return SettingsEngineStatus(word: "Not found", detail: "scripts/mlx-agent is missing from the saved checkout.", symbol: "xmark.circle.fill", tone: .negative)
        case .notUsable(_, _, let reason):
            return SettingsEngineStatus(word: "Can't be used", detail: reason, symbol: "xmark.circle.fill", tone: .negative)
        case .notConfigured:
            return SettingsEngineStatus(word: "Not configured", detail: "Set the checkout path, or choose Detect.", symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
    }
}

// MARK: - Layout

/// Settings width thresholds, derived from the width the page is offered.
struct SettingsLayout: Equatable {
    /// The page content width, including group padding.
    private(set) var contentWidth: CGFloat
    /// The width inside a group.
    private(set) var innerWidth: CGFloat
    /// Labels sit above their controls.
    private(set) var stacksRows = false
    /// A ledger row's figures sit under its path.
    private(set) var stacksLedgerFigures = false

    static let assumedViewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2

    /// A compact layout flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(width: CGFloat, threshold: CGFloat, wasCompact: Bool) -> Bool {
        width < (wasCompact ? threshold + WorkbenchSize.Settings.hysteresis : threshold)
    }

    /// The offered width that yields `innerWidth` inside a group, below the content cap.
    static func viewportWidth(forInnerWidth inner: CGFloat) -> CGFloat {
        inner + WorkbenchSize.Settings.groupPadding * 2 + WorkbenchSpacing.pageInset * 2
    }

    init(viewportWidth: CGFloat = Self.assumedViewportWidth, previous: SettingsLayout? = nil) {
        let page = min(max(viewportWidth - WorkbenchSpacing.pageInset * 2, 0), WorkbenchSize.Settings.contentMaxWidth)
        contentWidth = page
        innerWidth = max(page - WorkbenchSize.Settings.groupPadding * 2, 0)
        stacksRows = Self.isCompact(
            width: innerWidth, threshold: WorkbenchSize.Settings.rowThreshold,
            wasCompact: previous?.stacksRows ?? false
        )
        stacksLedgerFigures = Self.isCompact(
            width: innerWidth, threshold: WorkbenchSize.Settings.ledgerThreshold,
            wasCompact: previous?.stacksLedgerFigures ?? false
        )
    }
}
