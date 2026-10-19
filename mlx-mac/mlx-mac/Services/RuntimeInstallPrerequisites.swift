import Foundation

/// Read-only checks for the tools used by `make install`, with the same PATH
/// carried into the confirmed installer. No shell startup files are executed.
struct RuntimeInstallPrerequisites: Equatable, Sendable {
    struct Issue: Equatable, Sendable {
        let detail: String
        var command: String? = nil
    }

    let root: String
    let environment: [String: String]
    let issues: [Issue]
    let pythonSummary: String
    var canInstall: Bool { issues.isEmpty }

    typealias Probe = @Sendable (URL, [String], [String: String]) async -> String?

    static var defaultSearchDirectories: [URL] {
        ["/opt/homebrew/bin", "/opt/homebrew/opt/python@3.12/bin", "/usr/local/bin",
         "/usr/local/opt/python@3.12/bin", NSHomeDirectory() + "/.local/bin"]
            .map { URL(fileURLWithPath: $0) }
    }

    static func inspect(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                        searchDirectories: [URL] = defaultSearchDirectories,
                        probe: Probe) async -> Self {
        let fm = FileManager.default
        let original = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").filter { $0.hasPrefix("/") }.map(String.init)
        var directories: [String] = []
        for path in original + searchDirectories.map(\.path) where !directories.contains(path) {
            directories.append(path)
        }
        func candidates(_ name: String) -> [URL] {
            directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .filter { fm.isExecutableFile(atPath: $0.path) }
        }
        let versionArguments = ["-I", "-S", "-c", "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))"]
        var issues: [Issue] = []
        let developer = await probe(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], environment)
        let developerPath = developer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var isDirectory: ObjCBool = false
        let developerAvailable = developerPath.hasPrefix("/") && fm.fileExists(atPath: developerPath, isDirectory: &isDirectory)
            && isDirectory.boolValue && fm.isExecutableFile(atPath: "/usr/bin/make")
        if !developerAvailable {
            issues.append(Issue(detail: "Apple's Command Line Tools are missing or unavailable. Install them in Terminal, then recheck.",
                command: "xcode-select --install"))
        }
        if !fm.isWritableFile(atPath: root.path) {
            issues.append(Issue(detail: "The selected engine folder is not writable. Choose a writable checkout or prepare the bundled engine."))
        }
        func pythonVersion(_ executable: URL, environment: [String: String]) async -> String? {
            // Apple's python3 shim can open the system installer when the
            // developer tools are absent. A read-only check must not launch it.
            if !developerAvailable && executable.resolvingSymlinksInPath().path == "/usr/bin/python3" { return nil }
            return await probe(executable, versionArguments, environment)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var uv: URL?
        let uvCandidates = candidates("uv")
        for candidate in uvCandidates {
            if await probe(candidate, ["--version"], environment)?.hasPrefix("uv ") == true { uv = candidate; break }
        }
        if !uvCandidates.isEmpty && uv == nil {
            issues.append(Issue(detail: "The installed uv command did not respond correctly. Repair it before installing; make would otherwise select that command."))
        }
        var python312: URL?
        for candidate in candidates("python3.12") {
            if await pythonVersion(candidate, environment: environment) == "3.12" {
                python312 = candidate; break
            }
        }
        let venv = root.appendingPathComponent(".venv")
        let existingPython = venv.appendingPathComponent("bin/python")
        let hasEnvironment = fm.fileExists(atPath: venv.path)
        var pythonSummary = "Python 3.12 or uv is needed."
        if hasEnvironment {
            let version = fm.isExecutableFile(atPath: existingPython.path)
                ? await pythonVersion(existingPython, environment: environment) : nil
            if version == "3.12" {
                pythonSummary = "Using the existing Python 3.12 environment."
            } else {
                issues.append(Issue(detail: "The existing Python environment is incomplete or does not use Python 3.12. Repair it or select another engine folder; Workbench will keep its files."))
            }
        } else if let uv {
            pythonSummary = "uv will prepare Python 3.12 and install packages: " + uv.path
        } else if let python312 {
            pythonSummary = "Python 3.12 found: " + python312.path
        } else {
            issues.append(Issue(detail: "Install Python 3.12 or uv, then recheck. Python 3.12 is required for the runtime packages.",
                command: "brew install python@3.12"))
        }
        // Include the new environment before it exists, so the checks at the end
        // of make install find its entry points rather than unrelated tools.
        var ordered = [venv.appendingPathComponent("bin").path]
        for path in [uv, python312].compactMap({ $0?.deletingLastPathComponent().path }) + directories
            where !ordered.contains(path) { ordered.append(path) }
        var resolvedEnvironment = environment
        resolvedEnvironment["PATH"] = ordered.joined(separator: ":")
        if !hasEnvironment {
            // The Makefile reads configuration before creating .venv. A system
            // Python can bootstrap that step; it need not be the package Python.
            let bootstrap = ordered.map { URL(fileURLWithPath: $0).appendingPathComponent("python3") }
                .first { fm.isExecutableFile(atPath: $0.path) }
            let version = if let bootstrap { await pythonVersion(bootstrap, environment: resolvedEnvironment) } else { nil as String? }
            let parts = version?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
            if developerAvailable && (uv != nil || python312 != nil)
                && (parts?.count != 2 || parts?[0] != 3 || (parts?[1] ?? 0) < 9) {
                issues.append(Issue(detail: "Python 3.9 or newer must also be available as python3 to start setup. Install Python 3.12, then recheck.",
                    command: "brew install python@3.12"))
            }
        }
        return Self(root: root.path, environment: resolvedEnvironment, issues: issues, pythonSummary: pythonSummary)
    }
}
