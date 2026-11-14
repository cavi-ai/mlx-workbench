import Foundation
import CryptoKit
import Darwin

// MARK: - Quarantine
//
// GGUF parity with the web, plus explicitly reviewed local MLX directories.
// Quarantine moves are reversible; removal uses native macOS Trash only.

enum QuarantineError: LocalizedError {
    case notGGUF(String)
    case notFound(String)
    case outsideRoots(String)
    case alreadyQuarantined(String)
    case moveFailed(String)
    case restoreBlocked(String)
    case symlinkRefused(String)
    case notInQuarantine(String)
    case changedSincePreview
    case trashFailed(String)
    case unsafeFolder(String)

    var errorDescription: String? {
        switch self {
        case .notGGUF:
            return "Only .gguf files can be moved from here. Move anything else yourself, deliberately."
        case .notFound(let path):
            return "No file at \(path). Rescan; the file may already have been moved."
        case .outsideRoots(let path):
            return "\(path) is not inside an allowed scan root, or is itself a configured root. Review your scan roots in Settings."
        case .alreadyQuarantined(let path):
            return "\(path) is already in the quarantine directory."
        case .moveFailed(let detail):
            return "The file could not be moved: \(detail). Check free space and permissions on the quarantine directory."
        case .restoreBlocked(let path):
            return "Cannot put \(path) back: a file already exists at the original location. Resolve it yourself first."
        case .symlinkRefused(let path):
            return "\(path) is a symbolic link; refusing to move or write through it."
        case .notInQuarantine(let path):
            return "\(path) is not a recorded model file, GGUF bundle or MLX folder in the configured quarantine directory."
        case .changedSincePreview:
            return "The item or its configuration changed after preview. Review it again before moving it."
        case .trashFailed(let detail):
            return "Could not move the file to Trash: \(detail). Refresh quarantine before retrying."
        case .unsafeFolder(let detail):
            return "Cannot quarantine this model folder: \(detail)"
        }
    }
}

enum QuarantineKind: String, Codable, Sendable {
    case mlxDirectory, ggufBundle, updateStaging, ollamaModel, assetFile
    var isDirectory: Bool {
        switch self { case .mlxDirectory, .ggufBundle, .updateStaging, .ollamaModel: true; case .assetFile: false }
    }
}

/// One Ollama tag: its manifest and the blobs no other manifest references.
struct OllamaRemovalPlan: Equatable, Sendable {
    let manifest: String
    let modelsRoot: String
    let blobs: [String]
    let bytes: Int64
    let device: UInt64
    let fingerprint: String
}

struct QuarantineRecord: Codable, Equatable, Sendable {
    let movedAt: String
    let from: String
    let to: String
    let bytes: Int64
    var deletedAt: String? = nil
    var kind: QuarantineKind? = nil

    enum CodingKeys: String, CodingKey {
        case from, to, bytes, kind
        case movedAt = "moved_at"
        case deletedAt = "deleted_at"
    }
}

struct QuarantineFileSnapshot: Codable, Equatable, Sendable {
    let path: String
    let bytes: Int64
    let device: UInt64
    let inode: UInt64
    let modifiedAt: Date
    let createdAt: Date
    var treeFingerprint: String? = nil
    var fileCount: Int? = nil
}

struct AssetFileReview: Equatable, Sendable {
    let item: StoredModel
    let root: String
}

struct AssetRemovalReview: Equatable, Sendable {
    let source: AssetFileReview
    let keeper: AssetFileReview
}

final class AssetVerificationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check(deadline: TimeInterval) throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            throw QuarantineError.unsafeFolder("File verification timed out. Compare again before retrying.")
        }
    }
}

struct QuarantineTrashResult: Sendable {
    let bytes: Int64
    let ledgerWarning: String?
}

struct LibraryTrashPlan: Equatable, Sendable {
    let modelPath: String
    let roots: [String]
    let snapshot: QuarantineFileSnapshot
    let includesCacheRepository: Bool
}

enum Quarantine {
    static let ledgerName = "quarantine-ledger.jsonl"
    static let maxLedgerBytes = 4 * 1024 * 1024

    /// Update cleanup keeps provider caches in place. A managed bundle requires its exact main-first selection.
    static func modelUpdateSnapshot(target: String, roots: [String], protected: [String],
                                    managedBundle: String? = nil, bundleFiles: [String] = [],
                                    fileManager: FileManager = .default) throws -> QuarantineFileSnapshot {
        if let managedBundle {
            return try ggufBundleSnapshot(target: target, bundle: managedBundle, files: bundleFiles,
                roots: roots, protected: protected, fileManager: fileManager)
        }
        guard bundleFiles.isEmpty else { throw QuarantineError.unsafeFolder("the managed bundle selection is missing.") }
        let expanded = NSString(string: target).expandingTildeInPath
        try refuseLinks(in: expanded, fileManager: fileManager)
        guard HFRepoID.forPath(expanded) == nil, HFRepoID.forPath(resolve(expanded)) == nil else {
            throw QuarantineError.unsafeFolder("Hugging Face cache files must be kept or cleaned through Check HF cache.")
        }
        if expanded.lowercased().hasSuffix(".gguf") {
            let plan = try previewModelTrash(target, roots: roots, protected: protected, fileManager: fileManager)
            guard !plan.includesCacheRepository else { throw QuarantineError.unsafeFolder("provider caches cannot be quarantined by a model update.") }
            return plan.snapshot
        }
        return try folderSnapshot(target: target, roots: roots, protected: protected, fileManager: fileManager)
    }

    static func moveModelUpdate(expected: QuarantineFileSnapshot, roots: [String], protected: [String], quarantineDir: String,
                                managedBundle: String? = nil, bundleFiles: [String] = [],
                                now: Date = Date(), fileManager: FileManager = .default) throws -> QuarantineRecord {
        if let managedBundle {
            guard let main = bundleFiles.first, expected.path == resolve(managedBundle) else { throw QuarantineError.changedSincePreview }
            let target = URL(fileURLWithPath: resolve(managedBundle)).appendingPathComponent(main).path
            let recheck = {
                try modelUpdateSnapshot(target: target, roots: roots, protected: protected,
                    managedBundle: managedBundle, bundleFiles: bundleFiles, fileManager: fileManager)
            }
            return try moveGGUFBundle(expected: expected, quarantineDir: quarantineDir, now: now,
                fileManager: fileManager, recheck: recheck)
        }
        let current = try modelUpdateSnapshot(target: expected.path, roots: roots, protected: protected,
            bundleFiles: bundleFiles, fileManager: fileManager)
        guard current == expected else { throw QuarantineError.changedSincePreview }
        if expected.path.lowercased().hasSuffix(".gguf") {
            guard !quarantineDir.isEmpty else { throw QuarantineError.unsafeFolder("configure a quarantine directory first.") }
            try refuseLinks(in: NSString(string: quarantineDir).expandingTildeInPath, fileManager: fileManager)
            return try move(target: current.path, roots: roots, quarantineDir: quarantineDir, now: now, fileManager: fileManager)
        }
        return try moveFolder(expected: expected, roots: roots, protected: protected, quarantineDir: quarantineDir,
            now: now, fileManager: fileManager)
    }

    /// Incomplete update output has no usable model config. Its exact bounded
    /// tree still receives the same atomic move, ledger and rollback protections.
    static func updateStagingSnapshot(target: String, roots: [String], protected: [String],
                                      fileManager: FileManager = .default) throws -> QuarantineFileSnapshot {
        try refuseLinks(in: target, fileManager: fileManager)
        let path = resolve(target)
        let allowed = roots.filter { !$0.isEmpty }.map(resolve)
        guard allowed.contains(where: { path != $0 && isWithin(path, parent: $0) }),
              !allowed.contains(where: { isWithin($0, parent: path) }), HFRepoID.forPath(path) == nil,
              !protected.filter({ $0.hasPrefix("/") }).map(resolve).contains(where: {
                  isWithin(path, parent: $0) || isWithin($0, parent: path)
              }) else { throw QuarantineError.unsafeFolder("the incomplete update is outside its managed root or is still in use.") }
        return try directorySnapshot(path, fileManager: fileManager)
    }

    static func moveUpdateStaging(expected: QuarantineFileSnapshot, roots: [String], protected: [String], quarantineDir: String,
                                  now: Date = Date(), fileManager: FileManager = .default) throws -> QuarantineRecord {
        try moveGGUFBundle(expected: expected, quarantineDir: quarantineDir, now: now, fileManager: fileManager, kind: .updateStaging) {
            try updateStagingSnapshot(target: expected.path, roots: roots, protected: protected, fileManager: fileManager)
        }
    }

