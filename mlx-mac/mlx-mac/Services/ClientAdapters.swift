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
        advisoryNote: nil
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
        advisoryNote: nil
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
        advisoryNote: nil
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
        advisoryNote: nil
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
        plan: { before, _ in before ?? "" }
    )

    static let ollama = ClientAdapter(
        clientID: "ollama",
        displayName: "Ollama",
        relativeConfigPath: ".ollama",
        advisoryOnly: true,
        advisoryNote: "Ollama serves its own registry. The local endpoint from this app is OpenAI-compatible; use it directly from clients instead.",
        plan: { before, _ in before ?? "" }
    )

    private static func parseOrEmpty(_ before: String?) throws -> [String: Any] {
        guard let before, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        return try JSONCTolerant.parse(before)
    }
}
