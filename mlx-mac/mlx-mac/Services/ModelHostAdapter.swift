import CoreFoundation
import Foundation

/// What one memory release acts on.
enum HostReleaseScope: Sendable {
    case model, instance, host
}

struct HostReleaseRequest: Equatable, Sendable {
    let path: String
    let body: Data

    init(path: String, payload: [String: Any]) throws {
        self.path = path
        body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

struct HostModelDetails: Equatable, Sendable {
    let capabilities: [String]?
    let maximumContextLength: Int?
}

/// One provider's read and memory-release protocol. Adapters receive validated hosts;
/// transport limits, redirects and credentials stay in `HostHTTPClient`.
protocol ModelHostAdapter: Sendable {
    var title: String { get }
    var defaultURL: String { get }
    /// Nil when the provider has no supported release API.
    var releaseScope: HostReleaseScope? { get }
    /// Installed weights are identified by digest, and model details are read for one digest.
    var identifiesWeightsByDigest: Bool { get }
    var reportsDeviceMemory: Bool { get }
    /// Comparisons run submitted image workflows instead of chat requests.
    var runsImageWorkflows: Bool { get }

    func inventory(from reader: HostReader) async throws -> HostInventory
    func activity(from reader: HostReader) async throws -> HostActivity
    func details(of model: HostedModel, from reader: HostReader) async throws -> HostModelDetails
    /// Provider identity checks beyond the shared loaded-model match.
    func validateRelease(of model: HostedModel, selection: HostResourceSelection) throws
    func releaseRequest(for preview: HostResourcePreview) throws -> HostReleaseRequest
    func releaseReadback(_ preview: HostResourcePreview, inventory: HostInventory) -> String
}

extension ModelHostAdapter {
    var releaseScope: HostReleaseScope? { nil }
    var identifiesWeightsByDigest: Bool { false }
    var reportsDeviceMemory: Bool { false }
    var runsImageWorkflows: Bool { false }

    func activity(from reader: HostReader) async throws -> HostActivity {
        HostActivity(state: .unknown, detail: "This host does not report other clients' active requests. Check its application before releasing model memory.")
    }

    func details(of model: HostedModel, from reader: HostReader) async throws -> HostModelDetails {
        throw HostedIntegrationError.invalid("This host does not report model details.")
    }

    func validateRelease(of model: HostedModel, selection: HostResourceSelection) throws {}

    func releaseRequest(for preview: HostResourcePreview) throws -> HostReleaseRequest {
        throw HostResourceError.unsupportedProvider
    }

    func releaseReadback(_ preview: HostResourcePreview, inventory: HostInventory) -> String {
        guard let model = HostReleaseReadback.model(preview, in: inventory) else { return HostReleaseReadback.absent }
        return HostReleaseReadback.loadedState(model)
    }
}

enum HostReleaseReadback {
    static let absent = "The model is absent from the refreshed inventory; memory release could not be verified."

    static func model(_ preview: HostResourcePreview, in inventory: HostInventory) -> HostedModel? {
        inventory.models.first { $0.modelID == preview.selection.modelID }
    }

    static func loadedState(_ model: HostedModel) -> String {
        switch model.isLoaded {
        case false: return "The model is no longer loaded."
        case true: return "The model is still reported loaded."
        case nil: return "Loaded state is unknown; memory release could not be verified."
        }
    }
}

extension ModelHostProvider {
    var adapter: any ModelHostAdapter {
        switch self {
        case .ollama: return OllamaHostAdapter()
        case .lmStudio: return LMStudioHostAdapter()
        case .comfyUI: return ComfyUIHostAdapter()
        case .llamaCpp: return OpenAIHostAdapter(title: "llama.cpp", readsLlamaMetadata: true)
        case .openAICompatible: return OpenAIHostAdapter(title: "OpenAI-compatible", readsLlamaMetadata: false)
        }
    }

    var title: String { adapter.title }
    var defaultURL: String { adapter.defaultURL }
}

/// Bounded JSON reads from one validated host. Provider metadata stays optional when unreported.
struct HostReader: Sendable {
    let host: ModelHost
    let token: String?
    let http: HostHTTPClient
    static let maximumModels = 512

    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await http.request(host: host, path: path, method: method, body: body, token: token)
    }

    func object(_ path: String) async throws -> [String: Any] {
        guard let object = try Self.json(try await data(path)) as? [String: Any] else { throw HostHTTPError.invalidResponse }
        return object
    }

    static func json(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw HostHTTPError.invalidResponse }
    }

    static func records(_ value: Any?) throws -> [[String: Any]] {
        guard let records = value as? [[String: Any]], records.count <= maximumModels else { throw HostHTTPError.invalidResponse }
        return records
    }

    static func validateIDs(_ models: [HostedModel]) throws {
        guard models.count <= maximumModels, Set(models.map(\.modelID)).count == models.count else { throw HostHTTPError.invalidResponse }
    }

    static func identifier(_ value: Any?) throws -> String {
        guard let value = text(value), value.utf8.count <= 2048 else { throw HostHTTPError.invalidResponse }
        return value
    }

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value.rounded(.towardZero) == value, value < Double(Int64.max) else { return nil }
        return number.int64Value
    }

    static func int(_ value: Any?) -> Int? { integer(value).flatMap(Int.init(exactly:)) }
}
