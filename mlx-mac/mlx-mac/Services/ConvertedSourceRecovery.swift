import CryptoKit
import Darwin
import Foundation

struct SourceRecoverySnapshot: Equatable {
    let fingerprint: String
    let bytes: Int64
}

enum SourceRecoveryError: LocalizedError {
    case refused(String)
    var errorDescription: String? {
        switch self { case .refused(let reason): return "Cannot restore original sources: \(reason)" }
    }
}

struct SourceRestoreItem: Equatable {
    let record: ConvertedSourceMove
    let snapshot: SourceRecoverySnapshot
}

struct SourceRestorePlan: Equatable {
    let items: [SourceRestoreItem]
    let roots: [String]
    var bytes: Int64 { items.reduce(0) { $0 + $1.snapshot.bytes } }
    var includesLegacyRecords: Bool { items.contains { $0.record.trashFingerprint == nil } }
}

enum SourceCleanupState: String {
    case inTrash = "In Trash"
    case restored = "Restored"
    case conflict = "Original location occupied"
    case unavailable = "Trash item unavailable"
    case incomplete = "Recovery location not recorded"
    case needsReview = "Recovery needs manual review"
}

struct SourceCleanupHistoryItem: Identifiable {
    let record: ConvertedSourceMove
    let state: SourceCleanupState
    var id: String { record.id }
    var canReveal: Bool { state == .inTrash || state == .conflict }
}

struct SourceCleanupBatch: Identifiable {
    let id: String
    let items: [SourceCleanupHistoryItem]
    var title: String {
        URL(fileURLWithPath: items.first?.record.outputPath ?? items.first?.record.from ?? "Original source").lastPathComponent
    }
    var movedAt: Date? { items.compactMap { $0.record.movedAt }.min() }
    var bytes: Int64? {
        guard items.allSatisfy({ $0.record.bytes != nil }) else { return nil }
        return items.reduce(0) { $0 + ($1.record.bytes ?? 0) }
    }
    var restorableIDs: [String] {
        let remaining = items.filter { $0.state != .restored }
        guard remaining.allSatisfy({ $0.state == .inTrash }) else { return [] }
        return remaining.map(\.id)
    }
}

/// Journal-backed recovery. Filesystem reads run on a worker, never in a view.
/// Trash and original destinations are independently fenced; no overwrite or
/// recursive deletion is used. Old journals bind identity at explicit preview.
enum ConvertedSourceRecovery {
    static var journalURL: URL { JSONStore<ConvertedSourceMove>.defaultFileURL("source-cleanup.json") }

