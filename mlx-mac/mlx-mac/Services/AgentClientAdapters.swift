import Foundation
import TOMLKit
import Yams

/// Client-native formats; the wiring coordinator owns paths, credentials and every write.
enum AgentClientAdapters {
    static let providerID = "workbench"
    static let mlxAgentProviderID = "mlx-agent"
    static let openclawProviderIDs = [providerID, mlxAgentProviderID]
    static let openclawAPIKeyEnvReference = "${MLX_AGENT_API_KEY}"

    static let openclaw = ClientAdapter(
        clientID: "openclaw", displayName: "OpenClaw", relativeConfigPath: ".openclaw/openclaw.json",
        advisoryOnly: false, advisoryNote: nil,
        credentialInstruction: "Export MLX_AGENT_API_KEY with this endpoint’s inference key in the OpenClaw gateway environment before restarting OpenClaw. No raw API key is written to openclaw.json.",
        normalizesFormatting: true,
        validate: {
            let root = try json5($0)
            guard root["mlx_agent_wire"] == nil else { throw invalid() }
        },
        read: { text in
            reading {
                let root = try json5(text)
                let models = try object(root, "models"), providers = try object(models, "providers")
                let defaults = try object(try object(root, "agents"), "defaults")
                let selected = (defaults["model"] as? String) ?? (defaults["model"] as? [String: Any])?["primary"] as? String
                guard let match = try openclawProviderForRead(providers: providers, selected: selected),
                      let base = match.provider["baseUrl"] as? String else { return .noWorkbenchEntry }
                let names = (match.provider["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                return endpointReading(base: base, models: names, selected: selected, prefix: match.id + "/")
            }
        },
        plan: { before, endpoint in
            var root = try json5(before)
            var models = try object(root, "models"), providers = try object(models, "providers")
            var agents = try object(root, "agents"), defaults = try object(agents, "defaults")
            let currentSelected = (defaults["model"] as? String) ?? (defaults["model"] as? [String: Any])?["primary"] as? String
            let activeProviderID = openclawProviderIDForWrite(providers: providers, selected: currentSelected)
            var provider = try object(providers, activeProviderID)
            provider["baseUrl"] = endpoint.baseURL; provider["api"] = "openai-completions"
            if endpoint.apiKeySHA256 != nil {
                if !isOpenClawEnvSecretRef(provider["apiKey"]) {
                    provider["apiKey"] = openclawAPIKeyEnvReference
                }
                provider.removeValue(forKey: "auth")
                provider["authHeader"] = true
            } else {
                provider["auth"] = "none"; provider.removeValue(forKey: "apiKey"); provider["authHeader"] = false
            }
            if var headers = provider["headers"] as? [String: Any] {
                for key in headers.keys where key.lowercased() == "authorization" { headers.removeValue(forKey: key) }
                provider["headers"] = headers
            }
            var entries = provider["models"] as? [[String: Any]] ?? []
            for model in endpoint.models + [endpoint.modelName] where !model.isEmpty {
                if !entries.contains(where: { $0["id"] as? String == model }) {
                    entries.append(["id": model, "name": model])
                }
            }
            provider["models"] = entries; providers[activeProviderID] = provider; models["providers"] = providers
            if models["mode"] == nil { models["mode"] = "merge" }
            root["models"] = models
            var selected = defaults["model"] as? [String: Any] ?? [:]
            selected["primary"] = activeProviderID + "/" + endpoint.modelName
            defaults["model"] = selected; agents["defaults"] = defaults; root["agents"] = agents
            return try JSONCTolerant.serialize(root)
        })

    static let hermes = ClientAdapter(
        clientID: "hermes", displayName: "Hermes", relativeConfigPath: ".hermes/config.yaml",
        advisoryOnly: false, advisoryNote: nil,
        apiKeyPlan: { text, key in
            var root = try yaml(text), model = try object(root, "model")
            model["api_key"] = key; root["model"] = model
            return try Yams.dump(object: root, sortKeys: true)
        },
        normalizesFormatting: true,
        validate: { _ = try yaml($0) },
        read: { text in
            reading {
                let root = try yaml(text), model = try object(root, "model")
                guard model["provider"] as? String == "custom", let base = model["base_url"] as? String else { return .noWorkbenchEntry }
                return endpointReading(base: base, models: [model["default"] as? String ?? model["model"] as? String ?? ""])
            }
        },
        plan: { before, endpoint in
            var root = try yaml(before)
            var model = root["model"] as? [String: Any] ?? [:]
            guard root["model"] == nil || root["model"] is String || root["model"] is [String: Any] else { throw invalid() }
            model["provider"] = "custom"; model["default"] = endpoint.modelName; model["model"] = endpoint.modelName
            model["base_url"] = endpoint.baseURL; model["api_key"] = "workbench"
            model["api_mode"] = "chat_completions"
            for key in ["key_env", "key_cmd", "api_key_env", "api_key_command"] { model.removeValue(forKey: key) }
            root["model"] = model
            return try Yams.dump(object: root, sortKeys: true)
        })

    static let codex = ClientAdapter(
        clientID: "codex", displayName: "Codex", relativeConfigPath: ".codex/config.toml",
        advisoryOnly: false, advisoryNote: nil,
        apiKeyPlan: { text, key in
            let root = try TOMLTable(string: text), providers = try table(root, "model_providers")
            let provider = try table(providers, providerID)
            provider["experimental_bearer_token"] = key; providers[providerID] = provider; root["model_providers"] = providers
            return root.convert(to: .toml) + "\n"
        },
        normalizesFormatting: true,
        validate: { _ = try TOMLTable(string: $0) },
        read: { text in
            reading {
                let root = try TOMLTable(string: text), providers = try table(root, "model_providers")
                let provider = try table(providers, providerID)
                guard let base = provider["base_url"]?.string else { return .noWorkbenchEntry }
                var active = root
                if let profile = root["profile"]?.string { active = try table(try table(root, "profiles"), profile) }
                let name = active["model"]?.string ?? root["model"]?.string ?? ""
                return endpointReading(base: base, models: [name], selected: active["model_provider"]?.string ?? root["model_provider"]?.string, prefix: providerID)
            }
        },
        plan: { before, endpoint in
            let root = try TOMLTable(string: before ?? "")
            root["model"] = endpoint.modelName; root["model_provider"] = providerID
            let providers = try table(root, "model_providers"), previous = try table(providers, providerID)
            let provider = TOMLTable()
            let authFields = Set(["auth", "env_key", "env_http_headers", "http_headers", "experimental_bearer_token"])
            for key in previous.keys where !authFields.contains(key) { provider[key] = previous[key] }
            provider["name"] = "MLX Workbench"; provider["base_url"] = endpoint.baseURL
            provider["wire_api"] = "responses"; provider["requires_openai_auth"] = false
            providers[providerID] = provider; root["model_providers"] = providers
            if let profile = root["profile"]?.string {
                let profiles = try table(root, "profiles"), active = try table(profiles, profile)
                active["model"] = endpoint.modelName; active["model_provider"] = providerID
                profiles[profile] = active; root["profiles"] = profiles
            }
            return root.convert(to: .toml) + "\n"
        })

    static let claude = ClientAdapter(
        clientID: "claude", displayName: "Claude Code", relativeConfigPath: ".claude/settings.json",
        advisoryOnly: false, advisoryNote: nil,
        apiKeyPlan: { text, key in
            var root = try JSONCTolerant.parse(text), env = try object(root, "env")
            env["ANTHROPIC_AUTH_TOKEN"] = key; root["env"] = env
            return try JSONCTolerant.serialize(root)
        },
        normalizesFormatting: true,
        read: { text in
            reading {
                let root = try JSONCTolerant.parse(text), env = try object(root, "env")
                guard let base = env["ANTHROPIC_BASE_URL"] as? String else { return .noWorkbenchEntry }
                return endpointReading(base: base + (base.hasSuffix("/v1") ? "" : "/v1"), models: [root["model"] as? String ?? ""])
            }
        },
        plan: { before, endpoint in
            var root = try json5(before), env = try object(root, "env")
            root["model"] = endpoint.modelName
            env["ANTHROPIC_BASE_URL"] = String(endpoint.baseURL.dropLast(3))
            env["ANTHROPIC_AUTH_TOKEN"] = "workbench"; env["ANTHROPIC_API_KEY"] = ""
            root["env"] = env
            return try JSONCTolerant.serialize(root)
        })

    private static func openclawProviderForRead(providers: [String: Any], selected: String?) throws -> (id: String, provider: [String: Any])? {
        if let selected {
            for id in openclawProviderIDs where selected.hasPrefix(id + "/") {
                let candidate = try object(providers, id)
                if candidate["baseUrl"] as? String != nil { return (id, candidate) }
            }
        }
        for id in openclawProviderIDs {
            let candidate = try object(providers, id)
            if candidate["baseUrl"] as? String != nil { return (id, candidate) }
        }
        return nil
    }

    private static func openclawProviderIDForWrite(providers: [String: Any], selected: String?) -> String {
        let hasWorkbench = providers[providerID] != nil
        let hasMLXAgent = providers[mlxAgentProviderID] != nil
        if hasMLXAgent && !hasWorkbench { return mlxAgentProviderID }
        if hasMLXAgent && hasWorkbench, let selected, selected.hasPrefix(mlxAgentProviderID + "/") {
            return mlxAgentProviderID
        }
        return providerID
    }

    private static func isOpenClawEnvSecretRef(_ value: Any?) -> Bool {
        if let str = value as? String { return SecretRedaction.isEnvVarReference(str) }
        guard let dict = value as? [String: Any],
              dict["source"] as? String == "env",
              Set(dict.keys).isSubset(of: ["source", "id", "provider"]),
              let envID = dict["id"] as? String,
              envID.range(of: "^[A-Z][A-Z0-9_]{0,127}$", options: .regularExpression) != nil else { return false }
        if let provider = dict["provider"] {
            guard let text = provider as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }

    private static func invalid() -> WorkflowEvidenceError { .invalid("This client config has an unsupported structure. Correct the marked settings before reviewing setup.") }
    private static func object(_ root: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = root[key] else { return [:] }
        guard let result = value as? [String: Any] else { throw invalid() }
        return result
    }
    private static func table(_ root: TOMLTable, _ key: String) throws -> TOMLTable {
        guard let value = root[key] else { return TOMLTable() }
        guard let table = value.table else { throw invalid() }
        return table
    }
    private static func json5(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed]) as? [String: Any] else { throw invalid() }
        return root
    }
    private static func yaml(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let root = try Yams.load(yaml: text) as? [String: Any] else { throw invalid() }
        return root
    }
    private static func reading(_ action: () throws -> ClientConfigReading) -> ClientConfigReading {
        do { return try action() } catch { return .unreadable("The config could not be parsed") }
    }
    private static func endpointReading(base: String, models: [String], selected: String? = nil, prefix: String? = nil) -> ClientConfigReading {
        guard ClientEndpointURL.port(of: base) != nil else { return .noWorkbenchEntry }
        let entries = [ClientConfigEntry(baseURL: base, models: models.filter { !$0.isEmpty })]
        if let selected, let prefix {
            if prefix.hasSuffix("/") {
                guard selected.hasPrefix(prefix) else { return .notDefault(entries) }
                return .entries([ClientConfigEntry(baseURL: base, models: [String(selected.dropFirst(prefix.count))])])
            }
            if selected != prefix { return .notDefault(entries) }
        }
        return .entries(entries)
    }
}
