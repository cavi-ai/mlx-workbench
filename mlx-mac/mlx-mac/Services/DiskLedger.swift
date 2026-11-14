import Foundation

// MARK: - DiskLedger
//
// Reclaim's model view: one row per model, with every version of it the scan
// found across MLX folders, GGUF files, the Hugging Face cache and Ollama.
// Versions share the engine's architecture family and its model key, so
// fine-tunes of one base model stay apart. Bytes are counted once per file on
// disk, so shared blobs and hard links never inflate a total or a saving.

struct DiskCopy: Identifiable, Hashable {
    let item: StoredModel
    let lastUsed: Date?
    /// Serving, preferred or otherwise claimed: never offered for removal.
    let isProtected: Bool
    /// The scan found identical weights in another copy.
    let isIdentical: Bool
    var id: String { item.path }
}

/// Every stored version of one model.
struct DiskModel: Identifiable, Hashable {
    enum KeepReason: Hashable {
        case chosen
        case used(Date)
        case protected
    }

    let id: String
    let name: String
    /// Kept version first, then the largest.
    let copies: [DiskCopy]
    /// Set only with a reason: chosen, used here, or serving.
    let keep: String?
    let keepReason: KeepReason?
    /// Every file of every version, once.
    let bytes: Int64
    /// Bytes freed by keeping one version (the kept one, else the largest) and removing the others that are not protected.
    let couldFree: Int64
    let lastUsed: Date?
    let stores: [String]

    /// Versions a person may select for removal.
    var removable: [DiskCopy] { copies.filter { $0.id != keep && !$0.isProtected } }
    /// Versions `couldFree` counts: all but the kept or largest one.
    var extras: [DiskCopy] {
        guard copies.count > 1 else { return [] }
        let stays = keep ?? copies.first?.id
        return copies.filter { $0.id != stays && !$0.isProtected }
    }
}

/// One thing Reclaim recommends, with the evidence behind it and the exact bytes it frees.
struct DiskSuggestion: Identifiable, Hashable {
    enum Kind: Int, Hashable {
        /// The same weights stored more than once.
        case identical
        /// One version is used, serving or chosen; the others are not used.
        case otherVersions
        /// Several versions, none used: a person picks the one to keep.
        case chooseVersion
        /// A model with no recent use here.
        case notUsed
    }

    let kind: Kind
    let modelID: String
    let name: String
    let detail: String
    /// Paths the suggestion removes; empty when a person must choose first.
    let remove: [String]
    /// Freed by `remove`; for `chooseVersion`, freed by keeping the largest version.
    let bytes: Int64

    var id: String { "\(kind.rawValue):\(modelID):\(remove.sorted().joined(separator: "|"))" }
}

enum DiskFilter: String, CaseIterable, Identifiable {
    case all, redundant, unused, identical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All models"
        case .redundant: "Several versions"
        case .unused: "Not used recently"
        case .identical: "Identical copies"
        }
    }
}

enum DiskLedger {
    /// Smallest model `notUsed` suggests removing.
    static let suggestionFloorBytes: Int64 = 1_000_000_000

