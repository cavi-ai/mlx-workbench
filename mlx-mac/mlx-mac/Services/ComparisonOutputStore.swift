import Foundation

/// Durable input copies owned by saved prompt sets. Uses the same fenced UUID
/// layout and copying rules as outputs, but never participates in run retention.
struct ComparisonPromptInputStore: Sendable {
    let root: URL
    private var files: ComparisonOutputStore { ComparisonOutputStore(root: root) }

    func copyingInputs(in set: PromptSet, reusingInputsFrom original: PromptSet? = nil) async throws -> PromptSet {
        guard set.effectiveMode.inputKind != nil else { return set }
        guard set.prompts.contains(where: { $0.inputPath != nil }) else {
            var copy = set
            if original != nil { copy.inputStorageID = nil }
            return copy
        }
        var copying: [Int] = []
        for index in set.prompts.indices {
            let entry = set.prompts[index]
            guard let path = entry.inputPath else { continue }
            if original?.prompts.contains(where: { $0.id == entry.id && $0.inputPath == path }) == true,
               let id = storageID(for: path) {
                guard files.readableInputArtifactURL(runID: id, artifact: URL(fileURLWithPath: path).lastPathComponent) != nil else {
                    throw ComparisonOutputStore.InputError.unsafeLocation
                }
                continue
            }
            copying.append(index)
        }
        guard !copying.isEmpty else { return set }
        let storageID = UUID()
        var copy = set
        copy.inputStorageID = storageID
        var created = false
        do {
            try await Task.detached {
                let fm = FileManager.default
                guard (try? fm.attributesOfItem(atPath: root.deletingLastPathComponent().path)[.type]) as? FileAttributeType == .typeDirectory else {
                    throw ComparisonOutputStore.InputError.unsafeLocation
                }
                if fm.fileExists(atPath: root.path) {
                    guard (try? fm.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory else {
                        throw ComparisonOutputStore.InputError.unsafeLocation
                    }
                } else { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
                try fm.createDirectory(at: files.runDirectory(storageID), withIntermediateDirectories: false)
                do { try fm.createDirectory(at: files.inputsDirectory(storageID), withIntermediateDirectories: false) }
                catch { discard(storageID); throw error }
            }.value
            created = true
            for index in copying {
                try Task.checkCancellation()
                guard let path = copy.prompts[index].inputPath else { continue }
                guard path.hasPrefix("/") else { throw ComparisonOutputStore.InputError.unavailable }
                let artifact = try await files.snapshotInput(from: URL(fileURLWithPath: path), runID: storageID)
                copy.prompts[index].inputPath = files.inputArtifactURL(runID: storageID, artifact: artifact)?.path
            }
            try Task.checkCancellation()
            return copy
        } catch {
            if created { discard(storageID) }
            throw error
        }
    }

    /// Only a task-created or recorded UUID folder under this owned root is removed.
    func discard(_ storageID: UUID) {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? fm.attributesOfItem(atPath: files.runDirectory(storageID).path)[.type]) as? FileAttributeType == .typeDirectory else { return }
        try? fm.removeItem(at: files.runDirectory(storageID))
    }

    /// Resolve only this store's exact `<uuid>/inputs/<basename>` path shape.
    func storageID(for path: String) -> UUID? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let inputs = url.deletingLastPathComponent()
        let directory = inputs.deletingLastPathComponent()
        guard path.hasPrefix("/"), ComparisonOutputStore.isContainedName(url.lastPathComponent),
              inputs.lastPathComponent == "inputs", directory.deletingLastPathComponent() == root.standardizedFileURL,
              let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
        return id
    }

    /// Reclaim unreferenced owned folders after a successful removal or edit.
    /// Borrowed paths from other sets and legacy runs keep their source folders.
    func reclaimInputs(of removed: PromptSet, sets: [PromptSet], legacyEntries: [PromptEntry]) {
        guard (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory else { return }
        var keep = Set(sets.compactMap(\.inputStorageID))
        for entry in sets.flatMap(\.prompts) + legacyEntries {
            if let path = entry.inputPath, let id = storageID(for: path) { keep.insert(id) }
        }
        var candidates = Set(removed.prompts.compactMap { entry in entry.inputPath.flatMap(storageID(for:)) })
        if let id = removed.inputStorageID { candidates.insert(id) }
        for id in candidates.subtracting(keep) { discard(id) }
    }
}

// MARK: - ComparisonOutputStore
//
// Where media comparison runs keep what the models produced, so the results
// grid can show the image, play the audio, and play the video next to the
// metrics: `<Application Support>/mlx-workbench/comparison-outputs/<run-id>/`.
// The app owns this cache. Run JSON (metrics) stays; only the files here are
// pruned, and only whole run directories named by a run UUID.

struct ComparisonOutputStore: Sendable {
    /// Runs whose output files are kept; older runs' directories are deleted.
    static let retainedRuns = 10

