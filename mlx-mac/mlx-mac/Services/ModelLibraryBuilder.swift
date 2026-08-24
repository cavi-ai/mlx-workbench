import Foundation

enum ModelLibraryBuilder {
    static func build(scan: ScanResult, hardware: HardwareProfile, now: Date) -> LibrarySnapshot {
        let duplicatePaths = redundantDuplicatePaths(in: scan.duplicates)
        let pendingPaths = Set(scan.pending)
        let models = buildModels(
            scan: scan,
            duplicatePaths: duplicatePaths,
            pendingPaths: pendingPaths
        )
        let groups = buildGroups(from: models)
        let pathBytes = uniquePathBytes(for: scan.models)

        return LibrarySnapshot(
            models: models,
            groups: groups,
            hardware: hardware,
            totalBytes: pathBytes.values.reduce(0, +),
            reclaimableBytes: reclaimableBytes(
                duplicates: scan.duplicates,
                pathBytes: pathBytes
            ),
            generatedAt: now
        )
    }

    private static func buildModels(
        scan: ScanResult,
        duplicatePaths: Set<String>,
        pendingPaths: Set<String>
    ) -> [LibraryModel] {
        let ggufModels = scan.models.map { item in
            LibraryModel(
                item: item,
                normalizedFamilyKey: normalizedFamilyKey(
                    modelKey: item.modelKey,
                    path: item.path,
                    fallbackName: item.name
                ),
                displayName: displayName(path: item.path, fallbackName: item.name),
                readiness: readiness(
                    for: item,
                    duplicatePaths: duplicatePaths,
                    pendingPaths: pendingPaths
                )
            )
        }
        let outputModels = scan.outputs.map { output in
            let item = ModelItem(
                path: output.path,
                name: output.name,
                bytes: 0,
                modifiedAt: nil,
                shard: nil,
                modelKey: output.modelKey,
                architecture: nil,
                quantization: output.quantization.map { "q\($0.bits)" },
                parameters: nil,
                structure: nil,
                signature: output.provenance,
                companion: nil,
                readable: true,
                status: "ready",
                outputs: [output.path],
                tensorCount: nil,
                error: nil
            )
            return LibraryModel(
                item: item,
                normalizedFamilyKey: normalizedFamilyKey(
                    modelKey: output.modelKey,
                    path: output.path,
                    fallbackName: output.name
                ),
                displayName: displayName(path: output.path, fallbackName: output.name),
                readiness: .ready,
                sourcePaths: [output.path],
                outputPaths: [output.path],
                evidence: outputEvidence(for: output)
            )
        }

        return (ggufModels + outputModels).sorted(by: modelSort)
    }

    private static func buildGroups(from models: [LibraryModel]) -> [ModelGroup] {
        Dictionary(grouping: models, by: \.normalizedFamilyKey)
            .map { key, variants in
                ModelGroup(
                    variants: variants.sorted(by: modelSort),
                    normalizedModelKey: key
                )
            }
            .sorted(by: groupSort)
    }

    private static func outputEvidence(for output: MLXOutput) -> [String] {
        var evidence = [
            "path=\(output.path)",
            "status=ready",
            "origin=mlx_output",
        ]
        if let modelKey = output.modelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !modelKey.isEmpty {
            evidence.append("model_key=\(modelKey)")
        }
        if let provenance = output.provenance?.trimmingCharacters(in: .whitespacesAndNewlines), !provenance.isEmpty {
            evidence.append("provenance=\(provenance)")
        }
        if let quantization = output.quantization {
            evidence.append("quant_bits=\(quantization.bits)")
        }
        return evidence
    }

