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
        now: Date = Date(),
        measuredSuperseded: [ReclaimOpportunity] = []
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
        found.insert(contentsOf: measuredSuperseded, at: 0)
        var seen = Set<String>()
        // A path contributes once. Keep task-specific review evidence ahead of generic age advice.
        return found.filter { opportunity in
            guard opportunity.paths.allSatisfy({ !occupiedPaths.contains($0) && !seen.contains($0) }) else { return false }
            seen.formUnion(opportunity.paths)
            return true
        }.sorted { $0.bytes > $1.bytes }
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

    /// Compatibility helper: quantization and verification alone cannot
    /// establish task quality. Evidence-backed replacement reviews come
    /// from ComparisonInsights and are supplied to opportunities explicitly.
    static func supersededVariants(
        snapshot: LibrarySnapshot?,
        isVerified: (String) -> Bool,
        occupiedPaths: Set<String>
    ) -> [ReclaimOpportunity] {
        // Verification and quantization alone are not evidence of task quality.
        return []
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
