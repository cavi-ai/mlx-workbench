import Foundation
import Darwin

enum UseCase: String, CaseIterable, Codable, Identifiable {
    case coding = "coding"
    case generalChat = "general_chat"
    case reasoning = "reasoning"
    case vision = "vision"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coding:
            return "Coding"
        case .generalChat:
            return "General Chat"
        case .reasoning:
            return "Reasoning/Research"
        case .vision:
            return "Vision"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch normalizedToken(raw) {
        case "coding":
            self = .coding
        case "generalchat", "general":
            self = .generalChat
        case "reasoning", "reasoningresearch", "research":
            self = .reasoning
        case "vision":
            self = .vision
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown use case: \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ModelReadiness: String, CaseIterable, Codable, Identifiable {
    case ready = "ready"
    case needsConversion = "needs_conversion"
    case needsRuntime = "needs_runtime"
    case incompleteCache = "incomplete_cache"
    case unsupported = "unsupported"
    case duplicate = "duplicate"
    case quarantined = "quarantined"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .needsConversion:
            return "Needs Conversion"
        case .needsRuntime:
            return "Needs Runtime"
        case .incompleteCache:
            return "Incomplete Cache"
        case .unsupported:
            return "Unsupported"
        case .duplicate:
            return "Duplicate"
        case .quarantined:
            return "Quarantined"
        }
    }

