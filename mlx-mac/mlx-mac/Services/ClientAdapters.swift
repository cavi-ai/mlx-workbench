import Foundation

// MARK: - Client adapters
//
// One adapter per supported client. Adapters are pure: they take the current
// file contents (nil if missing) plus the endpoint and produce the new
// contents. All file I/O, hashing, backups, and drift checks live in
// WiringCoordinator. Write targets are a fixed allowlist of well-known
// config paths — adapters never accept a user-supplied path.

struct ClientAdapter: Sendable {
    let clientID: String
    let displayName: String
    /// Path relative to the user's home directory; nil for advisory-only.
    let relativeConfigPath: String?
    let advisoryOnly: Bool
    let advisoryNote: String?
    /// The inverse of `plan`: the local endpoints a config's contents point at.
    let read: @Sendable (_ contents: String) -> ClientConfigReading
    let plan: @Sendable (_ before: String?, _ endpoint: WireEndpoint) throws -> String

    func installation(home: URL, fileManager: FileManager = .default) -> ClientInstallation? {
        if advisoryOnly {
            // Advisory rows only appear when the client looks installed.
            guard let marker = relativeConfigPath,
                  fileManager.fileExists(atPath: home.appendingPathComponent(marker).path) else {
                return nil
            }
            return ClientInstallation(
                clientID: clientID,
                displayName: displayName,
                configPath: nil,
                advisoryOnly: true,
                advisoryNote: advisoryNote
            )
        }
        guard let relative = relativeConfigPath else { return nil }
        let path = home.appendingPathComponent(relative).path
        let directory = (path as NSString).deletingLastPathComponent
        // Positive detection: the config file exists, or its parent directory
        // does — except home-root files (e.g. ~/.aider.conf.yml), whose parent
        // is home itself and would always "detect".
        let directoryIsClientOwned = directory != home.standardizedFileURL.path
            && directory != home.path
        guard fileManager.fileExists(atPath: path)
                || (directoryIsClientOwned && fileManager.fileExists(atPath: directory)) else {
            return nil
        }
        return ClientInstallation(
            clientID: clientID,
            displayName: displayName,
            configPath: path,
            advisoryOnly: false,
            advisoryNote: nil
        )
    }
}

enum ClientAdapters {
    static let providerID = "mlx-local"

    static let all: [ClientAdapter] = [opencode, continue_, zed, aider, lmStudio, ollama]

    static let opencode = ClientAdapter(
        clientID: "opencode",
        displayName: "opencode",
        relativeConfigPath: ".config/opencode/opencode.jsonc",
        advisoryOnly: false,
        advisoryNote: nil,
        read: { contents in
            readJSON(contents) { config in
                let providers = config["provider"] as? [String: Any]
                guard let local = providers?[providerID] as? [String: Any],
                      let baseURL = (local["options"] as? [String: Any])?["baseURL"] as? String,
                      ClientEndpointURL.port(of: baseURL) != nil else { return .noWorkbenchEntry }
                let prefix = "\(providerID)/"
                var models = ((local["models"] as? [String: Any])?.keys.sorted()) ?? []
                if let selected = config["model"] as? String {
                    guard selected.hasPrefix(prefix) else {
                        return .notDefault([ClientConfigEntry(baseURL: baseURL, models: models)])
                    }
                    models = [String(selected.dropFirst(prefix.count))]
                }
                return .entries([ClientConfigEntry(baseURL: baseURL, models: models)])
            }
        }
    ) { before, endpoint in
        var config = try parseOrEmpty(before)
        var provider = (config["provider"] as? [String: Any]) ?? [:]
        provider[providerID] = [
            "npm": "@ai-sdk/openai-compatible",
            "options": ["baseURL": endpoint.baseURL],
            "models": [endpoint.modelName: [String: Any]()],
        ]
        config["provider"] = provider
        config["model"] = "\(providerID)/\(endpoint.modelName)"
        return try JSONCTolerant.serialize(config)
    }

    static let continue_ = ClientAdapter(
        clientID: "continue",
        displayName: "Continue",
        relativeConfigPath: ".continue/config.json",
        advisoryOnly: false,
        advisoryNote: nil,
        read: { contents in
            readJSON(contents) { config in
                var entries: [ClientConfigEntry] = []
                for model in (config["models"] as? [[String: Any]]) ?? [] {
                    guard model["provider"] as? String == "openai",
                          let baseURL = model["apiBase"] as? String,
                          ClientEndpointURL.port(of: baseURL) != nil else { continue }
                    let name = (model["model"] as? String).map { [$0] } ?? []
                    if let index = entries.firstIndex(where: { $0.baseURL == baseURL }) {
                        entries[index] = ClientConfigEntry(
                            baseURL: baseURL, models: entries[index].models + name.filter { !entries[index].models.contains($0) })
                    } else {
                        entries.append(ClientConfigEntry(baseURL: baseURL, models: name))
                    }
                }
                return entries.isEmpty ? .noWorkbenchEntry : .entries(entries)
            }
        }
    ) { before, endpoint in
        var config = try parseOrEmpty(before)
        var models = (config["models"] as? [[String: Any]]) ?? []
        models.removeAll { ($0["title"] as? String) == endpoint.modelName }
        models.append([
            "title": endpoint.modelName,
            "provider": "openai",
            "model": endpoint.modelName,
            "apiBase": endpoint.baseURL,
        ])
        config["models"] = models
        return try JSONCTolerant.serialize(config)
    }

