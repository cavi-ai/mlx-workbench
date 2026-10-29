import SwiftUI

// MARK: - Layout

/// LM Studio's width thresholds, derived from the width the page is offered and built
/// on the Run content width, never from measured children.
struct LMStudioLayout: Equatable {
    enum RowTier: Equatable {
        case wide, medium, stacked
    }

    private(set) var contentWidth: CGFloat
    private(set) var rowTier = RowTier.wide
    private(set) var headerWraps = false
    private(set) var legendWraps = false

    static let assumedViewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2

    /// A compact layout flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(width: CGFloat, threshold: CGFloat, wasCompact: Bool) -> Bool {
        width < (wasCompact ? threshold + WorkbenchSize.LMStudio.hysteresis : threshold)
    }

    init(viewportWidth: CGFloat = Self.assumedViewportWidth, previous: LMStudioLayout? = nil) {
        let width = min(max(viewportWidth - WorkbenchSpacing.pageInset * 2, 0), WorkbenchSize.LMStudio.contentMaxWidth)
        contentWidth = width
        let prior = previous?.rowTier ?? .wide
        if Self.isCompact(width: width, threshold: WorkbenchSize.LMStudio.rowThreshold, wasCompact: prior != .wide) {
            let stacked = Self.isCompact(
                width: width, threshold: WorkbenchSize.LMStudio.mediumThreshold, wasCompact: prior == .stacked
            )
            rowTier = stacked ? .stacked : .medium
        }
        headerWraps = Self.isCompact(
            width: width, threshold: WorkbenchSize.LMStudio.headerThreshold, wasCompact: previous?.headerWraps ?? false
        )
        legendWraps = Self.isCompact(
            width: width, threshold: WorkbenchSize.LMStudio.legendThreshold, wasCompact: previous?.legendWraps ?? false
        )
    }
}

// MARK: - Path math

/// Path arithmetic on strings only: it never touches the file system, so it is safe in view evaluation.
enum LMStudioPathMath {
    static func components(_ path: String) -> [String] {
        URL(filePath: path, directoryHint: .notDirectory).standardized.pathComponents
    }

    /// The path of the directory holding `path`, as a comparable key.
    static func directory(_ path: String) -> String {
        components(path).dropLast().joined(separator: "/")
    }

    /// Components below `base`, when `candidate` lies at or under it.
    static func relative(of candidate: [String], under base: [String]) -> [String]? {
        guard candidate.count >= base.count, Array(candidate.prefix(base.count)) == base else { return nil }
        return Array(candidate.dropFirst(base.count))
    }
}

// MARK: - Rows

struct LMStudioRow: Equatable, Identifiable {
    enum Format: String, Equatable {
        case gguf = "GGUF"
        case mlx = "MLX"
    }

    enum Action: Equatable {
        case prepare
        case run(path: String)
        case none

        var title: String? {
            switch self {
            case .prepare: return "Convert to MLX…"
            case .run: return "Run…"
            case .none: return nil
            }
        }
    }

    enum Tag: Equatable {
        case converted
        case visionProjector(help: String)

        var title: String {
            switch self {
            case .converted: return "Converted"
            case .visionProjector: return "Vision projector"
            }
        }

        var help: String? {
            if case .visionProjector(let help) = self { return help }
            return nil
        }
    }

    let id: String
    let format: Format
    let repo: String
    /// The GGUF file name; nil for an MLX folder, whose name is the repo label.
    let detail: String?
    let quantText: String
    let bytes: Int64
    let sizeText: String
    let fit: LibraryFitPresentation
    let tags: [Tag]
    let isUnreadable: Bool
    let action: Action

    static let unreadableSentence = "This file can't be read."
    static let menuActionNames = ["Show in Library", "Reveal in Finder", "Copy Path"]

    var figuresText: String { quantText.isEmpty ? sizeText : "\(quantText) · \(sizeText)" }

    var accessibilityLabel: String {
        var parts = [repo, format.rawValue]
        if !quantText.isEmpty { parts.append(quantText) }
        parts.append(sizeText)
        parts.append(isUnreadable ? Self.unreadableSentence : fit.accessibilityLabel)
        parts += tags.map(\.title)
        return parts.joined(separator: ", ")
    }

