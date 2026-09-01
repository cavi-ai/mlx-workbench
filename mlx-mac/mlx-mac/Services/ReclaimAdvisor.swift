import Foundation

// MARK: - ReclaimAdvisor
//
// Pure detectors for the Disk Pressure Advisor (premium spec 04). All inputs
// are supplied; the advisor never touches the filesystem or the network —
// apply goes through ReclaimCoordinator → Quarantine.

enum ReclaimAdvisor {
    static let defaultStaleDays = 60
    static let badgeThresholdBytes: Int64 = 20 * 1024 * 1024 * 1024

    static func opportunities(
        snapshot: LibrarySnapshot?,
        duplicates: [DuplicateGroup],
        lastUsedByPath: [String: Date],
        isVerified: (String) -> Bool,
        occupiedPaths: Set<String>,
        staleDays: Int = defaultStaleDays,
        now: Date = Date()
    ) -> [ReclaimOpportunity] {
        var found: [ReclaimOpportunity] = []
        found.append(contentsOf: crossRootDuplicates(duplicates))
        found.append(contentsOf: staleModels(
            snapshot: snapshot,
            lastUsedByPath: lastUsedByPath,
            occupiedPaths: occupiedPaths,
            staleDays: staleDays,
            now: now
        ))
        found.append(contentsOf: supersededVariants(
            snapshot: snapshot,
            isVerified: isVerified,
            occupiedPaths: occupiedPaths
        ))
        return found.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Cross-root duplicates (scan-computed)

    static func crossRootDuplicates(_ duplicates: [DuplicateGroup]) -> [ReclaimOpportunity] {
        duplicates.compactMap { group in
            let redundant = group.redundant ?? group.paths.filter { $0 != group.keep }
            guard !redundant.isEmpty else { return nil }
            return ReclaimOpportunity(
                kind: .crossRootDuplicate,
                paths: redundant,
                bytes: group.reclaimableBytes ?? 0,
                evidence: "Scan found \(redundant.count) redundant copie(s) of \(group.modelKey ?? "this model"); keep: \(group.keep ?? "unspecified")",
                confidence: .high,
                actionable: redundant.allSatisfy { $0.lowercased().hasSuffix(".gguf") }
            )
        }
    }

    // MARK: - Staleness

    static func staleModels(
        snapshot: LibrarySnapshot?,
        lastUsedByPath: [String: Date],
        occupiedPaths: Set<String>,
        staleDays: Int,
        now: Date
    ) -> [ReclaimOpportunity] {
        let cutoff = now.addingTimeInterval(-TimeInterval(staleDays) * 86_400)
        return (snapshot?.models ?? []).compactMap { model in
            let path = model.item.path
            guard !occupiedPaths.contains(path) else { return nil }
            guard model.readiness != .quarantined else { return nil }
            if let used = lastUsedByPath[path] {
                guard used < cutoff else { return nil }
                let days = Int(now.timeIntervalSince(used) / 86_400)
                return ReclaimOpportunity(
                    kind: .stale,
                    paths: [path],
                    bytes: model.item.bytes,
                    evidence: "Not served, verified, or measured in \(days) days.",
                    confidence: .high,
                    actionable: path.lowercased().hasSuffix(".gguf")
                )
            }
            // No usage evidence: fall back to file mtime at lower confidence.
            guard let modified = model.item.modifiedAt else { return nil }
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modified))
            guard modifiedDate < cutoff else { return nil }
            let days = Int(now.timeIntervalSince(modifiedDate) / 86_400)
            return ReclaimOpportunity(
                kind: .stale,
                paths: [path],
                bytes: model.item.bytes,
                evidence: "No recorded use; file last modified \(days) days ago.",
                confidence: .review,
                actionable: path.lowercased().hasSuffix(".gguf")
            )
        }
    }

    // MARK: - Superseded variants

    /// A variant is superseded when a sibling with the same model key is
    /// verified at equal or higher quant bits. Verified winners never
    /// supersede; unknown quant parses as 0 bits (most conservative).
    static func supersededVariants(
        snapshot: LibrarySnapshot?,
        isVerified: (String) -> Bool,
        occupiedPaths: Set<String>
    ) -> [ReclaimOpportunity] {
        let models = (snapshot?.models ?? []).filter {
            $0.item.modelKey != nil && $0.readiness == .ready
        }
        var byKey: [String: [LibraryModel]] = [:]
        for model in models { byKey[model.item.modelKey ?? "", default: []].append(model) }

        var found: [ReclaimOpportunity] = []
        for (_, group) in byKey where group.count > 1 {
            let verified = group.filter { isVerified($0.item.path) }
            guard let best = verified.max(by: { quantBits($0.item.quantization) < quantBits($1.item.quantization) }) else { continue }
            let bestBits = quantBits(best.item.quantization)
            for candidate in group {
                let path = candidate.item.path
                guard path != best.item.path,
                      !isVerified(path),
                      !occupiedPaths.contains(path),
                      quantBits(candidate.item.quantization) <= bestBits else { continue }
                found.append(ReclaimOpportunity(
                    kind: .supersededVariant,
                    paths: [path],
                    bytes: candidate.item.bytes,
                    evidence: "Superseded by verified sibling \(best.displayName) (\(best.item.quantization ?? "unknown quant")).",
                    confidence: .review,
                    actionable: path.lowercased().hasSuffix(".gguf")
                ))
            }
        }
        return found
    }

    /// First digit run in a quant string: "Q4_K_M" → 4, "8-bit" → 8,
    /// "fp16" → 16. Unknown → 0 (never wins a supersede comparison).
    static func quantBits(_ quantization: String?) -> Int {
        guard let quantization else { return 0 }
        var digits = ""
        for character in quantization {
            if character.isNumber { digits.append(character) }
            else if !digits.isEmpty { break }
        }
        return Int(digits) ?? 0
    }
}