    private static func readiness(
        for item: ModelItem,
        duplicatePaths: Set<String>,
        pendingPaths: Set<String>
    ) -> ModelReadiness {
        let status = normalizedToken(item.status)

        if status.contains("quarantine") || item.path.localizedCaseInsensitiveContains("/quarantine/") {
            return .quarantined
        }
        if item.readable == false || !(item.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return .unsupported
        }
        if !(item.shard?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || ["incompletecache", "cacheincomplete", "incomplete", "partial", "shard"].contains(status) {
            return .incompleteCache
        }
        if ["missingruntime", "needsruntime", "runtimemissing"].contains(status) {
            return .needsRuntime
        }
        if duplicatePaths.contains(item.path) {
            return .duplicate
        }
        if ["ready", "converted", "available"].contains(status) || !item.outputs.isEmpty {
            return .ready
        }
        if pendingPaths.contains(item.path) || ["needsconversion", "pending", "queued", "conversionpending"].contains(status) {
            return .needsConversion
        }
        return .unsupported
    }

    private static func reclaimableBytes(
        duplicates: [DuplicateGroup],
        pathBytes: [String: Int64]
    ) -> Int64 {
        var countedPaths = Set<String>()
        var total: Int64 = 0

        for group in duplicates {
            let redundantPaths = candidateRedundantPaths(in: group)
            var usedKnownPathBytes = false

            for path in redundantPaths where countedPaths.insert(path).inserted {
                if let bytes = pathBytes[path] {
                    total += bytes
                    usedKnownPathBytes = true
                }
            }

            if !usedKnownPathBytes, let fallback = group.reclaimableBytes {
                total += max(0, fallback)
            }
        }

        return total
    }

    private static func uniquePathBytes(for items: [ModelItem]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for item in items where result[item.path] == nil {
            result[item.path] = item.bytes
        }
        return result
    }

    private static func redundantDuplicatePaths(in groups: [DuplicateGroup]) -> Set<String> {
        Set(groups.flatMap(candidateRedundantPaths))
    }

    private static func candidateRedundantPaths(in group: DuplicateGroup) -> [String] {
        let keep = group.keep?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPaths = (group.redundant ?? group.paths).filter { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return trimmed != keep
        }
        return uniqueStrings(rawPaths)
    }

    private static func normalizedFamilyKey(modelKey: String?, path: String, fallbackName: String) -> String {
        if let modelKey = modelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !modelKey.isEmpty {
            return normalizedToken(modelKey)
        }

        let pathCandidate = normalizedToken(cleanedFamilyStem(from: path))
        if !pathCandidate.isEmpty {
            return pathCandidate
        }

        let nameCandidate = normalizedToken(cleanedFamilyStem(from: fallbackName))
        if !nameCandidate.isEmpty {
            return nameCandidate
        }

        return normalizedToken(path)
    }

    private static func displayName(path: String, fallbackName: String) -> String {
        let trimmedName = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let stem = cleanedFamilyStem(from: path)
        return stem.isEmpty ? path : stem
    }

    private static func cleanedFamilyStem(from rawValue: String) -> String {
        let pathComponent = URL(fileURLWithPath: rawValue).lastPathComponent
        let base = pathComponent.isEmpty ? rawValue : pathComponent
        let withoutExtension = stripKnownExtensions(from: base)
        let withoutShard = withoutExtension.replacingOccurrences(
            of: #"(?i)([-_.]?\d{5}-of-\d{5})$"#,
            with: "",
            options: .regularExpression
        )
        let withoutQuantization = withoutShard.replacingOccurrences(
            of: #"(?i)([-_. ](?:q\d+(?:_[a-z0-9]+)*|iq\d+(?:_[a-z0-9]+)*|bf16|f16|fp16|fp32|int4|int8|4bit|8bit))+$"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = withoutQuantization.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return trimmed.isEmpty ? withoutExtension : trimmed
    }

    private static func stripKnownExtensions(from value: String) -> String {
        var current = value
        let knownExtensions = [".gguf", ".safetensors", ".bin", ".json"]
        while let ext = knownExtensions.first(where: { current.lowercased().hasSuffix($0) }) {
            current.removeLast(ext.count)
        }
        return current
    }

    private static func modelSort(lhs: LibraryModel, rhs: LibraryModel) -> Bool {
        let displayOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayOrder != .orderedSame {
            return displayOrder == .orderedAscending
        }
        return lhs.item.path < rhs.item.path
    }

    private static func groupSort(lhs: ModelGroup, rhs: ModelGroup) -> Bool {
        let displayOrder = lhs.primaryDisplayName.localizedCaseInsensitiveCompare(rhs.primaryDisplayName)
        if displayOrder != .orderedSame {
            return displayOrder == .orderedAscending
        }
        return primaryPath(for: lhs) < primaryPath(for: rhs)
    }

    private static func primaryPath(for group: ModelGroup) -> String {
        group.variants.first?.item.path ?? ""
    }
}

private func normalizedToken(_ value: String) -> String {
    value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
        ordered.append(trimmed)
    }
    return ordered
}
