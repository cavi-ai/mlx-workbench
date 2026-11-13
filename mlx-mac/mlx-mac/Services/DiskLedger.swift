import Foundation

// MARK: - DiskLedger
//
// Reclaim's model view: one row per family of copies the scan groups across
// MLX folders, GGUF files, the Hugging Face cache and Ollama. Bytes are
// counted once per file on disk, so shared blobs and hard links never inflate
// a total or a saving.

struct DiskCopy: Identifiable, Hashable {
    let item: StoredModel
    let lastUsed: Date?
    /// Serving, preferred or otherwise claimed: never offered for removal.
    let isProtected: Bool
    /// The scan found identical weights in another copy of this family.
    let isIdentical: Bool
    var id: String { item.path }
}

struct DiskFamily: Identifiable, Hashable {
    let id: String
    let name: String
    /// Kept copy first, then the largest.
    let copies: [DiskCopy]
    let keep: String?
    /// Every file of every copy, once.
    let bytes: Int64
    /// Bytes freed by removing every copy except the kept and protected ones.
    let couldFree: Int64
    let lastUsed: Date?
    let stores: [String]

    var removable: [DiskCopy] { copies.filter { $0.id != keep && !$0.isProtected } }
}

enum DiskFilter: String, CaseIterable, Identifiable {
    case redundant, unused, identical, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .redundant: "Several copies"
        case .unused: "Not used recently"
        case .identical: "Identical copies"
        case .all: "All models"
        }
    }
}

enum DiskLedger {
    static func families(
        storage: ScanStorage,
        families: [ModelFamily],
        duplicates: [DuplicateGroup] = [],
        lastUsedByPath: [String: Date] = [:],
        protectedPaths: Set<String> = [],
        keep overrides: [String: String] = [:]
    ) -> [DiskFamily] {
        let items = Dictionary(storage.items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let identicalGroups = duplicates.filter { $0.kind == "exact" }.map { Set($0.sources) }
        var grouped = Set<String>()
        var result: [DiskFamily] = []
        func family(id: String, name: String, members: [StoredModel]) -> DiskFamily {
            let paths = Set(members.map(\.path))
            let copies = members.map { item in
                DiskCopy(item: item, lastUsed: lastUsedByPath[item.path],
                         isProtected: isProtected(item.path, by: protectedPaths),
                         isIdentical: identicalGroups.contains { $0.contains(item.path) && !$0.intersection(paths).subtracting([item.path]).isEmpty })
            }
            let keep = overrides[id].flatMap { paths.contains($0) ? $0 : nil } ?? defaultKeep(copies)
            let ordered = copies.sorted { lhs, rhs in
                if (lhs.id == keep) != (rhs.id == keep) { return lhs.id == keep }
                return lhs.item.bytes == rhs.item.bytes ? lhs.id < rhs.id : lhs.item.bytes > rhs.item.bytes
            }
            let removable = ordered.filter { $0.id != keep && !$0.isProtected }.map(\.item.path)
            return DiskFamily(
                id: id, name: name, copies: ordered, keep: keep,
                bytes: uniqueBytes(members.flatMap(\.files)),
                couldFree: freedBytes(removing: Set(removable), items: storage.items),
                lastUsed: copies.compactMap(\.lastUsed).max(),
                stores: Array(Set(members.map(\.store))).sorted()
            )
        }
        for entry in families {
            let members = entry.members.compactMap { items[$0] }.filter { !grouped.contains($0.path) }
            guard !members.isEmpty else { continue }
            grouped.formUnion(members.map(\.path))
            result.append(family(id: entry.familyID, name: entry.name, members: members))
        }
        for item in storage.items where !grouped.contains(item.path) {
            result.append(family(id: "path:" + item.path, name: item.name, members: [item]))
        }
        return result
    }

    static func filter(_ families: [DiskFamily], by filter: DiskFilter, staleBefore: Date) -> [DiskFamily] {
        switch filter {
        case .redundant: families.filter { $0.copies.count > 1 }
        case .unused: families.filter { family in
            !family.copies.contains(where: \.isProtected) && (family.lastUsed.map { $0 < staleBefore } ?? true)
        }
        case .identical: families.filter { $0.copies.contains(where: \.isIdentical) }
        case .all: families
        }
    }

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

    /// The most recently used copy; else a protected one; else the largest.
    private static func defaultKeep(_ copies: [DiskCopy]) -> String? {
        if let used = copies.filter({ $0.lastUsed != nil }).max(by: { $0.lastUsed! < $1.lastUsed! }) { return used.id }
        if let held = copies.first(where: \.isProtected) { return held.id }
        return copies.max { $0.item.bytes == $1.item.bytes ? $0.id > $1.id : $0.item.bytes < $1.item.bytes }?.id
    }
}
