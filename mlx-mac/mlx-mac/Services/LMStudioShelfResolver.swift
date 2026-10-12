import Foundation

/// Finds the folders LM Studio keeps its models in and states, per format, whether the
/// Library scan reaches each one. `resolve` walks the folders and runs off the main actor;
/// `downloadsFolder` reads only a regular `settings.json` within `settingsByteLimit` and may run on it.
enum LMStudioShelfResolver {
    enum Source: Equatable {
        case settings, `default`, legacy
    }

    enum Coverage: Equatable {
        case unknown
        /// `folder` is the folder's spelling under the scanned root, as scan paths are spelled.
        case scanned(root: String, folder: String)
        case configuredNotScanned
        case notConfigured

        var scannedFolder: String? {
            if case .scanned(_, let folder) = self { return folder }
            return nil
        }
    }

    struct Folder: Equatable {
        let url: URL
        let source: Source
        let isPresent: Bool
        let gguf: Coverage
        let mlx: Coverage
    }

    struct Resolution: Equatable {
        let installed: Bool
        let folders: [Folder]
    }

    static let settingsByteLimit = 1_048_576

    /// Directory names the agent's GGUF walk never enters.
    static let agentSkippedNames: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", "venv", ".tox",
        ".mypy_cache", ".pytest_cache", ".quarantine", ".Trash",
    ]

    /// The `downloadsFolder` string of LM Studio's settings, `~` expanded against `home`.
    static func parseDownloadsFolder(settingsJSON: Data, home: URL) -> URL? {
        guard settingsJSON.count <= settingsByteLimit,
              let object = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any],
              let raw = (object["downloadsFolder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let expanded: String
        if raw == "~" {
            expanded = home.path
        } else if raw.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            expanded = raw
        }
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// LM Studio's downloads folder from `<home>/.lmstudio/settings.json`, a regular file of at most `settingsByteLimit` bytes.
    static func downloadsFolder(home: URL) -> URL? {
        readSettings(at: home.appendingPathComponent(".lmstudio/settings.json"))
            .flatMap { parseDownloadsFolder(settingsJSON: $0, home: home) }
    }

    /// True when the path from a scan root down to the folder holds a name the agent skips.
    static func isSkipped(_ components: [String]) -> Bool {
        components.contains { $0.hasPrefix(".") || agentSkippedNames.contains($0) }
    }

    /// Coverage of one format: the folder's spelling under the first root that contains it
    /// without a skipped component, else whether the configured roots would reach it.
    static func coverage(
        of folder: URL,
        scannedRoots: [String]?,
        configuredRoots: [String],
        fileIdentity: (String) -> NSObject? = AppHost.fileIdentity
    ) -> Coverage {
        guard let scannedRoots else { return .unknown }
        if let found = reach(of: folder, in: scannedRoots, fileIdentity: fileIdentity) {
            return .scanned(root: found.root, folder: found.folder)
        }
        return reach(of: folder, in: configuredRoots, fileIdentity: fileIdentity) == nil ? .notConfigured : .configuredNotScanned
    }

    private static func reach(of folder: URL, in roots: [String], fileIdentity: (String) -> NSObject?) -> (root: String, folder: String)? {
        for root in roots {
            guard let names = AppHost.components(of: folder.path, within: root, fileIdentity: fileIdentity), !isSkipped(names) else { continue }
            let rootURL = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath).standardizedFileURL
            let spelled = names.reduce(rootURL) { $0.appendingPathComponent($1) }
            return (rootURL.path, spelled.path)
        }
        return nil
    }

    static func resolve(
        home: URL,
        scannedRoots: ScanRoots?,
        configGGUFRoots: [String],
        configMLXRoots: [String],
        fileIdentity: (String) -> NSObject? = AppHost.fileIdentity
    ) -> Resolution {
        let lmstudio = home.appendingPathComponent(".lmstudio")
        let settings = downloadsFolder(home: home)
        // LM Studio reads only its configured folder; the default and older folders apply when none is set.
        var candidates: [(URL, Source)] = []
        if let settings {
            candidates.append((settings, .settings))
        } else {
            candidates.append((lmstudio.appendingPathComponent("models").standardizedFileURL, .default))
            candidates.append((home.appendingPathComponent(".cache/lm-studio/models").standardizedFileURL, .legacy))
        }

        var folders: [Folder] = []
        var seen: [NSObject] = []
        var seenPaths: Set<String> = []
        for (url, source) in candidates {
            var isDirectory: ObjCBool = false
            let isPresent = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if !isPresent && source != .settings { continue }
            if let identity = isPresent ? fileIdentity(url.path) : nil {
                if seen.contains(where: { $0.isEqual(identity) }) { continue }
                seen.append(identity)
            }
            guard seenPaths.insert(url.path).inserted else { continue }
            folders.append(Folder(
                url: url, source: source, isPresent: isPresent,
                gguf: coverage(of: url, scannedRoots: scannedRoots?.gguf, configuredRoots: configGGUFRoots, fileIdentity: fileIdentity),
                mlx: coverage(of: url, scannedRoots: scannedRoots?.mlx, configuredRoots: configMLXRoots, fileIdentity: fileIdentity)
            ))
        }
        var isDirectory: ObjCBool = false
        let installed = FileManager.default.fileExists(atPath: lmstudio.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return Resolution(installed: installed, folders: folders)
    }

    /// Opens only a regular file within the limit, so a pipe or device is never opened.
    private static func readSettings(at url: URL) -> Data? {
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= settingsByteLimit,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: settingsByteLimit + 1)
    }
}