    let root: URL

    init(root: URL = ComparisonOutputStore.defaultRoot()) {
        self.root = root
    }

    /// Same Application Support folder the JSON stores use.
    static func defaultRoot() -> URL {
        JSONStore<ComparisonRun>.defaultFileURL("comparison-outputs")
    }

    func runDirectory(_ runID: UUID) -> URL {
        root.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    /// Generated prompt inputs (built-in images, videos, audio) live here, shared by every variant.
    func inputsDirectory(_ runID: UUID) -> URL {
        runDirectory(runID).appendingPathComponent("inputs", isDirectory: true)
    }

    enum InputError: LocalizedError {
        case unavailable, unsafeLocation
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Choose a readable regular input file; symbolic links and directories cannot be saved."
            case .unsafeLocation: return "The comparison input folder is unavailable or contains a symbolic link."
            }
        }
    }

    /// Copy once before replaying any model. File copying stays off the main actor.
    /// Unique names preserve extensions without colliding with prompt ids or other inputs.
    func snapshotInput(from source: URL, runID: UUID) async throws -> String {
        try await Task.detached {
            let fm = FileManager.default
            guard !source.path.unicodeScalars.contains(where: { $0.value < 32 }),
                  Self.isReadableRegularFile(source) else { throw InputError.unavailable }
            for directory in [root, runDirectory(runID), inputsDirectory(runID)] {
                guard (try? fm.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory else {
                    throw InputError.unsafeLocation
                }
            }
            var target = inputsDirectory(runID).appendingPathComponent(UUID().uuidString)
            if !source.pathExtension.isEmpty { target.appendPathExtension(source.pathExtension) }
            guard Self.isContainedName(target.lastPathComponent) else { throw InputError.unavailable }
            do {
                try fm.copyItem(at: source, to: target)
                guard Self.isReadableRegularFile(target) else { throw InputError.unavailable }
                return target.lastPathComponent
            } catch {
                try? fm.removeItem(at: target)
                throw error
            }
        }.value
    }

    func inputArtifactURL(runID: UUID, artifact: String) -> URL? {
        guard Self.isContainedName(artifact) else { return nil }
        return inputsDirectory(runID).appendingPathComponent(artifact, isDirectory: false)
    }

    func readableInputArtifactURL(runID: UUID, artifact: String) -> URL? {
        for directory in [root, runDirectory(runID), inputsDirectory(runID)] {
            guard (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory else { return nil }
        }
        guard let url = inputArtifactURL(runID: runID, artifact: artifact), Self.isReadableRegularFile(url) else { return nil }
        return url
    }

    static func isReadableRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    @discardableResult
    func createRunDirectory(_ runID: UUID) throws -> URL {
        let directory = runDirectory(runID)
        try FileManager.default.createDirectory(at: inputsDirectory(runID), withIntermediateDirectories: true)
        return directory
    }

    /// `<variant-index>-<prompt-id>.<ext>`; prompt ids that are not file-name safe are reduced to safe characters.
    static func artifactName(variantIndex: Int, promptID: String, kind: ComparisonOutputKind) -> String {
        "\(variantIndex)-\(safeComponent(promptID)).\(kind.fileExtension)"
    }

    static func safeComponent(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(raw.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "prompt" : String(cleaned.prefix(80))
    }

    /// The file a sample's `artifact` names inside a run's directory. Nil when the name
    /// could point anywhere else: a separator, a `..`, a leading dot, or an empty name.
    func artifactURL(runID: UUID, artifact: String) -> URL? {
        guard Self.isContainedName(artifact) else { return nil }
        return runDirectory(runID).appendingPathComponent(artifact, isDirectory: false)
    }

    static func isContainedName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
            && !name.contains("\0")
    }

    func artifactExists(runID: UUID, artifact: String?) -> Bool {
        guard let artifact, let url = artifactURL(runID: runID, artifact: artifact) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletes every run directory directly under the root whose name is a run UUID
    /// and which is not in `keeping`. Symbolic links and anything not named by a
    /// UUID are left alone. Returns the run ids removed.
    @discardableResult
    func prune(keeping: Set<UUID>) -> [UUID] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [UUID] = []
        for name in names {
            guard let runID = UUID(uuidString: name), runID.uuidString == name.uppercased(),
                  !keeping.contains(runID) else { continue }
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removed.append(runID)
            }
        }
        return removed
    }
}