    var accessibilityHint: String { tags.compactMap(\.help).joined(separator: " ") }

    /// The row's own action first, then the context-menu actions.
    var accessibilityActionNames: [String] { (action.title.map { [$0] } ?? []) + Self.menuActionNames }

    /// A redacted row that holds the final layout while the shelf resolves or scans.
    static func placeholder(_ index: Int) -> LMStudioRow {
        LMStudioRow(
            id: "placeholder-\(index)", format: .mlx, repo: "publisher/model-name", detail: nil, quantText: "8-bit",
            bytes: 0, sizeText: "00.0 GB",
            fit: LibraryFitPresentation(
                state: .redacted, tone: .neutral, fill: nil, word: "Won't fit", help: "", accessibilityLabel: "",
                contextTokens: 0, needBytes: nil
            ),
            tags: [], isUnreadable: false, action: .none
        )
    }
}

struct LMStudioLane: Equatable, Identifiable {
    enum Notice: Equatable {
        case notConfigured(path: String)
        case configuredNotScanned
    }

    let format: LMStudioRow.Format
    let rows: [LMStudioRow]
    let notice: Notice?

    var id: String { format.rawValue }

    var title: String {
        switch format {
        case .mlx: return "MLX models"
        case .gguf: return "GGUF files"
        }
    }

    var footer: String? { format == .mlx && notice == nil ? "Unquantized MLX folders aren't listed." : nil }
}

// MARK: - States

enum LMStudioShelfState: Equatable {
    case resolving
    case notFound
    case folderMissing(path: String)
    case libraryNotScanned
    case scanning
    case scanFailed(String)
    case emptyFolder
    case folderNotice(LMStudioLane.Notice)
    case lanes([LMStudioLane])

    static let notFoundSentence = "LM Studio isn't set up on this Mac. Its models appear here after LM Studio downloads one."
    static let libraryNotScannedSentence = "The Library hasn't scanned yet."
    static let emptyFolderSentence = "LM Studio's folder has no models yet."
    static let configuredNotScannedSentence = "Added in Settings; scan to list it."

    static func folderMissingSentence(path: String) -> String {
        "LM Studio keeps models in \(path), which isn't available. Connect the drive, then scan again."
    }

    static func notConfiguredSentence(path: String) -> String {
        "LM Studio keeps models in \(path), which the Library does not scan. Add it under Library folders in Settings."
    }
}

// MARK: - Summary

struct LMStudioSummary: Equatable {
    struct Item: Equatable {
        let figure: String
        let label: String
    }

    let mlxModels: Int
    let ggufToConvert: Int
    let mlxFitNow: Int
    var mlxWithoutFitEstimate: Int = 0
    let totalBytes: Int64

    private var fitCountItem: Item {
        if mlxWithoutFitEstimate == 0 { return Item(figure: "\(mlxFitNow)", label: "fit now") }
        if mlxWithoutFitEstimate == mlxModels { return Item(figure: "—", label: "fit unknown") }
        return Item(figure: "\(mlxFitNow)", label: "known to fit")
    }

    var items: [Item] {
        [
            Item(figure: "\(mlxModels)", label: mlxModels == 1 ? "MLX model" : "MLX models"),
            Item(figure: "\(ggufToConvert)", label: "GGUF to convert"),
            fitCountItem,
            Item(figure: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file), label: "on disk"),
        ]
    }
}

// MARK: - Folder lines

struct LMStudioFolderLine: Equatable, Identifiable {
    let path: String
    let displayPath: String
    let sourceCaption: String
    let coverageWord: String

    var id: String { path }

    static func make(_ folder: LMStudioShelfResolver.Folder, home: URL) -> LMStudioFolderLine {
        let path = folder.url.path
        let caption: String
        switch folder.source {
        case .settings: caption = "From LM Studio settings"
        case .default: caption = "LM Studio default"
        case .legacy: caption = "Older LM Studio folder"
        }
        return LMStudioFolderLine(
            path: path, displayPath: abbreviated(path, home: home), sourceCaption: caption, coverageWord: coverageWord(folder)
        )
    }

    static func abbreviated(_ path: String, home: URL) -> String {
        let base = home.standardizedFileURL.path
        if path == base { return "~" }
        return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
    }

