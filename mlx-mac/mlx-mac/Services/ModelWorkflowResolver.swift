import Foundation

enum WorkflowDestinationDecision: Equatable {
    case reuseExisting(LibraryModel)
    case available(URL)
    case blocked(URL, reason: String)
}

enum ModelWorkflowResolver {
    static func destination(
        for source: ModelItem,
        library: LibrarySnapshot?,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> WorkflowDestinationDecision {
        _ = now
        if let existing = library?.models.first(where: { matchesEquivalent(source: source, candidate: $0) }) {
            return .reuseExisting(existing)
        }

        let outputURL = sameDirectoryOutputURL(for: source)
        let outputPath = canonicalPath(outputURL.path)
        if fileManager.fileExists(atPath: outputPath) {
            return .blocked(
                URL(fileURLWithPath: outputPath),
                reason: "The destination already exists and is not an equivalent model."
            )
        }
        return .available(URL(fileURLWithPath: outputPath))
    }

    static func matchesEquivalent(source: ModelItem, candidate: LibraryModel) -> Bool {
        if let sourceKey = normalizedEvidence(source.modelKey),
           let candidateKey = normalizedEvidence(candidate.item.modelKey ?? candidate.normalizedFamilyKey) {
            if sourceKey == candidateKey {
                return true
            }
        }

        if let sourceSignature = normalizedEvidence(source.signature),
           let candidateSignature = normalizedEvidence(candidate.item.signature) {
            if sourceSignature == candidateSignature {
                return true
            }
        }

        let destinationPath = canonicalPath(sameDirectoryOutputURL(for: source).path)
        let candidatePaths = candidate.sourcePaths + candidate.outputPaths + [candidate.item.path]
        if candidatePaths.contains(where: { canonicalPath($0) == destinationPath }) {
            return true
        }

        let sourceIdentity = normalizedPathIdentity(URL(fileURLWithPath: canonicalPath(source.path)).deletingPathExtension().lastPathComponent)
        guard !sourceIdentity.isEmpty else { return false }
        return candidatePaths.contains {
            normalizedPathIdentity(URL(fileURLWithPath: canonicalPath($0)).lastPathComponent) == sourceIdentity
        }
    }

    static func sameDirectoryOutputURL(for source: ModelItem) -> URL {
        URL(fileURLWithPath: canonicalPath(source.path)).deletingPathExtension()
    }

    private static func canonicalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedEvidence(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedPathIdentity(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
