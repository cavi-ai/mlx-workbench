import Foundation

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
