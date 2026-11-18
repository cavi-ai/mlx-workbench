import Foundation

/// The engine's per-user list of models that may run on more than one endpoint.
struct DuplicationPolicy: Decodable, Equatable, Sendable {
    let allowlist: [String]
    let status: String?
    enum CodingKeys: String, CodingKey { case allowlist = "duplicate_model_allowlist", status }
}

/// One previewed allowlist change, bound to the policy it was previewed against.
struct DuplicationPolicyReview: Identifiable {
    let id = UUID()
    let current: [String]
    let proposed: [String]
    var added: [String] { proposed.filter { !current.contains($0) } }
    var removed: [String] { current.filter { !proposed.contains($0) } }
}

extension WorkbenchAPI {
    func duplicationPolicy() async throws -> DuplicationPolicy {
        try await duplicationPolicyCall([])
    }

    /// Resolves `models` to the exact allowlist a confirmation would save, without saving it.
    func previewDuplicationPolicy(models: [String]) async throws -> DuplicationPolicy {
        try await duplicationPolicyCall(try Self.duplicationSelection(models))
    }

    /// Replaces the allowlist with `models`; an empty list clears it.
    func confirmDuplicationPolicy(models: [String]) async throws -> DuplicationPolicy {
        try await duplicationPolicyCall(try Self.duplicationSelection(models) + ["--confirm"])
    }

    private static func duplicationSelection(_ models: [String]) throws -> [String] {
        guard models.count <= 256, Set(models).count == models.count,
              models.allSatisfy({ $0.hasPrefix("/") && !$0.contains("*") }) else {
            throw WorkflowEvidenceError.invalid("Choose up to 256 exact local models.")
        }
        return models.isEmpty ? ["--clear"] : models.flatMap { ["--allow-model", $0] }
    }

    private func duplicationPolicyCall(_ selection: [String]) async throws -> DuplicationPolicy {
        let data = try await raw(["serve", "duplication-policy"] + selection, timeout: 15, cancellable: true)
        return try JSONDecoder().decode(DuplicationPolicy.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

/// Settings' editor for the allowlist: the engine previews each change, the policy is read again, then the change is saved.
@MainActor
final class DuplicationPolicyCoordinator: ObservableObject {
    @Published private(set) var allowlist: [String]?
    @Published private(set) var review: DuplicationPolicyReview?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let api: WorkbenchAPI
    init(api: WorkbenchAPI) { self.api = api }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { allowlist = try await api.duplicationPolicy().allowlist; error = nil }
        catch { self.error = AppHost.render(error) }
    }

    func propose(adding model: String) async {
        await propose { $0.contains(model) ? $0 : $0 + [model] }
    }

    func propose(removing model: String) async {
        await propose { $0.filter { $0 != model } }
    }

    func cancelReview() {
        guard !busy else { return }
        review = nil
    }

    private func propose(_ change: ([String]) -> [String]) async {
        guard !busy else { return }
        busy = true; error = nil; review = nil
        defer { busy = false }
        do {
            let current = try await api.duplicationPolicy().allowlist
            allowlist = current
            let preview = try await api.previewDuplicationPolicy(models: change(current))
            guard preview.status == "preview" else { throw BridgeError.skillOutputUnreadable }
            guard preview.allowlist != current else { error = "The policy already matches this choice."; return }
            review = DuplicationPolicyReview(current: current, proposed: preview.allowlist)
        } catch { self.error = AppHost.render(error) }
    }

    /// Saves `review` only while the policy still equals the one it was previewed against.
    func confirm(_ review: DuplicationPolicyReview) async {
        guard !busy else { return }
        busy = true; error = nil; self.review = nil
        defer { busy = false }
        do {
            let current = try await api.duplicationPolicy().allowlist
            allowlist = current
            guard current == review.current else {
                error = "The policy changed after this review. Review the change again."
                return
            }
            let saved = try await api.confirmDuplicationPolicy(models: review.proposed).allowlist
            allowlist = saved
            if saved != review.proposed { error = "The saved policy differs from the review. Check the list." }
        } catch { self.error = AppHost.render(error) }
    }
}

enum DuplicationPolicyPresentation {
    struct Choice: Identifiable, Equatable {
        let name: String
        let path: String
        var id: String { path }
    }

    /// Library models with a local path, by name.
    static func choices(_ models: [LibraryModel]) -> [Choice] {
        var seen = Set<String>()
        return models.compactMap { model in
            let path = model.item.path
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return Choice(name: model.displayName, path: path)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What a confirmation saves, for the review dialog.
    static func reviewMessage(_ review: DuplicationPolicyReview, models: [LibraryModel]) -> String {
        func lines(_ paths: [String]) -> String {
            paths.map { MenuBarPresentation.modelName($0, models: models) + " · " + $0 }.joined(separator: "\n")
        }
        var parts: [String] = []
        if !review.added.isEmpty { parts.append("Allow on more than one endpoint:\n" + lines(review.added)) }
        if !review.removed.isEmpty { parts.append("Return to one endpoint:\n" + lines(review.removed)) }
        parts.append("Applies to endpoints started after this change. API keys and memory admission stay in effect.")
        return parts.joined(separator: "\n\n")
    }
}