    static func coverageWord(_ folder: LMStudioShelfResolver.Folder) -> String {
        guard folder.isPresent else { return "Not available" }
        let scanned = [(folder.gguf, "GGUF"), (folder.mlx, "MLX")].filter { $0.0.scannedFolder != nil }.map(\.1)
        if scanned.count == 2 { return "Scanned" }
        if let only = scanned.first { return "Scanned for \(only)" }
        let all = [folder.gguf, folder.mlx]
        if all.contains(.configuredNotScanned) { return "Scan to list it" }
        if all.contains(.notConfigured) { return "Not scanned" }
        return "Waiting for a scan"
    }
}

// MARK: - Index

extension LMStudioShelfResolver.Resolution {
    /// The folders that decide what the shelf shows: the settings folder LM Studio reads, else the folders found on disk.
    var deciding: [LMStudioShelfResolver.Folder] {
        if let settings = folders.first(where: { $0.source == .settings }) { return [settings] }
        return folders.filter(\.isPresent)
    }
}

/// Which snapshot models belong to the shelf, with split sizes and projector companions grouped,
/// computed from strings only so it is built once per snapshot and resolution.
struct LMStudioShelfIndex {
    struct Entry {
        let model: LibraryModel
        let relative: [String]
        let companions: [LibraryModel]
    }

    private struct ShardKey: Hashable {
        let directory: String
        let modelKey: String?
    }

    let generatedAt: Date
    let resolution: LMStudioShelfResolver.Resolution
    let byPath: [String: LibraryModel]
    let mlx: [Entry]
    let gguf: [Entry]

    func matches(snapshot: LibrarySnapshot, resolution: LMStudioShelfResolver.Resolution) -> Bool {
        generatedAt == snapshot.generatedAt && self.resolution == resolution
    }

    private static func isGGUF(_ model: LibraryModel) -> Bool { model.item.path.lowercased().hasSuffix(".gguf") }

    static func make(snapshot: LibrarySnapshot, resolution: LMStudioShelfResolver.Resolution) -> LMStudioShelfIndex {
        func spellings(_ format: LMStudioRow.Format) -> [[String]] {
            resolution.deciding
                .compactMap { (format == .gguf ? $0.gguf : $0.mlx).scannedFolder }
                .map(LMStudioPathMath.components)
        }
        let mlxSpellings = spellings(.mlx)
        let ggufSpellings = spellings(.gguf)

        let companions = Dictionary(
            grouping: snapshot.models.filter { isGGUF($0) && $0.item.isCompanion },
            by: { LMStudioPathMath.directory($0.item.path) }
        )
        var shardBytes: [ShardKey: Int64] = [:]
        for model in snapshot.models where model.item.status == "shard" {
            let key = ShardKey(directory: LMStudioPathMath.directory(model.item.path), modelKey: model.item.modelKey)
            shardBytes[key, default: 0] += model.item.bytes
        }

        var seen: Set<String> = []
        var mlx: [Entry] = []
        var gguf: [Entry] = []
        for model in snapshot.models {
            let item = model.item
            guard seen.insert(item.path).inserted else { continue }
            let candidate = LMStudioPathMath.components(item.path)
            func relative(under spellings: [[String]]) -> [String]? {
                guard let found = spellings.lazy.compactMap({ LMStudioPathMath.relative(of: candidate, under: $0) }).first,
                      !found.isEmpty
                else { return nil }
                return found
            }
            if isGGUF(model) {
                guard item.status != "shard", !item.isCompanion, let found = relative(under: ggufSpellings) else { continue }
                let directory = LMStudioPathMath.directory(item.path)
                let extra = shardBytes[ShardKey(directory: directory, modelKey: item.modelKey)] ?? 0
                let sized = extra == 0 ? model : LibraryModel(item: Self.item(item, bytes: item.bytes + extra), readiness: model.readiness)
                gguf.append(Entry(model: sized, relative: found, companions: companions[directory] ?? []))
            } else if item.quantization != nil, let found = relative(under: mlxSpellings) {
                mlx.append(Entry(model: model, relative: found, companions: []))
            }
        }
        return LMStudioShelfIndex(
            generatedAt: snapshot.generatedAt, resolution: resolution,
            byPath: Dictionary(snapshot.models.map { ($0.item.path, $0) }, uniquingKeysWith: { first, _ in first }),
            mlx: mlx, gguf: gguf
        )
    }