    private static func ggufBundleSnapshot(target: String, bundle: String, files: [String], roots: [String], protected: [String],
                                           fileManager: FileManager) throws -> QuarantineFileSnapshot {
        let expanded = NSString(string: bundle).expandingTildeInPath
        try refuseLinks(in: expanded, fileManager: fileManager)
        try refuseLinks(in: NSString(string: target).expandingTildeInPath, fileManager: fileManager)
        let path = resolve(expanded)
        let allowed = roots.filter { !$0.isEmpty }.map(resolve)
        guard allowed.contains(where: { path != $0 && isWithin(path, parent: $0) }),
              !allowed.contains(where: { isWithin($0, parent: path) }) else { throw QuarantineError.outsideRoots(path) }
        guard HFRepoID.forPath(path) == nil, HFRepoID.forPath(target) == nil else {
            throw QuarantineError.unsafeFolder("Hugging Face cache selections must be kept or cleaned through Check HF cache.")
        }
        guard !protected.filter({ $0.hasPrefix("/") }).map(resolve).contains(where: {
            isWithin(path, parent: $0) || isWithin($0, parent: path)
        }) else { throw QuarantineError.unsafeFolder("the bundle is in use, preferred, or contains a protected model.") }
        guard !files.isEmpty, files.count <= 10000, Set(files).count == files.count,
              files.allSatisfy({ file in
                  !file.hasPrefix("/") && !file.contains("\\") && file.lowercased().hasSuffix(".gguf") &&
                  !file.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                  file.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
              }), let main = files.first,
              resolve(target) == URL(fileURLWithPath: path).appendingPathComponent(main).path else {
            throw QuarantineError.unsafeFolder("the selected GGUF does not match the declared main file and companion selection.")
        }
        let snapshot = try directorySnapshot(path, fileManager: fileManager)
        let permitted = Set(files)
        var found = Set<String>(), pending = [path], inspected = 0
        let metadataExtensions: Set<String> = ["json", "jsonl", "txt", "md", "rst", "yaml", "yml", "toml", "ini", "cfg", "metadata", "lock"]
        let metadataNames: Set<String> = ["license", "notice", "readme", ".gitattributes", ".gitignore"]
        while let directory = pending.popLast() {
            for name in try fileManager.contentsOfDirectory(atPath: directory) {
                inspected += 1
                guard inspected <= 10000 else { throw QuarantineError.unsafeFolder("more than 10,000 entries; review this bundle in Finder.") }
                let child = directory + "/" + name
                let attributes = try fileManager.attributesOfItem(atPath: child)
                if attributes[.type] as? FileAttributeType == .typeDirectory { pending.append(child); continue }
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw QuarantineError.symlinkRefused(child) }
                let relative = String(child.dropFirst(path.count + 1))
                if name.lowercased().hasSuffix(".gguf") {
                    guard permitted.contains(relative) else { throw QuarantineError.unsafeFolder("the bundle contains an undeclared GGUF: \(relative). Keep it or review a single file instead.") }
                    found.insert(relative)
                } else {
                    let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
                    guard metadataExtensions.contains(suffix) || metadataNames.contains(name.lowercased()) else {
                        throw QuarantineError.unsafeFolder("the bundle contains a non-metadata payload: \(relative). Keep it or review a single file instead.")
                    }
                }
            }
        }
        guard found == permitted else { throw QuarantineError.unsafeFolder("a declared GGUF main file or companion is missing.") }
        guard try directorySnapshot(path, fileManager: fileManager) == snapshot else { throw QuarantineError.changedSincePreview }
        var bound = snapshot
        let context = [main, files.sorted().joined(separator: "\n"), snapshot.treeFingerprint ?? ""].joined(separator: "\n")
        bound.treeFingerprint = "gguf-bundle:" + SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        return bound
    }

    private static func moveGGUFBundle(expected: QuarantineFileSnapshot, quarantineDir: String, now: Date,
                                       fileManager: FileManager, kind: QuarantineKind = .ggufBundle, recheck: () throws -> QuarantineFileSnapshot) throws -> QuarantineRecord {
        guard !quarantineDir.isEmpty else { throw QuarantineError.unsafeFolder("configure a quarantine directory first.") }
        try refuseLinks(in: NSString(string: quarantineDir).expandingTildeInPath, fileManager: fileManager)
        let destinationRoot = resolve(quarantineDir)
        guard !isWithin(destinationRoot, parent: expected.path), !isWithin(expected.path, parent: destinationRoot) else {
            throw QuarantineError.alreadyQuarantined(expected.path)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        guard try fileManager.attributesOfItem(atPath: destinationRoot)[.systemNumber] as? UInt64 == expected.device else {
            throw QuarantineError.unsafeFolder("quarantine must be on the same volume for an atomic bundle move.")
        }
        let ledgerURL = URL(fileURLWithPath: destinationRoot).appendingPathComponent(ledgerName)
        try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: ledgerURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: ledgerURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, fileManager.isWritableFile(atPath: ledgerURL.path),
                  let size = attributes[.size] as? Int64, size < maxLedgerBytes - 4096 else {
                throw QuarantineError.unsafeFolder("quarantine history is full or unwritable.")
            }
        }
        guard try recheck() == expected else { throw QuarantineError.changedSincePreview }
        try refuseLinks(in: destinationRoot, fileManager: fileManager)
        let destination = URL(fileURLWithPath: destinationRoot)
            .appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: expected.path).lastPathComponent).path
        try fileManager.moveItem(atPath: expected.path, toPath: destination)
        let record = QuarantineRecord(movedAt: isoFormatter.string(from: now), from: expected.path, to: destination,
            bytes: expected.bytes, kind: kind)
        do { try appendLedger(record, quarantineDir: destinationRoot, fileManager: fileManager) }
        catch {
            do { try fileManager.moveItem(atPath: destination, toPath: expected.path) }
            catch { throw QuarantineError.unsafeFolder("history and rollback failed; recover the bundle at \(destination). \(error.localizedDescription)") }
            throw QuarantineError.unsafeFolder("could not record the move; the bundle was put back.")
        }
        return record
    }

    /// Explicit Library removal. Trash remains recoverable in Finder. A cache
    /// repository moves as one unit, retaining its relative blob references.
    static func previewModelTrash(_ modelPath: String, roots: [String], protected: [String], fileManager fm: FileManager = .default) throws -> LibraryTrashPlan {
        let expanded = NSString(string: modelPath).expandingTildeInPath
        try refuseLinks(in: expanded, fileManager: fm)
        let cacheRepo = HFRepoID.forPath(expanded)
        var target = URL(fileURLWithPath: expanded).standardizedFileURL
        if cacheRepo != nil {
            while !target.lastPathComponent.hasPrefix("models--"), target.path != "/" { target.deleteLastPathComponent() }
            guard target.lastPathComponent.hasPrefix("models--"), fm.fileExists(atPath: target.path + "/snapshots") else { throw QuarantineError.outsideRoots(expanded) }
        }
        let path = target.path
        let allowed = roots.filter { !$0.isEmpty }.map(resolve)
        guard allowed.contains(where: { path != $0 && isWithin(path, parent: $0) }),
              !allowed.contains(where: { isWithin($0, parent: path) }) else { throw QuarantineError.outsideRoots(path) }
        guard !protected.contains(where: { item in
            if item.hasPrefix("/") {
                let other = resolve(item)
                return isWithin(path, parent: other) || isWithin(other, parent: path)
            }
            return cacheRepo == item
        }) else { throw QuarantineError.unsafeFolder("the model is serving, preferred, or in use. Stop its endpoint and remove its preference before deleting it.") }
        let snapshot: QuarantineFileSnapshot
        if cacheRepo != nil {
            snapshot = try directorySnapshot(path, fileManager: fm, cacheRepository: true)
        } else if path.lowercased().hasSuffix(".gguf") {
            _ = try guardPath(path, roots: roots, fileManager: fm)
            let attributes = try fm.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = attributes[.systemNumber] as? UInt64, let inode = attributes[.systemFileNumber] as? UInt64,
                  let modified = attributes[.modificationDate] as? Date, let created = attributes[.creationDate] as? Date else { throw QuarantineError.notFound(path) }
            var status = stat()
            guard lstat(path, &status) == 0 else { throw QuarantineError.changedSincePreview }
            snapshot = QuarantineFileSnapshot(path: path, bytes: attributes[.size] as? Int64 ?? 0, device: device, inode: inode, modifiedAt: modified, createdAt: created, treeFingerprint: "\(status.st_ctimespec.tv_sec)|\(status.st_ctimespec.tv_nsec)")
        } else {
            snapshot = try folderSnapshot(target: path, roots: roots, protected: protected, fileManager: fm)
        }
        return LibraryTrashPlan(modelPath: modelPath, roots: roots, snapshot: snapshot, includesCacheRepository: cacheRepo != nil)
    }

    static func trashModel(_ plan: LibraryTrashPlan, roots: [String], protected: [String], fileManager fm: FileManager = .default, trash: ((URL) throws -> URL)? = nil) throws -> URL {
        guard plan.roots == roots, try previewModelTrash(plan.modelPath, roots: roots, protected: protected, fileManager: fm) == plan else { throw QuarantineError.changedSincePreview }
        let source = URL(fileURLWithPath: plan.snapshot.path)
        if let trash { return try trash(source) }
        var destination: NSURL?
        try fm.trashItem(at: source, resultingItemURL: &destination)
        guard let destination else { throw QuarantineError.trashFailed("Trash returned no recovery location. Inspect Finder before retrying.") }
        return destination as URL
    }

    /// Local, independently owned MLX outputs only. Cache snapshots and shared
    /// files require the cache manager's own reference-aware cleanup.
    static func folderSnapshot(target: String, roots: [String], protected: [String], fileManager: FileManager = .default) throws -> QuarantineFileSnapshot {
        let expanded = NSString(string: target).expandingTildeInPath
        try refuseLinks(in: expanded, fileManager: fileManager)
        let path = resolve(target)
        let allowed = roots.filter { !$0.isEmpty }.map(resolve)
        guard allowed.contains(where: { path != $0 && isWithin(path, parent: $0) }),
              !allowed.contains(where: { isWithin($0, parent: path) }) else {
            throw QuarantineError.outsideRoots(path)
        }
        guard HFRepoID.forPath(path) == nil else { throw QuarantineError.unsafeFolder("Hugging Face cache snapshots must be cleaned through Check HF cache.") }
        guard !protected.filter({ $0.hasPrefix("/") }).map(resolve).contains(where: { isWithin(path, parent: $0) || isWithin($0, parent: path) }) else {
            throw QuarantineError.unsafeFolder("the folder is in use, preferred, or contains a protected model.")
        }
        let snapshot = try directorySnapshot(path, fileManager: fileManager)
        let configURL = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        let attrs = try fileManager.attributesOfItem(atPath: configURL.path)
        guard let size = attrs[.size] as? Int64, size <= 1024 * 1024,
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              config["quantization"] is [String: Any] || fileManager.fileExists(atPath: path + "/mlx-converter.json") else {
            throw QuarantineError.unsafeFolder("no recognized MLX conversion config.")
        }
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        let hasWeights = contents.contains { $0.hasSuffix(".safetensors") && (try? fileManager.attributesOfItem(atPath: path + "/" + $0)[.type] as? FileAttributeType) == .typeRegular }
        let components = config["components"] as? [String] ?? []
        let hasComponentWeights = !components.isEmpty && components.allSatisfy { name in
            !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
            ((try? fileManager.contentsOfDirectory(atPath: path + "/" + name))?.contains { $0.hasSuffix(".safetensors") && (try? fileManager.attributesOfItem(atPath: path + "/" + name + "/" + $0)[.type] as? FileAttributeType) == .typeRegular } == true)
        }
        guard hasWeights || hasComponentWeights else { throw QuarantineError.unsafeFolder("no MLX safetensors weights.") }
        return snapshot
    }

    static func moveFolder(expected: QuarantineFileSnapshot, roots: [String], protected: [String], quarantineDir: String,
                           now: Date = Date(), fileManager: FileManager = .default) throws -> QuarantineRecord {
        guard !quarantineDir.isEmpty else { throw QuarantineError.unsafeFolder("configure a quarantine directory first.") }
        try refuseLinks(in: NSString(string: quarantineDir).expandingTildeInPath, fileManager: fileManager)
        let destinationRoot = resolve(quarantineDir)
        guard !isWithin(destinationRoot, parent: expected.path), !isWithin(expected.path, parent: destinationRoot) else {
            throw QuarantineError.alreadyQuarantined(expected.path)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        let attributes = try fileManager.attributesOfItem(atPath: destinationRoot)
        guard attributes[.systemNumber] as? UInt64 == expected.device else {
            throw QuarantineError.unsafeFolder("quarantine must be on the same volume for an atomic folder move.")
        }
        let current = try folderSnapshot(target: expected.path, roots: roots, protected: protected, fileManager: fileManager)
        guard current == expected else { throw QuarantineError.changedSincePreview }
        try refuseLinks(in: destinationRoot, fileManager: fileManager)
        let ledgerURL = URL(fileURLWithPath: destinationRoot).appendingPathComponent(ledgerName)
        try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: ledgerURL.path) {
            guard fileManager.isWritableFile(atPath: ledgerURL.path),
                  let size = try fileManager.attributesOfItem(atPath: ledgerURL.path)[.size] as? Int64,
                  size < maxLedgerBytes - 4096 else { throw QuarantineError.unsafeFolder("quarantine history is full or unwritable.") }
        }
        let destination = URL(fileURLWithPath: destinationRoot).appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: current.path).lastPathComponent).path
        try fileManager.moveItem(atPath: current.path, toPath: destination)
        let record = QuarantineRecord(movedAt: isoFormatter.string(from: now), from: current.path, to: destination, bytes: current.bytes, kind: .mlxDirectory)
        // A folder must remain recoverable through its ledger. Roll back if
        // recording fails, rather than reporting an unrecorded move as success.
        do {
            try appendLedger(record, quarantineDir: destinationRoot, fileManager: fileManager)
        } catch {
            do { try fileManager.moveItem(atPath: destination, toPath: current.path) }
            catch { throw QuarantineError.unsafeFolder("history and rollback failed; recover the folder at \(destination). \(error.localizedDescription)") }
            throw QuarantineError.unsafeFolder("could not record the move; the folder was put back.")
        }
        return record
    }

    static let ollamaManifestDirectories = ["manifests", "manifests-v2"]

    /// An Ollama tag inside a configured root. Blobs another manifest still
    /// references stay in place, so every remaining tag keeps working.
    static func ollamaSnapshot(manifest: String, roots: [String], protected: [String],
                               fileManager: FileManager = .default) throws -> OllamaRemovalPlan {
        let expanded = NSString(string: manifest).expandingTildeInPath
        try refuseLinks(in: expanded, fileManager: fileManager)
        let path = resolve(expanded)
        let allowed = roots.filter { !$0.isEmpty }.map(resolve)
        guard allowed.contains(where: { path != $0 && isWithin(path, parent: $0) }) else { throw QuarantineError.outsideRoots(path) }
        guard !protected.filter({ $0.hasPrefix("/") }).map(resolve).contains(where: { isWithin(path, parent: $0) || isWithin($0, parent: path) }) else {
            throw QuarantineError.unsafeFolder("the model is serving, preferred, or in use.")
        }
        var url = URL(fileURLWithPath: path)
        while url.path != "/", !ollamaManifestDirectories.contains(url.lastPathComponent) { url.deleteLastPathComponent() }
        guard url.path != "/" else { throw QuarantineError.unsafeFolder("not an Ollama manifest.") }
        let modelsRoot = url.deletingLastPathComponent().path
        let blobDirectory = modelsRoot + "/blobs"
        guard (try? fileManager.attributesOfItem(atPath: blobDirectory)[.type] as? FileAttributeType) == .typeDirectory else {
            throw QuarantineError.unsafeFolder("the Ollama blob folder is missing.")
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let device = attributes[.systemNumber] as? UInt64 else {
            throw QuarantineError.notFound(path)
        }
        let own = try ollamaDigests(path, fileManager: fileManager)
        var shared = Set<String>(), inspected = 0
        for directory in ollamaManifestDirectories.map({ modelsRoot + "/" + $0 }) where fileManager.fileExists(atPath: directory) {
            var pending = [directory]
            while let current = pending.popLast() {
                for name in try fileManager.contentsOfDirectory(atPath: current) {
                    inspected += 1
                    guard inspected <= 10000 else { throw QuarantineError.unsafeFolder("more than 10,000 Ollama manifests; review them in Finder.") }
                    let child = current + "/" + name
                    let type = try fileManager.attributesOfItem(atPath: child)[.type] as? FileAttributeType
                    if type == .typeDirectory { pending.append(child); continue }
                    guard type == .typeRegular, child != path, !name.hasPrefix(".") else { continue }
                    shared.formUnion(try ollamaDigests(child, fileManager: fileManager))
                }
            }
        }
        var bytes = attributes[.size] as? Int64 ?? 0, blobs: [String] = []
        var entries = ["\(path)|\(attributes[.systemFileNumber] ?? 0)|\(bytes)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"]
        for blob in own.subtracting(shared).sorted() {
            let blobPath = blobDirectory + "/" + blob
            guard let blobAttributes = try? fileManager.attributesOfItem(atPath: blobPath) else { continue }
            guard blobAttributes[.type] as? FileAttributeType == .typeRegular, blobAttributes[.systemNumber] as? UInt64 == device,
                  (blobAttributes[.referenceCount] as? UInt64 ?? 1) == 1 else {
                throw QuarantineError.unsafeFolder("an Ollama blob is linked or on another volume: \(blob)")
            }
            let size = blobAttributes[.size] as? Int64 ?? 0
            bytes += size
            blobs.append(blob)
            entries.append("\(blob)|\(blobAttributes[.systemFileNumber] ?? 0)|\(size)|\((blobAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")
        }
        let fingerprint = SHA256.hash(data: Data(entries.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return OllamaRemovalPlan(manifest: path, modelsRoot: modelsRoot, blobs: blobs, bytes: bytes, device: device, fingerprint: fingerprint)
    }

    /// Blob file names (`sha256-…`) a manifest references.
    private static func ollamaDigests(_ manifest: String, fileManager: FileManager) throws -> Set<String> {
        guard let size = try fileManager.attributesOfItem(atPath: manifest)[.size] as? Int64, size <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [String: Any] else {
            throw QuarantineError.unsafeFolder("unreadable Ollama manifest: \(manifest)")
        }
        let layers = (object["layers"] as? [[String: Any]]) ?? []
        let digests = ([object["config"] as? [String: Any]].compactMap { $0 } + layers).compactMap { $0["digest"] as? String }
        return Set(try digests.map { digest in
            let parts = digest.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isLetter || $0.isNumber }),
                  !parts[1].isEmpty, parts[1].allSatisfy({ $0.isHexDigit }) else {
                throw QuarantineError.unsafeFolder("unrecognized Ollama digest in \(manifest)")
            }
            return "\(parts[0])-\(parts[1])"
        })
    }

    /// Moves the manifest and its unshared blobs into one quarantine folder.
    static func moveOllamaModel(expected: OllamaRemovalPlan, roots: [String], protected: [String], quarantineDir: String,
                                now: Date = Date(), fileManager: FileManager = .default) throws -> QuarantineRecord {
        guard !quarantineDir.isEmpty else { throw QuarantineError.unsafeFolder("configure a quarantine directory first.") }
        try refuseLinks(in: NSString(string: quarantineDir).expandingTildeInPath, fileManager: fileManager)
        let destinationRoot = resolve(quarantineDir)
        guard !isWithin(destinationRoot, parent: expected.modelsRoot), !isWithin(expected.modelsRoot, parent: destinationRoot) else {
            throw QuarantineError.alreadyQuarantined(expected.manifest)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        guard try fileManager.attributesOfItem(atPath: destinationRoot)[.systemNumber] as? UInt64 == expected.device else {
            throw QuarantineError.unsafeFolder("quarantine must be on the same volume for an atomic move.")
        }
        let ledgerURL = URL(fileURLWithPath: destinationRoot).appendingPathComponent(ledgerName)
        try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: ledgerURL.path) {
            guard fileManager.isWritableFile(atPath: ledgerURL.path),
                  let size = try fileManager.attributesOfItem(atPath: ledgerURL.path)[.size] as? Int64,
                  size < maxLedgerBytes - 4096 else { throw QuarantineError.unsafeFolder("quarantine history is full or unwritable.") }
        }
        guard try ollamaSnapshot(manifest: expected.manifest, roots: roots, protected: protected, fileManager: fileManager) == expected else {
            throw QuarantineError.changedSincePreview
        }
        try refuseLinks(in: destinationRoot, fileManager: fileManager)
        let tag = expected.manifest.split(separator: "/").suffix(2).joined(separator: "-")
        let bundle = destinationRoot + "/" + UUID().uuidString + "-ollama-" + tag
        try fileManager.createDirectory(atPath: bundle + "/blobs", withIntermediateDirectories: true)
        var moved: [(from: String, to: String)] = []
        func rollBack() -> String? {
            for move in moved.reversed() {
                do { try fileManager.moveItem(atPath: move.to, toPath: move.from) } catch { return move.to }
            }
            removeIfEmpty(bundle + "/blobs", fileManager: fileManager)
            removeIfEmpty(bundle, fileManager: fileManager)
            return nil
        }
        do {
            try fileManager.moveItem(atPath: expected.manifest, toPath: bundle + "/manifest")
            moved.append((expected.manifest, bundle + "/manifest"))
            for blob in expected.blobs {
                try fileManager.moveItem(atPath: expected.modelsRoot + "/blobs/" + blob, toPath: bundle + "/blobs/" + blob)
                moved.append((expected.modelsRoot + "/blobs/" + blob, bundle + "/blobs/" + blob))
            }
            let record = QuarantineRecord(movedAt: isoFormatter.string(from: now), from: expected.manifest, to: bundle,
                bytes: expected.bytes, kind: .ollamaModel)
            try appendLedger(record, quarantineDir: destinationRoot, fileManager: fileManager)
            return record
        } catch {
            if let stranded = rollBack() { throw QuarantineError.moveFailed("the move and its rollback failed; recover the model at \(stranded). \(error.localizedDescription)") }
            throw QuarantineError.moveFailed("the model was put back. \(error.localizedDescription)")
        }
    }

    /// Puts an Ollama manifest and its blobs back. Refuses rather than overwrite.
    private static func restoreOllamaModel(_ record: QuarantineRecord, fileManager: FileManager) throws {
        let bundle = resolve(record.to), manifest = NSString(string: record.from).expandingTildeInPath
        try refuseLinks(in: bundle, fileManager: fileManager)
        try refuseLinks(in: manifest, fileManager: fileManager)
        var url = URL(fileURLWithPath: manifest)
        while url.path != "/", !ollamaManifestDirectories.contains(url.lastPathComponent) { url.deleteLastPathComponent() }
        guard url.path != "/" else { throw QuarantineError.notFound(manifest) }
        let blobDirectory = url.deletingLastPathComponent().path + "/blobs"
        let blobs = (try? fileManager.contentsOfDirectory(atPath: bundle + "/blobs")) ?? []
        guard fileManager.fileExists(atPath: bundle + "/manifest") else { throw QuarantineError.notFound(bundle + "/manifest") }
        if fileManager.fileExists(atPath: manifest) { throw QuarantineError.restoreBlocked(manifest) }
        if let present = blobs.first(where: { fileManager.fileExists(atPath: blobDirectory + "/" + $0) }) {
            throw QuarantineError.restoreBlocked(blobDirectory + "/" + present)
        }
        try fileManager.createDirectory(atPath: blobDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: URL(fileURLWithPath: manifest).deletingLastPathComponent().path, withIntermediateDirectories: true)
        do {
            for blob in blobs { try fileManager.moveItem(atPath: bundle + "/blobs/" + blob, toPath: blobDirectory + "/" + blob) }
            try fileManager.moveItem(atPath: bundle + "/manifest", toPath: manifest)
        } catch { throw QuarantineError.moveFailed(error.localizedDescription) }
        removeIfEmpty(bundle + "/blobs", fileManager: fileManager)
        removeIfEmpty(bundle, fileManager: fileManager)
    }

    /// Only an empty folder is removed; anything with contents stays.
    private static func removeIfEmpty(_ directory: String, fileManager: FileManager) {
        guard (try? fileManager.contentsOfDirectory(atPath: directory))?.isEmpty == true else { return }
        try? fileManager.removeItem(atPath: directory)
    }

    private static func refuseLinks(in path: String, fileManager: FileManager) throws {
        var component = URL(fileURLWithPath: path).standardizedFileURL
        while component.path != "/" {
            // macOS exposes these system-owned aliases for its writable volume.
            if ["/var", "/tmp", "/etc"].contains(component.path),
               (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) == "private" + component.path { break }
            if (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) != nil { throw QuarantineError.symlinkRefused(component.path) }
            component.deleteLastPathComponent()
        }
    }

    private static func directorySnapshot(_ path: String, fileManager: FileManager, cacheRepository: Bool = false) throws -> QuarantineFileSnapshot {
        let root = try fileManager.attributesOfItem(atPath: path)
        guard root[.type] as? FileAttributeType == .typeDirectory,
              let device = root[.systemNumber] as? UInt64, let inode = root[.systemFileNumber] as? UInt64,
              let modified = root[.modificationDate] as? Date, let created = root[.creationDate] as? Date else {
            throw QuarantineError.unsafeFolder("the selected path is not a model directory.")
        }
        var entries: [String] = []
        var bytes: Int64 = 0
        var fileCount = 0
        var pending = [path]
        while let directory = pending.popLast() {
            for name in try fileManager.contentsOfDirectory(atPath: directory).sorted() {
                let child = directory + "/" + name
                let attrs = try fileManager.attributesOfItem(atPath: child)
                let type = attrs[.type] as? FileAttributeType
                if cacheRepository, type == .typeSymbolicLink {
                    let destination = try fileManager.destinationOfSymbolicLink(atPath: child)
                    guard !destination.hasPrefix("/"), isWithin(resolve(child), parent: path + "/blobs"),
                          (try? fileManager.attributesOfItem(atPath: resolve(child))[.type] as? FileAttributeType) == .typeRegular else { throw QuarantineError.symlinkRefused(child) }
                    entries.append("\(child)|\(attrs[.systemFileNumber] ?? 0)|\(destination)")
                    guard entries.count <= 10000 else { throw QuarantineError.unsafeFolder("more than 10,000 entries; review this folder in Finder.") }
                    continue
                }
                guard type == .typeDirectory || type == .typeRegular,
                      attrs[.systemNumber] as? UInt64 == device else { throw QuarantineError.unsafeFolder("links, special files and mounted volumes are not allowed: \(child)") }
                let size = (attrs[.size] as? Int64) ?? 0
                if type == .typeRegular {
                    guard (attrs[.referenceCount] as? UInt64 ?? 1) == 1 else { throw QuarantineError.unsafeFolder("shared hard-linked files are not allowed: \(child)") }
                    bytes += size
                    fileCount += 1
                } else { pending.append(child) }
                let relative = String(child.dropFirst(path.count))
                let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
                var status = stat()
                guard lstat(child, &status) == 0 else { throw QuarantineError.changedSincePreview }
                entries.append("\(relative)|\(type?.rawValue ?? "")|\(attrs[.systemFileNumber] ?? 0)|\(size)|\(date)|\(status.st_ctimespec.tv_sec)|\(status.st_ctimespec.tv_nsec)")
                guard entries.count <= 10000 else { throw QuarantineError.unsafeFolder("more than 10,000 entries; review this folder in Finder.") }
            }
        }
        let fingerprint = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return QuarantineFileSnapshot(path: path, bytes: bytes, device: device, inode: inode, modifiedAt: modified, createdAt: created, treeFingerprint: fingerprint, fileCount: fileCount)
    }

    /// Allow only .gguf files that live under a configured scan root.
    /// Returns the canonical resolved path.
    static func guardPath(_ target: String, roots: [String], fileManager: FileManager = .default) throws -> String {
        // A symlinked source must be refused before resolve() follows it:
        // the check runs on the user-supplied path, not the canonical one.
        let expanded = NSString(string: target).expandingTildeInPath
        if (try? fileManager.destinationOfSymbolicLink(atPath: expanded)) != nil {
            throw QuarantineError.symlinkRefused(expanded)
        }
        let location = resolve(target)
        guard location.lowercased().hasSuffix(".gguf") else {
            throw QuarantineError.notGGUF(location)
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: location, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw QuarantineError.notFound(location)
        }
        let allowed = roots.map(resolve).filter { !$0.isEmpty }
        guard allowed.contains(where: { isWithin(location, parent: $0) }) else {
            throw QuarantineError.outsideRoots(location)
        }
        return location
    }

    private static func assetMarkerExists(_ path: String) throws -> Bool {
        var value = stat()
        if lstat(path, &value) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw QuarantineError.unsafeFolder("Model-file ownership could not be checked at \(path).")
    }

    /// Freeze a compared standalone file without reading its payload again.
    static func assetReview(_ item: StoredModel, roots: [String], protected: [String], quarantineDir: String,
                            requireSameVolume: Bool = true, fileManager: FileManager = .default) throws -> AssetFileReview {
        guard item.kind == "asset", item.files.count == 1, let evidence = item.asset,
              let digest = evidence.sha256, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              evidence.nlink == 1, item.files[0].path == item.path, item.files[0].bytes == item.bytes else {
            throw QuarantineError.unsafeFolder("Compare the model files again before removal.")
        }
        let expanded = NSString(string: item.path).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard path == item.path, path.hasPrefix("/"), ["safetensors", "ckpt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              URL(fileURLWithPath: path).lastPathComponent.range(of: #"(?:^|[-_.])\d+-of-\d+(?:\.|$)"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw QuarantineError.unsafeFolder("The file is not an independent standalone model file.")
        }
        try refuseLinks(in: path, fileManager: fileManager)
        let root = try roots.map { raw -> String in
            let expanded = NSString(string: raw).expandingTildeInPath
            try refuseLinks(in: expanded, fileManager: fileManager)
            return resolve(expanded)
        }.filter { isWithin(path, parent: $0) && path != $0 }.max { $0.count < $1.count }
        guard let root else { throw QuarantineError.outsideRoots(path) }
        let folders = String(path.dropFirst(root.count)).split(separator: "/").dropLast()
        let skipped: Set<String> = ["node_modules", "__pycache__", "venv"]
        guard folders.allSatisfy({ !$0.hasPrefix(".") && !skipped.contains(String($0)) }) else {
            throw QuarantineError.unsafeFolder("This folder is excluded from model-file scans.")
        }
        guard !quarantineDir.isEmpty else { throw QuarantineError.unsafeFolder("Configure quarantine first.") }
        let expandedQuarantine = NSString(string: quarantineDir).expandingTildeInPath
        try refuseLinks(in: expandedQuarantine, fileManager: fileManager)
        let quarantine = resolve(expandedQuarantine)
        guard !isWithin(path, parent: quarantine), !DiskLedger.isProtected(path, by: Set(protected)) else {
            throw QuarantineError.unsafeFolder("The model file is protected or already in quarantine.")
        }
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let markers = ["config.json", "model_index.json", "model.safetensors.index.json", "pytorch_model.bin.index.json", "diffusion_pytorch_model.safetensors.index.json"]
        while true {
            if directory.lastPathComponent.hasPrefix("models--") {
                throw QuarantineError.unsafeFolder("This file belongs to a provider store.")
            }
            for marker in markers where try assetMarkerExists(directory.appendingPathComponent(marker).path) {
                throw QuarantineError.unsafeFolder("This file belongs to a model directory.")
            }
            if isWithin(directory.path, parent: root) {
                let names = try fileManager.contentsOfDirectory(atPath: directory.path)
                guard names.count <= 10_000, !names.contains(where: { $0.hasSuffix(".index.json") }) else {
                    throw QuarantineError.unsafeFolder("The model directory has an index or too many entries to review.")
                }
            }
            if try assetMarkerExists(directory.appendingPathComponent("blobs").path) {
                for marker in ["manifests", "manifests-v2"] where try assetMarkerExists(directory.appendingPathComponent(marker).path) {
                    throw QuarantineError.unsafeFolder("This file belongs to a provider store.")
                }
            }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, "\(value.st_dev):\(value.st_ino)" == item.files[0].id,
              value.st_size == item.bytes,
              Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec) == evidence.mtimeNS,
              Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec) == evidence.ctimeNS else {
            throw QuarantineError.changedSincePreview
        }
        var parent = URL(fileURLWithPath: quarantine)
        while !fileManager.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
        var volume = stat()
        guard lstat(parent.path, &volume) == 0, !requireSameVolume || volume.st_dev == value.st_dev else {
            throw QuarantineError.unsafeFolder("Choose a quarantine folder on the same volume as this file.")
        }
        return AssetFileReview(item: item, root: root)
    }

    static func verifyAsset(_ review: AssetFileReview, roots: [String], protected: [String], quarantineDir: String,
                            cancellation: AssetVerificationCancellation, deadline: TimeInterval,
                            requireSameVolume: Bool = true, fileManager: FileManager = .default) throws {
        try cancellation.check(deadline: deadline)
        guard try assetReview(review.item, roots: roots, protected: protected, quarantineDir: quarantineDir, requireSameVolume: requireSameVolume, fileManager: fileManager) == review else {
            throw QuarantineError.changedSincePreview
        }
        let relative = String(review.item.path.dropFirst(review.root.count)).split(separator: "/").map(String.init)
        guard !relative.isEmpty else { throw QuarantineError.changedSincePreview }
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var parent = open(review.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw QuarantineError.changedSincePreview }
        descriptors.append(parent)
        for component in relative.dropLast() {
            parent = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw QuarantineError.changedSincePreview }
            descriptors.append(parent)
        }
        let fd = openat(parent, relative.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw QuarantineError.changedSincePreview }
        descriptors.append(fd)
        var opened = stat()
        guard fstat(fd, &opened) == 0, "\(opened.st_dev):\(opened.st_ino)" == review.item.files[0].id,
              opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else { throw QuarantineError.changedSincePreview }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try cancellation.check(deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            guard count >= 0 else { throw QuarantineError.changedSincePreview }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        try cancellation.check(deadline: deadline)
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == review.item.asset?.sha256,
              try assetReview(review.item, roots: roots, protected: protected, quarantineDir: quarantineDir, requireSameVolume: requireSameVolume, fileManager: fileManager) == review else {
            throw QuarantineError.changedSincePreview
        }
    }

    static func moveAsset(_ review: AssetRemovalReview, roots: [String], protected: [String], quarantineDir: String,
                          now: Date, fileManager: FileManager = .default) throws -> QuarantineRecord {
        guard review.source.item.path != review.keeper.item.path,
              review.source.item.files.first?.id != review.keeper.item.files.first?.id,
              let digest = review.source.item.asset?.sha256, digest == review.keeper.item.asset?.sha256 else {
            throw QuarantineError.changedSincePreview
        }
        guard try assetReview(review.source.item, roots: roots, protected: protected, quarantineDir: quarantineDir, fileManager: fileManager) == review.source,
              try assetReview(review.keeper.item, roots: roots, protected: [], quarantineDir: quarantineDir, requireSameVolume: false, fileManager: fileManager) == review.keeper else {
            throw QuarantineError.changedSincePreview
        }
        let destinationRoot = resolve(quarantineDir)
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        try refuseLinks(in: destinationRoot, fileManager: fileManager)
        let rootFD = open(review.source.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw QuarantineError.changedSincePreview }
        var descriptors = [rootFD]
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        let relative = String(review.source.item.path.dropFirst(review.source.root.count)).split(separator: "/").map(String.init)
        guard let sourceName = relative.last else { throw QuarantineError.changedSincePreview }
        var sourceParent = rootFD
        for component in relative.dropLast() {
            sourceParent = openat(sourceParent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard sourceParent >= 0 else { throw QuarantineError.changedSincePreview }
            descriptors.append(sourceParent)
        }
        let destinationFD = open(destinationRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard destinationFD >= 0 else { throw QuarantineError.changedSincePreview }
        descriptors.append(destinationFD)
        var sourceStat = stat(), destinationStat = stat(), currentDestination = stat()
        guard fstatat(sourceParent, sourceName, &sourceStat, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(destinationFD, &destinationStat) == 0, lstat(destinationRoot, &currentDestination) == 0,
              destinationStat.st_dev == sourceStat.st_dev, destinationStat.st_dev == currentDestination.st_dev,
              destinationStat.st_ino == currentDestination.st_ino,
              "\(sourceStat.st_dev):\(sourceStat.st_ino)" == review.source.item.files[0].id,
              sourceStat.st_mode & S_IFMT == S_IFREG, sourceStat.st_nlink == 1,
              sourceStat.st_size == review.source.item.bytes,
              Int64(sourceStat.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(sourceStat.st_mtimespec.tv_nsec) == review.source.item.asset?.mtimeNS,
              Int64(sourceStat.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(sourceStat.st_ctimespec.tv_nsec) == review.source.item.asset?.ctimeNS else { throw QuarantineError.changedSincePreview }
        let destinationName = UUID().uuidString + "-" + sourceName
        let destination = URL(fileURLWithPath: destinationRoot).appendingPathComponent(destinationName).path
        guard try assetReview(review.keeper.item, roots: roots, protected: [], quarantineDir: quarantineDir, requireSameVolume: false, fileManager: fileManager) == review.keeper else {
            throw QuarantineError.changedSincePreview
        }
        guard renameatx_np(sourceParent, sourceName, destinationFD, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            throw QuarantineError.moveFailed("The file could not be moved on its volume.")
        }
        var moved = stat(), stillDestination = stat()
        guard fstatat(destinationFD, destinationName, &moved, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(destinationRoot, &stillDestination) == 0,
              moved.st_dev == sourceStat.st_dev, moved.st_ino == sourceStat.st_ino,
              stillDestination.st_dev == destinationStat.st_dev, stillDestination.st_ino == destinationStat.st_ino else {
            if renameatx_np(destinationFD, destinationName, sourceParent, sourceName, UInt32(RENAME_EXCL)) != 0 {
                throw QuarantineError.moveFailed("The location changed and rollback failed; recover the file at \(destination).")
            }
            throw QuarantineError.changedSincePreview
        }
        let record = QuarantineRecord(movedAt: isoFormatter.string(from: now), from: review.source.item.path,
                                      to: destination, bytes: review.source.item.bytes, kind: .assetFile)
        do {
            guard try assetReview(review.keeper.item, roots: roots, protected: [], quarantineDir: quarantineDir,
                                  requireSameVolume: false, fileManager: fileManager) == review.keeper else {
                throw QuarantineError.changedSincePreview
            }
            try appendLedger(record, quarantineDir: destinationRoot, fileManager: fileManager)
        }
        catch {
            if renameatx_np(destinationFD, destinationName, sourceParent, sourceName, UInt32(RENAME_EXCL)) != 0 {
                throw QuarantineError.moveFailed("History and rollback failed; recover the file at \(destination).")
            }
            throw QuarantineError.moveFailed("History could not be saved; the file was put back.")
        }
        return record
    }

    /// Move one redundant GGUF into the quarantine directory. Never deletes.
    @discardableResult
    static func move(
        target: String,
        roots: [String],
        quarantineDir: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> QuarantineRecord {
        let location = try guardPath(target, roots: roots, fileManager: fileManager)
        // A symlink at the quarantine dir would redirect where files land;
        // check the user-supplied path before resolve() hides the link.
        let expandedRoot = NSString(string: quarantineDir).expandingTildeInPath
        let destinationRoot = resolve(quarantineDir)
        if fileManager.fileExists(atPath: destinationRoot),
           (try? fileManager.destinationOfSymbolicLink(atPath: expandedRoot)) != nil {
            throw QuarantineError.symlinkRefused(expandedRoot)
        }
        if isWithin(location, parent: destinationRoot) {
            throw QuarantineError.alreadyQuarantined(location)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        if (try? fileManager.destinationOfSymbolicLink(atPath: destinationRoot)) != nil {
            throw QuarantineError.symlinkRefused(destinationRoot)
        }

        let stamp = stampFormatter.string(from: now)
        let name = (location as NSString).lastPathComponent
        var destination = "\(destinationRoot)/\(stamp)-\(name)"
        var suffix = 1
        while fileManager.fileExists(atPath: destination) {
            destination = "\(destinationRoot)/\(stamp)-\(suffix)-\(name)"
            suffix += 1
        }

        let size = (try? fileManager.attributesOfItem(atPath: location)[.size] as? Int64) ?? 0
        do {
            try fileManager.moveItem(atPath: location, toPath: destination)
        } catch {
            throw QuarantineError.moveFailed(error.localizedDescription)
        }

        let record = QuarantineRecord(
            movedAt: isoFormatter.string(from: now),
            from: location,
            to: destination,
            bytes: size
        )
        do {
            try appendLedger(record, quarantineDir: destinationRoot, fileManager: fileManager)
        } catch {
            let historyError = error
            do { try fileManager.moveItem(atPath: destination, toPath: location) }
            catch { throw QuarantineError.moveFailed("History could not be saved and the model could not be put back. Recover it at \(destination). \(error.localizedDescription)") }
            throw QuarantineError.moveFailed("History could not be saved; the model was put back. \(historyError.localizedDescription)")
        }
        return record
    }

    /// Reconcile a completed rename after interruption without replaying a move.
    static func confirmModelUpdateMove(expected: QuarantineFileSnapshot, quarantineDir: String,
                                      fileManager: FileManager = .default) throws -> Bool {
        guard !fileManager.fileExists(atPath: expected.path) else { return false }
        for record in ledger(quarantineDir: quarantineDir, limit: 10000, fileManager: fileManager)
            where record.from == expected.path && record.deletedAt == nil {
            let actual = try trashSnapshot(record, quarantineDir: quarantineDir, fileManager: fileManager)
            if actual.device == expected.device && actual.inode == expected.inode &&
                actual.bytes == expected.bytes && actual.modifiedAt == expected.modifiedAt && actual.createdAt == expected.createdAt {
                return true
            }
        }
        return false
    }

    /// Recent quarantine records, newest first.
    static func ledger(quarantineDir: String, limit: Int = 200, fileManager: FileManager = .default) -> [QuarantineRecord] {
        let ledgerURL = URL(fileURLWithPath: resolve(quarantineDir)).appendingPathComponent(ledgerName)
        guard !quarantineDir.isEmpty, limit > 0,
              (try? fileManager.destinationOfSymbolicLink(atPath: NSString(string: quarantineDir).expandingTildeInPath)) == nil,
              (try? fileManager.destinationOfSymbolicLink(atPath: ledgerURL.path)) == nil,
              let size = try? fileManager.attributesOfItem(atPath: ledgerURL.path)[.size] as? Int64, size <= maxLedgerBytes,
              let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            try? decoder.decode(QuarantineRecord.self, from: Data(line.utf8))
        }.reversed()
    }

    /// Files offered for Trash must still belong to this quarantine and its ledger.
    static func trashSnapshot(_ record: QuarantineRecord, quarantineDir: String, fileManager: FileManager = .default) throws -> QuarantineFileSnapshot {
        let path = try guardQuarantinedPath(record.to, quarantineDir: quarantineDir, kind: record.kind, fileManager: fileManager)
        guard record.deletedAt == nil, ledger(quarantineDir: quarantineDir, limit: 10000, fileManager: fileManager).contains(record) else { throw QuarantineError.notInQuarantine(record.to) }
        if record.kind?.isDirectory == true { return try directorySnapshot(path, fileManager: fileManager) }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard record.deletedAt == nil,
              let bytes = attributes[.size] as? Int64,
              let device = attributes[.systemNumber] as? UInt64,
              let inode = attributes[.systemFileNumber] as? UInt64,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date,
              ledger(quarantineDir: quarantineDir, limit: 10000, fileManager: fileManager).contains(record) else {
            throw QuarantineError.notInQuarantine(record.to)
        }
        return QuarantineFileSnapshot(path: path, bytes: bytes, device: device, inode: inode, modifiedAt: modified, createdAt: created)
    }

    static func guardQuarantinedPath(_ path: String, quarantineDir: String, kind: QuarantineKind? = nil, fileManager: FileManager = .default) throws -> String {
        let expandedRoot = NSString(string: quarantineDir).expandingTildeInPath
        if kind?.isDirectory == true { try refuseLinks(in: path, fileManager: fileManager); try refuseLinks(in: expandedRoot, fileManager: fileManager) }
        guard expandedRoot.hasPrefix("/"), resolve(expandedRoot) != "/", path.hasPrefix("/") else {
            throw QuarantineError.notInQuarantine(path)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: expandedRoot)) != nil {
            throw QuarantineError.symlinkRefused(expandedRoot)
        }
        let root = resolve(expandedRoot)
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let extensionAllowed = kind == .assetFile && ["safetensors", "ckpt"].contains(target.pathExtension.lowercased())
        guard target.lastPathComponent != ledgerName, (kind?.isDirectory == true || extensionAllowed || target.path.lowercased().hasSuffix(".gguf")),
              target.path != root, isWithin(target.path, parent: root) else {
            throw QuarantineError.notInQuarantine(path)
        }
        var component = target
        while component.path != root {
            if (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw QuarantineError.symlinkRefused(component.path)
            }
            component.deleteLastPathComponent()
        }
        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == (kind?.isDirectory == true ? .typeDirectory : .typeRegular) else {
            throw QuarantineError.notInQuarantine(path)
        }
        return target.path
    }

    /// Native macOS Trash only. Never fall back to unlinking a file.
    static func trash(_ record: QuarantineRecord, quarantineDir: String, expected: QuarantineFileSnapshot,
                      now: Date = Date(), fileManager: FileManager = .default,
                      trashFile: ((URL) throws -> Void)? = nil) throws -> QuarantineTrashResult {
        let quarantineRoot = resolve(quarantineDir)
        let current = try trashSnapshot(record, quarantineDir: quarantineDir, fileManager: fileManager)
        guard current == expected else { throw QuarantineError.changedSincePreview }
        do {
            let url = URL(fileURLWithPath: current.path)
            if let trashFile { try trashFile(url) }
            else { try fileManager.trashItem(at: url, resultingItemURL: nil) }
        } catch { throw QuarantineError.trashFailed(error.localizedDescription) }
        // Preserve unknown fields and history, matching the web's deleted_at contract.
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        do {
            try refuseRootDrift(quarantineDir, expected: quarantineRoot, fileManager: fileManager)
            let ledgerURL = URL(fileURLWithPath: quarantineRoot).appendingPathComponent(ledgerName)
            try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
            let data = try Data(contentsOf: ledgerURL)
            guard data.count <= maxLedgerBytes, let text = String(data: data, encoding: .utf8) else {
                throw QuarantineError.notInQuarantine(ledgerURL.path)
            }
            let lines = try text.split(separator: "\n").map { line -> String in
                guard var json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      json["to"] as? String == record.to, json["moved_at"] as? String == record.movedAt else { return String(line) }
                json["deleted_at"] = isoFormatter.string(from: now)
                return String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
            }
            try refuseRootDrift(quarantineDir, expected: quarantineRoot, fileManager: fileManager)
            try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: ledgerURL, options: .atomic)
            return QuarantineTrashResult(bytes: current.bytes, ledgerWarning: nil)
        } catch {
            return QuarantineTrashResult(bytes: current.bytes, ledgerWarning: "Moved to Trash, but could not update quarantine history: \(error.localizedDescription)")
        }
    }

    /// Put a quarantined file back where it came from. Extends the Python
    /// original (which has no restore): the guard is the same spirit — move,
    /// never delete, and refuse rather than overwrite. The original location
    /// must be free; the quarantined copy must still exist. The ledger is
    /// left untouched: the record's file simply leaves the quarantine dir.
    static func restore(_ record: QuarantineRecord, fileManager: FileManager = .default) throws {
        if record.kind == .ollamaModel { return try restoreOllamaModel(record, fileManager: fileManager) }
        let quarantined = resolve(record.to)
        var isDirectory = ObjCBool(false)
        if record.kind?.isDirectory == true || record.kind == .assetFile { try refuseLinks(in: record.to, fileManager: fileManager) }
        guard fileManager.fileExists(atPath: quarantined, isDirectory: &isDirectory), isDirectory.boolValue == (record.kind?.isDirectory == true) else {
            throw QuarantineError.notFound(quarantined)
        }
        let original = resolve(record.from)
        // Never write through a symlink when putting a file back; resolve()
        // follows links, so the check must use the unresolved path.
        let expandedOriginal = NSString(string: record.from).expandingTildeInPath
        if record.kind?.isDirectory == true || record.kind == .assetFile { try refuseLinks(in: expandedOriginal, fileManager: fileManager) }
        if (try? fileManager.destinationOfSymbolicLink(atPath: expandedOriginal)) != nil {
            throw QuarantineError.symlinkRefused(original)
        }
        if fileManager.fileExists(atPath: original) {
            throw QuarantineError.restoreBlocked(original)
        }
        do {
            try fileManager.moveItem(atPath: quarantined, toPath: original)
        } catch {
            throw QuarantineError.moveFailed(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private static func refuseRootDrift(_ directory: String, expected: String, fileManager: FileManager) throws {
        let expanded = NSString(string: directory).expandingTildeInPath
        if (try? fileManager.destinationOfSymbolicLink(atPath: expanded)) != nil {
            throw QuarantineError.symlinkRefused(expanded)
        }
        guard resolve(expanded) == expected else { throw QuarantineError.changedSincePreview }
    }

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func isWithin(_ child: String, parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static let ledgerLock = NSLock()

    private static func appendLedger(_ record: QuarantineRecord, quarantineDir: String, fileManager: FileManager) throws {
        ledgerLock.lock()
        defer { ledgerLock.unlock() }
        let ledgerURL = URL(fileURLWithPath: quarantineDir).appendingPathComponent(ledgerName)
        try refuseLinks(in: quarantineDir, fileManager: fileManager)
        try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
        var data = Data()
        if fileManager.fileExists(atPath: ledgerURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: ledgerURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int64, size <= maxLedgerBytes else {
                throw QuarantineError.moveFailed("Quarantine history is full or unavailable.")
            }
            data = try Data(contentsOf: ledgerURL)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if !data.isEmpty, data.last != 0x0A { data.append(0x0A) }
        data.append(try encoder.encode(record))
        data.append(0x0A)
        guard data.count <= maxLedgerBytes else { throw QuarantineError.moveFailed("Quarantine history is full.") }
        try data.write(to: ledgerURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: ledgerURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

struct ConvertedSourcePlan: Equatable {
    let workflow: ConversionWorkflow
    let roots: [String]
    let paths: [String]
    let bytes: Int64
    let fingerprint: String
}

struct ConvertedSourceMove: Codable, Equatable, Identifiable {
    let id: String
    let from: String
    var to: String?
    var batchID: String? = nil
    var workflowID: String? = nil
    var outputPath: String? = nil
    var movedAt: Date? = nil
    var bytes: Int64? = nil
    var trashFingerprint: String? = nil
    var restoredAt: Date? = nil
}

/// Reclaim only sources identified by a successful conversion receipt, after
/// verification. Cache links are references, never independently owned weights.
enum ConvertedSourceCleanup {
    static func preview(workflow: ConversionWorkflow, roots: [String], protected: [String], fileManager fm: FileManager = .default) throws -> ConvertedSourcePlan {
        guard workflow.state == .verified, let receiptPath = workflow.jobReceipt,
              let output = workflow.completedModelPath else { throw refused("the conversion must pass verification first.") }
        try noParentLinks(receiptPath, fm: fm)
        let data = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        guard data.count <= 1024 * 1024,
              let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["exit_status"] as? String == "done", let out = receipt["out"] as? String,
              Quarantine.resolve(out) == Quarantine.resolve(output),
              let argv = receipt["argv"] as? [String] else { throw refused("no matching successful conversion receipt.") }
        let outputSnapshot = try Quarantine.folderSnapshot(target: output, roots: roots, protected: [], fileManager: fm)
        let outputEntries = try entries(outputSnapshot.path, fm: fm)
        for path in outputEntries where path.hasSuffix(".safetensors") || path.hasSuffix(".json") {
            if let modified = try fm.attributesOfItem(atPath: path)[.modificationDate] as? Date, modified > workflow.updatedAt {
                throw refused("the converted output changed after verification; verify it again.")
            }
        }
        var sourcePaths = [String]()
        for flag in ["--hf-path", "--lora", "--gguf"] {
            if let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) { sourcePaths.append(argv[index + 1]) }
        }
        // Older receipts used a repo id; resolve only its existing refs/main.
        if sourcePaths.allSatisfy({ !$0.hasPrefix("/") }) {
            for root in roots {
                let repo = (receipt["repo"] as? String) ?? String(workflow.sourcePath.dropFirst("hf://".count))
                let entry = NSString(string: root).expandingTildeInPath + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
                if let revision = try? String(contentsOfFile: entry + "/refs/main", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !revision.isEmpty, !revision.contains("/"), revision != ".", revision != ".." {
                    sourcePaths = [entry + "/snapshots/" + revision]
                    break
                }
            }
        }
        guard !sourcePaths.isEmpty, sourcePaths.allSatisfy({ $0.hasPrefix("/") }) else { throw refused("the receipt does not identify a local source.") }
        let allowed = roots.map(Quarantine.resolve)
        var targets = Set<String>(), cacheRoots = Set<String>(), candidates = Set<String>()
        for source in sourcePaths {
            let components = URL(fileURLWithPath: source).standardizedFileURL.pathComponents
            if let index = components.firstIndex(where: { $0.hasPrefix("models--") }), components.count > index + 2, components[index + 1] == "snapshots" {
                let spelling = NSString.path(withComponents: Array(components.prefix(index + 1)))
                if (try? fm.destinationOfSymbolicLink(atPath: spelling)) != nil { throw QuarantineError.symlinkRefused(spelling) }
                let cacheSpelling = URL(fileURLWithPath: spelling).deletingLastPathComponent().path
                let repo: String
                if roots.contains(where: { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path == cacheSpelling }) {
                    // A configured cache alias is supported only through its
                    // physical root; model directories themselves remain fenced.
                    repo = Quarantine.resolve(cacheSpelling) + "/" + components[index]
                } else { repo = spelling }
                try noParentLinks(repo, fm: fm)
                let snapshots = try fm.contentsOfDirectory(atPath: repo + "/snapshots")
                guard snapshots == [components[index + 2]] else { throw refused("the source cache contains other revisions; keep them or review the cache separately.") }
                targets.insert(repo)
                cacheRoots.insert(URL(fileURLWithPath: repo).deletingLastPathComponent().path)
            } else if source.lowercased().hasSuffix(".gguf") {
                try noParentLinks(source, fm: fm)
                targets.insert(try Quarantine.guardPath(source, roots: roots, fileManager: fm))
            } else { throw refused("only receipt-owned GGUF files or single-revision HF sources can be reclaimed.") }
        }
        for target in targets {
            guard allowed.contains(where: { target != $0 && Quarantine.isWithin(target, parent: $0) }),
                  !allowed.contains(where: { Quarantine.isWithin($0, parent: target) }),
                  !Quarantine.isWithin(outputSnapshot.path, parent: target),
                  !Quarantine.isWithin(target, parent: outputSnapshot.path),
                  !isProtected(target, protected: protected) else { throw refused("a source is outside the configured roots or still in use.") }
            for item in try entries(target, fm: fm) {
                if let _ = try? fm.destinationOfSymbolicLink(atPath: item) {
                    let resolved = Quarantine.resolve(item)
                    guard let cache = cacheRoots.first(where: { Quarantine.isWithin(resolved, parent: $0) }) else { throw refused("a source links outside its owned cache.") }
                    if Quarantine.isWithin(resolved, parent: cache + "/blobs") { candidates.insert(resolved) }
                }
            }
        }
        // Walk every configured model root and the entire cache, without
        // following links. A surviving reference protects a shared blob.
        var references = [String]()
        var visited = Set<String>()
        for root in Set(allowed).union(cacheRoots) where fm.fileExists(atPath: root) {
            for item in try entries(root, excluding: targets, fm: fm) where visited.insert(item).inserted {
                if let destination = try? fm.destinationOfSymbolicLink(atPath: item) {
                    candidates.remove(Quarantine.resolve(item))
                    references.append(item + "|" + destination)
                }
            }
        }
        for blob in candidates {
            try noParentLinks(blob, fm: fm)
            let attrs = try fm.attributesOfItem(atPath: blob)
            if attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.referenceCount] as? Int ?? 1) == 1, !isProtected(blob, protected: protected) { targets.insert(blob) }
        }
        let paths = targets.sorted { lhs, rhs in
            // Remove cache references before moving their unshared payloads.
            let ld = (try? fm.attributesOfItem(atPath: lhs)[.type] as? FileAttributeType) == .typeDirectory
            let rd = (try? fm.attributesOfItem(atPath: rhs)[.type] as? FileAttributeType) == .typeDirectory
            return ld == rd ? lhs < rhs : ld
        }
        var states = references + [outputSnapshot.treeFingerprint ?? "", outputSnapshot.path]
        var bytes: Int64 = 0
        for target in paths {
            for item in try entries(target, fm: fm) {
                let attrs = try fm.attributesOfItem(atPath: item)
                let link = (try? fm.destinationOfSymbolicLink(atPath: item)) ?? ""
                let size = attrs[.size] as? Int64 ?? 0
                var status = stat()
                guard lstat(item, &status) == 0 else { throw QuarantineError.changedSincePreview }
                states.append("\(item)|\(status.st_dev)|\(status.st_ino)|\(size)|\(status.st_mtimespec)|\(status.st_ctimespec)|\(link)")
                if attrs[.type] as? FileAttributeType == .typeRegular { bytes += size }
            }
        }
        let fingerprint = SHA256.hash(data: Data(states.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return ConvertedSourcePlan(workflow: workflow, roots: roots, paths: paths, bytes: bytes, fingerprint: fingerprint)
    }

    static func apply(_ plan: ConvertedSourcePlan, workflow: ConversionWorkflow, roots: [String], protected: [String],
                      fileManager fm: FileManager = .default, journalURL: URL = JSONStore<ConvertedSourceMove>.defaultFileURL("source-cleanup.json"),
                      trash: ((URL) throws -> URL)? = nil) throws -> [ConvertedSourceMove] {
        guard workflow == plan.workflow, roots == plan.roots,
              try preview(workflow: workflow, roots: roots, protected: protected, fileManager: fm).fingerprint == plan.fingerprint else { throw QuarantineError.changedSincePreview }
        let store = JSONStore<ConvertedSourceMove>(fileURL: journalURL, fileManager: fm)
        let batchID = UUID().uuidString
        var moves = [ConvertedSourceMove]()
        for path in plan.paths {
            var move = ConvertedSourceMove(id: UUID().uuidString, from: path, to: nil)
            move.batchID = batchID
            move.workflowID = workflow.id.uuidString
            move.outputPath = workflow.completedModelPath
            try store.upsert(move, id: \.id)
            let destination: URL
            if let trash { destination = try trash(URL(fileURLWithPath: path)) }
            else {
                var url: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &url)
                guard let url else { throw refused("Trash did not return a recovery location; inspect Finder before retrying.") }
                destination = url as URL
            }
            move.to = destination.path
            move.movedAt = Date()
            moves.append(move)
            do { try store.upsert(move, id: \.id) }
            catch { throw refused("moved \(path) to \(destination.path), but could not update recovery history: \(error.localizedDescription)") }
            // Persist the native recovery URL before inspecting the moved tree,
            // so even an interrupted identity capture leaves a Finder location.
            let snapshot = try ConvertedSourceRecovery.snapshot(destination.path, fileManager: fm)
            move.bytes = snapshot.bytes
            move.trashFingerprint = snapshot.fingerprint
            try store.upsert(move, id: \.id)
            moves[moves.count - 1] = move
        }
        return moves
    }

    private static func entries(_ root: String, excluding: Set<String> = [], fm: FileManager) throws -> [String] {
        var result = [String](), pending = [root]
        while let path = pending.popLast() {
            if excluding.contains(path) { continue }
            let attrs = try fm.attributesOfItem(atPath: path)
            result.append(path)
            guard result.count < 100000 else { throw refused("the reference scan is too large; review this source manually.") }
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                pending.append(contentsOf: try fm.contentsOfDirectory(atPath: path).map { path + "/" + $0 })
            }
        }
        return result
    }

    private static func noParentLinks(_ path: String, fm: FileManager) throws {
        var url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        while url.path != "/" {
            if ["/var", "/tmp", "/etc"].contains(url.path), (try? fm.destinationOfSymbolicLink(atPath: url.path)) == "private" + url.path { break }
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw QuarantineError.symlinkRefused(url.path) }
            url.deleteLastPathComponent()
        }
    }

    private static func isProtected(_ path: String, protected: [String]) -> Bool {
        protected.contains { item in
            if item.hasPrefix("/") {
                let canonical = Quarantine.resolve(item)
                return Quarantine.isWithin(path, parent: canonical) || Quarantine.isWithin(canonical, parent: path)
            }
            return HFRepoID.forPath(path) == item
        }
    }

    private static func refused(_ reason: String) -> QuarantineError { .unsafeFolder(reason) }
}
