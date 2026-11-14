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
        found.insert(contentsOf: measuredSuperseded, at: 0)
        let keepers = Set(measuredSuperseded.compactMap { $0.replacement?.keeper.path })
            .union(duplicates.filter { $0.kind == "exact" }.compactMap(\.keep))
        var seen = Set(measuredSuperseded.flatMap(\.paths))
        // Preserve distinct task reviews, and never offer their retained models as stale files.
        return found.filter { opportunity in
            if opportunity.replacement != nil {
                return opportunity.paths.allSatisfy { !occupiedPaths.contains($0) }
            }
            guard opportunity.paths.allSatisfy({ !occupiedPaths.contains($0) && !seen.contains($0) }) else { return false }
            guard opportunity.paths.allSatisfy({ !keepers.contains($0) }) else { return false }
            seen.formUnion(opportunity.paths)
            return true
        }.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Cross-root duplicates (scan-computed)

    static func crossRootDuplicates(_ duplicates: [DuplicateGroup]) -> [ReclaimOpportunity] {
        duplicates.compactMap { group in
            guard group.kind == "exact", let keep = group.keep, !keep.isEmpty,
                  let redundant = group.redundant, !redundant.isEmpty,
                  !redundant.contains(keep), Set(redundant).count == redundant.count,
                  let bytes = group.reclaimableBytes, bytes > 0 else { return nil }
            return ReclaimOpportunity(
                kind: .crossRootDuplicate,
                paths: redundant,
                bytes: bytes,
                evidence: "Scan found \(redundant.count) redundant copies of \(group.modelKey ?? "this model"); keep: \(keep)",
                confidence: .high,
                actionable: redundant.allSatisfy { $0.lowercased().hasSuffix(".gguf") }
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