    static func history(roots: [String], journalURL: URL = journalURL, trashRoots: [String]? = nil,
                        fileManager fm: FileManager = .default) throws -> [SourceCleanupBatch] {
        let records = try load(journalURL, fm: fm)
        let groups = Dictionary(grouping: records) { $0.batchID ?? $0.id }
        return groups.map { id, records in
            SourceCleanupBatch(id: id, items: records.map { record in
                let state: SourceCleanupState
                if record.restoredAt != nil { state = .restored }
                else if record.to == nil { state = .incomplete }
                else if (try? fence(record, roots: roots, trashRoots: trashRoots, fm: fm)) == nil { state = .needsReview }
                else if !exists(record.to!, fm: fm) { state = .unavailable }
                else if exists(record.from, fm: fm) { state = .conflict }
                else { state = .inTrash }
                return SourceCleanupHistoryItem(record: record, state: state)
            })
        }.sorted {
            let lhs = $0.movedAt ?? .distantPast, rhs = $1.movedAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    static func preview(ids: [String], roots: [String], journalURL: URL = journalURL,
                        trashRoots: [String]? = nil, fileManager fm: FileManager = .default) throws -> SourceRestorePlan {
        let records = try load(journalURL, fm: fm)
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw error("select source items to restore.") }
        var items = [SourceRestoreItem]()
        for id in ids {
            let matches = records.filter { $0.id == id }
            guard matches.count == 1, let record = matches.first, record.restoredAt == nil, let path = record.to else {
                throw error("recovery history changed or has no recorded Trash location.")
            }
            try fence(record, roots: roots, trashRoots: trashRoots, fm: fm)
            guard !exists(record.from, fm: fm) else { throw QuarantineError.restoreBlocked(record.from) }
            let current = try snapshot(path, fileManager: fm)
            if let recorded = record.trashFingerprint, recorded != current.fingerprint { throw QuarantineError.changedSincePreview }
            try validatePayload(record, fm: fm)
            items.append(SourceRestoreItem(record: record, snapshot: current))
        }
        guard Set(items.map { $0.record.from }).count == items.count, Set(items.compactMap { $0.record.to }).count == items.count else {
            throw error("recovery history contains overlapping destinations.")
        }
        for lhs in items {
            for rhs in items where lhs.record.id != rhs.record.id {
                guard !Quarantine.isWithin(rhs.record.from, parent: lhs.record.from) else {
                    throw error("recovery history contains overlapping destinations.")
                }
            }
        }
        // Restore blobs before their cache references. A partial restore remains
        // recorded item by item and can resume with the remaining Trash items.
        items.sort { lhs, rhs in
            let ld = isDirectory(lhs.record.to!, fm: fm), rd = isDirectory(rhs.record.to!, fm: fm)
            return ld == rd ? lhs.record.from < rhs.record.from : !ld
        }
        return SourceRestorePlan(items: items, roots: roots)
    }

    static func restore(_ plan: SourceRestorePlan, roots: [String], journalURL: URL = journalURL,
                        trashRoots: [String]? = nil, fileManager fm: FileManager = .default) throws {
        guard roots == plan.roots,
              try preview(ids: plan.items.map { $0.record.id }, roots: roots, journalURL: journalURL, trashRoots: trashRoots, fileManager: fm) == plan else {
            throw QuarantineError.changedSincePreview
        }
        let store = JSONStore<ConvertedSourceMove>(fileURL: journalURL, fileManager: fm)
        var restored = 0
        for item in plan.items {
            do {
                guard try load(journalURL, fm: fm).first(where: { $0.id == item.record.id }) == item.record else { throw QuarantineError.changedSincePreview }
                try fence(item.record, roots: roots, trashRoots: trashRoots, fm: fm)
                guard !exists(item.record.from, fm: fm), let path = item.record.to,
                      try snapshot(path, fileManager: fm) == item.snapshot else { throw QuarantineError.changedSincePreview }
                // Preflight journal writes before moving anything.
                try store.upsert(item.record, id: \.id)
                let parent = URL(fileURLWithPath: item.record.from).deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try noParentLinks(item.record.from, fm: fm)
                try fm.moveItem(atPath: path, toPath: item.record.from)
                var record = item.record
                record.restoredAt = Date()
                do { try store.upsert(record, id: \.id) }
                catch {
                    do { try fm.moveItem(atPath: record.from, toPath: path) }
                    catch { throw self.error("history and rollback failed; inspect \(record.from) and \(path) in Finder.") }
                    throw error
                }
                restored += 1
            } catch {
                throw self.error("recorded \(restored) successful restores out of \(plan.items.count) items. \(error.localizedDescription)")
            }
        }
    }

    /// Metadata identity, not a weight-content hash. Symlink targets are
    /// recorded without reading or traversing their payloads.
    static func snapshot(_ path: String, fileManager fm: FileManager = .default) throws -> SourceRecoverySnapshot {
        try noParentLinks(path, fm: fm)
        var pending = [path], states = [String](), bytes: Int64 = 0
        while let item = pending.popLast() {
            var metadata = stat()
            guard lstat(item, &metadata) == 0 else { throw QuarantineError.notFound(item) }
            let kind = metadata.st_mode & S_IFMT
            guard [S_IFDIR, S_IFREG, S_IFLNK].contains(kind) else { throw error("unsupported source file type.") }
            let link = kind == S_IFLNK ? try fm.destinationOfSymbolicLink(atPath: item) : ""
            states.append("\(item.dropFirst(path.count))|\(metadata.st_dev)|\(metadata.st_ino)|\(metadata.st_size)|\(metadata.st_mtimespec)|\(metadata.st_ctimespec)|\(metadata.st_nlink)|\(link)")
            guard states.count <= 100000 else { throw error("the source tree is too large; review it in Finder.") }
            if kind == S_IFREG { bytes += metadata.st_size }
            if kind == S_IFDIR { pending += try fm.contentsOfDirectory(atPath: item).map { item + "/" + $0 } }
        }
        let fingerprint = SHA256.hash(data: Data(states.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return SourceRecoverySnapshot(fingerprint: fingerprint, bytes: bytes)
    }

    private static func load(_ url: URL, fm: FileManager) throws -> [ConvertedSourceMove] {
        try noParentLinks(url.path, fm: fm)
        try JSONStore<ConvertedSourceMove>.refuseSymlink(url, fileManager: fm)
        let records = try JSONStore<ConvertedSourceMove>(fileURL: url, fileManager: fm).load()
        guard Set(records.map(\.id)).count == records.count else { throw error("duplicate journal identities; inspect recovery history before retrying.") }
        return records
    }

    private static func fence(_ record: ConvertedSourceMove, roots: [String], trashRoots: [String]?, fm: FileManager) throws {
        guard let to = record.to, record.from.hasPrefix("/"), to.hasPrefix("/"),
              URL(fileURLWithPath: record.from).standardizedFileURL.path == record.from,
              URL(fileURLWithPath: to).standardizedFileURL.path == to else { throw error("invalid recovery paths.") }
        try noParentLinks(record.from, fm: fm)
        try noParentLinks(to, fm: fm)
        let allowed = roots.filter { !$0.isEmpty }.map(Quarantine.resolve)
        let original = Quarantine.resolve(record.from)
        guard allowed.contains(where: { original != $0 && Quarantine.isWithin(original, parent: $0) }),
              !allowed.contains(where: { Quarantine.isWithin($0, parent: original) }) else { throw QuarantineError.outsideRoots(record.from) }
        let trash = trashRoots ?? nativeTrashRoots(for: record.from, fm: fm)
        guard trash.contains(where: { to != $0 && URL(fileURLWithPath: to).deletingLastPathComponent().path == $0 }),
              !Quarantine.isWithin(record.from, parent: URL(fileURLWithPath: to).deletingLastPathComponent().path) else { throw error("the recorded item is outside native Trash.") }
    }

    private static func nativeTrashRoots(for original: String, fm: FileManager) -> [String] {
        var result = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path]
        var ancestor = URL(fileURLWithPath: original).deletingLastPathComponent()
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        if let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: ancestor, create: false) {
            result.append(trash.path)
        }
        return result
    }

    private static func validatePayload(_ record: ConvertedSourceMove, fm: FileManager) throws {
        let original = URL(fileURLWithPath: record.from), to = record.to!
        var metadata = stat()
        guard lstat(to, &metadata) == 0 else { throw QuarantineError.notFound(to) }
        let kind = metadata.st_mode & S_IFMT
        if original.pathExtension.lowercased() == "gguf" { guard kind == S_IFREG else { throw error("the GGUF Trash item is not a regular file.") }; return }
        if original.lastPathComponent.hasPrefix("models--") {
            guard kind == S_IFDIR else { throw error("the cache repository Trash item is not a directory.") }
            let cache = original.deletingLastPathComponent().path
            var pending = [to]
            while let path = pending.popLast() {
                guard lstat(path, &metadata) == 0 else { throw QuarantineError.notFound(path) }
                let kind = metadata.st_mode & S_IFMT
                if kind == S_IFLNK {
                    let link = try fm.destinationOfSymbolicLink(atPath: path)
                    let restoredPath = record.from + String(path.dropFirst(to.count))
                    let destination = (link.hasPrefix("/") ? URL(fileURLWithPath: link) : URL(fileURLWithPath: restoredPath).deletingLastPathComponent().appendingPathComponent(link)).standardizedFileURL.path
                    guard Quarantine.isWithin(destination, parent: cache + "/blobs") || Quarantine.isWithin(destination, parent: record.from) else { throw error("a cache reference leaves its original cache.") }
                } else if kind == S_IFDIR { pending += try fm.contentsOfDirectory(atPath: path).map { path + "/" + $0 } }
            }
            return
        }
        guard original.pathComponents.contains("blobs"), kind == S_IFREG else { throw error("the recorded source is not a GGUF, cache repository or cache blob.") }
    }

    private static func isDirectory(_ path: String, fm: FileManager) -> Bool { (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory }
    private static func exists(_ path: String, fm: FileManager) -> Bool {
        fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }
    private static func noParentLinks(_ path: String, fm: FileManager) throws {
        var component = URL(fileURLWithPath: path).standardizedFileURL
        while component.path != "/" {
            if ["/var", "/tmp", "/etc"].contains(component.path), (try? fm.destinationOfSymbolicLink(atPath: component.path)) == "private" + component.path { break }
            if (try? fm.destinationOfSymbolicLink(atPath: component.path)) != nil { throw QuarantineError.symlinkRefused(component.path) }
            component.deleteLastPathComponent()
        }
    }
    private static func error(_ reason: String) -> SourceRecoveryError { .refused(reason) }
}