    static func models(
        storage: ScanStorage,
        families: [ModelFamily],
        duplicates: [DuplicateGroup] = [],
        lastUsedByPath: [String: Date] = [:],
        protectedPaths: Set<String> = [],
        keep overrides: [String: String] = [:]
    ) -> [DiskModel] {
        let identicalGroups = duplicates.filter { $0.kind == "exact" }.map { Set($0.sources) }
        var familyOf: [String: String] = [:]
        for family in families { for path in family.members where familyOf[path] == nil { familyOf[path] = family.familyID } }
        var groups: [String: [StoredModel]] = [:]
        var order: [String] = []
        for item in storage.items {
            let family = familyOf[item.path] ?? "path:" + item.path
            let key = "model:" + family + "|" + (item.modelKey.flatMap { $0.isEmpty ? nil : $0 } ?? item.path)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.compactMap { id in
            guard let members = groups[id] else { return nil }
            let paths = Set(members.map(\.path))
            let copies = members.map { item in
                DiskCopy(item: item, lastUsed: lastUsedByPath[item.path],
                         isProtected: isProtected(item.path, by: protectedPaths),
                         isIdentical: identicalGroups.contains { $0.contains(item.path) && $0.count > 1 })
            }
            let chosen = overrides[id].flatMap { paths.contains($0) ? $0 : nil }
            let kept = chosen.map { ($0, DiskModel.KeepReason.chosen) } ?? defaultKeep(copies)
            let ordered = copies.sorted { lhs, rhs in
                if (lhs.id == kept?.0) != (rhs.id == kept?.0) { return lhs.id == kept?.0 }
                return lhs.item.bytes == rhs.item.bytes ? lhs.id < rhs.id : lhs.item.bytes > rhs.item.bytes
            }
            let stays = kept?.0 ?? ordered.first?.id
            let extras = ordered.count > 1 ? ordered.filter { $0.id != stays && !$0.isProtected }.map(\.id) : []
            return DiskModel(
                id: id, name: displayName(members), copies: ordered, keep: kept?.0, keepReason: kept?.1,
                bytes: uniqueBytes(members.flatMap(\.files)),
                couldFree: freedBytes(removing: Set(extras), items: storage.items),
                lastUsed: copies.compactMap(\.lastUsed).max(),
                stores: Array(Set(members.map(\.store))).sorted()
            )
        }
    }

    static func filter(_ models: [DiskModel], by filter: DiskFilter, staleBefore: Date) -> [DiskModel] {
        switch filter {
        case .all: models
        case .redundant: models.filter { $0.copies.count > 1 }
        case .unused: models.filter { model in
            !model.copies.contains(where: \.isProtected) && (model.lastUsed.map { $0 < staleBefore } ?? true)
        }
        case .identical: models.filter { $0.copies.contains(where: \.isIdentical) }
        }
    }

    // MARK: Suggestions

    /// What to remove and why, largest saving first after identical copies.
    /// `modifiedByPath` dates a model with no recorded use by when its files last changed.
    static func suggestions(
        models: [DiskModel],
        items: [StoredModel],
        duplicates: [DuplicateGroup],
        staleBefore: Date,
        modifiedByPath: [String: Date] = [:],
        now: Date = Date()
    ) -> [DiskSuggestion] {
        let copies = Dictionary(models.flatMap { model in model.copies.map { ($0.id, (model, $0)) } },
                                uniquingKeysWith: { first, _ in first })
        var claimed = Set<String>()
        var found: [DiskSuggestion] = []

        for group in duplicates where group.kind == "exact" {
            guard let keep = group.keep, let entry = copies[keep] else { continue }
            let (model, kept) = entry
            let remove = Array(Set(group.redundant ?? group.sources).subtracting([keep]))
                .filter { copies[$0].map { !$0.1.isProtected } ?? false }.sorted()
            claimed.formUnion(group.sources)
            let bytes = freedBytes(removing: Set(remove), items: items)
            guard !remove.isEmpty, bytes > 0 else { continue }
            found.append(DiskSuggestion(
                kind: .identical, modelID: model.id, name: model.name,
                detail: "The same weights are stored \(remove.count + 1) times. Keeps the copy in \(place(kept.item)).",
                remove: remove, bytes: bytes))
        }

        for model in models where model.copies.count > 1 {
            let open = model.copies.filter { !claimed.contains($0.id) }
            if let keep = model.keep, let reason = model.keepReason, let kept = model.copies.first(where: { $0.id == keep }) {
                let remove = open.filter { $0.id != keep && !$0.isProtected && ($0.lastUsed.map { $0 < staleBefore } ?? true) }
                let bytes = freedBytes(removing: Set(remove.map(\.id)), items: items)
                guard !remove.isEmpty, bytes > 0 else { continue }
                let others = remove.count == 1 ? "The other version was" : "The other \(remove.count) versions were"
                let why: String
                switch reason {
                case .used(let date):
                    why = "\(versionLabel(kept.item, model: model)) was used \(WorkbenchRelativeTime.text(for: date, style: .full, now: now))."
                case .protected:
                    why = "\(versionLabel(kept.item, model: model)) is serving or kept for a task."
                case .chosen:
                    why = "You chose to keep \(versionLabel(kept.item, model: model))."
                }
                found.append(DiskSuggestion(kind: .otherVersions, modelID: model.id, name: model.name,
                                            detail: why + " " + others + " not used recently.",
                                            remove: remove.map(\.id).sorted(), bytes: bytes))
            } else if open.filter({ !$0.isProtected }).count > 1, model.couldFree > 0 {
                let labels = model.copies.map { "\(versionLabel($0.item, model: model)) \(ReclaimFormat.byteCount($0.item.bytes))" }
                found.append(DiskSuggestion(kind: .chooseVersion, modelID: model.id, name: model.name,
                                            detail: "\(model.copies.count) versions, none used recently: " + labels.joined(separator: ", ") + ". Keep the one you run.",
                                            remove: [], bytes: model.couldFree))
            }
        }

        for model in models where model.copies.count == 1 {
            guard let copy = model.copies.first, !copy.isProtected, !claimed.contains(copy.id),
                  copy.lastUsed.map({ $0 < staleBefore }) ?? true,
                  modifiedByPath[copy.id].map({ $0 < staleBefore }) ?? true else { continue }
            let bytes = freedBytes(removing: [copy.id], items: items)
            guard bytes >= suggestionFloorBytes else { continue }
            let detail: String
            if let used = copy.lastUsed {
                detail = "Last used here \(WorkbenchRelativeTime.text(for: used, style: .full, now: now))."
            } else if let modified = modifiedByPath[copy.id] {
                detail = "No use recorded here; files unchanged since \(modified.formatted(date: .abbreviated, time: .omitted))."
            } else {
                detail = "No use recorded here."
            }
            found.append(DiskSuggestion(kind: .notUsed, modelID: model.id, name: model.name, detail: detail,
                                        remove: [copy.id], bytes: bytes))
        }

        return found.sorted { lhs, rhs in
            if (lhs.kind == .identical) != (rhs.kind == .identical) { return lhs.kind == .identical }
            return lhs.bytes == rhs.bytes ? lhs.id < rhs.id : lhs.bytes > rhs.bytes
        }
    }

    // MARK: Names

    /// A trailing format or quantization label, as the engine strips it from model names.
    private static let quantSuffix =
        #"[-_.](?:mlx|vq|\d+(?:\.\d+)?-?bits?|\d+(?:\.\d+)?bpw|bf16|fp16|f16|fp32|f32|mxfp[48]|nvfp4|q[2-8](?:_[0-9a-z]+)*)$"#

    /// A model name without its file extension and trailing quantization labels.
    static func stem(_ name: String) -> String {
        var stem = name.lowercased().hasSuffix(".gguf") ? String(name.dropLast(5)) : name
        while let range = stem.range(of: quantSuffix, options: [.regularExpression, .caseInsensitive]),
              range.lowerBound > stem.startIndex {
            stem.removeSubrange(range)
        }
        return stem
    }

    /// The shortest stem among the non-Ollama versions, else among all.
    static func displayName(_ members: [StoredModel]) -> String {
        let named = members.filter { $0.kind != "ollama" }
        let stems = (named.isEmpty ? members : named).map { stem($0.name) }
        return stems.min { ($0.count, $0) < ($1.count, $1) } ?? members.first?.name ?? ""
    }

    /// How one version differs from the others: its format, quantization and store.
    static func versionLabel(_ item: StoredModel, model: DiskModel) -> String {
        if item.store == "ollama" { return "Ollama " + item.name }
        var name = item.name.lowercased().hasSuffix(".gguf") ? String(item.name.dropLast(5)) : item.name
        if name.lowercased().hasPrefix(model.name.lowercased()) { name.removeFirst(model.name.count) }
        let label = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        let format = (item.format ?? item.kind).uppercased()
        let base = label.isEmpty ? format : (label.uppercased().hasPrefix(format) ? label : format + " " + label)
        return item.store == "huggingface" ? base + " (Hugging Face cache)" : base
    }

    private static func place(_ item: StoredModel) -> String {
        switch item.store {
        case "huggingface": "the Hugging Face cache"
        case "ollama": "Ollama"
        default: URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent
        }
    }

    // MARK: Bytes

    /// Bytes that leave the disk when these copies go. A file shared with a
    /// copy that stays is not freed; removing a Hugging Face snapshot takes
    /// its whole cache repository with it.
    static func freedBytes(removing paths: Set<String>, items: [StoredModel]) -> Int64 {
        let removed = expanded(paths, items: items)
        guard !removed.isEmpty else { return 0 }
        var holders: [String: Set<String>] = [:]
        for item in items { for file in item.files { holders[file.id, default: []].insert(item.path) } }
        var counted = Set<String>(), total: Int64 = 0
        for item in items where removed.contains(item.path) {
            for file in removedFiles(of: item) where counted.insert(file.id).inserted {
                if holders[file.id, default: []].isSubset(of: removed) { total += file.bytes }
            }
        }
        return total
    }

    /// Selected copies plus every snapshot that shares a selected snapshot's cache repository.
    static func expanded(_ paths: Set<String>, items: [StoredModel]) -> Set<String> {
        let repositories = Set(items.filter { paths.contains($0.path) }.compactMap(cacheRepository))
        return paths.union(items.filter { cacheRepository($0).map(repositories.contains) ?? false }.map(\.path))
    }

    /// The `models--…` directory holding a Hugging Face snapshot.
    static func cacheRepository(_ item: StoredModel) -> String? {
        guard item.store == "huggingface" else { return nil }
        var url = URL(fileURLWithPath: item.path)
        while url.path != "/" {
            if url.lastPathComponent.hasPrefix("models--") { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Files a removal moves: a GGUF copy moves its GGUF files and leaves
    /// notes beside them; folders, cache repositories and Ollama models move whole.
    static func removedFiles(of item: StoredModel) -> [StoredFile] {
        item.kind == "gguf" ? item.files.filter { $0.path.lowercased().hasSuffix(".gguf") } : item.files
    }

    static func uniqueBytes(_ files: [StoredFile]) -> Int64 {
        var seen = Set<String>()
        return files.reduce(0) { total, file in seen.insert(file.id).inserted ? total + file.bytes : total }
    }

    static func isProtected(_ path: String, by protected: Set<String>) -> Bool {
        protected.contains { entry in
            guard entry.hasPrefix("/") else { return HFRepoID.forPath(path) == entry }
            return Quarantine.isWithin(path, parent: entry) || Quarantine.isWithin(entry, parent: path)
        }
    }

    /// The most recently used version; else a protected one; else none.
    private static func defaultKeep(_ copies: [DiskCopy]) -> (String, DiskModel.KeepReason)? {
        if let used = copies.compactMap({ copy in copy.lastUsed.map { (copy.id, $0) } }).max(by: { $0.1 < $1.1 }) {
            return (used.0, .used(used.1))
        }
        if let held = copies.first(where: \.isProtected) { return (held.id, .protected) }
        return nil
    }
}
