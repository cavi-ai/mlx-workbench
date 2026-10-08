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
//
// The repository is the checkout the app was built from or, for installed
// builds, the checkout whose `vendor/mlx-agent` is the configured agent path.

enum WorkbenchPython {
    /// The source tree this binary was built from
    /// (<root>/mlx-mac/mlx-mac/Services/WorkbenchPython.swift). `make dmg`
    /// compiles with MLX_WORKBENCH_DISTRIBUTION, so installed builds carry
    /// no source path.
    static func buildSourceRoot() -> URL? {
        #if MLX_WORKBENCH_DISTRIBUTION
        return nil
        #else
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // mlx-mac (app package)
            .deletingLastPathComponent() // mlx-mac (project dir)
            .deletingLastPathComponent() // repo root
        #endif
    }

    /// The build source tree when it is still a workbench checkout.
    static func buildCheckoutRoot(fileManager: FileManager = .default) -> URL? {
        guard let root = buildSourceRoot(), isCheckout(root, fileManager: fileManager) else { return nil }
        return root
    }

    /// The build checkout, else the checkout holding the configured agent
    /// path (`<root>/vendor/mlx-agent`).
    static func repoRoot(
        agentPath: String? = nil,
        buildRoot: URL? = WorkbenchPython.buildCheckoutRoot(),
        fileManager: FileManager = .default
    ) -> URL? {
        if let buildRoot { return buildRoot }
        let configured = agentPath ?? ConfigModule().load().mlxAgentPath
        return checkoutRoot(containingAgent: configured, fileManager: fileManager)
    }

    /// `<root>/vendor/mlx-agent` → `<root>` when `<root>` is a workbench checkout.
    static func checkoutRoot(containingAgent agentPath: String, fileManager: FileManager = .default) -> URL? {
        let trimmed = agentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let agent = Path.expandedURL(trimmed).standardizedFileURL
        let vendor = agent.deletingLastPathComponent()
        guard agent.lastPathComponent == "mlx-agent", vendor.lastPathComponent == "vendor" else { return nil }
        let root = vendor.deletingLastPathComponent()
        return isCheckout(root, fileManager: fileManager) ? root : nil
    }

    static func isCheckout(_ root: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: root.appendingPathComponent("Makefile").path)
            && fileManager.fileExists(atPath: root.appendingPathComponent("vendor/mlx-agent/scripts/mlx-agent").path)
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