    var isAvailable: Bool {
        self == .ready
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch normalizedToken(raw) {
        case "ready":
            self = .ready
        case "needsconversion", "conversionneeded", "needsconvert":
            self = .needsConversion
        case "needsruntime", "runtimemissing", "missingruntime":
            self = .needsRuntime
        case "incompletecache", "cacheincomplete":
            self = .incompleteCache
        case "unsupported", "unreadable":
            self = .unsupported
        case "duplicate", "redundant":
            self = .duplicate
        case "quarantined":
            self = .quarantined
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown model readiness: \(raw)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct HardwareProfile: Codable, Equatable, Hashable {
    let chip: String?
    let model: String?
    let memoryBytes: Int64?
    let macOSVersion: String?
    let summary: String

    init(chip: String? = nil, model: String? = nil, memoryBytes: Int64? = nil, macOSVersion: String? = nil, summary: String? = nil) {
        self.chip = chip?.trimmedNonEmpty
        self.model = model?.trimmedNonEmpty
        self.memoryBytes = memoryBytes
        self.macOSVersion = macOSVersion?.trimmedNonEmpty
        self.summary = summary ?? Self.makeSummary(chip: self.chip, model: self.model, memoryBytes: self.memoryBytes, macOSVersion: self.macOSVersion)
    }

    static func current() -> HardwareProfile {
        HardwareProfile(
            chip: currentChipText(),
            model: currentModelText(),
            memoryBytes: currentMemoryBytes(),
            macOSVersion: currentMacOSVersion()
        )
    }

    private static func currentChipText() -> String? {
        currentSysctlString("machdep.cpu.brand_string") ?? currentSysctlString("hw.machine")
    }

    private static func currentModelText() -> String? {
        currentSysctlString("hw.model")
    }

    private static func currentMemoryBytes() -> Int64? {
        currentSysctlInt64("hw.memsize")
    }

    private static func currentMacOSVersion() -> String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func makeSummary(chip: String?, model: String?, memoryBytes: Int64?, macOSVersion: String?) -> String {
        let chipText = chip ?? "Unknown chip"
        let modelText = model ?? "Unknown model"
        let memoryText = memoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "Unknown memory"
        let versionText = macOSVersion ?? "Unknown macOS"
        return "\(chipText) · \(modelText) · \(memoryText) · macOS \(versionText)"
    }
}

struct LibraryModel: Codable, Equatable, Hashable {
    let item: ModelItem
    let normalizedFamilyKey: String
    let displayName: String
    let readiness: ModelReadiness
    let capabilities: [UseCase]
    let sourcePaths: [String]
    let outputPaths: [String]
    let evidence: [String]

    var modelItem: ModelItem { item }
    var familyKey: String { normalizedFamilyKey }

    init(
        item: ModelItem,
        normalizedFamilyKey: String? = nil,
        displayName: String? = nil,
        readiness: ModelReadiness? = nil,
        capabilities: [UseCase]? = nil,
        sourcePaths: [String]? = nil,
        outputPaths: [String]? = nil,
        evidence: [String]? = nil
    ) {
        let derivedFamilyKey = normalizedFamilyKey ?? Self.normalizeFamilyKey(from: item)
        let derivedDisplayName = displayName ?? Self.makeDisplayName(from: item, normalizedFamilyKey: derivedFamilyKey)
        let derivedReadiness = readiness ?? Self.makeReadiness(from: item)
        let derivedCapabilities = capabilities ?? Self.makeCapabilities(from: item)
        let derivedSourcePaths = sourcePaths ?? Self.makeSourcePaths(from: item)
        let derivedOutputPaths = outputPaths ?? uniqueStrings(item.outputs)
        self.item = item
        self.normalizedFamilyKey = derivedFamilyKey
        self.displayName = derivedDisplayName
        self.readiness = derivedReadiness
        self.capabilities = derivedCapabilities
        self.sourcePaths = derivedSourcePaths
        self.outputPaths = derivedOutputPaths
        self.evidence = evidence ?? Self.makeEvidence(
            from: item,
            normalizedFamilyKey: derivedFamilyKey,
            displayName: derivedDisplayName,
            readiness: derivedReadiness,
            sourcePaths: derivedSourcePaths,
            outputPaths: derivedOutputPaths
        )
    }

    private static func normalizeFamilyKey(from item: ModelItem) -> String {
        let candidate = item.modelKey ?? item.architecture ?? item.name
        let token = normalizedToken(candidate)
        return token.isEmpty ? "unknown" : token
    }

    private static func makeDisplayName(from item: ModelItem, normalizedFamilyKey: String) -> String {
        if let trimmedName = item.name.trimmedNonEmpty {
            return trimmedName
        }
        return normalizedFamilyKey.isEmpty ? "Unknown model" : normalizedFamilyKey
    }

    private static func makeReadiness(from item: ModelItem) -> ModelReadiness {
        switch normalizedToken(item.status) {
        case "ready", "converted", "available":
            return .ready
        case "needsconversion", "pending", "queued":
            return .needsConversion
        case "needsruntime", "runtimemissing", "missingruntime":
            return .needsRuntime
        case "incompletecache", "cacheincomplete":
            return .incompleteCache
        case "unsupported", "unreadable":
            return .unsupported
        case "duplicate", "redundant":
            return .duplicate
        case "quarantined":
            return .quarantined
        default:
            if item.readable == false {
                return .unsupported
            }
            if item.outputs.isEmpty {
                return .needsConversion
            }
            if item.error != nil {
                return .incompleteCache
            }
            return .ready
        }
    }

    private static func makeCapabilities(from item: ModelItem) -> [UseCase] {
        let searchSpace = [
            item.name,
            item.modelKey,
            item.architecture,
            item.quantization,
            item.parameters,
            item.structure,
            item.signature,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        var cases: [UseCase] = [.generalChat]
        if containsAny(searchSpace, ["code", "coder", "coding", "starcoder", "codestral", "deepseek-coder", "qwen2.5-coder"]) {
            cases.append(.coding)
        }
        if containsAny(searchSpace, ["reason", "think", "research", "r1", "o1", "o3", "deepseek-reasoner"]) {
            cases.append(.reasoning)
        }
        if containsAny(searchSpace, ["vision", "vl", "multimodal", "llava", "pixtral", "phi-4", "gemma-3", "qwen2.5-vl"]) {
            cases.append(.vision)
        }
        return uniqueUseCases(cases)
    }

    private static func makeSourcePaths(from item: ModelItem) -> [String] {
        uniqueStrings([item.path, item.shard].compactMap { $0 })
    }

    private static func makeEvidence(
        from item: ModelItem,
        normalizedFamilyKey: String,
        displayName: String,
        readiness: ModelReadiness,
        sourcePaths: [String],
        outputPaths: [String]
    ) -> [String] {
        var evidence: [String] = [
            "path=\(item.path)",
            "status=\(item.status)",
            "family_key=\(normalizedFamilyKey)",
            "display_name=\(displayName)",
            "readiness=\(readiness.rawValue)",
            "source_count=\(sourcePaths.count)",
            "output_count=\(outputPaths.count)",
        ]
        if let architecture = item.architecture?.trimmedNonEmpty {
            evidence.append("architecture=\(architecture)")
        }
        if let quantization = item.quantization?.trimmedNonEmpty {
            evidence.append("quantization=\(quantization)")
        }
        if let parameters = item.parameters?.trimmedNonEmpty {
            evidence.append("parameters=\(parameters)")
        }
        if let tensorCount = item.tensorCount {
            evidence.append("tensor_count=\(tensorCount)")
        }
        if let error = item.error?.trimmedNonEmpty {
            evidence.append("error=\(error)")
        }
        return evidence
    }
}

struct ModelGroup: Codable, Equatable, Hashable {
    let normalizedModelKey: String
    let primaryDisplayName: String
    let variants: [LibraryModel]
    let totalBytes: Int64
    let duplicateBytes: Int64

    var modelKey: String { normalizedModelKey }

    init(variants: [LibraryModel], normalizedModelKey: String? = nil, primaryDisplayName: String? = nil) {
        let key = normalizedModelKey ?? variants.first?.normalizedFamilyKey ?? ""
        let totalBytes = variants.reduce(into: Int64(0)) { partialResult, variant in
            partialResult += variant.item.bytes
        }
        let primaryVariant = Self.primaryVariant(in: variants)
        self.normalizedModelKey = key
        self.primaryDisplayName = primaryDisplayName ?? primaryVariant?.displayName ?? key
        self.variants = variants
        self.totalBytes = totalBytes
        self.duplicateBytes = max(0, totalBytes - (primaryVariant?.item.bytes ?? 0))
    }

    private static func primaryVariant(in variants: [LibraryModel]) -> LibraryModel? {
        variants.max(by: { lhs, rhs in
            let lhsRank = lhs.readiness.rank
            let rhsRank = rhs.readiness.rank
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            if lhs.item.bytes != rhs.item.bytes {
                return lhs.item.bytes < rhs.item.bytes
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedDescending
        })
    }
}

struct LibrarySnapshot: Codable, Equatable, Hashable {
    let models: [LibraryModel]
    let groups: [ModelGroup]
    let hardware: HardwareProfile
    let totalBytes: Int64
    let reclaimableBytes: Int64
    let generatedAt: Date

    init(
        models: [LibraryModel],
        groups: [ModelGroup],
        hardware: HardwareProfile,
        totalBytes: Int64? = nil,
        reclaimableBytes: Int64? = nil,
        generatedAt: Date
    ) {
        self.models = models
        self.groups = groups
        self.hardware = hardware
        self.totalBytes = totalBytes ?? models.reduce(into: Int64(0)) { $0 += $1.item.bytes }
        self.reclaimableBytes = reclaimableBytes ?? groups.reduce(into: Int64(0)) { $0 += $1.duplicateBytes }
        self.generatedAt = generatedAt
    }
}

private extension ModelReadiness {
    var rank: Int {
        switch self {
        case .ready:
            return 0
        case .needsRuntime:
            return 1
        case .needsConversion:
            return 2
        case .incompleteCache:
            return 3
        case .unsupported:
            return 4
        case .duplicate:
            return 5
        case .quarantined:
            return 6
        }
    }
}

private func uniqueUseCases(_ useCases: [UseCase]) -> [UseCase] {
    var seen = Set<UseCase>()
    var ordered: [UseCase] = []
    for useCase in useCases where !seen.contains(useCase) {
        seen.insert(useCase)
        ordered.append(useCase)
    }
    return ordered
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for value in values {
        let trimmed = value.trimmedNonEmpty ?? value
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
        seen.insert(trimmed)
        ordered.append(trimmed)
    }
    return ordered
}

private func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
    needles.contains(where: { haystack.contains($0) })
}

private func normalizedToken(_ value: String) -> String {
    value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}

private func currentSysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        return nil
    }
    return String(cString: buffer)
}

private func currentSysctlInt64(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout.size(ofValue: value)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
        return nil
    }
    return value
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
