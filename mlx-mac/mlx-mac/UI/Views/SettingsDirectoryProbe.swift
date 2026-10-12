import Foundation

/// The only place Settings reads the file system. Views run it off the main
/// actor and store the results; presentation values never call it.
struct SettingsDirectoryProbe: Sendable {
    var state: @Sendable (String) -> SettingsDirectoryState

    static let live = SettingsDirectoryProbe { path in
        var isDirectory: ObjCBool = false
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .exists : .notDirectory
    }

    /// States keyed by the trimmed spelling the caller passed in; empty paths are skipped.
    func states(for paths: [String]) -> [String: SettingsDirectoryState] {
        var result: [String: SettingsDirectoryState] = [:]
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, result[path] == nil { result[path] = state(path) }
        }
        return result
    }
}
