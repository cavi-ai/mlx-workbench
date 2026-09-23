import XCTest

/// Static checks over the SwiftUI sources so the design tokens stay the only
/// way to pick a font or a color, and routes stay typed.
final class DesignLintTests: XCTestCase {
    private struct Rule {
        let pattern: String
        let reason: String
        var allowedFiles: Set<String> = []
    }

    private static let rules: [Rule] = [
        Rule(pattern: ".font(.", reason: "raw text style; use WorkbenchTypography", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: "Font.system(", reason: "raw font; use WorkbenchTypography", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: "Color(nsColor:", reason: "raw AppKit color; use WorkbenchColor", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: "NSColor(hex", reason: "hex color literal; use WorkbenchColor"),
        Rule(pattern: ".foregroundColor(", reason: "use .foregroundStyle with a WorkbenchColor role"),
        Rule(pattern: ".foregroundStyle(.secondary", reason: "use WorkbenchColor.muted"),
        Rule(pattern: "onRouteSelection(\"", reason: "route passed as a string; use AppRoute"),
        Rule(pattern: "AnyView(", reason: "type erasure in the view tree; use @ViewBuilder"),
    ]

    private static var uiDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // mlx-macTests
            .deletingLastPathComponent()   // mlx-mac (project dir)
            .appendingPathComponent("mlx-mac/UI", isDirectory: true)
    }

    private func swiftSources() throws -> [URL] {
        let directory = Self.uiDirectory
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue,
            "UI source directory not found at \(directory.path)"
        )
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    func testUISourcesUseDesignTokensAndTypedRoutes() throws {
        let sources = try swiftSources()
        XCTAssertGreaterThan(sources.count, 10, "expected the UI sources to be enumerated")

        var violations: [String] = []
        for file in sources {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                for rule in Self.rules where !rule.allowedFiles.contains(name) {
                    if line.contains(rule.pattern) {
                        violations.append("\(name):\(offset + 1): \(rule.reason) — \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Design lint violations:\n" + violations.joined(separator: "\n"))
    }
}
