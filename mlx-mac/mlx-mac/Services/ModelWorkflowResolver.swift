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
        qBits: Int = 4,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> WorkflowDestinationDecision {
        _ = now
        // Match the agent's companion classification, including filename evidence
        // for saved workflows whose source metadata was not persisted.
        let stem = URL(fileURLWithPath: source.path).deletingPathExtension().lastPathComponent.lowercased()
        if source.companion == true
            || ["clip", "mmproj"].contains(source.architecture?.lowercased() ?? "")
            || stem.contains("mmproj") || stem.contains("projector") {
            return .blocked(
                sameDirectoryOutputURL(for: source, qBits: qBits),
                reason: "This GGUF is a vision projector or companion file and cannot be converted as a standalone model. Select the main model GGUF or a supported Hugging Face source instead."
            )
        }
        let outputURL = sameDirectoryOutputURL(for: source, qBits: qBits)
        let outputPath = canonicalPath(outputURL.path)
        if fileManager.fileExists(atPath: outputPath) {
            return .blocked(
                URL(fileURLWithPath: outputPath),
                reason: "The destination already exists. Choose another precision or review the existing output."
            )
        }
        return .available(URL(fileURLWithPath: outputPath))
    }

    static func sameDirectoryOutputURL(for source: ModelItem, qBits: Int = 4) -> URL {
        let url = URL(fileURLWithPath: canonicalPath(source.path)).deletingPathExtension()
        return url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-MLX-\(qBits)bit")
    }

    private static func canonicalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        var unresolved = URL(fileURLWithPath: expanded).standardizedFileURL
        var trailingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: unresolved.path) {
            let parent = unresolved.deletingLastPathComponent()
            guard parent.path != unresolved.path else { break }
            trailingComponents.insert(unresolved.lastPathComponent, at: 0)
            unresolved = parent
        }

        var resolved = unresolved.resolvingSymlinksInPath()
        for component in trailingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

}
