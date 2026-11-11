import AppKit
import SwiftUI
import XCTest
@testable import mlx_workbench

/// Hosts the real window shell (sidebar, toolbar, detail) in light and dark system appearance.
/// Captures run only when `MLX_WORKBENCH_RENDERS=1`.
@MainActor
final class ShellRenderTests: XCTestCase {
    private func makeHost() -> AppHost {
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", agentHealth: .notConfigured, runtimeReport: .checking)
        let models = ["Qwen3-8B-4bit", "Qwen3-8B-8bit", "Llama-3.2-3B-4bit"].map { name in
            LibraryModel(item: ModelItem(path: "/models/" + name, name: name, bytes: 5_000_000_000, modifiedAt: nil,
                shard: nil, modelKey: name, architecture: "qwen3", quantization: "4-bit", parameters: "8B", structure: nil,
                signature: "weights-" + name, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil))
        }
        host.librarySnapshot = LibrarySnapshot(models: models, groups: [], hardware: host.hardwareProfile, generatedAt: Date())
        return host
    }

    private func capture(route: AppRoute, size: CGSize, dark: Bool, expectedTitle: String) async throws {
        let suiteName = "shell-render-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        if route != .library { suite.set(route.rawValue, forKey: AppRoute.selectionStorageKey) }
        let hosting = NSHostingView(rootView: AnyView(ContentView(appHost: makeHost()).workbenchTheme().defaultAppStorage(suite)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        window.displayIfNeeded()
        XCTAssertEqual(window.title, expectedTitle)

        // The window's frame view includes the titlebar and toolbar when AppKit draws them.
        let target: NSView = window.contentView?.superview ?? hosting
        let bitmap = try XCTUnwrap(target.bitmapImageRepForCachingDisplay(in: target.bounds))
        target.cacheDisplay(in: target.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "shell-\(route == .library ? "library" : "settings")-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShellRendersLibraryAndSettingsInLightAndDark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        for dark in [false, true] {
            try await capture(route: .library, size: CGSize(width: 1440, height: 900), dark: dark, expectedTitle: "Library")
        }
        for dark in [false, true] {
            try await capture(route: .settings, size: CGSize(width: 740, height: 560), dark: dark, expectedTitle: "Settings")
        }
    }
}