    private static func item(_ item: ModelItem, bytes: Int64) -> ModelItem {
        ModelItem(
            path: item.path, name: item.name, bytes: bytes, modifiedAt: item.modifiedAt, shard: item.shard,
            modelKey: item.modelKey, architecture: item.architecture, quantization: item.quantization,
            parameters: item.parameters, structure: item.structure, signature: item.signature,
            companion: item.companion, readable: item.readable, status: item.status, outputs: item.outputs,
            tensorCount: item.tensorCount, error: item.error, task: item.task, draft: item.draft
        )
    }
}

// MARK: - Presentation

/// Everything the shelf shows, derived from injected inputs: no I/O, no process.
struct LMStudioShelfPresentation: Equatable {
    let state: LMStudioShelfState
    let legend: DiscoverLegend
    let summary: LMStudioSummary

    /// `index` is the prebuilt row grouping for this snapshot and resolution; a stale or absent one is rebuilt.
    static func make(
        resolution: LMStudioShelfResolver.Resolution?,
        snapshot: LibrarySnapshot?,
        index: LMStudioShelfIndex? = nil,
        isScanning: Bool,
        lastError: String?,
        memory: MemorySnapshot?,
        hasProbed: Bool,
        contextTokens: Int,
        reserveGB: Double,
        hardware: HardwareProfile
    ) -> LMStudioShelfPresentation {
        let legend = DiscoverLegend.make(
            memory: memory, hasProbed: hasProbed, reserveGB: reserveGB, contextTokens: contextTokens, hardware: hardware
        )
        func result(_ state: LMStudioShelfState) -> LMStudioShelfPresentation {
            var lanes: [LMStudioLane] = []
            if case .lanes(let built) = state { lanes = built }
            let mlx = lanes.first { $0.format == .mlx }?.rows ?? []
            let gguf = lanes.first { $0.format == .gguf }?.rows ?? []
            return LMStudioShelfPresentation(
                state: state, legend: legend,
                summary: LMStudioSummary(
                    mlxModels: mlx.count,
                    ggufToConvert: gguf.filter { $0.action == .prepare }.count,
                    mlxFitNow: mlx.filter { $0.fit.tone == .fits }.count,
                    mlxWithoutFitEstimate: mlx.filter { $0.fit.state != .estimated }.count,
                    totalBytes: (mlx + gguf).reduce(0) { $0 + $1.bytes }
                )
            )
        }
        guard let resolution else { return result(.resolving) }
        if resolution.folders.isEmpty { return result(.notFound) }
        if let settings = resolution.folders.first(where: { $0.source == .settings }), !settings.isPresent {
            return result(.folderMissing(path: settings.url.path))
        }
        let deciding = resolution.deciding
        guard !deciding.isEmpty else { return result(.folderMissing(path: resolution.folders[0].url.path)) }
        guard let snapshot else {
            if isScanning { return result(.scanning) }
            if let lastError { return result(.scanFailed(lastError)) }
            return result(.libraryNotScanned)
        }
        if deciding.allSatisfy({ $0.gguf == .unknown && $0.mlx == .unknown }) { return result(.libraryNotScanned) }

        let built = index.flatMap { $0.matches(snapshot: snapshot, resolution: resolution) ? $0 : nil }
            ?? LMStudioShelfIndex.make(snapshot: snapshot, resolution: resolution)
        let context = RowContext(memory: memory, hasProbed: hasProbed, contextTokens: contextTokens, reserveGB: reserveGB, hardware: hardware)
        var lanes: [LMStudioLane] = []
        for format in [LMStudioRow.Format.mlx, .gguf] {
            let coverages = deciding.map { format == .gguf ? $0.gguf : $0.mlx }
            if coverages.contains(where: { $0.scannedFolder != nil }) {
                let rows = context.rows(format: format, index: built)
                if !rows.isEmpty { lanes.append(LMStudioLane(format: format, rows: rows, notice: nil)) }
            } else if coverages.contains(.configuredNotScanned) {
                lanes.append(LMStudioLane(format: format, rows: [], notice: .configuredNotScanned))
            } else if let blocked = deciding.first(where: { ($0.gguf == .notConfigured && format == .gguf) || ($0.mlx == .notConfigured && format == .mlx) }) {
                lanes.append(LMStudioLane(format: format, rows: [], notice: .notConfigured(path: blocked.url.path)))
            }
        }
        if lanes.isEmpty { return result(.emptyFolder) }
        // Both formats blocked the same way is one folder problem, not two lanes.
        if let notice = lanes[0].notice, lanes.allSatisfy({ $0.notice == notice }) { return result(.folderNotice(notice)) }
        return result(.lanes(lanes))
    }

