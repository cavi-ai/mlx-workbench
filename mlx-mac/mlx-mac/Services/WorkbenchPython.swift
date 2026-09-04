import Foundation

// MARK: - WorkbenchPython
//
// Single resolution point for the Python interpreter that runs conversions,
// serving, and runtime probes. Resolution order:
//
//   1. MLX_WORKBENCH_PYTHON / PYTHON environment overrides (tests, debugging)
//   2. The repository's own `.venv/bin/python` (what `make install` creates)
//   3. A bare `python3` resolved via PATH
//
// Before this existed, the app only ever probed PATH python3, so a machine
// with a fully installed repo .venv still showed "needs attention — make
// install" forever.

enum WorkbenchPython {
    /// The repository root when running from a checkout (derived from this
    /// file's location: <root>/mlx-mac/mlx-mac/Services/WorkbenchPython.swift).
    /// Nil for installed/release builds where the source tree is absent.
    static func repoRoot(fileManager: FileManager = .default) -> URL? {
        let here = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // mlx-mac (app package)
            .deletingLastPathComponent() // mlx-mac (project dir)
            .deletingLastPathComponent() // repo root
        let marker = here.appendingPathComponent("Makefile")
        let agent = here.appendingPathComponent("vendor/mlx-agent/scripts/mlx-agent")
        guard fileManager.fileExists(atPath: marker.path),
              fileManager.fileExists(atPath: agent.path) else { return nil }
        return here
    }

    /// The repo's own virtualenv interpreter, when it exists and is executable.
    static func repoVenvPython(repoRoot: URL?, fileManager: FileManager = .default) -> URL? {
        guard let repoRoot else { return nil }
        let python = repoRoot.appendingPathComponent(".venv/bin/python")
        guard fileManager.isExecutableFile(atPath: python.path) else { return nil }
        return python
    }

    /// The interpreter to use, honoring environment overrides first.
    /// Returns nil when nothing executable can be resolved (callers treat
    /// that as "runtime unavailable" rather than throwing at launch).
    static func preferredExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        repoRoot: URL? = WorkbenchPython.repoRoot(),
        fileManager: FileManager = .default
    ) -> URL? {
        for key in ["MLX_WORKBENCH_PYTHON", "PYTHON"] {
            if let override = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                let expanded = NSString(string: override).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    if fileManager.isExecutableFile(atPath: expanded) {
                        return URL(fileURLWithPath: expanded)
                    }
                } else if let resolved = resolveOnPath(expanded, environment: environment, fileManager: fileManager) {
                    return resolved
                }
            }
        }
        if let venv = repoVenvPython(repoRoot: repoRoot, fileManager: fileManager) {
            return venv
        }
        return resolveOnPath("python3", environment: environment, fileManager: fileManager)
    }

    static func resolveOnPath(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let pathValue = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
