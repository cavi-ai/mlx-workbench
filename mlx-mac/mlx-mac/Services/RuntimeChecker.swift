import Foundation

// MARK: - RuntimeChecker
//
// Mirrors mlx_workbench/deps.py: probes the Python interpreter that would run
// conversions/serving for the presence of modules and executables.

struct RuntimeChecker {
    private static let convertModules = ["torch", "transformers", "gguf", "accelerate"]
    private static let convertExecutables = ["mlx_lm.convert"]
    private static let serveExecutables = ["mlx_lm.server"]
    private static let installHint = "make install"

    static func report() -> RuntimeReport {
        let convert = checkConvert()
        let serve = checkServe()
        return RuntimeReport(
            convert: convert,
            serve: serve,
            install: installHint,
            ok: convert.ok && serve.ok
        )
    }

    private static func checkConvert() -> ConvertStatus {
        let modules = modulePresence(convertModules)
        let executables = executablePresence(convertExecutables)
        let missingModules = convertModules.filter { modules[$0] != true }
        let missingExecutables = convertExecutables.filter { executables[$0] != true }
        let ok = missingModules.isEmpty && missingExecutables.isEmpty
        var parts: [String] = []
        if !missingModules.isEmpty {
            parts.append("missing modules: \(missingModules.joined(separator: ", "))")
        }
        if !missingExecutables.isEmpty {
            parts.append("missing on PATH: \(missingExecutables.joined(separator: ", "))")
        }
        let message = ok
            ? "Convert dependencies ready."
            : "\(parts.joined(separator: "; ")). On this Mac run `\(installHint)`."

        return ConvertStatus(
            ok: ok,
            modules: modules,
            executables: executables,
            missingModules: missingModules,
            missingExecutables: missingExecutables,
            install: installHint,
            message: message
        )
    }

    private static func checkServe() -> ServeStatus {
        let executables = executablePresence(serveExecutables)
        let missing = serveExecutables.filter { executables[$0] != true }
        let ok = missing.isEmpty
        let message = ok
            ? "Serve runtime ready."
            : "missing on PATH: \(missing.joined(separator: ", ")). On this Mac run `\(installHint)`."

        return ServeStatus(
            ok: ok,
            executables: executables,
            missingExecutables: missing,
            install: installHint,
            message: message
        )
    }

    // MARK: - Probes

    private static func modulePresence(_ names: [String]) -> [String: Bool] {
        guard !names.isEmpty else { return [:] }
        var result: [String: Bool] = [:]
        for name in names {
            result[name] = pythonModulePresent(name)
        }
        return result
    }

    private static func pythonModulePresent(_ name: String) -> Bool {
        let script = """
        import importlib.util
        print(importlib.util.find_spec("\(name)") is not None)
        """
        guard let output = pythonOutput(script) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "True"
    }

    private static func executablePresence(_ names: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for name in names {
            result[name] = isExecutableOnPath(name) || isPythonModuleExecutable(name)
        }
        return result
    }

    /// Look for a `python -m ...` style entry point the way mlx_lm ships it.
    private static func isPythonModuleExecutable(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count == 2 else { return false }
        let module = "\(parts[0]).\(parts[1])"
        let script = """
        import importlib.util
        try:
            spec = importlib.util.find_spec("\(module)")
            print(bool(spec))
        except Exception:
            print(False)
        """
        guard let output = pythonOutput(script) else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "True"
    }

    private static func isExecutableOnPath(_ name: String) -> Bool {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return false }
        return pathValue.split(separator: ":").contains { dir in
            FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)")
        }
    }

    private static func pythonOutput(_ script: String) -> String? {
        guard let python = pythonPath() else { return nil }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// Absolute URL to the configured Python (resolves via PATH). Process
    /// needs an absolute executable URL; a bare "python3" would throw at launch.
    private static func pythonPath() -> URL? {
        let python = ProcessInfo.processInfo.environment["MLX_WORKBENCH_PYTHON"]
            ?? ProcessInfo.processInfo.environment["PYTHON"]
            ?? "python3"
        if python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) {
            return URL(fileURLWithPath: python)
        }
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in pathValue.split(separator: ":") {
            let full = URL(fileURLWithPath: String(dir)).appendingPathComponent(python)
            if FileManager.default.isExecutableFile(atPath: full.path) {
                return full
            }
        }
        return nil
    }
}

// MARK: - RuntimeReport

struct RuntimeReport: Codable, Equatable {
    let convert: ConvertStatus
    let serve: ServeStatus
    let install: String
    let ok: Bool
}

struct ConvertStatus: Codable, Equatable {
    let ok: Bool
    let modules: [String: Bool]
    let executables: [String: Bool]
    let missingModules: [String]
    let missingExecutables: [String]
    let install: String
    let message: String
}

struct ServeStatus: Codable, Equatable {
    let ok: Bool
    let executables: [String: Bool]
    let missingExecutables: [String]
    let install: String
    let message: String
}