import CryptoKit
import Foundation

/// A packaged source payload. Preparing it never installs packages or loads models.
struct BundledRuntime: Sendable {
    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let path: String
            let sha256: String
            let size: Int64
            let executable: Bool
        }
        let schema: Int
        let engineRevision: String
        let workbenchVersion: String
        let files: [File]
    }

    let source: URL
    let parent: URL
    let manifest: Manifest
    let identity: String
    private let manifestData: Data
    var destination: URL { parent.appendingPathComponent(identity, isDirectory: true) }
    var agentPath: String { destination.appendingPathComponent("vendor/mlx-agent").path }

    init(source: URL, parent: URL) throws {
        self.source = source.standardizedFileURL
        // Foundation standardization rewrites /private/var to the symlink /var.
        // Preserve the caller's canonical base so the ancestor fence checks the
        // actual path rather than introducing an alias itself.
        self.parent = parent
        let file = try Self.safeFile("manifest.json", under: source)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 4 * 1024 * 1024 else {
            throw Failure("The packaged runtime manifest is missing or too large.")
        }
        manifestData = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        manifest = try decoder.decode(Manifest.self, from: manifestData)
        identity = Self.digest(manifestData)
        let names = manifest.files.map(\.path)
        let required: Set<String> = ["Makefile", "requirements.txt", "LICENSE", "mlx_workbench/__init__.py",
            "mlx_workbench/config.py", "mlx_workbench/deps.py", "vendor/mlx-agent/LICENSE",
            "vendor/mlx-agent/scripts/mlx-agent", "vendor/mlx-agent/src/mlx_agent/__init__.py"]
        guard manifest.schema == 1, Self.isHex(manifest.engineRevision, length: 40),
              !manifest.workbenchVersion.isEmpty, (1...10000).contains(names.count),
              Set(names).count == names.count, required.isSubset(of: Set(names)) else {
            throw Failure("The packaged runtime identity or source list is invalid.")
        }
        var total: Int64 = 0
        for record in manifest.files {
            try Self.validatePath(record.path)
            guard Self.isHex(record.sha256, length: 64), (0...128 * 1024 * 1024).contains(record.size) else {
                throw Failure("The packaged runtime source metadata is invalid.")
            }
            total += record.size
        }
        guard total <= 256 * 1024 * 1024 else { throw Failure("The packaged runtime is too large.") }
    }

    static func included(bundle: Bundle = .main) throws -> Self? {
        guard let source = bundle.resourceURL?.appendingPathComponent("Runtime", isDirectory: true),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        return try Self(source: source,
            parent: WorkbenchStatePaths.applicationSupport().resolvingSymlinksInPath()
                .appendingPathComponent("runtimes", isDirectory: true))
    }

    /// All disk work runs on the caller's worker. Existing runtime folders are
    /// verified and reused, never overwritten; virtualenv files remain separate.
    func prepare() throws -> URL {
        let fm = FileManager.default
        try validateFiles(in: source)
        var ancestor = parent
        while ancestor.path != "/" {
            if fm.fileExists(atPath: ancestor.path) || (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                guard (try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw Failure("The runtime destination contains a symbolic link.")
                }
            }
            ancestor.deleteLastPathComponent()
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) || (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try validateFiles(in: destination)
            return destination
        }
        let stage = parent.appendingPathComponent(".prepare-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for record in manifest.files {
            let sourceFile = try Self.safeFile(record.path, under: source)
            let target = stage.appendingPathComponent(record.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: sourceFile, to: target)
            try fm.setAttributes([.posixPermissions: record.executable ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        try manifestData.write(to: stage.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try validateFiles(in: stage)
        do { try fm.moveItem(at: stage, to: destination) }
        catch {
            // A concurrent preparation may have published the same identity.
            guard fm.fileExists(atPath: destination.path) else { throw error }
            try validateFiles(in: destination)
        }
        return destination
    }

    /// Discover only an already prepared, verified payload; never create or repair it.
    func existingAgentPath() throws -> String? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        try validateFiles(in: destination)
        return agentPath
    }

    private func validateFiles(in root: URL) throws {
        let metadata = try Self.safeFile("manifest.json", under: root)
        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == manifestData.count,
              try Data(contentsOf: metadata) == manifestData else {
            throw Failure("The runtime folder contains a different manifest.")
        }
        for record in manifest.files {
            let file = try Self.safeFile(record.path, under: root)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize.map(Int64.init) == record.size,
                  Self.digest(try Data(contentsOf: file)) == record.sha256 else {
                throw Failure("A runtime source is missing or changed: " + record.path)
            }
        }
    }

    private static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), path.utf8.count <= 4096,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw Failure("A runtime source path is invalid.")
        }
    }

    private static func safeFile(_ path: String, under root: URL) throws -> URL {
        try validatePath(path)
        var url = root
        for part in [""] + path.split(separator: "/").map(String.init) {
            if !part.isEmpty { url.appendPathComponent(part) }
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw Failure("A runtime source contains a symbolic link.")
            }
        }
        return url
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@MainActor
final class BundledRuntimePreparation: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var preparedPath: String?

    @discardableResult
    func prepare(_ plan: BundledRuntime, publish: @escaping (String) async throws -> Void) -> Task<Void, Never>? {
        guard !isPreparing else { return nil }
        isPreparing = true
        errorMessage = nil
        preparedPath = nil
        return Task {
            defer { isPreparing = false }
            do {
                _ = try await Task.detached(priority: .utility) { try plan.prepare() }.value
                try await publish(plan.agentPath)
                preparedPath = plan.agentPath
            } catch { errorMessage = AppHost.render(error) }
        }
    }
}
