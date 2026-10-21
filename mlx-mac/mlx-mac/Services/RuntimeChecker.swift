import Foundation

// Probes the Python interpreter and PATH used by the bridge. Presence checks
// remain separate from model loading and model-specific runtime verification.
struct RuntimeChecker {
    private static let convertModules = ["torch", "transformers", "gguf", "accelerate"]
    private static let convertExecutables = ["mlx_lm.convert"]
    private static let serveExecutables = ["mlx_lm.server"]
    private static let installHint = "make install"

    static func report() -> RuntimeReport {
        report(python: pythonPath())
    }

    static func report(python: URL?, environment: [String: String] = ProcessInfo.processInfo.environment,
                       timeout: TimeInterval = 5) -> RuntimeReport {
        var modules: [String: Bool] = [:]
        var executables: [String: Bool] = [:]
        var failure: String?
        if let python {
            var environment = environment
            environment["PATH"] = python.deletingLastPathComponent().path + ":" +
                (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            let script = """
            import importlib.util, json, shutil, sys
            def present(name):
                try: return importlib.util.find_spec(name) is not None
                except Exception: return False
            modules, tools = map(json.loads, sys.argv[1:])
            print(json.dumps({'modules': {n: present(n) for n in modules},
                              'executables': {n: bool(shutil.which(n)) or present(n) for n in tools}}))
            """
            do {
                let inputs = try [convertModules, convertExecutables + serveExecutables].map {
                    String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
                }
                let output = try RuntimeInstaller.probe(executable: python, arguments: ["-c", script] + inputs,
                    environment: environment, timeout: timeout)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(output.utf8))
                guard Set(snapshot.modules.keys) == Set(convertModules),
                      Set(snapshot.executables.keys) == Set(convertExecutables + serveExecutables) else {
                    throw ProbeError.invalidReply
                }
                modules = snapshot.modules
                executables = snapshot.executables
            } catch RuntimeInstaller.InstallError.timedOut {
                failure = "Runtime check timed out. Check the selected Python interpreter before retrying."
            } catch RuntimeInstaller.InstallError.outputTooLarge {
                failure = "Runtime check returned too much output. Check the selected Python interpreter before retrying."
            } catch {
                failure = "The selected Python could not complete runtime checks. Review its path and installed packages."
            }
        } else {
            failure = "No Python interpreter was found. Configure the runtime before retrying."
        }
        let convert = checkConvert(modules: modules, executables: executables, failure: failure)
        let serve = checkServe(executables: executables, failure: failure)
        return RuntimeReport(convert: convert, serve: serve, install: installHint,
                             ok: convert.ok && serve.ok, python: python?.path)
    }

    private static func checkConvert(modules foundModules: [String: Bool], executables foundExecutables: [String: Bool],
                                     failure: String?) -> ConvertStatus {
        let modules = Dictionary(uniqueKeysWithValues: convertModules.map { ($0, foundModules[$0] == true) })
        let executables = Dictionary(uniqueKeysWithValues: convertExecutables.map { ($0, foundExecutables[$0] == true) })
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
        let message = ok ? "Convert dependencies ready."
            : failure ?? "\(parts.joined(separator: "; ")). On this Mac run `\(installHint)`."
        return ConvertStatus(ok: ok, modules: modules, executables: executables, missingModules: missingModules,
                             missingExecutables: missingExecutables, install: installHint, message: message)
    }

    private static func checkServe(executables found: [String: Bool], failure: String?) -> ServeStatus {
        let executables = Dictionary(uniqueKeysWithValues: serveExecutables.map { ($0, found[$0] == true) })
        let missing = serveExecutables.filter { executables[$0] != true }
        let ok = missing.isEmpty
        let message = ok ? "Serve runtime ready."
            : failure ?? "missing on PATH: \(missing.joined(separator: ", ")). On this Mac run `\(installHint)`."
        return ServeStatus(ok: ok, executables: executables, missingExecutables: missing,
                           install: installHint, message: message)
    }

    private struct Snapshot: Decodable {
        let modules: [String: Bool]
        let executables: [String: Bool]
    }

    private enum ProbeError: Error { case invalidReply }

    /// The same resolution order used by CLIProcess: override, repo venv, PATH.
    private static func pythonPath() -> URL? {
        WorkbenchPython.preferredExecutable()
    }
}

// MARK: - RuntimeReport

struct RuntimeReport: Codable, Equatable {
    static var checking: RuntimeReport {
        RuntimeReport(
            convert: ConvertStatus(ok: false, modules: [:], executables: [:], missingModules: [], missingExecutables: [],
                                   install: "make install", message: "Checking runtime…"),
            serve: ServeStatus(ok: false, executables: [:], missingExecutables: [], install: "make install", message: "Checking runtime…"),
            install: "make install", ok: false)
    }

    let convert: ConvertStatus
    let serve: ServeStatus
    let install: String
    let ok: Bool
    /// The interpreter every probe in this report ran under; nil when none resolved.
    var python: String? = nil
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