    /// Scan failure shown above rows once a snapshot exists.
    static func bannerText(snapshot: LibrarySnapshot?, lastError: String?) -> String? {
        snapshot == nil ? nil : lastError
    }
}

// MARK: - Row building

private struct RowContext {
    let memory: MemorySnapshot?
    let hasProbed: Bool
    let contextTokens: Int
    let reserveGB: Double
    let hardware: HardwareProfile

    func rows(format: LMStudioRow.Format, index: LMStudioShelfIndex) -> [LMStudioRow] {
        let built: [LMStudioRow]
        switch format {
        case .gguf: built = index.gguf.map { ggufRow($0, lookup: index.byPath) }
        case .mlx: built = index.mlx.map(mlxRow)
        }
        return built.sorted {
            ($0.fit.rank, $0.bytes, $0.id) < ($1.fit.rank, $1.bytes, $1.id)
        }
    }

    private func fit(_ model: LibraryModel) -> LibraryFitPresentation {
        LibraryFitPresentation.make(
            model: model, memory: memory, hasProbed: hasProbed, contextTokens: contextTokens,
            reserveGB: reserveGB, hardware: hardware
        )
    }

    private func ggufRow(_ entry: LMStudioShelfIndex.Entry, lookup: [String: LibraryModel]) -> LMStudioRow {
        let model = entry.model
        let item = model.item
        let relative = entry.relative
        let repo = relative.count >= 3 ? relative[relative.count - 3] + "/" + relative[relative.count - 2] : item.name
        let unreadable = item.readable == false || model.readiness == .unsupported

        var tags: [LMStudioRow.Tag] = []
        var action: LMStudioRow.Action = .prepare
        if unreadable {
            action = .none
        } else if !item.outputs.isEmpty {
            tags.append(.converted)
            let output = item.outputs.lazy.compactMap { lookup[$0] }.first { ModelTaskPresentation.isServable($0) && $0.readiness == .ready }
            action = output.map { .run(path: $0.item.path) } ?? .none
        }
        if !entry.companions.isEmpty {
            let help = entry.companions.map {
                "\($0.item.name) (\(ByteCountFormatter.string(fromByteCount: $0.item.bytes, countStyle: .file))) isn't converted; the MLX output is text only."
            }.joined(separator: " ")
            tags.append(.visionProjector(help: help))
        }
        return LMStudioRow(
            id: item.path, format: .gguf, repo: repo, detail: item.name, quantText: item.quantization ?? "", bytes: item.bytes,
            sizeText: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file), fit: fit(model),
            tags: tags, isUnreadable: unreadable, action: action
        )
    }

    private func mlxRow(_ entry: LMStudioShelfIndex.Entry) -> LMStudioRow {
        let model = entry.model
        let item = model.item
        let relative = entry.relative
        let repo = relative.count >= 2 ? relative[relative.count - 2] + "/" + relative[relative.count - 1] : (relative.last ?? item.name)
        let runnable = ModelTaskPresentation.isServable(model) && model.readiness == .ready
        return LMStudioRow(
            id: item.path, format: .mlx, repo: repo, detail: nil, quantText: Self.bitsText(item.quantization), bytes: item.bytes,
            sizeText: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file), fit: fit(model),
            tags: [], isUnreadable: false, action: runnable ? .run(path: item.path) : .none
        )
    }

    /// "q8" reads "8-bit"; anything else is shown as the agent reported it.
    static func bitsText(_ quantization: String?) -> String {
        guard let quantization else { return "" }
        let digits = quantization.lowercased().hasPrefix("q") ? String(quantization.dropFirst()) : quantization
        return Int(digits).map { "\($0)-bit" } ?? quantization
    }
}
