import Foundation

/// Related names suggest a review cohort; they never establish identical weights or purpose.
enum ModelFamilyReview {
    struct Group: Identifiable {
        let id: String
        let models: [LibraryModel]
    }

    static func groups(models: [LibraryModel], purposes: [ModelPurpose] = []) -> [Group] {
        Dictionary(grouping: models.filter { $0.readiness != .quarantined }, by: familyHint)
            .filter { $0.value.count > 1 || $0.value.contains { model in purposes.contains { $0.path == model.item.path } } }
            .map { Group(id: $0.key, models: $0.value.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func familyHint(_ model: LibraryModel) -> String {
        let name = NSString(string: model.displayName).lastPathComponent.lowercased()
        // Keep model generation, size and MoE active size distinct; tuning labels stay on each row.
        let pattern = #"^(.+?)[-_ ](\d+(?:\.\d+)?[bm](?:[-_ ]a\d+(?:\.\d+)?[bm])?)(?=$|[-_. ])"#
        if let range = name.range(of: pattern, options: .regularExpression) {
            return String(name[range]).replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        }
        return model.normalizedFamilyKey
    }

    static func reasons(for model: LibraryModel, purpose: ModelPurpose?, preferredRoles: [UseCase],
                        served: Bool, replacements: [ReclaimOpportunity]) -> [String] {
        var reasons: [String] = []
        if let purpose {
            reasons.append("Keep: \(purpose.note)")
            if purpose.signature != model.item.signature { reasons.append("Model identity changed since this purpose was saved; review it.") }
        }
        reasons += preferredRoles.sorted { $0.rawValue < $1.rawValue }.map { "Preferred for \($0.title)." }
        if served { reasons.append("Selected for serving to other apps.") }
        let kept = replacements.compactMap(\.replacement).filter { $0.keeper.path == model.item.path }
        reasons += kept.map { "Keep for \($0.task): comparable reviewed quality with no worse speed, latency, estimated memory or disk." }
        let replaced = replacements.compactMap(\.replacement).filter { $0.replaced.contains { $0.path == model.item.path } }
        reasons += replaced.map { "Removal candidate for \($0.task): \($0.keeper.name) covers this measured task. Review other uses first." }
        if reasons.isEmpty { reasons.append("No retention decision yet. Record its purpose or compare it on the tasks you need.") }
        return reasons
    }
}

struct FamilyComparisonRequest: Equatable, Identifiable {
    struct Entrant: Equatable { let path: String; let signature: String? }
    let id = UUID()
    let entrants: [Entrant]
    let mode: ComparisonMode

    init?(models: [LibraryModel]) {
        guard (2...ComparePresentation.maxSlots).contains(models.count),
              Set(models.map(\.item.path)).count == models.count,
              let mode = models.first.flatMap({ ComparisonMode.preferred(for: $0.item) }),
              models.allSatisfy({ $0.readiness == .ready && $0.item.signature?.isEmpty == false && mode.supports($0.item) }) else { return nil }
        entrants = models.map { Entrant(path: $0.item.path, signature: $0.item.signature) }
        self.mode = mode
    }

    func resolve(in models: [LibraryModel]) -> [LibraryModel]? {
        let resolved = entrants.compactMap { entrant in
            models.first { $0.item.path == entrant.path && $0.item.signature == entrant.signature && $0.readiness == .ready && mode.supports($0.item) }
        }
        return resolved.count == entrants.count ? resolved : nil
    }
}
