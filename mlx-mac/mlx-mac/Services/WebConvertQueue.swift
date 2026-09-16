import Foundation

/// One item in the web UI's durable convert queue, shown read-only in the
/// native app. Field contract mirrors mlx_workbench/convert_queue.py and is
/// pinned by tests/fixtures/convert-queue.json on both sides.
struct WebQueueItem: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case gguf, repo
    }

    enum State: String, Sendable {
        case queued, starting, failed
    }

    struct Failure: Equatable, Sendable {
        let code: String
        let message: String
        let remediation: String
    }

    let id: String
    let kind: Kind
    let previewHash: String
    let qBits: Int
    let out: String?
    let path: String?
    let repo: String?
    let hfCache: String?
    let label: String
    let state: State
    let failure: Failure?
}

/// Read-only loader for the web UI's durable convert queue.
///
/// The web server is the single writer; the native app never mutates this
/// file. A missing file is an empty snapshot, not an error — the web UI may
/// simply never have queued anything. An invalid file is preserved by the
/// web UI itself (convert-queue.json.N.corrupt); here it surfaces as a
/// problem string so the view can say "unreadable" instead of lying.
enum WebConvertQueue {
    struct Snapshot: Equatable, Sendable {
        let items: [WebQueueItem]
        let path: String
        let problem: String?
    }

    enum LoadError: Error, Equatable {
        case unreadable(String)
        case invalidSchema(String)
    }

    static let fileName = "convert-queue.json"
    static let currentSchemaVersion = "1.1"
    static let legacySchemaVersion = "1.0"

    /// Mirrors convert_queue.queue_path: beside an explicit
    /// MLX_WORKBENCH_CONFIG profile, else $XDG_STATE_HOME/mlx-workbench/,
    /// else ~/.local/state/mlx-workbench/.
    static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["MLX_WORKBENCH_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .deletingLastPathComponent()
                .appendingPathComponent(fileName)
        }
        let stateRoot: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            stateRoot = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
        } else {
            stateRoot = home.appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        }
        return stateRoot
            .appendingPathComponent("mlx-workbench", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func loadDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Snapshot {
        load(from: defaultPath(environment: environment))
    }

    static func load(from url: URL) -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot(items: [], path: url.path, problem: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let items = try parse(data)
            return Snapshot(items: items, path: url.path, problem: nil)
        } catch let error as LoadError {
            return Snapshot(items: [], path: url.path, problem: message(for: error))
        } catch {
            return Snapshot(items: [], path: url.path, problem: "The web queue file is not readable.")
        }
    }

    static func message(for error: LoadError) -> String {
        switch error {
        case .unreadable(let detail):
            return "The web queue file is not readable JSON: \(detail)"
        case .invalidSchema(let detail):
            return "The web queue file does not match the convert-queue schema: \(detail)"
        }
    }

    // MARK: - schema validation (mirror of convert_queue._validated_items)

    private static let itemKeys: Set<String> = [
        "id", "kind", "preview_hash", "q_bits", "out", "path", "repo",
        "hf_cache", "label", "state", "failure",
    ]
    private static let failureKeys: Set<String> = ["code", "message", "remediation"]

    static func parse(_ data: Data) throws -> [WebQueueItem] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        guard let payload = raw as? [String: Any] else {
            throw LoadError.invalidSchema("queue state must be an object")
        }
        guard Set(payload.keys) == ["schema_version", "items"] else {
            throw LoadError.invalidSchema("queue state fields do not match schema")
        }
        guard let version = payload["schema_version"] as? String,
              version == currentSchemaVersion || version == legacySchemaVersion else {
            throw LoadError.invalidSchema("queue schema version is unsupported")
        }
        let legacy = version == legacySchemaVersion
        guard let rawItems = payload["items"] as? [Any] else {
            throw LoadError.invalidSchema("queue items must be a list")
        }
        return try rawItems.map { try parseItem($0, legacy: legacy) }
    }

    private static func parseItem(_ raw: Any, legacy: Bool) throws -> WebQueueItem {
        guard let item = raw as? [String: Any] else {
            throw LoadError.invalidSchema("queue item fields do not match schema")
        }
        let expected = legacy ? itemKeys.subtracting(["failure"]) : itemKeys
        guard Set(item.keys) == expected else {
            throw LoadError.invalidSchema("queue item fields do not match schema")
        }
        guard let id = item["id"] as? String,
              id.hasPrefix("cq-"),
              !id.dropFirst(3).isEmpty,
              id.dropFirst(3).allSatisfy(\.isNumber) else {
            throw LoadError.invalidSchema("queue item id is invalid")
        }
        guard let kindRaw = item["kind"] as? String,
              let kind = WebQueueItem.Kind(rawValue: kindRaw) else {
            throw LoadError.invalidSchema("queue item kind is invalid")
        }
        guard let previewHash = nonEmpty(item["preview_hash"]) else {
            throw LoadError.invalidSchema("queue item preview_hash is invalid")
        }
        guard let qBitsValue = item["q_bits"], !(qBitsValue is Bool),
              let qBits = (qBitsValue as? NSNumber)?.intValue,
              qBits == 4 || qBits == 8 else {
            throw LoadError.invalidSchema("queue item q_bits is invalid")
        }
        let out = try optionalString(item["out"], field: "out")
        let path = try optionalString(item["path"], field: "path")
        let repo = try optionalString(item["repo"], field: "repo")
        let hfCache = try optionalString(item["hf_cache"], field: "hf_cache")
        guard let label = nonEmpty(item["label"]) else {
            throw LoadError.invalidSchema("queue item label is invalid")
        }
        guard let stateRaw = item["state"] as? String,
              let state = WebQueueItem.State(rawValue: stateRaw),
              !legacy || state != .failed else {
            throw LoadError.invalidSchema("queue item state is invalid")
        }
        switch kind {
        case .gguf:
            guard path != nil, repo == nil else {
                throw LoadError.invalidSchema("GGUF queue item requires only path")
            }
        case .repo:
            guard repo != nil, path == nil else {
                throw LoadError.invalidSchema("repo queue item requires only repo")
            }
        }
        if legacy {
            return WebQueueItem(
                id: id, kind: kind, previewHash: previewHash, qBits: qBits,
                out: out, path: path, repo: repo, hfCache: hfCache,
                label: label, state: state, failure: nil
            )
        }
        var failure: WebQueueItem.Failure?
        if state == .failed {
            guard let rawFailure = item["failure"] as? [String: Any],
                  Set(rawFailure.keys) == failureKeys,
                  let code = nonEmpty(rawFailure["code"]),
                  let message = nonEmpty(rawFailure["message"]),
                  let remediation = nonEmpty(rawFailure["remediation"]) else {
                throw LoadError.invalidSchema("failed queue item requires failure details")
            }
            failure = WebQueueItem.Failure(code: code, message: message, remediation: remediation)
        } else if !isNull(item["failure"]) {
            throw LoadError.invalidSchema("active queue item cannot include failure details")
        }
        return WebQueueItem(
            id: id, kind: kind, previewHash: previewHash, qBits: qBits,
            out: out, path: path, repo: repo, hfCache: hfCache,
            label: label, state: state, failure: failure
        )
    }

    // MARK: - value helpers

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func optionalString(_ value: Any?, field: String) throws -> String? {
        if isNull(value) { return nil }
        if let text = value as? String, !text.isEmpty { return text }
        throw LoadError.invalidSchema("queue item \(field) is invalid")
    }

    private static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }
}