    static let zed = ClientAdapter(
        clientID: "zed",
        displayName: "Zed",
        relativeConfigPath: ".config/zed/settings.json",
        advisoryOnly: false,
        advisoryNote: nil,
        read: { contents in
            readJSON(contents) { config in
                let openai = (config["language_models"] as? [String: Any])?["openai"] as? [String: Any]
                guard let baseURL = openai?["api_url"] as? String,
                      ClientEndpointURL.port(of: baseURL) != nil else { return .noWorkbenchEntry }
                let models = ((openai?["available_models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                return .entries([ClientConfigEntry(baseURL: baseURL, models: models)])
            }
        }
    ) { before, endpoint in
        var config = try parseOrEmpty(before)
        var languageModels = (config["language_models"] as? [String: Any]) ?? [:]
        languageModels["openai"] = [
            "api_url": endpoint.baseURL,
            "available_models": [[
                "name": endpoint.modelName,
                "display_name": endpoint.modelName,
                "max_tokens": 32000,
            ]],
        ]
        config["language_models"] = languageModels
        return try JSONCTolerant.serialize(config)
    }

    static let aider = ClientAdapter(
        clientID: "aider",
        displayName: "Aider",
        relativeConfigPath: ".aider.conf.yml",
        advisoryOnly: false,
        advisoryNote: nil,
        read: { contents in
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let base = yamlValue("openai-api-base", in: lines),
                  ClientEndpointURL.port(of: base) != nil else { return .noWorkbenchEntry }
            guard let model = yamlValue("model", in: lines) else {
                return .entries([ClientConfigEntry(baseURL: base, models: [])])
            }
            guard model.hasPrefix("openai/") else {
                return .notDefault([ClientConfigEntry(baseURL: base, models: [])])
            }
            return .entries([ClientConfigEntry(baseURL: base, models: [String(model.dropFirst("openai/".count))])])
        }
    ) { before, endpoint in
        // Minimal top-level YAML key update: replace existing keys in place,
        // append missing ones. No full YAML parse — comments and other keys
        // are preserved byte-for-byte.
        var lines = (before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let updates: [(key: String, value: String)] = [
            ("openai-api-base", endpoint.baseURL),
            ("model", "openai/\(endpoint.modelName)"),
        ]
        for update in updates {
            if let index = lines.firstIndex(where: { $0.hasPrefix("\(update.key):") }) {
                lines[index] = "\(update.key): \(update.value)"
            } else {
                if lines.last == "" { lines.removeLast() }
                lines.append("\(update.key): \(update.value)")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    static let lmStudio = ClientAdapter(
        clientID: "lmstudio",
        displayName: "LM Studio",
        relativeConfigPath: ".lmstudio",
        advisoryOnly: true,
        advisoryNote: "LM Studio owns its model state. Point it at the converted output directory from Library instead of editing its config.",
        read: { _ in .noWorkbenchEntry },
        plan: { before, _ in before ?? "" }
    )

    static let ollama = ClientAdapter(
        clientID: "ollama",
        displayName: "Ollama",
        relativeConfigPath: ".ollama",
        advisoryOnly: true,
        advisoryNote: "Ollama serves its own registry. The local endpoint from this app is OpenAI-compatible; use it directly from clients instead.",
        read: { _ in .noWorkbenchEntry },
        plan: { before, _ in before ?? "" }
    )

    /// Parses JSONC and hands the object to `extract`; parse failures become fixed reasons that quote no file content.
    private static func readJSON(_ contents: String, _ extract: ([String: Any]) -> ClientConfigReading) -> ClientConfigReading {
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noWorkbenchEntry }
        do {
            return extract(try JSONCTolerant.parse(contents))
        } catch JSONCTolerant.ParseError.invalidJSON(let detail) where detail == "top level is not an object" {
            return .unreadable("Top level isn't an object")
        } catch {
            return .unreadable("Isn't valid JSON")
        }
    }

    /// The value of the first top-level `key:` line, matching how `plan` finds it: trimmed, unquoted, without a trailing comment.
    private static func yamlValue(_ key: String, in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix("\(key):") }) else { return nil }
        let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if let quote = raw.first, quote == "\"" || quote == "'" {
            let rest = raw.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return String(rest) }
            return String(rest[..<end])
        }
        let uncommented = raw.hasPrefix("#") ? "" : (raw.components(separatedBy: " #").first ?? raw)
        return uncommented.trimmingCharacters(in: .whitespaces)
    }

    private static func parseOrEmpty(_ before: String?) throws -> [String: Any] {
        guard let before, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        return try JSONCTolerant.parse(before)
    }
}

// MARK: - Reading a client config file

/// Produces a client's config status from its allowlisted path. Called off the main actor.
typealias ClientConfigSource = @Sendable (_ path: String, _ adapter: ClientAdapter) async -> ClientConfigStatus

enum ClientConfigFile {
    /// Larger files are reported unreadable instead of parsed.
    static let sizeLimit = 1_048_576

    static let live: ClientConfigSource = { path, adapter in
        await Task.detached(priority: .utility) { load(path: path, adapter: adapter) }.value
    }

    static func load(path: String, adapter: ClientAdapter, fileManager: FileManager = .default) -> ClientConfigStatus {
        let isLinked = (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
        func status(_ reading: ClientConfigReading) -> ClientConfigStatus {
            ClientConfigStatus(reading: reading, isLinked: isLinked)
        }
        guard fileManager.fileExists(atPath: path) else { return status(.fileAbsent) }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return status(.unreadable("Couldn't be read")) }
        guard size <= sizeLimit else { return status(.unreadable("Larger than 1 MB")) }
        guard let data = fileManager.contents(atPath: path) else { return status(.unreadable("Couldn't be read")) }
        guard let text = String(data: data, encoding: .utf8) else { return status(.unreadable("Isn't UTF-8 text")) }
        return status(adapter.read(text))
    }
}
